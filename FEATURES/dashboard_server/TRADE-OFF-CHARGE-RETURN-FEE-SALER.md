# Trade-Off Analysis: Return-Shipping Seller Charge Has No Settlement Destination

**Document Target Path**: `/Users/nbarrera/projects/Docker/node-nginx-clean/FEATURES/dashboard_server/TRADE-OFF-CHARGE-RETURN-FEE-SALER.md`
**Target Agent**: Claude
**Author**: Claude, from findings surfaced during the `smoketestsuit` pre-release smoke test suite (see `FEATURES/app/`'s smoke-test-driven findings and the `server/scripts/smoketestsuit/` run at `output/20260811T212522Z`)
**Date**: 2026-08-11
**Status**: Flagged, NOT fixed — documentation only, no code changed by this doc.

---

## 1. Summary

Approving a return in the current codebase does two things to money, and
only two:

1. Optionally debits the **seller's** wallet a configurable return-shipping
   amount (`returnShippingChargedTo: 'seller'`).
2. Nothing else. The buyer's wallet is never touched. The debited amount
   is never credited anywhere.

This was confirmed twice, independently, this session:

- **Live, with real numbers**: the smoke test suite's step 5
  (`server/scripts/smoketestsuit/steps/step_05_returns_workflow.py`) filed
  and approved 4 real returns against a live database. Each seller was
  debited exactly 5.00 EUR (20.00 EUR total across the 4). `SELECT
  platform_ledger_balance` before and after those 4 debits was queried
  directly — **unchanged**. The 20.00 EUR left the sellers' wallets and
  does not exist anywhere else in the system afterward.
- **By code**: `PgWalletRepository.chargeReturnShipping()`
  (`server/src/repositories/PgWalletRepository.ts:207-241`) only ever
  does an `UPDATE wallets SET balance = balance - $amount ...` on the
  seller's row plus one `wallet_ledger_entries` insert
  (`entry_type='return_shipping_charge'`). No corresponding credit —
  not to `platform_ledger_balance`, not to any other account — exists
  anywhere in this call path or anywhere else in `src/`.

## 2. The broader trade-off this sits inside

This is a symptom, not an isolated bug. The return-approval flow
(`PgReturnRequestRepository.decide()`,
`server/src/repositories/PgReturnRequestRepository.ts`) was clearly built
to stop money moving further (it flips the acquisition to `'disputed'`
and, for a `buyer_protection_claim`, requires CS photo-verification
first) — but the actual **settlement** half of a return was never
finished:

- `wallet_ledger_entries.entry_type` includes `'escrow_refund'` in its
  CHECK constraint (migration 0046) and `WalletLedgerEntryType` in
  `server/src/domain/wallet.types.ts` — **declared, never written by any
  route.**
- `acquisitions.status` includes `'refunded'` as a legal value in its
  type/status-group definitions — **declared, never assigned by any
  route.**
- The buyer who returns an item keeps their money debited (from the
  original purchase) with no way back, and — separately — the seller
  can lose a return-shipping charge that isn't tracked as revenue for
  the platform, a carrier, or anyone else.

Put plainly: **there is currently no real refund path in this
marketplace, for either side of a return.** What exists today is a
one-directional "protect the platform, don't lose more money" guard,
not a settlement flow.

## 3. Why this hasn't mattered yet

Every wallet in this system today is a **sandboxed internal ledger** —
"Wallet is the ONLY method that ever moves real money" (locked-in
decision from the Shopping Cart feature), and even that "real money" is
entirely internal book-keeping: top-ups are a simulated sandbox credit
(`POST /v1/wallet/topup`), there is no real payment processor connected
anywhere in this codebase yet (Card/Bank Transfer/PayPal are admin-toggled
**mock display tiles**, explicitly scoped to be removed once a real
Phase 3 gateway lands). So today, an "unsettled" return-shipping charge
is lost platform-internal ledger money, not real currency leaving anyone's
bank account — which is presumably why this gap hasn't surfaced as a
production incident yet.

**This changes the moment Phase 3 connects a real payment gateway.** At
that point:
- A buyer who never gets refunded on a legitimate return is a real
  consumer-protection / chargeback-risk problem, not a ledger rounding
  error.
- A seller charged real money for return shipping, with that money
  going nowhere trackable, is a real accounting/reconciliation gap an
  auditor or payment processor will ask about directly.

## 4. Options (not decided — flagging for a real decision before Phase 3)

1. **Minimal fix, ledger-only**: credit `platform_ledger_balance` in
   `chargeReturnShipping()` for the amount charged to the seller (it's
   presumably meant to cover the platform's own return-shipping cost,
   so crediting the platform ledger is the most direct read of intent).
   Small, additive, no schema change — mirrors exactly how
   `releaseEscrowTx` already credits `platform_fee_retained`.
2. **Real settlement flow**: implement the actual buyer-refund path —
   `wallet_ledger_entries.entry_type='escrow_refund'` crediting the
   buyer, `acquisitions.status='refunded'`, and a decision on where a
   refund's money comes FROM (the platform's retained fee? clawed back
   from the seller's already-released payout? held back at
   `buyer_protection_claim` creation time instead of after approval?).
   This is a real design task, not a one-line fix — it changes the
   escrow-timing model this feature was built around.
3. **Do nothing until Phase 3**: explicitly accept this as a Phase 1/2
   sandbox limitation (same posture as the mock payment tiles), and
   schedule the real settlement design as Phase 3 work alongside the
   real payment gateway integration, since that's also when a real
   refund mechanism (reversing a real charge) becomes possible at all.

## 5. Reference for Phase 3 — fraud / non-payment / refund handling

Flagged by the user (not yet evaluated by anyone): **paywise.de** as a
candidate provider to look into for fraud and non-payment/refund
handling once a real payment gateway is in scope. API entry point
provided by the user: `https://paywise.de/connect/api/`. Not researched
or vetted as part of this document — this is a pointer for whoever picks
up the Phase 3 payment-gateway work to evaluate, alongside whatever due
diligence a real payment processor selection requires (PCI-DSS scope,
chargeback handling, EU consumer-protection/withdrawal-law compliance —
see `payment-data-compliance-and-fraud-review` for the compliance rules
already adopted for this codebase's card/IBAN handling).

## 6. What this document does NOT do

No code in this repository was changed to produce this document. The
smoke test suite (`server/scripts/smoketestsuit/`) already asserts the
CURRENT real behavior (seller charged, buyer unaffected) rather than an
assumed refund — see that suite's own `README.md` and step 5's doc
comment. If any of the options in §4 get picked up, step 5's assertions
need to be updated to match the new intended behavior at the same time.
