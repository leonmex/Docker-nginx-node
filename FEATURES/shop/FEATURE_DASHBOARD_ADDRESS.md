# Shop Feature: Profile & Shipping (`/dashboard/addresses`)

Status: **spec — not yet implemented.** Design source: `/mnt/junglenas/DesignWebSite/account-shipping-address/stitch_responsive_product_list_layout/screen.png` (+ `DESIGN.md`, `code.html`). Same "Core Admin" token set already in `shop/src/themes/default.css` — no new tokens needed.

This upgrades the existing `/dashboard/addresses` page (built in Part C: list/add/delete/set-default via `AddressesClient.tsx`) into the fuller "Profile & Shipping" page the design shows: an **Account Information** card (name/email/password) above the existing **Address Book**, now with a real **Edit** action the Part C version doesn't have, plus a "Professional Seller" status indicator in the page header.

## 1. Executive Summary

The design combines two concerns on one page: account identity (Full Name, Email, Password, a "Professional Seller" toggle) and the address book (multiple cards, each with Edit/Remove/Set Default, an "Add New Address" affordance). Sidebar in this mockup matches what's already built exactly (`Dashboard, My Products, My Sales, Address Book, Payments & Wallet, Invoices, Professional Seller: Sales Analytics/Revenue Reports/Best Customers, Settings, Support`) — unlike the Transactions design, no nav changes needed here.

**Important, load-bearing research finding before implementing any of the "Account Information" card:** the backend does not support most of what this card visually implies. Read §3 before writing frontend code — building against an endpoint that doesn't exist, or wiring a toggle the API explicitly marks read-only, would ship a control that silently does nothing or 404s.

## 2. Prior Art

- **Server API reference:** `server/docs/doc_enpoints_v3_07082026.md` — `GET /api/me` (full profile aggregate, line ~722) and the `/api/me/*` table (line ~4858).
- **Server route implementation:** `server/src/routes/mobileProfile.ts` (account info), `server/src/routes/addresses.ts` (address CRUD — already consumed by the existing Part C `AddressesClient.tsx`).
- **Server domain types:** `server/src/domain/address.types.ts` (`CustomerAddress`, `CreateAddressInput`/`UpdateAddressInput`).
- **Reference client implementation:** `app-blablaragsandrigs/lib/features/profile/` (`domain/user_profile.dart`, `domain/profile_api.dart`, `data/http_profile_api.dart`, `presentation/profile_section_screen.dart`) — the Flutter app's own Profile Hub, same backend. **Confirmed the Flutter app has no password-change screen either** (`grep` across the whole `lib/` tree for `changePassword`/`ChangePassword` returns nothing) — this is a real cross-platform gap, not something specific to a web port.

## 3. Critical Findings — read before implementing

### 3.1 Email is view-only. Don't build an editable email field.

`GET /api/me`'s response includes a backend-computed `"fieldAccess": { "accountSettings.email": "viewOnly" }`. There is no PATCH endpoint for email anywhere in the API surface (confirmed via full route-heading grep of the endpoint doc — only `GET /api/me` exists under that namespace besides the 9 `/api/me/*` sub-routes, none of which touch email). Render Email Address as a disabled/read-only input, exactly as the design shows it visually (it happens to already look like a static field in the mockup) — just don't wire a save handler to it.

### 3.2 "Professional Seller" is view-only from the account holder's side. Don't build a working toggle.

`GET /api/me`'s response includes `"sectionAccess": { "proSeller": "viewOnly" }`, and `server/docs/doc_enpoints_v3_07082026.md`'s Pro Seller Management section says outright: *"The ONLY write path `user_pro_seller` data ever has — the mobile app's own Profile > Pro Seller section is permanently view-only to the account holder."* Enabling Pro Seller status is an **admin-only** action (`PATCH /api/admin/mobile-accounts/:id/pro-seller`, dashboard-privilege-gated, not reachable from a mobile-JWT session at all). The design's switch must be rendered as a **read-only status indicator** (on/off badge, or a visually-disabled switch), never a real interactive control. If self-service Pro Seller enrollment is wanted later, that's a distinct, separately-scoped feature (an application/request flow with admin review) — not a toggle.

### 3.3 There is no password-change endpoint. "Change Password" has nothing to call.

No route anywhere in `server/src/routes/` updates a mobile account's password outside of registration. Confirmed absent both server-side and in the Flutter client. Recommendation: **omit the "Change Password" button/flow from this pass.** If it's wanted, that's real new backend work (a new endpoint — almost certainly wanting current-password re-verification before accepting a new one, given it's a security-sensitive mutation) and belongs in its own feature doc, not bundled into an address-book page. Flag this to the user before scoping it in.

