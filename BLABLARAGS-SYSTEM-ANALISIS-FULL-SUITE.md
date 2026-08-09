# BlablaRags — Full Suite System Analysis

**Date:** 2026-08-09
**Scope:** Web framework selection for the public storefront + cross-system API compatibility (web / mobile / dashboard) + validation of the endpoint & query documentation set
**Systems analysed:** `server/` (Fastify API) · `dashboard/` (Ant Design Pro) · `website/` (Astro coming-soon) · `app-blablaragsandrigs/` (Flutter mobile)

> **Status of this document:** analysis and recommendation only. No code, schema, or configuration was modified while producing it. All documentation validation was read-only; no write SQL was executed against the database.

---

## Table of contents

1. [Executive summary](#1-executive-summary)
2. [System inventory](#2-system-inventory)
3. [Framework recommendation](#3-framework-recommendation)
4. [API compatibility strategy](#4-api-compatibility-strategy)
5. [GraphQL — phase 2](#5-graphql--phase-2)
6. [Integration landmines](#6-integration-landmines)
7. [Documentation validation results](#7-documentation-validation-results)
8. [Prioritised action list](#8-prioritised-action-list)
9. [Suggested delivery sequence](#9-suggested-delivery-sequence)

---

## 1. Executive summary

**Framework recommendation: Next.js (App Router) + React 19 + TypeScript 7.**

The deciding factor is the shape of the product, not framework preference. The Flutter app declares ~60 API endpoints; exactly **two** are public/SEO-relevant. The other ~58 are authenticated, stateful application surface. This is an application with a storefront front door — not a content site — which rules out anything optimised primarily for content delivery.

**However, the framework is the easy half of the decision.** The genuine risk to web/mobile compatibility is a contract layer that does not exist yet:

- There is **no OpenAPI spec, no TypeBox, no Zod, no codegen** anywhere in the stack.
- Domain types are hand-maintained in **three parallel copies** — `server/src/domain/*.types.ts`, `dashboard/src/types/*.ts`, and Flutter's hand-written `fromJson` model classes — linked only by doc comments saying "mirrors the server's X".
- Response envelopes have **at least six competing shapes** and **four pagination conventions**.
- The dashboard's OpenAPI plugin is configured against the **stock Ant Design Pro demo spec** (`"title": "Ant Design Pro"`, `servers: localhost:8000`) — it describes nothing real.

Building a fourth consumer on top of that without first generating the contract compounds the problem rather than solving it.

**Documentation validation** (three docs, ~29,000 lines, validated against live code and the running database) confirms the cost of hand-maintenance concretely: the docs were written on 2026-08-07 and had already drifted measurably by 2026-08-09. Two live product bugs and one privilege-escalation gap were surfaced in the process.

### Headline findings

| # | Finding | Type | Severity |
|---|---|---|---|
| 1 | `autoSendEnabled` can be set with `MARKETING_CAMPAIGNS_EDIT` alone, bypassing the `trigger_send` privilege that exists to gate exactly that action | Privilege escalation | **HIGH** |
| 2 | `POST /api/admin/apparel/image-health/fix` is unauthenticated and destructive (deletes DB rows + MinIO objects) | Security | **HIGH** |
| 3 | Marketing campaign `targetRegions` filtering silently no-ops — campaigns do not reach their intended audience | Live product bug | **HIGH** |
| 4 | `db/schema.sql` has **zero drift** from the live database (66 tables, 638 columns verified) | Clean | ✅ |
| 5 | All documented auth guards match reality on both mobile and admin surfaces | Clean | ✅ |

---

## 2. System inventory

### 2.1 Server — `server/`

| Attribute | Value |
|---|---|
| Framework | Fastify `^5.8.0`, ESM, run via `tsx` (no build step) |
| Language | TypeScript `^7.0.2`, `strict`, `noUncheckedIndexedAccess`, `verbatimModuleSyntax` |
| Runtime | Node `>=22` |
| Data | `pg ^8.13` (master/replica split), `ioredis ^5.4`, `minio ^8.0.7` |
| Architecture | Hexagonal / DI — ~45 `Pg*Repository` instances assembled into a single `AppDeps`, injected into `buildApp(deps)` |
| Routes | 37 route files, **192 live routes**, registered flat in `src/app.ts:163-198` (no Fastify `prefix` used) |
| Validation | Plain Fastify JSON Schema literals — **request bodies only**. Zero `response:`, `querystring:`, or `params:` schemas |
| Tooling | Biome (not ESLint/Prettier), Vitest `^2.1.8` |
| GraphQL | **None.** No mercurius, apollo, graphql, or tRPC |
| OpenAPI | **None.** No `@fastify/swagger` |

**Four URL surfaces:**

| Surface | Prefix | Auth |
|---|---|---|
| Public/mobile versioned | `/api/v1/*` | mobile JWT (mostly); 2 fully public |
| Dashboard admin | `/api/admin/*` | session cookie + `requirePrivilege` |
| Legacy bare | `/api/*` | mixed — some mobile, some dashboard, some none |
| Health | `/api/health` | none |

Versioning is env-var string interpolation (`config.ts:148-157`), not plugin prefixing. There is no multi-version support — bumping `API_VERSION` moves every `/v1` route at once.

### 2.2 Two incompatible auth systems

This is critical for the web build and is stated explicitly in the source (`server/src/routes/accounts.ts:197-200`):

> *"Separate identity system from the dashboard's `/api/login/account` — different auth mechanism (JWT, not a cookie), different repository, different table."*

| | Dashboard | Mobile |
|---|---|---|
| Mechanism | Signed httpOnly `session` cookie | JWT bearer + refresh token |
| Cookie/token content | Literally the userid, signed with `COOKIE_SECRET` | Signed JWT, separate access/refresh secrets |
| TTL | **None set** — session cookie, no `maxAge` | access 3600s, refresh 30 days |
| `secure: true` | **Not set** | n/a |
| Storage (client) | Browser cookie jar | OS keystore (`flutter_secure_storage`) |
| User table | `users` | `mobile_accounts` |
| Gate | `app.authenticate` + `requirePrivilege` | `authenticateMobileJwt` |

**The web storefront serves mobile-app customers, so it must consume the JWT surface, not the cookie surface.**

### 2.3 Mobile app — `app-blablaragsandrigs/`

| Attribute | Value |
|---|---|
| Platform | **Flutter / Dart** — Flutter `>=3.44.0`, Dart `^3.11.0` |
| HTTP client | `dio 5.11.0`, single `DioClient` with one interceptor |
| State | `flutter_riverpod 2.6.1`, hand-written providers |
| Routing | `go_router 14.8.1` |
| Secure storage | `flutter_secure_storage 9.2.4` |
| Codegen | **None.** No `json_serializable`, no `freezed`, no OpenAPI generator. Zero `.g.dart` / `.freezed.dart` files |
| GraphQL | **None** |

**No source-level code sharing with a TypeScript web app is possible** — Dart ≠ TypeScript. Everything shared must be shared at the **contract** level: paths, wire shapes, error codes.

Two assets are directly portable to a web client:

- **`lib/core/network/api_paths.dart`** (123 lines) — the single best existing spec of the mobile API surface, including the documented `/v1` vs unversioned split. A direct port to a TS const object.
- **`lib/core/network/dio_client.dart:58-147`** — the auth interceptor semantics: attach bearer → on 401, `POST /api/accounts/refresh` on a *non-intercepted* client → retry once → on refresh failure clear + signal session-expired. Also the `X-Anonymous-Session-Id` round-trip for logged-out browsing.

**Not portable:** the SQLCipher offline outbox (`product_repository.dart`, 43 KB) and the on-device TFLite scan pipeline — mobile-only by nature.

### 2.4 Dashboard — `dashboard/`

| Attribute | Value |
|---|---|
| React | `^19.2.5` |
| TypeScript | `^7.0.2` |
| Framework | `@umijs/max ^4.6.64` |
| UI | `antd ^6.4.3`, `@ant-design/pro-components ^3.1.12-0` |
| Data | `@tanstack/react-query ^5.101.0` + Umi `request` (axios) |
| Styling | `tailwindcss ^4.3.0` (2-line stub config; theming via antd `ConfigProvider`) |
| Lint | Biome `^2.5.0` |
| Locales | **3** — `en-US`, `de-DE`, `es-ES` (~4,545 lines) |

> ⚠️ `dashboard/CLAUDE.md:37` claims "8 locales in `src/locales/`". This is **out of date** — there are 3.

**OpenAPI plugin is configured but points at the stock template spec** (`dashboard/config/oneapi.json`, 14 KB, `"title": "Ant Design Pro"`). The real API layer is hand-written in `dashboard/src/services/apparel.ts` (357 lines) and friends.

### 2.5 Website — `website/`

| Attribute | Value |
|---|---|
| Framework | Astro `^7.2.0` |
| Adapter | `@astrojs/cloudflare ^14.2.0` |
| Styling | Tailwind `^4.0.0` (v4 `@theme` tokens) |
| Deploy | Cloudflare **Workers Builds**, `www.blablarags.com` |
| Storage | Cloudflare KV (`WAITLIST_KV`) |
| Framework integrations | **None** — pure `.astro` + inline `<script>` islands |

Currently 6 static pages (`/`, `/es/`, `/de/` + a 404 each) plus one SSR endpoint `POST /api/waitlist`.

> **Note:** `website/` is git-tracked in the root repo while `server/` and `dashboard/` are blanket-`.gitignore`d — this is *required* for Cloudflare Workers Builds to see the source. If the storefront moves into the nginx stack, that constraint disappears.

---

## 3. Framework recommendation

### 3.1 Comparison

| | **Next.js App Router** | Astro 7 + React islands | Vite SPA | TanStack Start |
|---|---|---|---|---|
| SEO for catalog/PDP | ✅ RSC / SSG / ISR | ✅ best-in-class | ❌ needs prerender bolt-on | ✅ |
| Large authed surface (~58 endpoints) | ✅ one router, shared layouts | ⚠️ isolated React roots; cross-island state needs nanostores; no shared client router | ✅ | ✅ |
| React 19 + TS 7 alignment | ✅ | ✅ (islands only) | ✅ | ✅ |
| GraphQL phase-2 tooling | ✅ deepest | ⚠️ workable | ✅ | ⚠️ younger |
| Cloudflare Workers deploy | ⚠️ via `@opennextjs/cloudflare` | ✅ already working | ✅ | ✅ |
| Migration cost from current site | Medium | **Zero** | Medium | Medium |
| Ecosystem depth / hiring | ✅ largest | Medium | Large | Small |

### 3.2 Why Next.js despite Astro already working

Astro's islands model excels when interactivity is *sprinkled onto content*. This product is inverted — a cart badge, auth state, offer threads, and a messaging inbox all need shared client state and navigation without full page reloads. In Astro that means nanostores glue plus ViewTransitions, and the friction compounds as the app grows.

Next.js gives RSC for the two SEO-critical routes and conventional client components for the other ~58, in **one router and one build**.

### 3.3 Why not the alternatives

- **Vite SPA** — gives up SEO on exactly the two pages where SEO is the entire point. Product detail is the organic-search surface.
- **TanStack Start** — genuinely good, worth revisiting in a year. Today, for a team that needs to hire and lean on existing community answers, Next's ecosystem depth outweighs its rough edges.
- **Stay on Astro** — zero migration cost is real and should not be dismissed, but it optimises the 3% of routes that are content and penalises the 97% that are application.

### 3.4 What to carry over from the Astro site

This is **not** a throwaway. Port deliberately:

| Asset | Location | Notes |
|---|---|---|
| i18n dictionary | `website/src/i18n/ui.ts` (330 lines) | Typed `Dictionary`, en/de/es, includes legally-reviewed cookie copy |
| Design tokens | `website/src/styles/global.css:9-69` | Tailwind v4 `@theme` block — ports **as-is**, v4 works identically in Next |
| SEO metadata | `website/src/layouts/Base.astro:35-101` | canonical / hreflang / OG / JSON-LD → Next `generateMetadata` |
| GDPR consent | `website/src/components/CookieConsent.astro` (345 lines) | 5-tab preference centre + Google Consent Mode v2 → one React component |
| Storefront chrome | `website/src/components/NotFoundPage.astro` (224 lines) | Already a full layout skeleton: sticky header w/ search/bag/account/wishlist, 3-col footer |
| Legal PDFs | `website/public/legal/*.pdf` | Real cookie policies, en/de/es |
| Icons | `website/src/components/icons/` | 13 inline SVG components (Feather MIT + Simple Icons CC0) |
| Crawler config | `website/public/robots.txt`, `llms.txt` | Explicit AI-crawler allowlist |

**Brand token conflict to resolve:** the dashboard uses `colorPrimary: '#2563eb'` (`dashboard/config/defaultSettings.ts:10`); the website uses `--color-primary: #004ac6` with `#2563eb` as `--color-primary-container`. Related but not identical — pick one source of truth.

---

## 4. API compatibility strategy

> This section addresses the stated priority: *"we want to be more compatible with use of the apis in both systems."* **Framework choice barely affects this. The items below are what determine it.**

### 4.1 Generate the contract — `@fastify/swagger`

The server is already ~80% of the way there: routes carry Fastify JSON Schemas for request bodies (`accounts.ts:39-63`, `customers.ts:26-53`). What is missing is `response:` schemas and the spec emitter.

```
server: @fastify/swagger + response schemas
            │
            ├──► openapi.json ──► openapi-typescript  ──► @blabla/api-types (TS)  → web + dashboard
            └──► openapi.json ──► openapi-generator   ──► Dart models             → Flutter
```

This single change permanently retires the three-way hand-copying, **and** it is the only mechanism that makes web/mobile compatibility provable rather than a matter of vigilance.

**Do this before writing storefront code**, so the web client is generated from day one rather than retrofitted.

### 4.2 Normalise the response envelope

Do it now, with two consumers, rather than later with five.

**Current state — six competing shapes:**

| Shape | Example location |
|---|---|
| `{success, data}` | `auth.ts:159` |
| `{data, total, canDelete, success}` | `customers.ts:107` |
| `{success, data, meta:{total}}` | `notifications.ts:39` |
| `{data}` (no `success`) | `notices.ts:8` |
| raw object, no envelope | `users.ts:28`, `mobileProfile.ts:270` |
| `{status:'...'}` discriminated union | `accounts.ts` (mobile auth) |

**Four pagination conventions:** `{data,total}` · `{meta:{total}}` · `{total,page,pageSize,totalPages}` · `{pagination:{page,limit,totalItems,hasMore,nextCursor}}` (base64 cursor, public feed only).

**Two error field names:** `errorMessage` (on `/v1`) vs `message` (on auth routes).

There is also **no `setErrorHandler` and no `setNotFoundHandler`** anywhere — unhandled throws fall through to Fastify's default 500.

### 4.3 Port `api_paths.dart` to TypeScript verbatim

`app-blablaragsandrigs/lib/core/network/api_paths.dart` is 123 lines and documents the `/v1`-vs-unversioned split in its own header comment. Mirror it as a TS const object so both clients read the same route list.

### 4.4 Reuse the mobile auth semantics exactly

Port the `DioClient` interceptor behaviour (`dio_client.dart:58-147`) into a fetch/axios interceptor, including the `X-Anonymous-Session-Id` round-trip so logged-out browsing behaves identically on web and mobile.

> ⚠️ **Security divergence requiring a decision.** Mobile stores refresh tokens in the OS keystore. The browser has no equivalent — `localStorage` is XSS-readable. **Recommendation:** add a server variant that issues the refresh token as an **httpOnly cookie** for web clients, keeping the access token in memory only. Small server change; far cheaper before launch than after.

---

## 5. GraphQL — phase 2

The hexagonal DI architecture makes this unusually clean. `index.ts` assembles ~45 repositories into `AppDeps` and hands it to `buildApp(deps)`. **GraphQL resolvers can consume those same repositories directly** — no HTTP hop, no service duplication.

**Approach:**

- Mount **Mercurius** (Fastify-native) or GraphQL Yoga at `/graphql`, sharing `AppDeps`
- REST stays live — migrate client-by-client, screen-by-screen
- Both clients get codegen from one SDL: `graphql-codegen` (TS) and **Ferry** (Dart)

**This is the real compatibility payoff:** phase-2 GraphQL gives Flutter typed codegen it cannot get today. Phase-1 OpenAPI is the stepping stone, not wasted work.

**Do not** rewrite routes as GraphQL. A gateway over the existing repositories is the correct shape.

---

## 6. Integration landmines

All verified against the actual configuration, not hypothetical.

### 🔴 nginx swallows `/api/*` before Next.js sees it

`nginx/default.conf` contains `location /api/ → server:5000`, unconditional. Any Next.js route handler, server-action endpoint, or NextAuth callback under `/api/*` will be **silently proxied to Fastify and 404**.

**Fix:** namespace Next's handlers elsewhere (e.g. `/_api/*`) or add a more specific nginx location. This will cost a day if hit blind.

### 🔴 Self-signed certificate

Mobile pins the cert by SHA-256 fingerprint (`globals.dart:529-538`). Browsers cannot do fingerprint pinning — they show a full-page trust warning. **A real CA certificate is required before any web frontend is usable by anyone but the developer.**

### 🟠 Cloudflare vs nginx — pick one home

The Astro site deploys to Cloudflare Workers at `www.blablarags.com`; the rest of the stack is nginx at `webapp-node.io`.

- **Keep on Cloudflare:** use `@opennextjs/cloudflare`, budget for adapter friction, keep the `website/`-must-be-git-tracked constraint.
- **Move into nginx stack:** simpler, one origin, eliminates the `/api/` landmine, drops the git-tracking constraint.

### 🟠 `CLOUDFLARE_API_TOKEN` is referenced but never defined

Exactly one hit repo-wide (`docker-compose.yml:205`). Not present in `.env` or `.env.presentation` — it currently interpolates to an empty string.

### 🟡 SSR requires header threading

The API localises from `Accept-Language` server-side (`src/core/i18n.ts`) and mints anonymous sessions from `X-Anonymous-Session-Id` (`apparel.ts:336-340`). A server component that does not forward these will render in the default locale and **mint a fresh anonymous session on every request**.

### 🟡 Public catalog cache is not invalidated by admin edits

Public catalog responses are Redis-cached for 120s (`apparel.ts:397`); admin item-edit routes do not bust those keys (a documented gap). The storefront will serve stale product data for up to two minutes after an edit.

### 🟡 Binary endpoints need streaming, not JSON

`GET /api/admin/wallets/credit-notes/:id/pdf`, `GET /api/admin/wallets/export`, plus multipart uploads (`POST /api/me/avatar`, apparel images, marketing assets).

### ℹ️ Unused nginx slot

`location /new → webapp:3001` exists in `nginx/default.conf:126-133`, but `webapp` only listens on 3000. Dead configuration — could be repurposed for a staged storefront rollout.

---

## 7. Documentation validation results

Three documents totalling ~29,000 lines were validated against live source code and the running database on 2026-08-09.

| Document | Scope checked | Clean | Discrepancies |
|---|---|---|---|
| `doc_enpoints_v3_07082026.md` (mobile `/v1`) | 68 endpoints | 61 | 7 (0 security) |
| `doc_enpoints_v3_07082026.md` (admin) | 125 endpoints | ~112 | 13 (1 HIGH) |
| `doc_enpoints_queries_v3_07082026.md` | 66 tables · 638 columns · 188 SQL blocks · ~55 queries | — | 45 (6 HIGH) |

### 7.1 What is verifiably correct

- **All documented auth guards match reality** on both mobile and admin surfaces. No route is weaker than documented; no mobile route accidentally uses the dashboard cookie guard.
- **Every `PRIVILEGES.*` constant** named in the docs exists in `privilege.types.ts` with the exact `section.action` pair claimed (one placeholder excepted — see below).
- **All 106 admin paths and 68 mobile paths match exactly.** No typos.
- **Zero phantom endpoints, zero phantom tables, zero phantom columns.** Every table and column named across 188 SQL blocks exists in the live DB.
- **`db/schema.sql` has zero drift** from the live database — 66 tables, 638 columns verified, including 69 `ALTER TABLE` statements and conditional `DO $$` blocks. The two apparent mismatches were parser artifacts from `ALTER … RENAME COLUMN`.
- The docs' own self-flagged gaps were re-verified as **accurate, not stale** — including the IDOR on `GET /api/v1/accounts/:accountId/items` (no ownership check, `apparel.ts:814-875`) and `coverage.ts` being genuine dead code (never registered in `app.ts`).

### 7.2 🔴 Security findings

#### F-1 — Privilege escalation via `autoSendEnabled` (**HIGH**, not in the docs)

`privilege.types.ts:57-59` justifies the existence of `marketing_campaigns.trigger_send` by stating that sending real notifications *"manually **or by enabling `auto_send_enabled`**"* is more sensitive than editing a draft.

But `autoSendEnabled` is an accepted, schema-validated body field on both `POST` and `PUT /api/admin/marketing/campaigns` (`marketingCampaigns.ts:134,155` → written at `:438,476`), gated **only on `MARKETING_CAMPAIGNS_EDIT`**.

**A user holding `edit` but not `trigger_send` can enable the scheduler-driven send path** — reaching the exact outcome the privilege split exists to prevent. The field is also entirely absent from the docs' request-body examples, so a documentation review would not surface it.

#### F-2 — Unauthenticated destructive endpoint (**HIGH**, doc-accurate)

`POST /api/admin/apparel/image-health/fix` (`apparelImageHealth.ts:37`) has **no auth guard of any kind** — no `preHandler`, no `getSessionUserid`, no `requirePrivilege` — and performs real `deleteItemImagesByIds` plus `objectStorage.deleteObject` calls.

The file's own comment (lines 5-13) declares this deliberate, justified by *"`GET /api/tags` is already public."* That is precedent-by-worst-case rather than a threat model, and it reasons from a **read** endpoint to justify an unauthenticated **destructive** one.

Aggravating factor: nginx deliberately does **not** rate-limit `/api/admin/*` (`nginx/default.conf:60-67`) on the stated assumption that every route behind it is auth-gated.

#### F-3 — Seven further unguarded routes (doc-accurate, already marked 🔴)

| Route | Location |
|---|---|
| `GET /api/admin/apparel/image-health` | `apparelImageHealth.ts:27` |
| `GET /api/llm-performance/metrics` | `llm-performance.ts:62` |
| `GET /api/llm-performance/suggestions` | `llm-performance.ts:69` |
| `GET /api/llm-performance/logs` | `llm-performance.ts:112` |
| `GET /api/users` | `users.ts:25` |
| `GET /api/notices` | `notices.ts:6` |
| `GET /api/tags` | `tags.ts:6` |

Note: `llm-performance.ts:27-29`'s docblock claims "read endpoints are available to any logged-in user" — that check is **not implemented**.

#### F-4 — Inconsistent auth mechanism: bespoke `requireAdmin()`

Three files use a hand-rolled coarse `profile.access === 'admin'` check instead of `requirePrivilege()`:

| File | Routes |
|---|---|
| `llm-performance.ts:30-49` | 2 |
| `sysConfig.ts:85-103` | 6 |
| `systemCarriers.ts:114-139` | 1 (hand-rolled `Promise.all` OR of two privileges) |

`sysConfig.ts:80-81`'s code comment still claims it "mirrors `routes/paymentFraudReviews.ts`'s `requireAdmin`" — but that file migrated away from the pattern (migration 0042). Stale code comment.

### 7.3 🔴 Live product bugs found via doc validation

#### F-5 — Marketing campaign `targetRegions` filtering silently no-ops (**HIGH**)

The doc documents `AND prof.country_code = ANY($n)`. **That condition does not exist in the code** — it was deliberately removed, with a code comment recording a *confirmed live zero-match bug* (continent strings such as "Europe" cannot map to ISO country codes).

**Consequence:** a campaign targeted at a region currently applies no region filter at all. (`MarketingCampaignSendService.ts:64-74`)

#### F-6 — `blockGlobal` sets a different status than documented (**HIGH**)

| | Doc | Code |
|---|---|---|
| Status set | `status='action_required'` | `status='on_hold'` |
| Rows touched | "every acquisition tied to the account" | exactly one `wallets` row |

`wallets_status_check` permits **both** literals, so a developer following the doc would write a value that persists silently and never trips a constraint. (`PgWalletRepository.ts:463-469`)

### 7.4 🟠 Doc-vs-code discrepancies — endpoints

| Endpoint | Doc says | Code says | Location | Sev |
|---|---|---|---|---|
| `GET/POST /api/admin/payment-fraud-reviews[/:id/review]` | "Coarse `requireAdmin` — **NOT** the fine-grained `PRIVILEGES.*` model" | `requirePrivilege(..., PRIVILEGES.PAYMENT_FRAUD_REVIEW)`. `requireAdmin` does not exist in the file | `paymentFraudReviews.ts:47,68` | **HIGH** |
| `DELETE /api/v1/notifications/read` | **Undocumented** (doc lists 5 notification routes) | Live 6th route; returns `{success,data:{deletedCount}}` | `notifications.ts:115-123` | MED |
| `POST /api/v1/addresses` | Response 200 | `reply.code(201)` | `addresses.ts:84-85` | MED |
| `POST /api/accounts/verify/resend` | "nothing is actually emailed; only logged at `debug`" | Really sends via `emailService.send`; can return an undocumented **500** | `accounts.ts:367-384` | MED |
| `PATCH /api/me/account` | Lists **`phone`** as editable | Schema is `additionalProperties:false` without it → AJV 400 | `mobileProfile.ts:29-40` | MED |
| `PATCH /api/me/privacy` | Presents **2FA** as a working toggle | Any `twoFactorEnabled` value short-circuits to **501** | `mobileProfile.ts:377-384` | MED |
| `GET /api/admin/apparel/image-health` | `{data:[{id,itemId,url}]}` | `{success,data:{...scanReport,canFix}}` | `apparelImageHealth.ts:34` | MED |
| `POST /api/admin/apparel/image-health/fix` | `{status:'fixed',deletedCount}` | `{success,data:{...after,canFix,deletedCount}}` | `apparelImageHealth.ts:58` | MED |
| `GET /api/admin/payment-fraud-reviews` | `page`/`pageSize` only; "only `pending_review` rows returned" | Also accepts `includeReviewed`, `flaggedAtFrom`, `flaggedAtTo`; `includeReviewed=true` invalidates the stated invariant | `paymentFraudReviews.ts:54-60` | MED |
| `GET`/`PATCH /api/admin/mobile-accounts/:id` | "Same shape as list item + `canEdit`" | Also returns `personalization`, `notifications`, `privacy`, `friends` | `customers.ts:143-151,194-203` | MED |
| One `Security Coverage:` field | Literally reads `PRIVILEGES.X` — a placeholder never filled in; contradicts the same entry's own Auth line | bespoke `requireAdmin` | doc:3672 vs `llm-performance.ts:85-89` | MED |
| Various `/v1` routes | No 400 documented for invalid enums | 400 on invalid `role`, `statusGroup`, `reasonCode` | `acquisitions.ts:317-331`, `offers.ts:246-249`, `returnRequests.ts:127-133` | LOW |
| Roles / marketing / system-settings entries | Privilege tokens written `admin_roles:view` (colon) | Registry produces dot form `admin_roles.view`; colon form appears nowhere in code | `privilege.types.ts:180-228` | LOW |
| `GET /api/admin/invoices` | Filterable by "**type**" | Query key is `invoiceType` | `invoices.ts:19` | LOW |

### 7.5 🟠 Doc-vs-code discrepancies — SQL

| Item | Doc says | Code says | Location | Sev |
|---|---|---|---|---|
| `buy-now` (offer_accept branch) | 4-statement block via `appendAcceptRoundTx` | One statement: `UPDATE offer_threads SET status='accepted'`. **`appendAcceptRoundTx` is dead code** | `PgAcquisitionRepository.ts:293-298` (real), `:343-385` (dead) | HIGH |
| `getDetailForAdmin` | "joins `wallets` + `wallet_ledger_entries` + `wallet_audit_logs`" | Joins `wallets`+`mobile_accounts`+`user_friends`, then `acquisitions`+`product_groups`. **Neither ledger nor audit appears** | `PgWalletRepository.ts:377-411` | HIGH |
| Credit-note PDF | "not a query against this repository at all" | Runs a real `SELECT … FROM credit_notes c LEFT JOIN users u`; `getObject` is never called | `PgCreditNoteRepository.ts:189-195` | HIGH |
| Campaign language filter | `prof.language_code = ANY($n)` | `= ANY(SELECT code FROM languages WHERE name = ANY($n))` — param carries display names. Doc's form matches zero rows | `MarketingCampaignSendService.ts:80-83` | HIGH |
| `insertItem` / `POST /v1/apparel` | 27 columns ending at `brand` | **28** — `shipping_size_tier` follows `brand`. Copying the doc drops the tier → `MissingShippingTierError` at checkout | `PgApparelRepository.ts:67-70,137,242` | MED |
| `PATCH /admin/shipments/:id/tracking` | UPDATE with no status transition | Also sets `status = CASE WHEN status='awaiting_tracking' THEN 'in_transit' ELSE status END`. The doc shows this correctly for the *mobile* route calling the identical method — internally inconsistent | `PgShipmentRepository.ts:531-537` | MED |
| `releaseEscrowTx` | 3 statements | 5 — also `UPDATE platform_ledger_balance` and `INSERT INTO wallet_ledger_entries ('platform_fee_retained')` | `PgWalletRepository.ts:224-284` | MED |
| `POST /v1/conversations/messages` | Thread reused per **(buyer, item)** | `ON CONFLICT (buyer_account_id, seller_account_id, product_group_id)` — per product **group**; two items in one group share a thread | `PgConversationRepository.ts:116-121` | MED |
| Referral commission | wallet credit + `credit_notes` row "in the same transaction" | The `credit_notes` INSERT happens in the route **after** the tx commits | `routes/wallets.ts:456-470` | MED |
| Marketing campaign SELECT/INSERT | No `auto_send_enabled` | Present in `CAMPAIGN_SELECT`, `CAMPAIGN_DETAIL_SELECT`, the 10-col INSERT and the update SET; update also re-arms `scheduled_send_dispatched=false`, a column never mentioned | `PgMarketingCampaignRepository.ts:131-156,217-279` | MED |
| `listPendingReviews` | Hardcoded `WHERE status='pending_review'`, on `db.read` | Method is `listReviews(filter)`, dynamic WHERE, on `db.write` | `PgPaymentFraudRepository.ts:59-101` | MED |
| `PgWalletAuditRepository.list` | Method named `list` | No such method — it is `listAll(filter)` | `PgWalletAuditRepository.ts:73` | MED |

### 7.6 Coverage gaps

**Undocumented tables (3 real gaps):**

| Table | Written by | Significance |
|---|---|---|
| `invoice_number_sequences` | `PgInvoiceRepository.ts:713,717` | The atomic **legal** invoice-numbering mechanism (§14 UStG gapless numbering) |
| `platform_ledger_balance` | `PgWalletRepository.ts:267` | Platform fee accrual on escrow release |
| `user_payment_verification_codes` | `PgMobileProfileRepository.ts:407-475` | Payment-method verification / lockout |

Plus `category_tree` (dead — zero code references) and `schema_migrations` (infra, expected).

**Entire repository absent from the docs:** `PgCreditNoteRepository.ts` — the string `CreditNoteRepository` appears **0 times** in 4,906 lines. Four undocumented methods including `issue` (with `SELECT nextval('credit_note_number_seq')`).

**Prose-only, no SQL shown:** `PgInvoiceRepository.ts` (0/10 methods), `PgConversationRepository.ts` (0/8), `PgWalletAuditRepository.ts` (0/2). `listConversations` (`PgConversationRepository.ts:160`) — a 5-table LATERAL join — is the most complex undocumented query in the codebase.

**Security-relevant gaps:** the payment-verification lockout trio — `blockPaymentMethod` (`PgMobileProfileRepository.ts:496`, writes `payment_fraud_reviews` after 5 failed attempts), `incrementPaymentVerificationAttempts` (:473), `isPaymentMethodBlocked` (:488).

**Partial coverage:** `PgWalletRepository` 7/13 · `PgMobileProfileRepository` 10/17 · `PgNotificationRepository` 7/9 · `PgPaymentFraudRepository` 1/3 · `PgCustomerRepository` 6/8 · `PgOfferRepository` 4/5 · `PgMobileAccountRepository` 7/8 · `PgShipmentRepository` 23/24 · `PgApparelRepository` 17/18. **24 files fully covered.**

**Dead code identified:**

| Symbol | Location |
|---|---|
| `appendAcceptRoundTx` | `PgAcquisitionRepository.ts:343` |
| `PgPaymentFraudRepository.flagAccount` | `:110` |
| `PgCustomerRepository.findByUsername` / `.findByEmail` | `:157`, `:166` |
| `coverageRoutes` (`GET /api/coverage-summary`) | `routes/coverage.ts` — exported, never registered |
| `RETURNS_AUDIT_VIEW` privilege constant | `privilege.types.ts` — defined, never used |
| `category_tree` table | live DB — zero code references |

### 7.7 Systemic documentation problems

1. **Stale `Source:` line anchors** — wrong across ~10 files in the endpoint doc and ~60 anchors in the queries doc, drifting between 2 and 250 lines. Worst: `mobileProfile.ts` cited as `10-22` for `GET /api/me` (actually `259-271`); invoice anchors now land **inside the wrong method** (`:713-716` is described as "locks FOR UPDATE" but is actually `generate`'s `INSERT INTO invoice_number_sequences`).
2. **Incomplete TOC** — 24 endpoint headings missing from the queries-doc TOC (Notifications ×5, Conversations ×5, pro-seller ×2, send-estimate/send ×2, the whole `/api/me/*` family), despite the 2026-08-07 refresh note claiming they were added.
3. **Guards inside handler bodies** — `returnRequests.ts` and `apparel.ts` call `requirePrivilege(...)` inside the handler rather than as a `preHandler`. These guards are real and working, but a `grep preHandler` audit would false-positive them as unauthenticated. Worth knowing before the next security review.

---

## 8. Prioritised action list

### Immediate — security & correctness (small, independent)

| # | Action | Location | Est. |
|---|---|---|---|
| 1 | Gate `autoSendEnabled` behind `MARKETING_CAMPAIGNS_TRIGGER_SEND` | `marketingCampaigns.ts:134,155,438,476` | ~15 min |
| 2 | Add an auth guard to `POST /api/admin/apparel/image-health/fix` (and the sibling GET) | `apparelImageHealth.ts:27,37` | ~10 min |
| 3 | Fix or explicitly disable `targetRegions` campaign filtering | `MarketingCampaignSendService.ts:64-74` | ~1 h |
| 4 | Decide on the remaining 7 unguarded routes — guard or accept-and-document | see §7.2 F-3 | ~1 h |

### Before storefront work — contract foundation

| # | Action | Rationale |
|---|---|---|
| 5 | Normalise the response envelope; add `setErrorHandler` + `setNotFoundHandler` | Cheapest now, with two consumers |
| 6 | Add `@fastify/swagger` + `response:` schemas → emit `openapi.json` | Everything downstream is generated from this |
| 7 | Generate `@blabla/api-types` (TS) and Dart models | Retires three-way hand-copying |
| 8 | Obtain a real CA certificate | Browsers cannot use the pinned self-signed cert |
| 9 | Add an httpOnly refresh-cookie variant for web clients | `localStorage` refresh tokens are XSS-readable |

### Housekeeping

| # | Action |
|---|---|
| 10 | Regenerate all `Source:` line anchors (or script them) — currently wrong in ~70 places |
| 11 | Document the 3 missing tables + `PgCreditNoteRepository` + `DELETE /api/v1/notifications/read` |
| 12 | Delete the 6 confirmed dead-code symbols (§7.6) |
| 13 | Correct `dashboard/CLAUDE.md:37` — 3 locales, not 8 |
| 14 | Fix the stale `sysConfig.ts:80-81` comment referencing the pre-migration-0042 pattern |
| 15 | Add cache invalidation for public catalog keys on admin item edit (`apparel.ts:397`) |
| 16 | Define or remove `CLOUDFLARE_API_TOKEN` |

---

## 9. Suggested delivery sequence

| Phase | Work | Why this order |
|---|---|---|
| **0** | Immediate security fixes (#1-4). Normalise response envelope. Add `@fastify/swagger` + response schemas → `openapi.json` | Everything downstream is generated from this; retrofitting costs ~5× |
| **0.5** | Generate `@blabla/api-types` (TS) + Dart models. Real CA cert. httpOnly refresh-cookie variant | Unblocks both clients; removes the browser trust wall |
| **1** | Scaffold Next.js App Router. Port i18n dictionary, `@theme` tokens, SEO metadata, cookie consent, 404 chrome from Astro. Retire `website/` | Nothing is lost; the storefront starts type-safe from day one |
| **2** | Build public catalog + PDP as RSC (SEO-critical), then the authenticated app surface as client components | SEO routes ship first and can go live independently |
| **3** | Mount Mercurius over the existing `AppDeps`. Migrate screens incrementally. `graphql-codegen` (TS) + Ferry (Dart) | REST never breaks; both clients gain typed codegen |

### Two decisions required before Phase 1

1. **Where does the storefront live** — Cloudflare Workers (keeps the existing domain + CI, needs `@opennextjs/cloudflare`) or the nginx stack (simpler, one origin, eliminates the `/api/` landmine)?
2. **Is envelope normalisation in scope for Phase 0?** It is the least enjoyable work in this document and the highest-leverage. Deferring it means every subsequent client pays a per-endpoint tax to guess which of six shapes it is receiving.

---

## Appendix A — Validation methodology

- **Endpoint validation:** every documented endpoint's path, HTTP method, auth guard, request schema and response envelope compared against the route source in `server/src/routes/` and registration in `src/app.ts`. Route files grepped for `adminPrefix` / `/api/admin` and reconciled per-file to detect undocumented endpoints.
- **Privilege validation:** every `PRIVILEGES.*` constant named in the docs cross-checked against `server/src/domain/privilege.types.ts`.
- **SQL validation:** 68 table tokens and 645 column references extracted from the docs' SQL fences and validated against `information_schema` on the live database. ~55 documented queries manually diffed against repository source across 20 repositories.
- **Schema drift:** `db/schema.sql` (1,941 lines) parsed including 69 `ALTER TABLE` statements and conditional `DO $$` blocks, then compared table-by-table and column-by-column against the live database.
- **Constraint:** read-only throughout. No file modified; only `SELECT` and `\d` executed against the database.

## Appendix B — Documents validated

| File | Lines | Dated |
|---|---|---|
| `server/docs/doc_enpoints_v3_07082026.md` | 4,899 | 2026-08-07 |
| `server/docs/doc_enpoints_queries_v3_07082026.md` | 4,906 | 2026-08-07 |
| `server/db/schema.sql` | 1,941 | — |

Superseded versions present in `server/docs/` (v1 dated 2026-07-28, v2 dated 2026-08-05) were **not** validated.

---

*Generated 2026-08-09. Analysis and recommendation only — no code, schema, or configuration was modified.*
