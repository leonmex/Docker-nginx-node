# Feature V2: Clone Product Data Into Shopping Cart Row (item_snapshot) & Dynamic Cart Item Limit

**Document Target Path**: `/Users/nbarrera/projects/Docker/node-nginx-clean/FEATURES/App/FEATURE_CLON_PRODUCT_DATA_IN_SHOPPING_CART_IN_APP_DB_V2.md`
**Target Agent**: Claude
**Author**: Antigravity (AI Assistant)
**Date**: 2026-08-12
**Status**: Ready for implementation — Comprehensive architectural blueprint updated against database schema, dashboard configuration, user role checks (Normal Buyer vs. Pro Seller), and high-concurrency (100,000 active users) requirements.

---

## 1. Problem Statement & Root Cause

### The Bug
In the Flutter mobile application (`blablaragsandrigs`), tapping an item in the Cart screen (`lib/features/cart/presentation/cart_screen.dart`) navigates to `AppRoutes.productDetailPath(item.productItemId)`, invoking the public catalog endpoint:
`GET /v1/public/catalog/items/:itemId`

On device execution, this produces HTTP `404 Not Found` errors:
```text
I/flutter: blablarags.auth: onError: GET /v1/public/catalog/items/178 -> 404
I/flutter: blablarags.auth: onError: GET /v1/public/catalog/items/177 -> 404
```

### Database & Domain Mechanics
1. **Cart Reservation**: Adding an item/bundle to the cart invokes `reserveGroup()` (`server/src/repositories/PgShoppingCartRepository.ts`), setting `product_groups.listing_status = 'reserved'`.
2. **Catalog Query Guard**: The public detail query (`PgApparelRepository.getPublicItemDetail`) contains strict SQL filters:
   `WHERE i.item_status = 'active' AND g.listing_status = 'active'`
3. **Unauthenticated Public Endpoint**: The route `GET /v1/public/catalog/items/:itemId` (`server/src/routes/apparel.ts`) is unauthenticated. It cannot evaluate whether the requesting user is the account holding the reservation.

**Result**: Any item added to a cart immediately 404s on the public catalog detail route for all users (including the cart owner).

---

## 2. Architectural Solution (V2 Design)

### Part A: Freezing Detail Snapshot at Add-Time
Instead of introducing complex authenticated authorization logic into the public catalog query or executing extra round-trips, the application will **capture a complete JSON snapshot of the product detail at the moment it is added to the cart**.

* **Zero Extra Network Round-Trips**: Snapshot data is delivered inside the existing `GET /v1/cart` payload.
* **Consistency with Schema Design**: Follows the existing freeze-at-add-time pattern used by `shopping_cart_items.price` (Migration `0052_shopping_cart.sql`), which freezes price at add-time and compares against live price on read.
* **Bandwidth & Storage Optimization**: Only structured JSON metadata (including image CDN URLs) is stored. Image binary data remains hosted on the CDN.

### Part B: Dynamic Cart Item Cap by User Role (Pro-Seller vs. Normal Buyer)
To prevent memory bloat, bound JSON accumulation, and provide a premium incentive for Pro Sellers:
* **System Settings Configuration**: Managed via Dashboard (`admin/system/settings/shopping-cart` path):
  * `shopping_cart.max_items_normal_user`: Default **5** (Maximum items in cart for standard buyers).
  * `shopping_cart.max_items_pro_seller`: Default **20** (or configurable higher number for Pro Sellers).
* **Role Evaluation**: Evaluates seller status via `user_pro_seller.is_pro_seller` (or account pro flag).
* **Enforcement**:
  * **Server-Side**: `PgShoppingCartRepository.addItem()` checks the current active item count against the dynamic limit resolved from `system_settings` for the user's role. Throws a distinct error (e.g. `CART_ITEM_LIMIT_EXCEEDED`) if exceeded.
  * **Client-Side (Flutter App)**: If a normal buyer attempts to add more items beyond their allowed limit (e.g. > 5 items), the app catches the error or checks locally and presents a dialog/snackbar:
    > **"Just Pro Sellers can add more items."**
    > Includes an inline action button/link: **"Become a Pro Seller"** -> triggers a dialog or page stating **"Coming Soon"**.

