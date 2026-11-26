-- MILKISHOP: move administrator delivery writes into server-validated atomic RPCs.
-- Draft migration: apply and test only in a non-production Supabase environment first.

create or replace function public.mp_admin_save_delivery_assignment(
  p_order_id uuid,
  p_provider_name text,
  p_provider_phone text,
  p_fee_etb numeric
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_admin_id uuid;
  v_order public.mp_orders%rowtype;
  v_assignment public.mp_delivery_assignments%rowtype;
begin
  if auth.uid() is null
     or lower(coalesce(auth.jwt() ->> 'email','')) <> 'mohammedgena@gmail.com' then
    raise exception 'Not authorized to manage delivery assignments' using errcode = '42501';
  end if;

  select id into v_admin_id
  from public.mp_users
  where auth_user_id = auth.uid()
  limit 1;

  if v_admin_id is null then
    raise exception 'Admin profile not found' using errcode = 'P0002';
  end if;

  if length(trim(coalesce(p_provider_name,''))) not between 2 and 120 then
    raise exception 'Delivery provider name must be 2–120 characters' using errcode = '22023';
  end if;
  if length(trim(coalesce(p_provider_phone,''))) not between 5 and 30 then
    raise exception 'Delivery provider phone must be 5–30 characters' using errcode = '22023';
  end if;
  if p_fee_etb is null or p_fee_etb < 0 or p_fee_etb <> trunc(p_fee_etb) then
    raise exception 'Delivery fee must be a whole number of zero or more' using errcode = '22023';
  end if;

  select * into v_order
  from public.mp_orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'Order not found' using errcode = 'P0002';
  end if;
  if v_order.fulfillment_method <> 'delivery' then
    raise exception 'Pickup orders cannot be assigned for delivery' using errcode = '55000';
  end if;
  if v_order.status not in ('paid','processing','ready_for_pickup') then
    raise exception 'Order is not in a state that can be assigned for delivery' using errcode = '55000';
  end if;
  if not exists (
    select 1 from public.mp_payments p
    where p.order_id = p_order_id and p.status = 'verified'
  ) then
    raise exception 'A verified customer payment receipt is required' using errcode = '55000';
  end if;

  select * into v_assignment
  from public.mp_delivery_assignments
  where order_id = p_order_id
  for update;

  if found then
    if v_assignment.status not in ('assigned','pending','cancelled') then
      raise exception 'A delivery that has started or finished cannot be reassigned' using errcode = '55000';
    end if;
    update public.mp_delivery_assignments
    set provider_name = trim(p_provider_name),
        provider_phone = trim(p_provider_phone),
        fee_etb = p_fee_etb,
        status = 'assigned',
        updated_at = now()
    where id = v_assignment.id
    returning * into v_assignment;
  else
    insert into public.mp_delivery_assignments(
      order_id, provider_name, provider_phone, fee_etb, status
    )
    values (
      p_order_id, trim(p_provider_name), trim(p_provider_phone), p_fee_etb, 'assigned'
    )
    returning * into v_assignment;
  end if;

  return jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'assignment_id', v_assignment.id,
    'status', v_assignment.status
  );
end;
$function$;

create or replace function public.mp_admin_update_delivery_status(
  p_order_id uuid,
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_admin_id uuid;
  v_order public.mp_orders%rowtype;
  v_assignment public.mp_delivery_assignments%rowtype;
  v_next_order_status text;
begin
  if auth.uid() is null
     or lower(coalesce(auth.jwt() ->> 'email','')) <> 'mohammedgena@gmail.com' then
    raise exception 'Not authorized to update delivery status' using errcode = '42501';
  end if;

  select id into v_admin_id
  from public.mp_users
  where auth_user_id = auth.uid()
  limit 1;

  if v_admin_id is null then
    raise exception 'Admin profile not found' using errcode = 'P0002';
  end if;

  if p_status not in ('picked_up','delivered') then
    raise exception 'Status must be picked_up or delivered' using errcode = '22023';
  end if;

  select * into v_order
  from public.mp_orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'Order not found' using errcode = 'P0002';
  end if;
  if v_order.fulfillment_method <> 'delivery' then
    raise exception 'Pickup orders do not have delivery status' using errcode = '55000';
  end if;
  if not exists (
    select 1 from public.mp_payments p
    where p.order_id = p_order_id and p.status = 'verified'
  ) then
    raise exception 'A verified customer payment receipt is required' using errcode = '55000';
  end if;

  select * into v_assignment
  from public.mp_delivery_assignments
  where order_id = p_order_id
  for update;

  if not found then
    raise exception 'Save a delivery assignment first' using errcode = 'P0002';
  end if;

  if p_status = 'picked_up' then
    if v_assignment.status <> 'assigned'
       or v_order.status not in ('paid','processing','ready_for_pickup') then
      raise exception 'Only an assigned, paid delivery order can be picked up' using errcode = '55000';
    end if;
    v_next_order_status := 'out_for_delivery';
  else
    if v_assignment.status <> 'picked_up'
       or v_order.status <> 'out_for_delivery' then
      raise exception 'The delivery must be picked up before it can be completed' using errcode = '55000';
    end if;
    v_next_order_status := 'completed';
  end if;

  -- Both state changes occur in this transaction; either both commit or neither does.
  update public.mp_delivery_assignments
  set status = p_status, updated_at = now()
  where id = v_assignment.id;

  update public.mp_orders
  set status = v_next_order_status, updated_at = now()
  where id = p_order_id;

  return jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'assignment_id', v_assignment.id,
    'assignment_status', p_status,
    'order_status', v_next_order_status
  );
end;
$function$;

revoke all on function public.mp_admin_save_delivery_assignment(uuid,text,text,numeric) from public, anon;
revoke all on function public.mp_admin_update_delivery_status(uuid,text) from public, anon;
grant execute on function public.mp_admin_save_delivery_assignment(uuid,text,text,numeric) to authenticated;
grant execute on function public.mp_admin_update_delivery_status(uuid,text) to authenticated;
