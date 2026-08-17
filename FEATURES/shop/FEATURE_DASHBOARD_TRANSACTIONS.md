# Shop Feature: Seller Dashboard — Transaction History (`/dashboard/transactions`)

Status: **DONE — base list/detail view (this doc's original scope) plus a 2026-08-12 parity pass bringing it up to (and in places past) the Flutter app's own My Orders feature. Live-verified end-to-end.** Design source: `/mnt/junglenas/DesignWebSite/account-transactions/stitch_responsive_product_list_layout/screen.png` (+ `DESIGN.md`, `code.html`). Same "Core Admin" token set already ported into `shop/src/themes/default.css` — no new design tokens needed.

**2026-08-12 update — Flutter-parity pass, §9's "Explicitly Deferred" items now shipped:**

The user asked to verify what the Flutter mobile app shows for both Purchase History and Sales History states and bring the shop up to a matching, polished design. A parity audit (Explore-agent research against `app-blablaragsandrigs/lib/features/orders/`) found the shop's detail view was already *ahead* of Flutter in some respects (full price breakdown, tracking/carrier shown in detail — Flutter's detail screen shows neither), but behind on: status-group filter chips, a hide-order action (the `hideOrder()` API existed and was tested but never wired to any button), a tracking-number preview in list rows, Confirm Receipt button polish (icon + reassurance copy), a real carrier dropdown in Add Tracking (was free-text), and the entire Return Request ("Problem with Order") flow. The user opted to ship all of it, including Return Request, plus asked for a real server-side date-range filter (not in Flutter, a shop-only addition).

Shipped, server (`server/`):
- `GET /api/v1/acquisitions` gained real `dateFrom`/`dateTo` query params (`YYYY-MM-DD`, inclusive, validated — 400 on malformed or `dateFrom > dateTo`) — `src/routes/acquisitions.ts`, `src/repositories/PgAcquisitionRepository.ts#listForAccount`, `src/repositories/acquisition.types.ts`. New integration tests in `test/api.integration.test.ts` (`describe('dateFrom/dateTo filtering')`): inclusive-bounds correctness against 3 backdated real acquisitions sharing one buyer, malformed-date rejection, `dateFrom > dateTo` rejection.
- No other server changes — the return-request and carrier-list endpoints (`src/routes/returnRequests.ts`, `src/routes/carriers.ts`) already existed and needed no changes; the shop was simply never calling them.