---

## 3. Database Context & ERD Alignment

* Reference ERD: `server/docs/database-entity-relaction.md` (§ "Shopping Cart" & "System Settings")
* Target Tables:
  * `shopping_cart_items`: Added `item_snapshot JSONB` column.
  * `system_settings`: Seeded two new keys in `admin/accounts/shopping-carts` (`admin/system/settings/shopping-cart` namespace):
    * `shopping_cart.max_items_normal_user` (`integer`, default `'5'`)
    * `shopping_cart.max_items_pro_seller` (`integer`, default `'20'`)
  * `user_pro_seller`: Consulted via `account_id` to evaluate `is_pro_seller`.

---

## 4. High-Scale Analysis (100,000 Active Users)

### Storage Footprint with Cart Cap
* Average Snapshot Size: ~2 KB – 4 KB per cart row.
* **Capped Storage Impact**:
  * Normal users (95% of users): Max 5 items $\rightarrow$ Max 20 KB per user.
  * $100,000 \text{ users} \times \text{avg 4 items/cart} = 400,000 \text{ rows}$.
  * Total DB Overhead: Capped strictly at $\le 1.2 \text{ GB}$ JSONB storage across the cluster.
* **Purge Discipline**: Unchanged cart rows are automatically purged after expiration (`shopping_cart.expiration_days` = 7 days).

### Write Path Efficiency & Transaction Scope
* **Transaction Isolation**: Calling `apparelRepo.getPublicItemDetail()` performs read queries across `product_items`, `item_images`, `product_groups`, and taxonomy tables.
* **Requirement**: `getPublicItemDetail()` MUST be executed **BEFORE** acquiring group reservation locks or starting write transactions in `PgShoppingCartRepository.ts` to keep write transactions short and prevent lock contention.

---

## 5. Detailed Implementation Blueprint

### Step 1: Database Migration
**File**: `server/db/migrations/0058_shopping_cart_snapshot_and_limits.sql`
```sql
-- Migration 0058: Add item_snapshot column to shopping_cart_items
-- and seed cart quantity limits for normal users vs pro-sellers.

BEGIN;

ALTER TABLE shopping_cart_items 
ADD COLUMN IF NOT EXISTS item_snapshot JSONB;

COMMENT ON COLUMN shopping_cart_items.item_snapshot IS 
'Frozen product detail snapshot captured at add-to-cart time (JSONB). Used by mobile cart screen to render item detail without hitting live active catalog query.';

INSERT INTO system_settings (key, type_of_settings, value, data_type, description)
VALUES
  ('shopping_cart.max_items_normal_user', 'admin/accounts/shopping-carts', '5', 'integer',
   'Maximum number of items a standard (non-Pro) user can hold in their shopping cart simultaneously.'),
  ('shopping_cart.max_items_pro_seller', 'admin/accounts/shopping-carts', '20', 'integer',
   'Maximum number of items a Pro Seller user can hold in their shopping cart simultaneously.')
ON CONFLICT (key) DO NOTHING;

COMMIT;
```

### Step 2: System Settings & Cart Types (`server/src/domain/shoppingCart.types.ts`)
Update `ShoppingCartItem` and constants:
```typescript
export interface ShoppingCartItem {
  id: number;
  cartId: number;
  itemType: 'single' | 'bundle';
  productItemId: number | null;
  productGroupId: number | null;
  price: number;
  currencyCode: string;
  itemSnapshot: Record<string, unknown> | null;
  createdAt: Date;
  updatedAt: Date;
}

export interface CartLimitExceededErrorDetails {
  code: 'CART_ITEM_LIMIT_EXCEEDED';
  maxAllowed: number;
  currentCount: number;
  isProSeller: boolean;
  message: string;
}
```

### Step 3: Server Repository & Enforcement (`server/src/repositories/PgShoppingCartRepository.ts`)

1. **Limit Resolution**:
   Before executing `addItem`, fetch `is_pro_seller` status for `accountId` from `user_pro_seller` table and read limits from `system_settings`:
   * Keys: `shopping_cart.max_items_normal_user` (default 5) and `shopping_cart.max_items_pro_seller` (default 20).
   * Limit = `isProSeller ? maxItemsProSeller : maxItemsNormalUser`.
