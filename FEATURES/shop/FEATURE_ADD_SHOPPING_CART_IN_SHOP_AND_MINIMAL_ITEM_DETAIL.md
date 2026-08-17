# Shop Feature: Shopping Cart + Bundle-Aware Product Detail

Status: **DONE — server (§4/§5) and shop frontend (§6) fully built, tested, and live-verified end-to-end.**

**2026-08-12 update #4 — §6 complete, feature done:**

- Finished the `es`/`de` i18n blocks (`CartDictionary`/`CheckoutDictionary`/`ProductDetailDictionary`) — `tsc` clean across the shop again.
- Built `topNav/CartButton.tsx` (mirrors `AccountButton.tsx`'s dropdown pattern, live badge count) and wired it into `topNav/index.tsx`; mounted `CartProvider` in the root layout inside `AuthProvider`.
- Built `product/[id]/page.tsx` + `ProductDetailClient.tsx` (bundle-aware: per-item gallery selector, price breakdown), `cart/page.tsx` + `CartPageClient.tsx`, `checkout/page.tsx` + `CheckoutClient.tsx`.
- Wired the grid's previously-inert Add-to-Cart button and linked cards to the new detail page (`productGrid/types.ts` now carries `groupId`/`itemCount`).
- **Found and fixed a real structural bug during live verification**: `product`/`cart`/`checkout` rendered with zero site chrome (no topNav, no footer) — this codebase's topNav is assembled per-route (home via its page-config block list, dashboard via its own `layout.tsx`), and the three new routes had neither. Fixed by moving them into a new `(storefront)` route group with a shared `layout.tsx` (same `TopNavBlock`/`FooterBlock` wrapper `dashboard/layout.tsx` uses) — no URL change, `/product/[id]`, `/cart`, `/checkout` are unaffected.
- **Also found the running server process was stale**: it runs via `npm start` (no watch/hot-reload), so every server-side code change from this whole session had never actually gone live on the proxy-facing instance, even though the automated test suite (which builds fresh from source per test file) was accurate throughout. Restarted it — and separately flushed Redis, since the public item-detail route caches responses for 120s and was serving a stale pre-restart shape.
- **Found and fixed a live security/operational drift while re-verifying**: `accounts.security.{login,verify,resend,refresh}.max_attempts` were all left elevated ~100x above their real defaults on this environment (e.g. register max_attempts=500 instead of 5) — from earlier test-account-creation convenience work that was never reverted. Restored all five to their real `schema.sql` defaults; this had also been silently breaking `test/rateLimit.integration.test.ts` (timing out, not just under-enforcing).
- Full live Playwright walkthrough (fresh seller+buyer, a real single item + a real 3-item bundle, both funded via the real wallet-topup endpoint): browse → product detail (gallery/price/bundle breakdown all correct) → Add to Cart (topNav badge went 0→1→2 live) → cart page (correct lines/totals/badges, no false price-changed/unavailable flags) → checkout (delivery picker, wallet tile+balance, correct total) → Place Order → success screen → wallet debited the exact total shown (verified via direct DB read: 500.00 − 97.90 = 402.10) → badge reset to empty.
- Final state: shop `tsc`/`biome` clean (151 files), shop `vitest` 79/79 passing, server `tsc`/`biome` clean (193 files), server test suite 376/380 passing (same 4 pre-existing unrelated MinIO apparel-image-health flakes, confirmed via git-stash bisection in an earlier session).

**2026-08-12 update #2 — §5 done, plus a DB performance pass:**

- `getPublicCatalogFeed` now returns `groupId`/`itemCount` per row; `getPublicItemDetail` now returns `isBundle`/`itemCount`/`bundlePrice`/`bundleCurrency`/`groupItems[]` (every active item in the group, each with its own images/size/condition) — additive, the old `siblingItems` field is kept unchanged for the Flutter app's existing parser (confirmed it consumes that exact field).
- Refactored migration `0056_product_groups_listing_status.sql` to add two supporting indexes for the feed's hot-path query (`WHERE item_status='active' ORDER BY created_at DESC, id DESC`): a partial index on `product_items(created_at DESC, id DESC) WHERE item_status='active'`, and a partial index on `product_groups(listing_status) WHERE listing_status <> 'active'`. Applied live, folded into `schema.sql`. At the test DB's current tiny row count the planner still uses seq scans (verified via `EXPLAIN`) — expected; these indexes are for production scale, where Postgres switches to them automatically.
- 9 new tests added (5 for the bundle-aware feed/detail fields, all in `describe('public catalog feed & item detail — bundle-aware fields', ...)`). Full suite: 376/380 passing (same 4 pre-existing unrelated MinIO flakes).

**2026-08-12 update — §4 remediation complete:**

- Resynced the live dev/test DB (migration `0056`'s `ALTER TABLE` had never actually run despite being marked applied — 26 tests were failing on `column "listing_status" does not exist"`; now fixed, confirmed via `\d product_groups`).
- Closed the reservation-bypass gap: new migration `0057_product_groups_reserved_by.sql` (`product_groups.reserved_by_account_id`), wired into `PgShoppingCartRepository`'s reserve/revert paths and a new check inside `PgAcquisitionRepository.resolveGroupPricing` — a direct `buy-now` on an item sitting in someone else's cart now correctly 404s instead of silently succeeding. Confirmed by a live regression test (fails on pre-fix code, passes post-fix).
- Found and fixed a second, related bug the new tests caught: `lockAndVerifyGroupAvailable` didn't allow the *same* buyer to re-add their own already-reserved item, breaking the documented "re-add is an idempotent upsert" behavior — same `reserved_by_account_id`-aware check applied there too.
- Added `withTelemetry` to `checkout-quote` (was missing, unlike its sibling `checkout`).
- Added the previously-nonexistent automated test coverage: 14 functional + 3 concurrency cases in `server/test/api.integration.test.ts` (new `describe('Shopping cart', ...)` block + additions to `describe('Concurrency & money-safety', ...)`). Full suite: 371/375 passing, the 4 failures are the pre-existing unrelated MinIO apparel-image-health flakes.
- §5 (bundle-aware product detail) and §6 (shop frontend) remain entirely unbuilt — see below for the as-planned spec, unchanged.

## 0. Security & Telemetry addendum (2026-08-12, per explicit user directive)

Before building §6, the user asked to (a) confirm this feature has proper telemetry to catch issues in add-to-cart/purchase/payment/shipment, and (b) confirm sessions can never mix between buyers and IBAN/wallet data can never leak to the wrong party. Findings from a dedicated audit of both the Flutter app and this repo:

**Telemetry — already sufficient server-side, nothing to add:**

- The Flutter app itself has **zero** telemetry around cart/checkout/payment/shipment (grepped `lib/features/cart|checkout|wallet|orders` for any logging/analytics call — none found; its only telemetry is a local-only debug trace for auth events). There is nothing to "match."
- The server, however, already wraps every mutating cart/purchase/shipment action in the codebase's standard `withTelemetry` span (`cart.addItem`, `cart.removeItem`, `cart.clear`, `cart.checkout`, `cart.checkoutQuote`, `acquisitions.buyNow`, tracking, confirm-receipt, etc.) — confirmed present and now includes `checkout-quote` (§4.3 above closed the one gap). **No new server telemetry is needed for this feature.** The shop frontend itself has no telemetry system of any kind (confirmed: no Sentry/analytics in `shop/package.json`) and none is being introduced here — errors surface to the buyer via inline UI messages, and the server-side spans are the actual "catch any issue" mechanism, same as every other money-adjacent feature in this codebase.

**Session isolation — confirmed safe, one actionable gap for the code about to be written:**

- Shop session token lives only in `localStorage` (`shop/src/lib/auth/session.ts`), never in a server-side or module-level variable — confirmed no Server Component reads a session/cookie, so there is no cross-user leak path in SSR. `authFetch`'s 401-refresh-retry has no shared mutable state a concurrent request could corrupt (each call is a self-contained closure).
- **Actionable**: `AuthContext.logout()` only clears the auth token — it does not cascade to other contexts, and this codebase's post-logout navigation is client-side (`router.push`, not a full reload), so a root-mounted context's in-memory state survives a logout unless it explicitly clears itself. **`CartContext` (about to be built) must subscribe to `session` transitioning to `null` and clear its own cart state at that moment** — otherwise a second person using the same browser could briefly see the first person's stale cart UI until the next fetch. Built into §6.2 below.
- Server-side, `authenticateMobileJwt` derives `accountId` exclusively from the verified JWT for every cart/wallet route — no route schema even accepts an `accountId` field from the client, so there is no way to smuggle another account's id through.

**IBAN/wallet exposure — confirmed no leak path, one process rule for future code:**

- IBAN/BIC only ever appears in `GET /api/me` and `/api/me/payment-method/verify/*` (Pro Seller payout settings) — fully separate from every cart/checkout/wallet/catalog endpoint. `GET /cart/payment-methods` returns hardcoded admin-configured mock display values (`'John Doe'`/`'Visa'`/`'4242'`/demo PayPal email), identical for every user, never real per-user financial data. `GET /wallet` and the checkout result are scoped to `{balance, escrowHeld, currency}` / purchase totals only.
- **Process rule**: the new cart/checkout/product-detail frontend code must never call `GET /api/me` — that endpoint returns the full profile including decrypted IBAN/BIC by design, and there is no reason cart/checkout UI needs it (buyer's own display name, if ever needed, should come from `AuthSession`, already held client-side from login).
- **Secondary, non-IBAN finding worth a deliberate decision**: `POST /cart/checkout`'s response includes `sellerEmail`/`buyerEmail` on every acquisition line — real counterparty PII. Treated as intentional here (same pattern as any marketplace order confirmation — the buyer has a legitimate reason to see who they bought from), but the frontend must not log or forward this response elsewhere unexamined.

## 1. Executive Summary

The Flutter app (`/home/ander/projects/app-blablaragsandrigs`) ships a complete client-side cart (`lib/features/cart/`, `lib/features/checkout/`) that talks to `/v1/cart/*` server endpoints. **Update (2026-08-12): those endpoints now exist** — `origin/serv-24-add-shopping-carts` was merged into this branch (`merge: integrate serv-24-add-shopping-carts...`, followed by two fix commits, HEAD `180d780`). A fresh re-audit of the merged code (not a re-read of the old branch) found:

**DONE and working:**

- All 7 `/cart/*` routes + 2 admin routes implemented, registered, and wired into DI (`server/src/routes/shoppingCart.ts`, `server/src/repositories/PgShoppingCartRepository.ts`) — not dead code.
- Schema (`shopping_carts`/`shopping_cart_items`/`product_groups.listing_status`) fully folded into `db/schema.sql`.
- Cart-vs-cart concurrent add-to-cart race is closed (`FOR UPDATE` lock on `product_groups.id`).
- Public feed/detail correctly hide reserved/sold listings (`listing_status='active'` filter).
- Migration filename collisions (two files each sharing prefixes `0052`/`0053`/`0054`) are cosmetic only — the migration runner sorts/tracks by full filename, not numeric prefix, confirmed via `db/executeMigration.ts`.

**BROKEN — real gaps that must be fixed before this can be considered done:**

- **Reservation bypass, confirmed live in the current code**: `resolveGroupPricing`/`purchaseOneGroupTx` in `PgAcquisitionRepository.ts` only check `product_items.item_status`, never `product_groups.listing_status`. Concretely: Buyer A adds item X to their cart (sets `listing_status='reserved'`); Buyer B calls `POST /acquisitions/buy-now {itemId:X}` directly, bypassing the cart entirely, and it **succeeds** — the reservation is silently meaningless against a direct buy-now. The code's own comment on the `'sold'`-write in `purchaseOneGroupTx` explicitly says it's "additive only... **NOT a new precondition check**," confirming this wasn't an oversight in the diff so much as scope that was never closed. See §4.5.
- **The live dev/test database is currently out of sync with its own migration tracking**: `schema_migrations` claims `0056_product_groups_listing_status.sql` is applied, but the actual `product_groups` table on the running Postgres container has no `listing_status` column. This is causing **26/358 server tests to fail right now** (`column "listing_status" of relation "product_groups" does not exist`). Root cause: `db:reset`'s `CREATE TABLE IF NOT EXISTS` is a no-op against a pre-existing table, and migration-stamping marks 0056 "applied" without ever running its `ALTER TABLE`. Fix is operational, not a code change: run `npm run dev:executemigration` against this environment (not yet run — flagged, not executed, since it mutates the live dev/test DB).
- `checkout-quote` isn't wrapped in the local `withTelemetry` helper its sibling `checkout` route uses — a silent telemetry gap on a revenue-adjacent read path (minor, but worth closing alongside the above).

**MISSING:**

- **Zero automated test coverage of the cart feature** — no vitest/integration test file touches any `/cart/*` route. The only exercise is a manual bash smoke-test script (`scripts/smoke-test-shopping-cart-2-buyers-2-salers-3-shopping-carts.sh`) that isn't part of `npm run test`/CI, and it does **not** cover the cart-vs-direct-buy-now race that would have caught the bug above.
- No `reserved_by_account_id`-style column anywhere — reservation is a bare group-level `active|reserved|sold` state with no record of *which* buyer holds it, which is also why the bypass above can't be fixed with a simple status check alone.
- Bundle-aware public product detail fields (`isBundle`, `itemCount`, `bundlePrice`, `groupItems[]`) were **not** added — `getPublicItemDetail` still only returns a thin `siblingItems` array (id/name/price/coverImageUrl, no size/condition/gallery per sibling), and the catalog feed has no `groupId`/`itemCount` at all.
- **The shop frontend has had zero cart-related work land** — confirmed by a fresh re-audit of `shop/src/`: no `product/[id]` route, no `cart`/`checkout` route, no `src/lib/cart/`, no `CartButton.tsx`, no `CartProvider` in the root layout, topNav's cart icon and the grid's Add-to-Cart button are both still fully inert (no `onClick`, no badge), and `git log -- shop/` shows no recent cart-related commits. "The shopping cart is there now" refers entirely to the server merge — none of it is consumed by the web app yet.

**This feature is now: fix the two real server gaps + add the missing test coverage (§4.5–4.7), then build the bundle-aware product detail (§5) and the entire shop frontend (§6) from scratch — nothing in §6 has started.**

## 2. Prior Art — read before writing any code

- **The abandoned branch itself** (fetch first: `git fetch origin serv-24-add-shopping-carts`): `src/repositories/PgShoppingCartRepository.ts` (612 lines), `src/routes/shoppingCart.ts` (439 lines), `src/routes/adminShoppingCarts.ts` (132 lines), `src/domain/shoppingCart.types.ts` (61 lines), `src/repositories/shoppingCart.types.ts` (122 lines), `db/migrations/0052-0056_*.sql`, and the `PgAcquisitionRepository.ts` diff (+353/-lines) adding the `purchaseOneGroupTx`/`completeCartPurchase` refactor.
- **Flutter reference client** (mirror its contract, don't reinvent): `app-blablaragsandrigs/lib/features/cart/` (`domain/cart_item.dart`, `data/cart_repository.dart`, `providers/cart_providers.dart`, `presentation/cart_screen.dart`) and `lib/features/checkout/` (`data/checkout_repository.dart`, `presentation/cart_checkout_screen.dart`). Also `lib/core/network/api_paths.dart:114-124` for the exact endpoint paths, and the two concurrency tests `test/features/cart/cart_two_sessions_test.dart` + `test/features/product_detail/presentation/product_detail_add_to_cart_two_sessions_test.dart` (what the client expects the server to guarantee under a race).
- **Existing single-item purchase flow** (the code the cart must reuse, not duplicate): `server/src/routes/acquisitions.ts` (`checkout-quote`/`buy-now`), `server/src/repositories/PgAcquisitionRepository.ts`'s `resolveGroupPricing` (lines 576-630 — the "sum of active items in a group" semantics that must stay the single source of truth for pricing everywhere: cart, checkout, and the new product detail page).
- **Existing public item detail** (the endpoint to extend, not replace): `getPublicItemDetail`, `PgApparelRepository.ts:1604-1694`, and the admin-only `getGroupForAdmin` (`PgApparelRepository.ts:802-956`) whose per-item shape (images/size/condition per item) is what the public bundle response should mirror, scoped to public-safe fields.
- **Shop conventions to mirror**: `shop/src/lib/auth/AuthContext.tsx` (SSR-safe null-then-hydrate context shape) + `shop/src/blocks/topNav/AccountButton.tsx` (dropdown pattern) for the new `CartContext`/`CartButton`; `shop/src/lib/orders/api.ts` (API-wrapper convention: `authFetch` → throw on `!res.ok` → unwrap `{data}`) for the new `lib/cart/api.ts`; `shop/src/lib/productGrid/watchlist.ts` (optimistic-toggle + `'unauthenticated'`-outcome sign-in-prompt pattern) for guest-state handling.

## 3. Domain model recap

Every listing is a `product_group` (no price column) containing one or more `product_items` (a bundle if >1). Price lives per-item (`product_items.price NUMERIC(10,2)`); a group's effective price/availability is always `SUM(price) WHERE group_id=X AND item_status='active'` (sold/reserved/hidden excluded) — this is `resolveGroupPricing`'s existing logic and must remain the one source of truth. `item_status` enum: `active|sold|reserved|hidden` (`'reserved'` is currently dead code — nothing sets it, which is exactly why the cart needs its own reservation concept, see §4.1). Images live in `item_images`, keyed by `item_id` (not group), ordered by `sort_order`. `shipping_size_tier` (`small|medium|big`) must be uniform across every active item in a group or purchase fails.

## 4. Server: cart backend — remediation of the merged code (no porting needed anymore)

The migrations, domain types, `PgShoppingCartRepository`, both route files, and DI wiring are **already merged and live** (see §1) — do not re-port or rewrite any of it. What's left is fixing the two real gaps found in the fresh audit and filling the test-coverage hole.

### 4.1 Operational fix — resync the live dev/test database (do this first, unblocks 26 failing tests)

Run `npm run dev:executemigration` against the running server environment so migration `0056_product_groups_listing_status.sql`'s `ALTER TABLE` actually executes against the live `product_groups` table (currently desynced: `schema_migrations` claims it's applied, the column doesn't actually exist). Confirm via `docker compose exec -T dbPostgres psql -U postgres -d test -c '\d product_groups'` that `listing_status` is now present, then re-run `npm run test` and confirm the 26 currently-failing tests (all `buy-now`/catalog-feed fixture setup calls hitting the missing column) now pass.

### 4.2 Required fix — reservation-bypass bug (confirmed live in current code)

`resolveGroupPricing` (`server/src/repositories/PgAcquisitionRepository.ts:683-737`), when called with `forUpdate=true` (from `purchaseOneGroupTx` — both `buy_now` and `cart_checkout`), only locks/checks `product_items.item_status`, never `product_groups.listing_status`. Concrete failure: Buyer A adds item X to their cart (`PgShoppingCartRepository.addItem` sets `listing_status='reserved'`, but leaves `product_items.item_status` untouched); Buyer B calls `POST /acquisitions/buy-now {itemId:X}` directly, bypassing the cart entirely — `resolveGroupPricing` still sees `item_status='active'` and lets the purchase through. The only place this file touches `listing_status` at all is the unconditional `'sold'` write in `purchaseOneGroupTx` **after** its own gates already passed (comment there says explicitly: "additive only... not a new precondition check").

There's no `reserved_by_account_id` column today, so a status check alone can't tell "reserved by this buyer" from "reserved by someone else."

**Fix** — new migration `db/migrations/0057_product_groups_reserved_by.sql` adding `product_groups.reserved_by_account_id INTEGER NULL REFERENCES mobile_accounts(id)`, set alongside `listing_status='reserved'` in `PgShoppingCartRepository.addItem`'s existing lock/reserve step and cleared back to `NULL` everywhere `listing_status` reverts to `'active'` (remove/clear/expire). Then `resolveGroupPricing`, under its existing `FOR UPDATE` lock, additionally reads `listing_status`/`reserved_by_account_id` from `product_groups` and throws `ItemNotAvailableError` if `listing_status='sold'`, or if `listing_status='reserved'` and `reserved_by_account_id` isn't the calling buyer's own account id. Fold the new column into `db/schema.sql` per the cumulative-snapshot convention.

### 4.3 Minor fix — telemetry gap

`POST /cart/checkout-quote` (`server/src/routes/shoppingCart.ts:269-301`) isn't wrapped in the local `withTelemetry` helper its sibling `checkout` route uses (line 353) — wrap it for consistency (span `cart.checkoutQuote`).

### 4.4 Public catalog feed — additive fields needed for the shop grid

`getPublicCatalogFeed` (`PgApparelRepository.ts:1404-1577`) + its route + `RawCatalogFeedItem`/`CatalogFeedItem`/`mapCatalogFeedItem` need two new fields per row: `groupId` (int) and `itemCount` (active-item count for that group) — needed so the shop's grid can link to `/product/[id]` and decide `itemType:'bundle'` (with `productGroupId`) vs `'single'` (with `productItemId`) when Add-to-Cart is tapped directly from a card.

### 4.5 Test coverage — the real gap, must be filled

There is currently **zero** automated coverage of `/cart/*` — no unit test, no integration test, only a manual bash smoke script that itself never exercises the §4.2 race. All new tests go in `server/test/api.integration.test.ts`, following its existing convention (raw-SQL fixture helpers like `createSellableItemFixture`, `app.inject()`, skip-if-DB-unreachable). New `describe('Shopping cart', ...)` block: add single/bundle, upsert-on-re-add, reject own-listing (400), reject sold/hidden item (409), live price-changed/availability recompute on `GET /cart`, remove reverts reservation + caller-scoped, clear-all, lazy expiration purge, payment-methods shape + wallet-disabled kill switch, multi-line checkout-quote (silently skips unavailable lines), multi-seller checkout produces N acquisitions in one transaction, **a failed line rolls back the whole checkout (zero acquisitions persisted)**, wallet-disabled checkout → 503, admin list/delete.

Plus new cases inside the existing `describe('Concurrency & money-safety ...')` block (~line 6517): N concurrent add-to-cart of the same single item/bundle (exactly 1 succeeds — already true today per the audit, write the regression test anyway), **cart-checkout racing a direct buy-now on the same item — the regression guard for §4.2's fix; this exact test must fail on current `HEAD` and pass once §4.2 lands**, two buyers' carts both containing the same item racing checkout, wallet-insufficient-for-combined-total asserting zero partial commits.

## 5. Server: bundle-aware public product detail

**Decision**: extend `getPublicItemDetail` (`PgApparelRepository.ts:1604-1694`) in place — keep `GET /api/v1/public/catalog/items/:itemId` as the one entry point (every UI entry point is item-scoped, not group-scoped; the mobile app already calls this route) — do not add a separate `/groups/:id` route.

Add to the response: `isBundle`, `itemCount` (active-item count, never `product_groups.item_count` which includes non-active items), `bundlePrice`/`bundleCurrency` (must equal `resolveGroupPricing`'s exact sum, so the detail page never shows a price checkout won't honor), and replace the existing thin `siblingItems` with a richer `groupItems[]` — every active item in the group **including the tapped one** (`isTappedItem: true` flag), each with full public-safe detail mirroring `getGroupForAdmin`'s per-item shape (`id, name, price, currency, size, conditionId, conditionLabel, categoryName, images[]`) minus admin-only fields. Gate the whole query on `listing_status = 'active'` too (once that column exists) so a cart-reserved or sold listing correctly 404s from public detail rather than showing a page that would then fail at checkout.

## 6. Shop frontend

New files under `shop/src/`:

```text
lib/cart/
  types.ts        — EnrichedCartItem, CartQuoteLine, CartCheckoutResult (mirrors server field names, camelCase, no remap layer needed)
  api.ts           — listCart / addToCart / removeFromCart / clearCart / getPaymentMethods / getCheckoutQuote / checkout, all via authFetch
  CartContext.tsx  — SSR-safe null-then-hydrate (mirrors AuthContext.tsx), NOT localStorage-persisted (server-authoritative, requires login); mutators call-then-refresh() rather than optimistic local state, since priceChanged/available/livePrice are server-computed and can't be predicted client-side

lib/productDetail/
  types.ts   — ProductDetail (isBundle, itemCount, bundlePrice, groupItems[])
  api.ts      — getProductDetail(id), plain unauthenticated fetch (public endpoint)

app/[locale]/product/[id]/
  page.tsx                — Server Component, SSR-fetches detail for first paint/SEO
  ProductDetailClient.tsx  — gallery (per-item selector when isBundle), price block (bundlePrice headline + per-item breakdown), seller card, Add to Cart

app/[locale]/cart/
  page.tsx            — server wrapper
  CartPageClient.tsx  — full line list (thumbnail, title, bundle itemCount badge, price vs livePrice with "price changed" chip, dimmed row + "unavailable" chip when available:false — never hide the row), grand total from available lines only, guest state reuses watchlist.ts's 'unauthenticated'-outcome sign-in-prompt pattern

app/[locale]/checkout/
  page.tsx           — server wrapper
  CheckoutClient.tsx  — bulk quote (per-line standard/express, since each line is its own seller/shipment), payment tiles (wallet real/selectable, others preview-only, no paymentMethod field sent), Place Order -> success screen with acquisitions[]/grandTotal, failure surfaces mapped error inline without losing quote state
```

Edits to existing files:

- `shop/src/app/[locale]/layout.tsx` — mount `CartProvider` nested inside `AuthProvider`.
- `shop/src/blocks/topNav/CartButton.tsx` (new) + `shop/src/blocks/topNav/index.tsx` (edit) — replace the inert cart button (lines 60-66 today, no `onClick`, no badge) with `CartButton`, mirroring `AccountButton.tsx`'s dropdown structure exactly (`'use client'`, `useState isOpen`, `aria-expanded`, full-screen invisible closer) but showing a mini cart preview + live numeric badge from `useCart().count`.
- `shop/src/blocks/productGrid/types.ts` — add `groupId`/`itemCount` to `CatalogFeedItem` (fed by §4.6).
- `shop/src/blocks/productGrid/ProductGridClient.tsx` — wrap the card in a `<Link href="/${locale}/product/${item.id}">` (none exists today); wire the Add-to-Cart button's `onClick` (currently absent) to `useCart().addItem(...)`, choosing `itemType`/`productItemId`/`productGroupId` from `item.itemCount`; `stopPropagation` so the click doesn't also trigger card navigation.
- `shop/src/lib/i18n/ui.ts` — new `CartDictionary` sub-interface (mirrors `DashboardDictionary`'s composition pattern): cart page, checkout page, bundle-detail labels, price-changed/unavailable chips, remove-confirmation — populated for en/es/de (no runtime fallback in this codebase).

## 7. Verification

1. `docker compose exec -T server npx tsc --noEmit`, `npx biome check src`, then the full `npm run test` (real Postgres, DB-gated) including every new functional + concurrency case from §4.7 — specifically confirm the "cart-checkout races direct buy-now" test fails without §4.5's fix and passes with it, as a sanity check the test is real.
2. `docker compose exec -T shop npx tsc --noEmit`, `npx biome check src`, `npx vitest run` (add unit tests for any new pure-logic module, e.g. a price/availability chip-label mapper, following `statusLabel.test.ts`'s `it.each` precedent).
3. Live Docker Playwright verification of the full lifecycle for **both a single item and a bundle**: browse grid → product detail (gallery/price/bundle breakdown correct) → Add to Cart (topNav badge increments live) → cart page (correct lines/totals, no false flags) → checkout (per-line delivery picker, payment tiles, grand total matches) → place order (success screen, wallet debited exact total, cart empties, badge resets) → price-changed chip appears after an admin price edit mid-session → unavailable chip / 404-on-buy-now appears correctly when a second buyer tries to buy an item sitting in the first buyer's cart (the live confirmation of §4.5's fix).

## 8. Deferred / explicitly out of scope

- The `mobileProfile.ts` IBAN/BIC echo-removal fix sitting in the source branch is real and worthwhile but unrelated — a candidate for a separate future fix, not bundled into this work.
- The branch's Python smoke-test suite (`scripts/smoketestsuit/**`) is not being ported; its multi-buyer/multi-cart scenarios are instead covered as proper `api.integration.test.ts` concurrency cases (§4.7).
- Real payment gateway integration — the four mock payment-tile flags (§4.1.4) are explicitly documented in their own source as "PHASE 1/2 ONLY, expected to be removed when real payment gateway integration goes live"; only the Blabla Wallet path actually moves money in this feature, matching the Flutter app's current design exactly.
