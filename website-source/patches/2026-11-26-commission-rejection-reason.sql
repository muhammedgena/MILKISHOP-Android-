-- MILKISHOP: allow an administrator to record a reason when rejecting a seller commission receipt.
-- Draft migration only. Apply in a reviewed non-production environment first.
-- Safe to re-run: the column and named constraint are guarded.

alter table public.mp_commission_payments
  add column if not exists rejection_reason text;

do $migration$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.mp_commission_payments'::regclass
      and conname = 'mp_commission_payments_rejection_reason_length'
  ) then
    alter table public.mp_commission_payments
      add constraint mp_commission_payments_rejection_reason_length
      check (
        rejection_reason is null
        or char_length(trim(rejection_reason)) between 10 and 500
      ) not valid;
  end if;
end;
$migration$;

-- Validation intentionally fails if pre-existing values violate the rule.
alter table public.mp_commission_payments
  validate constraint mp_commission_payments_rejection_reason_length;

-- Rejected commission receipts must always carry a meaningful reason.
do $migration$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.mp_commission_payments'::regclass
      and conname = 'mp_commission_payments_rejected_reason_required'
  ) then
    alter table public.mp_commission_payments
      add constraint mp_commission_payments_rejected_reason_required
      check (
        status is distinct from 'rejected'
        or (
          rejection_reason is not null
          and char_length(trim(rejection_reason)) between 10 and 500
        )
      ) not valid;
  end if;
end;
$migration$;

alter table public.mp_commission_payments
  validate constraint mp_commission_payments_rejected_reason_required;

-- Review commission receipts through a single server-side authorization boundary.
create or replace function public.mp_admin_review_commission_payment(
  p_payment_id uuid,
  p_status text,
  p_rejection_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_admin_id uuid;
  v_payment public.mp_commission_payments%rowtype;
  v_reason text := nullif(trim(coalesce(p_rejection_reason, '')), '');
begin
  if auth.uid() is null
     or lower(coalesce(auth.jwt() ->> 'email','')) <> 'mohammedgena@gmail.com' then
    raise exception 'Not authorized to review commission payments' using errcode = '42501';
  end if;

  if p_status is null or p_status not in ('verified','rejected') then
    raise exception 'Status must be verified or rejected' using errcode = '22023';
  end if;

  if p_status = 'rejected'
     and (v_reason is null or char_length(v_reason) < 10 or char_length(v_reason) > 500) then
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
  from public.mp_commission_payments
  where id = p_payment_id
  for update;
  if not found then
    raise exception 'Commission receipt not found' using errcode = 'P0002';
  end if;
  if v_payment.status not in ('submitted','under_review') then
    raise exception 'This commission receipt is no longer awaiting review' using errcode = '55000';
  end if;

  update public.mp_commission_payments
  set status = p_status,
      rejection_reason = case when p_status = 'rejected' then v_reason else null end,
      verified_by = case when p_status = 'verified' then v_admin_id else null end,
      verified_at = case when p_status = 'verified' then now() else null end,
      updated_at = now()
  where id = p_payment_id;

  return jsonb_build_object(
    'success', true,
    'payment_id', p_payment_id,
    'status', p_status,
    'rejection_reason', case when p_status = 'rejected' then v_reason else null end
  );
end;
$function$;

revoke all on function public.mp_admin_review_commission_payment(uuid,text,text) from public, anon;
grant execute on function public.mp_admin_review_commission_payment(uuid,text,text) to authenticated;