### 3.4 Full Name *is* real and editable — via `PATCH /api/me/public-profile`.

```
PATCH /api/me/public-profile
Body: { displayName?: string (maxLength 128), bio?: string (maxLength 1000) }
```
`displayName` is the design's "Full Name" field. `bio` has no corresponding field in this design — don't add a UI control for it in this pass, the endpoint just happens to accept it too.

### 3.5 Security: this endpoint's response leaks plaintext IBAN/BIC. Handle the response narrowly.

Already a confirmed, documented finding in the endpoint doc (2026-08-07 audit): `PATCH /api/me/public-profile` (like 6 of the other 8 `/api/me/*` routes) re-fetches and returns the **entire profile aggregate**, including `payment.iban`/`payment.bic` in **plaintext** (decrypted server-side specifically for display, deliberately never cached — see that repository's own doc comment on why it's excluded from the Redis-backed `Cached*` decorator pattern every other repository uses). This is same-account-only exposure (not a cross-user leak), but real over-exposure of sensitive data to the client that only asked to change a display name.

**Frontend handling rule for this feature:** when calling `PATCH /api/me/public-profile`, extract only `data.publicProfile.displayName` from the response and discard the rest immediately — never store the full response object in React state, never log it, never pass it through to any error-reporting/telemetry pipeline. Mirrors `customers.ts`'s own existing fix pattern for the *admin* side of this same data-minimization issue (calls the same repository method but excludes `payment` from what it returns) — the shop's frontend can't fix the over-broad server response, but it can make sure it never lets that extra data leave the immediate response handler.

### 3.6 Address "type" icons in the mockup aren't backed by real data.

The design shows a house icon for "Studio (Primary)" and a building icon for "Fulfillment Center" — implying a categorized address type. The real `CustomerAddress` type (`server/src/domain/address.types.ts`) has no such field (`kind` is `'delivery' | 'collection_point' | ...`, an internal logistics distinction, not a user-facing "home vs. business" label; `label` is free text). Don't invent a fake type-inference heuristic off the label string. Use one consistent icon (`IconMapPin`, already in use on this page) for every address card — a deliberate, honest simplification, not a missing feature.

## 4. API Endpoints This Feature Uses

| Endpoint | Used for | Status |
|---|---|---|
| `GET /api/me` | Load current `displayName` + (read-only) `email`, pro-seller status | Real, already used nowhere in the shop yet |
| `PATCH /api/me/public-profile` | Save Full Name | Real — see §3.5 for the response-handling rule |
| `GET /api/v1/addresses` | Address Book list | Already used by the existing `AddressesClient.tsx` |
| `POST /api/v1/addresses` | Add New Address | Already used |
| `PATCH /api/v1/addresses/:id` | **New for this pass** — Edit an existing address (Part C only ever built add/delete/set-default, never edit, even though the server route has supported it since Part C) | Real, unused until now |
| `DELETE /api/v1/addresses/:id` | Remove | Already used |
| `POST /api/v1/addresses/:id/default` | Set Default | Already used |

No new server code. Every endpoint above already exists.

## 5. Frontend Architecture

Modified: `shop/src/app/[locale]/dashboard/addresses/`

```
AddressesClient.tsx   — split into two sections on one page:
  1. AccountInfoCard   — Full Name (editable), Email (disabled/read-only),
                          Professional Seller status (read-only badge),
                          Save Changes button. No Password field/button.
  2. AddressBookCard   — existing list/add/delete/set-default, PLUS:
       - Edit action per card (opens the same form used for Add, pre-filled,
         calls PATCH instead of POST)
       - Country stored as `countryCode` (unchanged, already correct
         server-side) but DISPLAYED as a full name (`Intl.DisplayNames`,
         locale-aware — matches the design showing "United States", not "US")
       - Country INPUT becomes a real `<select>` of ISO country
         names/codes instead of the current raw 2-character text box —
         meaningfully better UX, low effort, no backend change needed
         (countryCode validation server-side is already just
         minLength:2/maxLength:2, any 2-char value passes; a select just
         makes it hard for a user to enter a nonsense code)
```

New: `shop/src/lib/profile/` (mirrors the existing `lib/auth/` structure)

