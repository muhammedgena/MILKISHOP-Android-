-- MILKISHOP: allow an administrator to record a reason when rejecting a seller commission receipt.
-- Draft migration only. Apply in a reviewed non-production environment first.

alter table public.mp_commission_payments
  add column if not exists rejection_reason text;

alter table public.mp_commission_payments
  add constraint mp_commission_payments_rejection_reason_length
  check (
    rejection_reason is null
    or char_length(trim(rejection_reason)) between 10 and 500
  ) not valid;

alter table public.mp_commission_payments
  validate constraint mp_commission_payments_rejection_reason_length;