2. **Item Count Check**:
   Count existing non-expired items in `shopping_cart_items` for this `cartId`.
   If `currentCount >= limit` and the item being added is a **new item** (not an existing item update):
   Throw `CartLimitExceededError` with context `{ isProSeller, maxAllowed: limit }`.

### Step 4: Dashboard Integration (`node-nginx-clean/dashboard`)
* Path: `admin/system/settings/shopping-cart` (Dashboard Settings UI).
* Expose inputs to edit:
  1. `shopping_cart.expiration_days` (Cart Expiration in Days)
  2. `shopping_cart.max_items_normal_user` (**Max Items Normal User**)
  3. `shopping_cart.max_items_pro_seller` (**Max Items Pro Sellers**)

### Step 5: Flutter Mobile App Adaptation (`blablaragsandrigs`)

1. **Model Parsing (`lib/features/cart/domain/cart_item.dart`)**:
   Add `PublicItemDetail? itemSnapshot` to `CartItem`. Parse using `PublicItemDetail.fromJson(json['itemSnapshot'])` with safety `try-catch` fallback.
2. **UI Navigation (`lib/features/cart/presentation/cart_screen.dart`)**:
   Pass pre-loaded `itemSnapshot` via `context.push(..., extra: snapshot)`.
3. **Cart Limit Error Handling**:
   When `addItem` API returns `CART_ITEM_LIMIT_EXCEEDED` (or HTTP 422/400 with limit details):
   * If `isProSeller == false`:
     Display alert/dialog:
     * Title / Message: **"Just Pro Sellers can add more items."**
     * Action Button: **"Become a Pro Seller"**
     * On Tapping Action: Display dialog / modal: **"Coming soon"**.
   * If `isProSeller == true`:
     Display alert: **"You have reached the maximum allowed items limit in your cart (X items)."**

---

## 6. Verification & Test Plan

1. **Database Migration Verification**:
   Verify column and system setting inserts:
   `SELECT key, value FROM system_settings WHERE key LIKE 'shopping_cart.max_items%';`
2. **Dashboard Settings Verification**:
   Navigate to `admin/system/settings/shopping-cart` in dashboard, update limit values, and verify persistence.
3. **Normal Buyer Add Limit Test**:
   * Set `max_items_normal_user = 5`.
   * Add 5 items to cart with a normal account $\rightarrow$ Success.
   * Add 6th item $\rightarrow$ Server rejects with `CART_ITEM_LIMIT_EXCEEDED`. Mobile displays **"Just Pro Sellers can add more items."** with "Become a Pro Seller" button leading to **"Coming soon"**.
4. **Pro Seller Add Limit Test**:
   * Switch account to `is_pro_seller = true`.
   * Add up to `max_items_pro_seller` items $\rightarrow$ Allowed beyond 5 items.
## 7. Mandatory Post-Implementation Documentation Task

Once code changes are verified and committed, the following documentation files MUST be updated to accurately reflect the schema and API additions:

1. **API Endpoints Documentation**:
   * File: `server/docs/doc_enpoints_v5_10082026.md` (and related endpoint spec files in `server/docs/`)
   * Document new `itemSnapshot` field on `EnrichedCartItem` response object for `GET /v1/cart`.
   * Document `CART_ITEM_LIMIT_EXCEEDED` error code/payload for `POST /v1/cart/items`.
   * Document new system settings endpoints for `admin/accounts/shopping-carts` (`shopping_cart.max_items_normal_user` and `shopping_cart.max_items_pro_seller`).
2. **Database ERD & Schema Documentation**:
   * File: `server/docs/database-entity-relaction.md`
   * Update Migration History section with entry for `0058_shopping_cart_snapshot_and_limits.sql`.
   * Ensure `shopping_cart_items` entity table includes `item_snapshot JSONB`.
   * Ensure `system_settings` key list includes `shopping_cart.max_items_normal_user` and `shopping_cart.max_items_pro_seller`.

