# MILKISHOP workflow test checklist

Run in a non-production Supabase project and Vercel preview only. Do not use real transfers or alter production order history.

## Customer payment receipts
- [ ] Admin rejects a receipt with a 9-character reason: the UI refuses it.
- [ ] Admin rejects a receipt with a 10–500 character reason: status and reason are saved.
- [ ] Admin receipt list displays the saved reason.
- [ ] The customer who owns the order sees the rejection reason in order history.
- [ ] Existing rejected receipts with no reason show the legacy fallback; no reason is fabricated.
- [ ] A valid verified receipt changes an awaiting-payment order to paid.
- [ ] A delivery order receipt must equal subtotal plus delivery fee; a subtotal-only amount is rejected when a delivery fee applies.
- [ ] Placeholder transaction references cannot be verified.

## Seller commission
- [ ] Seller commission due excludes orders without a verified customer receipt.
- [ ] A completed order with a rejected receipt is excluded from commission due.
- [ ] Commission rates are read from each order's stored commission_rate, not a hardcoded display value.
- [ ] Verified seller commission receipts reduce the outstanding balance.
- [ ] Rejecting a seller commission receipt requires a 10–500 character reason.
- [ ] Commission receipt review uses the `mp_admin_review_commission_payment` RPC; direct client-side table updates are not used.
- [ ] Unauthenticated and non-admin users cannot call the commission review RPC; repeated reviews of a final receipt are rejected.
- [ ] Seller and admin views display the saved rejection reason.

## Delivery
- [ ] In non-production, apply the delivery-worker atomic-transition migration and verify it is idempotent.
- [ ] Delivery-worker RPC rejects unauthenticated users, inactive profiles, unassigned jobs, pickup orders, and orders without a verified customer receipt.
- [ ] Delivery-worker RPC rejects delivered-before-picked-up, repeated transitions, and invalid order states.
- [ ] Pickup and delivery completion update assignment and order together; force a failure and verify neither side is partially changed.
- [ ] Delivery-worker cancellation is allowed only before pickup and leaves the paid order available for admin reassignment.
- [ ] Awaiting-payment delivery order cannot receive a delivery assignment.
- [ ] An order with no verified customer receipt cannot receive a delivery assignment.
- [ ] An order with a verified customer receipt can receive a delivery assignment.
- [ ] An order without a verified customer receipt cannot be marked picked up or delivered.
- [ ] Pickup orders do not show or require delivery assignment.
- [ ] Marking a valid delivery as delivered updates the order to completed.
- [ ] An assigned delivery cannot be marked delivered before it is marked picked up.
- [ ] An order already out for delivery cannot have its provider or fee edited/reassigned through the admin form.
- [ ] A delivery can only be marked picked up from an eligible paid order; it can only be marked delivered from out_for_delivery.
- [ ] Editing an existing delivery provider or fee preserves its current assignment status.

## Regression and safety
- [ ] Customer, seller, and admin access boundaries still work.
- [ ] Receipt files remain private and open only through signed URLs.
- [ ] No real payment is initiated by these workflows.
- [ ] Production order/payment records remain unchanged during testing.

## Administrator delivery RPC (draft migration)
- [ ] Apply `2026-11-26-admin-delivery-atomic-rpcs.sql` only to a non-production database.
- [ ] Confirm unauthenticated and non-admin users cannot call either admin delivery RPC.
- [ ] Confirm a pickup order, unpaid order, or order without a verified customer receipt cannot be assigned.
- [ ] Confirm invalid provider name, phone, and negative/fractional fee are rejected by the database.
- [ ] Confirm assigning a new delivery creates exactly one assignment; editing an assigned delivery updates provider details without creating a duplicate.
- [ ] Confirm a picked-up or delivered assignment cannot be reassigned.
- [ ] Confirm pickup transition changes assignment to `picked_up` and order to `out_for_delivery` atomically.
- [ ] Confirm delivered transition changes assignment to `delivered` and order to `completed` atomically.
- [ ] Confirm invalid, repeated, and out-of-order transitions fail without changing either table.
- [ ] Simulate a failure during the transition and verify both rows roll back together.
- [ ] Confirm the admin page uses only the RPCs for assignment and status writes (no direct table updates).
- [ ] Confirm administrator and delivery-worker RPCs lock the order row before the assignment row and concurrent transitions cannot leave the two records out of sync.

## Delivery-worker administrator approval (draft migration)
- [ ] Apply `2026-11-27-delivery-worker-admin-approval.sql` only in a non-production database.
- [ ] New delivery-worker registrations create inactive profiles and return `pending_approval`.
- [ ] Re-registering an existing inactive worker cannot reactivate the profile.
- [ ] Re-registering an already-approved worker preserves the active state without changing it.
- [ ] An inactive worker cannot list, claim, or update delivery jobs.
- [ ] Only the configured administrator can activate or deactivate a delivery profile through `mp_admin_set_delivery_worker_status`.
- [ ] Unauthenticated and non-admin users cannot call the approval RPC.
- [ ] Confirm existing active delivery profiles are deactivated by the migration and require explicit review/re-approval.
- [ ] Confirm no order, payment, assignment, or customer data is changed by this migration.
