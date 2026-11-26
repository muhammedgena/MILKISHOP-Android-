-- MILKISHOP: record an admin-provided reason when rejecting a customer payment receipt.
-- Apply only after reviewing the draft PR and backing up production data.

alter table public.mp_payments
  add column if not exists rejection_reason text;

-- Replace the old two-argument RPC so rejection cannot bypass the reason requirement.
drop function if exists public.mp_admin_review_customer_payment(uuid, text);

create function public.mp_admin_review_customer_payment(
  p_payment_id uuid,
  p_status text,
  p_rejection_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_admin_id uuid;
  v_payment public.mp_payments%rowtype;
  v_order public.mp_orders%rowtype;
  v_reason text := nullif(trim(coalesce(p_rejection_reason, '')), '');
begin
  if auth.uid() is null
     or lower(coalesce(auth.jwt() ->> 'email','')) <> 'mohammedgena@gmail.com' then
    raise exception 'Not authorized to review customer payments' using errcode = '42501';
  end if;

  if p_status not in ('verified','rejected') then
    raise exception 'Status must be verified or rejected' using errcode = '22023';
  end if;

  if p_status = 'rejected' and (v_reason is null or char_length(v_reason) < 10 or char_length(v_reason) > 500) then
    raise exception 'A rejection reason between 10 and 500 characters is required' using errcode = '22023';
  end if;

  select id into v_admin_id
  from public.mp_users
  where auth_user_id = auth.uid()
  limit 1;

  if v_admin_id is null then
    raise exception 'Admin profile not found' using errcode = 'P0002';
  end if;

  select * into v_payment
  from public.mp_payments
  where id = p_payment_id
  for update;

  if not found then
    raise exception 'Payment receipt not found' using errcode = 'P0002';
  end if;

  if v_payment.status not in ('submitted','under_review') then
    raise exception 'This receipt is no longer awaiting review' using errcode = '55000';
  end if;

  select * into v_order
  from public.mp_orders
  where id = v_payment.order_id
  for update;

  if not found then
    raise exception 'Order not found' using errcode = 'P0002';
  end if;

  if v_order.status <> 'awaiting_payment' then
    raise exception 'Order is not awaiting payment' using errcode = '55000';
  end if;

  if p_status = 'verified' then
    if v_payment.method <> 'cash_on_pickup'
       and (nullif(trim(coalesce(v_payment.transaction_reference,'')),'') is null
         or lower(trim(v_payment.transaction_reference)) in ('reference','txn_reference','txn reference','test','demo','123456')) then
      raise exception 'A valid transaction reference is required' using errcode = '22023';
    end if;
    if v_payment.amount_etb <> v_order.subtotal_etb then
      raise exception 'Payment amount does not match the order subtotal' using errcode = '22023';
    end if;
  end if;

  update public.mp_payments
  set status = p_status,
      rejection_reason = case when p_status = 'rejected' then v_reason else null end,
      verified_by = case when p_status = 'verified' then v_admin_id else null end,
      verified_at = case when p_status = 'verified' then now() else null end
  where id = p_payment_id;

  if p_status = 'verified' then
    update public.mp_orders
    set status = 'paid', updated_at = now()
    where id = v_payment.order_id and status = 'awaiting_payment';
    if not found then
      raise exception 'Order status changed during verification' using errcode = '40001';
    end if;
  end if;

  return jsonb_build_object(
    'success', true,
    'payment_id', p_payment_id,
    'status', p_status,
    'rejection_reason', case when p_status = 'rejected' then v_reason else null end,
    'order_id', v_payment.order_id
  );
end;
$function$;

revoke all on function public.mp_admin_review_customer_payment(uuid, text, text) from public;
revoke all on function public.mp_admin_review_customer_payment(uuid, text, text) from anon;
grant execute on function public.mp_admin_review_customer_payment(uuid, text, text) to authenticated;
