# Feature: Clone Product Data Into the Shopping Cart Row (item_snapshot)

**Document Target Path**: `/Users/nbarrera/projects/Docker/node-nginx-clean/FEATURES/App/FEATURE_CLON_PRODUCT_DATA_IN_SHOPPING_CART_IN_APP_DB.md`
**Target Agent**: Claude
**Author**: Claude, from a bug the user hit live on device (2026-08-12) after wiring "tap a cart item → open its Product Detail screen" in the Flutter app (`blablaragsandrigs`)
**Date**: 2026-08-12
**Status**: Analysis + plan only — **no code changed yet**. Awaiting the user's go-ahead before touching `node-nginx-clean/server`.

---

## 1. The bug that triggered this

The Flutter Cart screen (`lib/features/cart/presentation/cart_screen.dart`)
was made tappable — tapping a cart line pushes
`AppRoutes.productDetailPath(item.productItemId)`, which calls
`GET /v1/public/catalog/items/:itemId`. On-device logs immediately showed:

```
I/flutter: blablarags.auth: onError: GET /v1/public/catalog/items/178 -> 404
I/flutter: blablarags.auth: onError: GET /v1/public/catalog/items/177 -> 404
```

Root cause, confirmed by reading both sides:

- Adding *anything* to the cart calls `reserveGroup()`
  (`server/src/repositories/PgShoppingCartRepository.ts:323-332`), which
  sets `product_groups.listing_status = 'reserved'`.
- The public item-detail query
  (`server/src/repositories/PgApparelRepository.ts:1659`) filters
  `WHERE i.item_status = 'active' AND g.listing_status = 'active'`.
- The route has no auth (`server/src/routes/apparel.ts:442`,
  `public/catalog/items/:itemId`) — it can't know "the requester is the
  same account that reserved this," so it has no exception to make.

**Net effect: every single item sitting in a cart 404s on the endpoint the
client needs to show its detail — always, not intermittently, for anyone,
including the account that reserved it.** This is a real gap, not a
client bug, and not something fixable purely in Flutter.

## 2. Decision (the user's, 2026-08-12)

Rather than making the public route auth-aware (see §4 for why that was
the other option), the user chose: **capture a full detail snapshot of
the product at the moment it's added to the cart, store it as JSON on the
cart line itself, and have the Cart tab's "view detail" flow read that
snapshot instead of re-querying the live catalog.**

