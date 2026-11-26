-- MILKISHOP: make delivery-worker state transitions atomic and payment-gated.
-- Apply only in a disposable/non-production Supabase project first.
-- This migration does not change existing orders, payments, or assignments.

create or replace function public.mp_update_delivery_job(
  p_assignment_id uuid,
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid;
  v_assignment public.mp_delivery_assignments%rowtype;
  v_order public.mp_orders%rowtype;
  v_order_code text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select u.id
    into v_user_id
  from public.mp_users u
  join public.mp_delivery_profiles d on d.user_id = u.id
  where u.auth_user_id = auth.uid()
    and d.active = true
  limit 1;

  if v_user_id is null then
    raise exception 'Register as an active delivery worker first' using errcode = '42501';
  end if;

  if p_status is null or p_status not in ('picked_up', 'delivered', 'cancelled') then
    raise exception 'Invalid delivery status' using errcode = '22023';
  end if;

  -- Lock the assignment and order so concurrent requests cannot split the transition.
  select *
    into v_assignment
  from public.mp_delivery_assignments
  where id = p_assignment_id
    and delivery_user_id = v_user_id
  for update;

  if not found then
    raise exception 'Delivery assignment not found' using errcode = 'P0002';
  end if;

  select *
    into v_order
  from public.mp_orders
  where id = v_assignment.order_id
  for update;

  if not found then
    raise exception 'Order not found' using errcode = 'P0002';
  end if;

  if v_order.fulfillment_method <> 'delivery' then
    raise exception 'This order is not a delivery order' using errcode = '55000';
  end if;

  if not exists (
    select 1
    from public.mp_payments p
    where p.order_id = v_order.id
      and p.status = 'verified'
  ) then
    raise exception 'A verified customer payment receipt is required' using errcode = '55000';
  end if;

  if p_status = 'picked_up' then
    if v_assignment.status <> 'assigned' then
      raise exception 'Only an assigned delivery can be picked up' using errcode = '55000';
    end if;
    if v_order.status not in ('paid', 'processing', 'ready_for_pickup') then
      raise exception 'Order is not in a pickup-eligible paid state' using errcode = '55000';
    end if;

    update public.mp_delivery_assignments
       set status = 'picked_up', updated_at = now()
     where id = v_assignment.id;

    update public.mp_orders
       set status = 'out_for_delivery', updated_at = now()
     where id = v_order.id;

  elsif p_status = 'delivered' then
    if v_assignment.status <> 'picked_up' then
      raise exception 'Pick up the order before marking it delivered' using errcode = '55000';
    end if;
    if v_order.status <> 'out_for_delivery' then
      raise exception 'Order must be out for delivery before completion' using errcode = '55000';
    end if;

    update public.mp_delivery_assignments
       set status = 'delivered', updated_at = now()
     where id = v_assignment.id;

    update public.mp_orders
       set status = 'completed', updated_at = now()
     where id = v_order.id;

  else
    -- A delivery worker may cancel only before pickup. The paid order remains
    -- paid so an administrator can reassign it; no payment/order history is erased.
    if v_assignment.status <> 'assigned' then
      raise exception 'A delivery can only be cancelled before pickup' using errcode = '55000';
    end if;
    if v_order.status not in ('paid', 'processing', 'ready_for_pickup') then
      raise exception 'Order is not in a cancellable delivery state' using errcode = '55000';
    end if;

    update public.mp_delivery_assignments
       set status = 'cancelled', updated_at = now()
     where id = v_assignment.id;
  end if;

  select order_code
    into v_order_code
  from public.mp_orders
  where id = v_order.id;

  return jsonb_build_object(
    'success', true,
    'order_code', v_order_code,
    'status', p_status
  );
end;
$function$;

revoke all on function public.mp_update_delivery_job(uuid, text) from public;
revoke all on function public.mp_update_delivery_job(uuid, text) from anon;
grant execute on function public.mp_update_delivery_job(uuid, text) to authenticated;
