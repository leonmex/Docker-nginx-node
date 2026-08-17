### Test 1
cd /home/ander/projects/Docker-nginx-node
ACTIONS=4 SELLER_POOL_SIZE=2 RETURN_EVERY_NTH=2 RESET_DB=true \
  ./server/scripts/smoke-test-full-cycle-signup-list-buy-ship-receive-invoice-and-wallet-payout-shipment-invoice_v2.sh 2>&1 | tail -25

cd /home/ander/projects/Docker-nginx-node
ACTIONS=100 SELLER_POOL_SIZE=5 RETURN_EVERY_NTH=4 RESET_DB=true \
  ./server/scripts/smoke-test-full-cycle-signup-list-buy-ship-receive-invoice-and-wallet-payout-shipment-invoice_v2.sh 2>&1 | tee /tmp/v2-full-run2.log | tail -30

Full round complete — database reset, 100 real actions, and a genuine production bug found and fixed
What happened, in order:

Reset the database (npm run db:seed) and ran a detailed Phase 1 narrative — real signup→list→buy→ship→confirm-receipt (the actual endpoint, not v1's old admin-workaround)→Type B invoice auto-generation→escrow release→wallet payout→return-request (create→verify-photos→decide, charging the seller's real earned wallet balance, not a synthetic test credit). All 19 checks passed, validating every fix from this session end-to-end via real HTTP calls.

Simulated 100 real actions (Phase 2: register buyer → list product → buy → ship → confirm-receipt → release, across a pool of 5 sellers, every 4th also attempting a return) — and this surfaced a real, previously-unknown production bug: 94/100 Type B invoices failed with duplicate key value violates unique constraint "invoices_invoice_number_key".

Root-caused it: invoice_number_sequences correctly scopes counters per seller (required — §14 UStG mandates each issuer's own invoice numbers be sequential/gapless), but the formatted invoice_number string (INV-2026-000001) never included anything seller-specific. Two different sellers independently reaching their own "1st invoice" both produced the identical string and collided on the global unique constraint — deterministic, not a race, and it would hit any real production traffic with more than one seller.

Fixed it in PgInvoiceRepository.ts: Type B invoice numbers now embed the issuer's account ID (INV-<issuerAccountId>-2026-000001), preserving the per-seller gapless legal requirement while guaranteeing global string uniqueness. Type A (platform_fee, single issuer) is untouched. Updated the one test assertion that hardcoded the old format.

Re-validated everything: tsc/lint/324 tests clean, restarted the live server (needed — it runs npm start without watch, a repeat of the earlier gotcha), reset the DB again, and reran the full 100-action script: 23/23 checks passed, 100/100 invoices issued, zero stuck in draft.

Also fixed two smaller script bugs found along the way: a stale live-server-needs-restart trap, and a locale bug (LC_NUMERIC=de_DE making awk's %.2f emit a comma decimal separator, silently corrupting the JSON payload) — same class of issue the rest of the codebase already guards against with LC_ALL=C.

Saved: server/scripts/smoke-test-full-cycle-signup-list-buy-ship-receive-invoice-and-wallet-payout-shipment-invoice_v2.sh — reusable, configurable (ACTIONS, SELLER_POOL_SIZE, RETURN_EVERY_NTH, RESET_DB), and documented with the exact bug chain it exists to catch.