Rationale, in the user's own words: save the information locally in the
app DB as JSON so we don't stress the database or bandwidth — images
still come from the CDN (only URLs are stored, not image bytes), we're
just copying the product's structured data once, at add-time. A
follow-up (separate, not in this doc's scope) will cap how many items a
cart can hold, to bound how much of this JSON accumulates.

### Why this fits the existing codebase, not just this one bug

`shopping_cart_items.price` already does exactly this pattern for one
field: it freezes the price at add-time and compares it against the live
`product_items.price` on every read to compute `priceChanged`
(migration `0052_shopping_cart.sql`'s own doc comment). This feature is
that same idea — freeze-at-add-time, don't trust it as live truth —
generalized from one column to the whole detail payload.

### Alternative considered and rejected

A `GET /v1/cart/items/:cartItemId/detail` authenticated endpoint that
live-joins the catalog with a `reserved_by_account_id = accountId`
exception. Architecturally simpler (no schema change, no staleness), but
rejected because:
- It needs a brand-new endpoint + an extra network round-trip per tap.
- The snapshot approach needs zero extra round-trips — the data already
  rides along in the `GET /cart` payload the app fetches today.
- It doesn't fit the "freeze at add-time" convention already established
  by the `price` column.

### Known trade-offs, accepted going in

1. **Staleness while reserved.** If a seller edits description/photos/
   condition while the item is reserved in someone's cart, the buyer's
   cart-detail view won't reflect that edit until the item leaves the
   cart. Treated as acceptable — arguably even correct (shows what the
   buyer saw when they added it), and the item's composition can't
   change while reserved anyway (bundle membership is locked).
2. **Row size.** JSONB snapshot roughly doubles a cart line's storage
   footprint vs. today's scalar-only columns. Bounded by (a) the
   existing 7-day expiration purge (row *count* over time) and (b) the
   planned items-per-cart cap (worst case at any instant) — the cap is
   the one that actually matters here, not the purge.

## 3. Snapshot shape — reuse, don't reinvent

`PgApparelRepository.getPublicItemDetail(itemId)`
(`server/src/repositories/PgApparelRepository.ts:1625-1780`) already
returns exactly the JSON shape the Flutter client needs: it's the same
payload the public detail endpoint returns today, and it's already
parsed unchanged by `PublicItemDetail.fromJson`
(`blablaragsandrigs/lib/features/product_detail/domain/public_item_detail.dart:73-109`).
**The plan is to call this exact method at add-time and store its return
value verbatim** — no new shape to design, no new client-side parser to
write.

For `single` lines: call `getPublicItemDetail(productItemId)` directly.

For `bundle` lines: `getPublicItemDetail` already includes every active
sibling in the group (`groupItems`) when called with ANY one item id
from that group — there's no separate "group snapshot" method needed.
The bundle `addItem` branch's existing group query
(`PgShoppingCartRepository.ts:423-438`) will need one extra column: a
representative active item id from the group (e.g.
`(ARRAY_AGG(pi.id) FILTER (WHERE pi.item_status='active'))[1] AS sample_item_id`),
then call `getPublicItemDetail(sampleItemId)` with that.

## 4. Concrete implementation steps (not yet done)

### Server (`node-nginx-clean/server`)

1. **Migration** `0058_shopping_cart_item_snapshot.sql` — nullable
   `ALTER TABLE shopping_cart_items ADD COLUMN IF NOT EXISTS item_snapshot JSONB;`.
   Nullable and no backfill: pre-existing cart rows just have no
   snapshot, client falls back to "detail unavailable" for those rather
   than attempting the live (guaranteed-404) fetch.
2. **Domain type** (`server/src/domain/shoppingCart.types.ts`) — add
   `itemSnapshot: Record<string, unknown> | null;` to
   `ShoppingCartItem` (flows through to `EnrichedCartItem` via
   `extends`).
3. **Repository** (`server/src/repositories/PgShoppingCartRepository.ts`):
   - Constructor needs a second dependency, `apparelRepo:
     IApparelRepository` (specifically its `getPublicItemDetail`
     method) — the two repositories are currently independent classes.
   - `CartItemRow` interface: add `item_snapshot: Record<string,
     unknown> | null;` (node-postgres auto-parses JSONB to a JS object,
     confirmed by existing convention in `PgAccountRepository.ts`/
     `PgMobileProfileRepository.ts`).
   - `enrichRows`: pass `itemSnapshot: row.item_snapshot ?? null` through
     to the returned `EnrichedCartItem`.
   - `addItem`, single branch: after confirming the item is
     `active` (before `reserveGroup` runs), call
     `apparelRepo.getPublicItemDetail(itemId)` and pass
     `JSON.stringify(snapshot)` into the INSERT as a new
     `item_snapshot` column, cast `$N::jsonb` — same parameter-binding
     convention already used for JSONB columns elsewhere in this repo
     (`PgAddressRepository.ts:111`, `PgMobileProfileRepository.ts:340`).
   - `addItem`, bundle branch: extend the existing group query with the
     `sample_item_id` column described in §3, call
     `getPublicItemDetail(sampleItemId)`, store the same way.
   - Both branches' `ON CONFLICT ... DO UPDATE` (re-add upsert): also
     set `item_snapshot = EXCLUDED.item_snapshot` so a re-add refreshes
     the snapshot too (harmless, keeps it current if the item changed
     before being re-added).
4. **Wiring** (`server/src/index.ts`) — `apparelRepo` is already
   constructed (line ~135) before `shoppingCartRepo` (line ~163), so
   change the latter to `new PgShoppingCartRepository(db, apparelRepo)`.
5. Route (`server/src/routes/shoppingCart.ts`) needs **no change** —
   it returns `EnrichedCartItem[]` as-is, so `itemSnapshot` flows to the
   JSON response automatically once it's on the type.

Per this repo's standing convention, Claude writes the code but does
**not** run `npm tsc`/`test`/`lint`/docker itself — the user CRs and runs
those, then pastes output back.

### Client (`blablaragsandrigs` Flutter app)

1. `CartItem` domain model
   (`lib/features/cart/domain/cart_item.dart`) — add a nullable
   snapshot field, parsed via the existing
   `PublicItemDetail.fromJson` (no new parsing logic needed, per §3).
2. Cart → Product Detail navigation
   (`lib/features/cart/presentation/cart_screen.dart`) — instead of
   pushing by id and hitting the network (today's now-known-broken
   path), pass the already-parsed `PublicItemDetail` through
   `context.push(..., extra: snapshot)` and have
   `MarketplaceItemDetailScreen` accept a pre-loaded detail, skipping
   `productDetailProvider`'s network fetch when one is supplied.
   - Bundle lines still have no `productItemId` today — but they now
     DO have a snapshot (see §3), so this actually removes the
     single-item-only limitation from the earlier client-only fix
     (previous state: bundle cart lines were left non-tappable because
     there was no id to fetch by; with the snapshot, they don't need
     an id at all).
3. Rows with `detailSnapshot == null` (pre-migration cart lines) stay
   non-tappable — same "don't attempt a call known to fail" posture as
   the server-side null fallback in step 1 above.

## 5. What this document does NOT do

No code in either repository has been changed to produce this document.
The earlier client-only fix (tap-to-detail wired directly to
`GET /v1/public/catalog/items/:itemId`) is still in place in
`cart_screen.dart` and is currently broken for exactly the reason in §1
— it should be treated as superseded by this plan once implemented, not
left as-is.

## 6. Follow-up explicitly out of scope here

Cart item-count cap (mentioned by the user as the compensating control
for JSONB row growth, §2) — no number decided yet, needs its own pass
once this lands.