```
lib/profile/
  types.ts   — PublicProfile/Account/ProSeller subset of the GET /api/me
               shape actually used here (NOT the full aggregate — no
               payment/personalization/notifications/privacy/friends
               fields modeled at all, precisely so nothing tempts a future
               edit here to accidentally render/log/store them)
  api.ts     — getMe() (GET /api/me), updateDisplayName(name) (PATCH
               .../public-profile, returns ONLY { displayName } per §3.5,
               never the raw response)
```

`lib/auth/api.ts`-style address functions get 1 addition: `updateAddress(id, input)` (PATCH), added next to the existing `listAddresses`/`createAddress`/`deleteAddress`/`setDefaultAddress` — wait, check: Part C's `AddressesClient.tsx` currently calls `authFetch` directly inline rather than through a dedicated `lib/addresses/api.ts` module. Decide at implementation time whether to extract one now (would also make unit-testing the mutations per §7 cleaner) or keep the inline pattern for consistency with how it's written today — leaning towards extracting, since this feature is already touching that file's mutation logic and §7 wants these functions unit-tested in isolation.

## 6. i18n

Extend the existing `dashboard` dictionary section (en/es/de) rather than adding a new one — this page already has `addressesTitle`/`addressesSubtitle`/etc. Add: `accountInfoTitle`, `fullNameLabel`, `emailLabel` (or reuse `authPages.emailLabel`), `saveChanges`, `professionalSellerLabel`, `professionalSellerActive`, `professionalSellerInactive`, `countryLabel`, `editAddress`, `saveAddressEdits`.

Page title changes from the current "Address Book" to match the design's "Profile & Shipping" — update `addressesTitle`/`addressesSubtitle` values in all 3 locales (content change, not a new key).

## 7. Testing Plan

Builds on the Vitest bootstrap from `FEATURE_DASHBOARD_TRANSACTIONS.md` §7 (shared infra — implement whichever of these two features lands first sets it up for both). Per the same ">20% calculation or server-write logic" bar:

- **`lib/profile/api.ts`** — `updateDisplayName`: mock `authFetch`, assert the request body only ever contains `displayName` (never accidentally forwards `bio` or anything else), and — this is the important one given §3.5 — assert the function's return value contains ONLY `{ displayName }`, proving the extra aggregate fields (payment/etc.) never survive past this function even though the mocked response includes them. This test is the actual enforcement mechanism for the data-minimization rule in §3.5, not just documentation of it.
- **Address `updateAddress` addition** — same pattern as the existing (soon to be extracted) address mutation tests: correct URL/method/body, success and error paths.
- **Country-name display helper** (`Intl.DisplayNames` wrapper, if extracted as its own function rather than inlined) — a few known-code assertions (`DE` -> `Germany`, `US` -> `United States`) per locale.

## 8. Telemetry

No money/wallet movement anywhere in this feature (name edits and address CRUD, not payments). No new backend code either (§4 — every endpoint already exists and, if it touches anything telemetry-worthy, is already instrumented at the source). Nothing to add here; noted for completeness/consistency with the Transactions doc's equivalent section.

## 9. Explicitly Deferred / Flagged for the user

- **Change Password** — no endpoint exists (§3.3). Omit from this pass; separate feature if wanted.
- **Editable email** — backend-flagged view-only (§3.1). Not a scope cut so much as "the API says no."
- **Self-service Professional Seller enrollment** — backend-flagged view-only (§3.2). A real "apply to become a Pro Seller" flow would need a genuinely new request/review endpoint and is its own feature, not a toggle.
- **`bio` field** — accepted by the same endpoint as displayName but has no corresponding UI in this design; not adding a control for it speculatively.

## 10. Verification Plan (once implemented)

```bash
docker compose exec -T shop npx tsc --noEmit
docker compose exec -T shop npx biome check src
docker compose exec -T shop npx vitest run
```

Live (Docker Playwright harness):
- Load `/dashboard/addresses`: Full Name pre-filled from `GET /api/me`, Email shown but disabled, Professional Seller shown as a read-only status (test against a non-pro-seller test account — confirm it reads "inactive"/off, not an interactive control).
- Edit Full Name, Save Changes, reload the page, confirm the new name persisted (round-trips through `PATCH` then a fresh `GET /api/me`).
- Address Book: existing add/delete/set-default still work (regression check on the Part C functionality), PLUS the new Edit action — open edit on an existing address, change a field, save, confirm the card reflects the change without a full page reload.
- Country shows as a full localized name on cards; the add/edit form's country control is a select, not free text.
- Confirm via the Network tab (or a quick server log check) that the `PATCH /api/me/public-profile` response is never written to `localStorage`/`console` anywhere in the client code path — the one security-sensitive check specific to this feature.
