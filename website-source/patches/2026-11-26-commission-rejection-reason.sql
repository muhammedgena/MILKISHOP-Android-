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