Shipped, shop (`shop/`):
- `src/lib/carriers/{types,api}.ts` (new) — `fetchActiveCarriers()` against `GET /api/v1/carriers/active`, the same real admin-managed carrier list (`system_settings`-backed) Flutter's `activeCarriersProvider` reads.
- `src/lib/orders/types.ts` / `api.ts` — added `StatusGroupFilter`, `dateFrom`/`dateTo` on `ListOrdersParams`; added `ReturnReasonCode`/`ReturnRequest` types and `uploadReturnRequestPhotos()` (real multipart `FormData` POST, no presigned-URL flow exists server-side) / `submitReturnRequest()`.
- `src/lib/orders/returnReason.ts` (new) — reason-code → i18n-key + display-order mapping, mirroring `return_request_screen.dart`'s dropdown order exactly.
- `TransactionsClient.tsx` — status-group filter chips (All/In Progress/Completed/Cancelled, server-filtered), a date-range filter (native date inputs, server-filtered, with a "Clear filters" affordance), a working hide-order trash icon (buyer rows only, optimistic removal with revert-on-error — correctly surfaces the server's real `CannotHideActiveAcquisitionError` 409 for non-terminal orders), and a tracking-number preview (truck icon) on any row that has one, matching Flutter's list-row treatment.
- `AddTrackingModal.tsx` — carrier field is now a real `<select>` populated from `fetchActiveCarriers()` (falls back to the old free-text input if that call fails, same UX Flutter's own dropdown uses), plus a copy-to-clipboard button that appears once a tracking number is entered.
- `OrderDetailClient.tsx` — Confirm Receipt button gained an icon + the reassurance prompt sentence above it (Flutter has this, the shop didn't); a "Report a Problem" button/link now appears whenever the order is in a returnable state (`escrow_held` or `buyer_confirmed`, mirroring the server's own gate), independent of whether Confirm Receipt is also available; a success banner renders after a return request is submitted (`?returnRequested=1`).
- `[id]/return-request/{page.tsx,ReturnRequestClient.tsx}` (new route) — the full flow: reason dropdown (7 codes, Flutter's exact order/labels), optional 500-char description with a live counter, a 2-4 photo evidence grid (one file picked per "Add photo" tap, removable, real multipart upload then a real create call), submit disabled until a reason + ≥2 photos are present, server-error-substring mapping for the two real business-rule failures (`AcquisitionNotReturnableError` 409, `InsufficientEvidenceError` 422).
- 9 new icons added to `src/components/icons/` (trash, truck, thumbs-up, copy, chevron-down, alert-triangle, image — Feather Icons paths, matching the existing convention).
- Full `en`/`es`/`de` i18n coverage for every new string (~40 new keys in `DashboardDictionary`).

Verification: `tsc`/`biome`/`vitest` clean in both `shop` (94 tests) and `server` (383 tests, full suite — this run also incidentally caught and fixed two pieces of unrelated environment drift: `system_settings` rate limits had crept back up to dev-convenience values again, and a full-suite run truncates `mobile_accounts`/`acquisitions` since one integration test genuinely reseeds the DB — both are pre-existing environment gotchas, not regressions from this change). Live Playwright walkthrough against a fresh real buyer/seller pair with two real `buy-now` purchases confirmed, end to end: filter chips, date-range restore, the hide-order 409/revert path, Confirm Receipt copy, the full Return Request submission (real multipart photo upload → real create → the acquisition's status genuinely flips to `disputed` server-side → success banner → actions correctly disappear once disputed), the real carrier dropdown (DHL Express / FedEx Logistics, the two `isActive:true` seeded carriers), the copy-tracking button, and the tracking-number row preview.

This is feature 3 of the shop build-out (1: login/register/verify, 2: seller dashboard shell + theme). It replaces the `/dashboard/sales` `ComingSoon` placeholder with a real, two-tab (Purchase History / Sales History) order-history page, and adds a per-order detail view.

## 1. Executive Summary

The design shows a "Transaction History" page: two tabs (**Purchase History** active, **Sales History** unmounted in the mockup), a table (Product Details / Date / Price / Status), a per-row contextual action button (**Track Package** when in transit, **View Details** otherwise), and pagination.

The critical finding from research, before writing a line of frontend code: **the entire backend this needs already exists and is fully built, tested, and documented** — this is a marketplace acquisition ("My Orders") system shipped 2026-07-28/29 and extended 2026-08-05 (`server/src/routes/acquisitions.ts`, `server/src/routes/wallet.ts`, `server/src/routes/returnRequests.ts`), already consumed by the Flutter app's own "My Orders" screen (`app-blablaragsandrigs/lib/features/orders/`). This feature is a **frontend-only** effort: a new web client for an API that already has a working mobile client. No new migration, no new endpoint, no new domain type on the server.

## 2. Prior Art — read before writing any code

- **Server API reference:** `server/docs/doc_enpoints_v3_07082026.md`, section "Marketplace Acquisition Flow" (search `## \`GET /api/v1/acquisitions\``). Full request/response shapes for every endpoint this feature touches.
- **Server domain types:** `server/src/domain/acquisition.types.ts` (`Acquisition`, `AcquisitionListItem`, `AcquisitionStatus`, `AcquisitionStatusGroup`, `acquisitionStatusGroup()`), `server/src/domain/shipment.types.ts` (`ShipmentStatus`).
- **Server route implementation:** `server/src/routes/acquisitions.ts` — read this for the exact `withTelemetry` spans already wrapping every mutating action (see §7).
- **Reference client implementation (mirror this, don't reinvent):** `app-blablaragsandrigs/lib/features/orders/`:
  - `domain/order_item.dart` — the exact DTO shape to mirror in TypeScript.
  - `domain/order_role.dart` / `domain/order_status_group.dart` — role/status-group enums + wire-value mapping.
  - `data/orders_repository.dart` — the 5 API calls this feature needs (`listOrders`, `hideOrder`, `addTracking`, `confirmReceipt`; return-request deferred, see §9).
  - `presentation/my_orders_screen.dart` — Sold tab taps → Add Tracking sheet; Bought tab taps → Order Detail screen. Mirror this exact per-role tap behavior.
  - `presentation/widgets/order_card_widget.dart` — list row layout + status chip.
  - `presentation/order_detail_screen.dart` — the "Everything is OK" / "Problem with Order" detail screen, gated on `status === 'escrow_held'`.
  - `presentation/widgets/add_tracking_sheet.dart` — seller's tracking-entry form, with a copy-to-clipboard affordance once a number exists.

## 3. Database Architecture Review

**Conclusion: no new schema, no new migration.** Every table this feature reads from already exists: `acquisitions`, `shipments`, `wallet_ledger_entries` (migrations `0026_marketplace_acquisitions.sql`, `0027_express_delivery.sql`). See `server/docs/database-entity-relaction.md` §5–§7 for the full escrow/idempotency design if a reviewer wants the entity-relationship detail. Inventing a parallel `shop_orders` table or similar would be a real architecture mistake — it would fork a second source of truth for money-in-flight state that the mobile app, the CS dashboard, and the wallet ledger all already share.

## 4. API Endpoints This Feature Uses

All mobile-JWT gated (`authenticateMobileJwt`), scoped to `req.mobileAccountId` — call all of these through the shop's existing `authFetch` (`src/lib/auth/authFetch.ts`), same as every other Part C dashboard page.

| Endpoint | Used for |
|---|---|
| `GET /api/v1/acquisitions?role=buying\|selling&statusGroup=...&page=...&limit=...` | Both tabs' list. `role=buying` → Purchase History, `role=selling` → Sales History. |
| `GET /api/v1/acquisitions/:id` | Order detail view — re-fetches fresh (unlike the Flutter app, which passes the list row as route `extra` — the web route is a real URL a user can bookmark/reload, so it must re-fetch, not rely on router state). |
| `PATCH /api/v1/acquisitions/:id/tracking` | Sales History → seller adds/corrects a tracking number. |
| `PATCH /api/v1/acquisitions/:id/confirm-receipt` | Purchase History → order detail → "Everything is OK." |
| `PATCH /api/v1/acquisitions/:id/hide` | Purchase History → row-level "remove from my list" (cosmetic only, buyer-side). Design doesn't show a trash icon in the one mocked tab, but the Flutter app has it on Bought — include it for parity; low effort, real endpoint already exists. |

Deferred (see §9): `POST /api/v1/acquisitions/:id/return-request(/photos)`.

## 5. Frontend Architecture

New files under `shop/src/`:

```
lib/orders/
  types.ts          — AcquisitionListItem/Acquisition mirror, OrderRole, StatusGroup (mirrors order_item.dart + acquisition.types.ts exactly)
  api.ts             — listOrders / getOrder / hideOrder / addTracking / confirmReceipt, all via authFetch
  statusLabel.ts     — pure function: (shipmentStatus, acquisitionStatus) -> { labelKey, tone } — see §6

app/[locale]/dashboard/transactions/
  page.tsx                — server wrapper, locale + dict
  TransactionsClient.tsx  — tabs (Purchase/Sales), table, pagination, per-row action button
  [id]/
    page.tsx               — server wrapper
    OrderDetailClient.tsx  — status pill, item card, order#/total, buyer actions (Everything is OK / Problem with Order) when actionable
  AddTrackingModal.tsx     — seller's tracking-entry form (Sales History row action), mirrors add_tracking_sheet.dart's fields
```

Modified files:

- `shop/src/app/[locale]/dashboard/DashboardSidebar.tsx` — add a **Transactions** nav item. Per the new design's sidebar, this supersedes the existing `/dashboard/sales` (`My Sales`) placeholder — remove that item rather than leaving two overlapping "orders" entries in the nav (`My Sales` was never built out beyond `ComingSoon`, so nothing real is lost). `My Products`/`Address Book`/`Payments & Wallet`/`Invoices` stay as-is — the new mockup's trimmed sidebar reflects Stitch's own mockup scope, not a real removal request; wallet balance and order history are different concepts and both stay.
- New icon: the design's Transactions nav glyph is a circular-arrow/history mark — closest existing convention is Feather's `rotate-ccw` (no exact "history" icon in Feather's set). Fetch and add as `IconHistory` following the exact same stroke-icon pattern as every other icon in `src/components/icons/`, at implementation time.
- `shop/src/lib/i18n/ui.ts` — new `transactions` dictionary section (en/es/de) — see §8.

### Reused, not rebuilt

`AuthPageShell`-style layout is NOT used here — this lives inside the existing `dashboard/layout.tsx` shell (sidebar + topNav + footer), same as every other Part C page. `authFetch` (bearer attach, 401 refresh-retry, 403 forced logout) is reused as-is — no new auth plumbing.

## 6. Status Mapping — the one real piece of logic in this feature

The design shows shipment-level granularity in the list itself ("In Transit", "Delivered") — more granular than the Flutter list's own status chip (which shows the coarser `statusGroup`: In Progress/Completed/Cancelled), though the *same* granular labels the Flutter app's **detail screen** already uses. Deliberate choice for this feature: match the design's list-level granularity, since the raw `shipmentStatus` field is already present on every `AcquisitionListItem` row (no extra round-trip needed) and it is strictly more informative to the person viewing their own order.

`statusLabel.ts` resolves the display status from state that exists today:

| `shipmentStatus` | `acquisitionStatus` (fallback when shipment is null) | Label | Tone |
|---|---|---|---|
| `awaiting_tracking` | — | Processing | neutral |
| `in_transit` | — | In Transit | primary |
| `delivered` | — | Delivered | success |
| `lost` | — | Lost | error |
| `disputed` | — | Disputed | error |
| `cancelled` | — | Cancelled | neutral |
| — | `disputed` | Disputed | error |
| — | `refunded` | Refunded | neutral |
| — | `cancelled` | Cancelled | neutral |

Action button per row (both tabs derive from the same resolved status):

- Purchase History: `in_transit` → **Track Package**; everything else → **View Details**. Both navigate to the same `[id]` detail route — "tracking" has no separate live-carrier view (no real carrier API integration anywhere in this codebase, see `shipment.types.ts`'s own doc comment), so "tracking" IS the detail view showing `trackingNumber`/`carrierCode`.
- Sales History: `awaiting_tracking` → **Add Tracking** (opens `AddTrackingModal`, does not navigate); everything else → **View Details** (navigates to `[id]`, read-only for the seller — no seller-side confirm-receipt/return action exists).

This mapping function is exactly the kind of "logic with real branching" the unit-test requirement (§7) targets, even though it's not itself a numeric calculation.

## 7. Testing Plan

**Gap found during research: the shop project has zero test infrastructure today** (`package.json` has `lint`/`tsc` but no `test` script, no Vitest/Jest, no Testing Library in `devDependencies`). This needs bootstrapping as part of this feature, matching the server's existing Vitest convention (`server/vitest.config.ts`) rather than introducing a third test runner into this codebase (Jest is what Ant Design Pro's `dashboard/` uses, but that's a different, Umi-specific toolchain — Vitest is the better fit for a plain Next.js/Vite-adjacent setup and keeps one test-runner mental model between `server/` and `shop/`).

Add to `shop/package.json`: `vitest`, `@testing-library/react`, `@testing-library/jest-dom`, `jsdom` (dev deps); `"test": "vitest run"` script; `vitest.config.ts` (jsdom environment, path alias matching `tsconfig.json`'s `@/*`).

Per the ">20% calculation or server/DB-write logic gets unit tests" instruction, in scope for this feature:

- **`lib/orders/statusLabel.ts`** — exhaustive test over every `shipmentStatus`/`acquisitionStatus` combination in the table above (§6). Pure function, no mocking needed.
- **`lib/orders/api.ts`** — every function that WRITES (`hideOrder`, `addTracking`, `confirmReceipt`): mock `authFetch`, assert correct URL/method/body, assert success and error-response handling both produce the right return shape. `listOrders`/`getOrder` (reads) get at least one happy-path test each for the query-string construction (role/statusGroup/page/limit — easy to get an off-by-one or a wrong param name wrong here, exactly the kind of thing worth locking down).
- **`TransactionsClient`/`OrderDetailClient`** — not full component tests for this pass (the auth-gated dashboard pages elsewhere in this codebase were verified live via Playwright, not unit tests, and that precedent holds — component-level rendering is cheap to eyeball, the *logic* underneath it is what regresses silently). Revisit if this project later adopts component testing more broadly.

## 8. i18n

New `transactions` dictionary section, en/es/de, mirroring the existing `dashboard` section's structure in `lib/i18n/ui.ts`:

`pageTitle`, `pageSubtitle`, `tabPurchaseHistory`, `tabSalesHistory`, `colProduct`, `colDate`, `colPrice`, `colStatus`, `statusProcessing`, `statusInTransit`, `statusDelivered`, `statusLost`, `statusDisputed`, `statusRefunded`, `statusCancelled`, `actionTrackPackage`, `actionViewDetails`, `actionAddTracking`, `emptyPurchases`, `emptySales`, `loadError`, `orderNumberLabel` (format `Order #{id}` — matches the real Flutter app's `orderNumberLabel`, **not** the mockup's cosmetic `#BR-9942` prefix; flag this discrepancy for the user before implementing in case the `BR-` prefix is actually wanted), `detailTitle`, `detailTotal`, `everythingOkButton`, `problemButton`, `confirmReceiptPrompt`, `confirmReceiptSuccess`, `alreadyActionedMessage`, `hideOrder`, `orderHiddenMessage`, `addTrackingTitle`, `trackingNumberLabel`, `carrierLabel`, `saveTracking`, `copyTracking`, `trackingCopiedMessage`.

## 9. Explicitly Deferred (not this pass)

- **Return Request flow** (`POST /api/v1/acquisitions/:id/return-request(/photos)`, "Problem with Order" → reason code + photo upload). Real endpoint, real legal logic server-side (statutory withdrawal vs. Buyer Protection claim, computed server-side — see the endpoint doc's own note), but it's a multi-step form with file upload that's a meaningfully separate chunk of work from "render order history." Ship history + confirm-receipt first; return-request as its own follow-up feature doc when picked up.
- **"Blabla Friends" tab** — Flutter's third My Orders tab, fully client-mocked referral data with no server endpoint (`orders_repository.dart`'s own doc comment: "no server endpoint yet"). The Stitch design for this page only shows 2 tabs. Not building a fake-data tab on the web without a real backend behind it.

## 10. Telemetry — already covered, nothing new to add

All 3 mutating endpoints this feature calls (`hide`, `tracking`, `confirm-receipt`) are already wrapped in `withTelemetry` server-side in `acquisitions.ts` (confirmed by reading the file — spans `acquisitions.addTracking`, `acquisitions.confirmReceipt`, plus fire-and-forget notification spans). `confirm-receipt` is the money-moving one (starts the escrow release timer, triggers real invoice generation) and it's already instrumented. This feature adds no new backend code, so there is no new telemetry to wire up — the instruction to use telemetry for money-touching processes is already satisfied by the existing server implementation this feature calls into. If a future phase adds a genuinely new backend endpoint (e.g. for return requests), that new route must follow the same `withTelemetry` convention already established in this file.

## 11. Verification Plan (once implemented)

```bash
docker compose exec -T shop npx tsc --noEmit
docker compose exec -T shop npx biome check src
docker compose exec -T shop npx vitest run
```

Live (Docker Playwright harness, same pattern used for Parts B/C):
- Purchase History tab renders real orders for a seeded/test account that has actually bought something (need a test fixture — today's manual test accounts have no purchase history; may need a throwaway buy-now via the API directly, or coordinate with an account that already has orders).
- Sales History tab, same for a seller account.
- Status chip + action button match §6's table for at least one order in each represented state.
- Click through to order detail, confirm the status pill + item card render.
- As a buyer on an `escrow_held` order: click "Everything is OK", confirm success + the row's status updates.
- As a seller on an `awaiting_tracking` order: Add Tracking, confirm the modal saves and the row flips to "In Transit".
- Pagination controls work past page 1 (needs a fixture account with >1 page of orders, or test against `limit` at a small value).
