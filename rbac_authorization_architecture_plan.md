# RBAC / Authorization Architecture Plan

Status: **PLAN ONLY — not implemented.** Written after auditing the current
state of `user_teams` / `user_teams_privileges` across the dashboard and
finding real gaps (see §1). No code should be written from this doc without
a separate go-ahead per phase (§6).

---

## 1. Current State Audit (what's actually true today)

### 1.1 Two disconnected authorization mechanisms, used inconsistently
| Mechanism | Backing | Used by |
|---|---|---|
| Coarse admin flag | `users.access === 'admin'` | `llm-performance.ts`, `paymentFraudReviews.ts`, `sysConfig.ts` |
| Team-based privilege | `user_teams` + `user_teams_privileges` (`hasPrivilege(userid, sectionKey, actionKey)`) | `customers.ts` only |

Nothing decides between these two on principle — it was whichever the
implementing session reached for. A reviewer can't predict which check a new
route will use without reading it.

### 1.2 `requireAdmin` is copy-pasted, not shared
`src/routes/llm-performance.ts`, `paymentFraudReviews.ts`, and `sysConfig.ts`
each define their own `async function requireAdmin(req, reply, deps)` —
functionally identical (confirmed via diff, only a comment/formatting
difference). `customers.ts` has a fourth variant, `requirePrivilege`, doing
the team-based check instead. Every new admin-gated route either copies one
of these four functions again or (worse) writes a fifth slightly-different
one. This is the concrete cost of not having a shared authorization
primitive — it's already drifted 4 ways with only 4 sections built.

### 1.3 The frontend has zero visibility into privileges
- `src/access.ts` derives exactly one thing: `canAdmin` from
  `currentUser.access === 'admin'`.
- `API.CurrentUser` (typings.d.ts) carries `access?: string` and nothing
  else privilege-related.
- `GET /api/currentUser` returns `UserProfile`, which has no permissions
  field.
- `PgPrivilegeRepository.listPermissions(userid)` — returns e.g.
  `['customers.view', 'account_data.edit_customers']` — is fully
  implemented and **never called by any route.** Dead code.
- Consequence: `config/routes.ts`'s `/accounts` entry (Customers) has no
  `access:` gate at all. The menu item is visible to every logged-in
  dashboard user regardless of team membership. A non-privileged user sees
  the menu, clicks it, and gets an empty ProTable / 403 toast — not a
  hidden menu item. This is the bug the user flagged.

### 1.4 `user_teams` conflates two different concerns
`user_teams` seeds a per-user "team" list that's ALSO rendered verbatim as
the Account Center sidebar's team/notice list (`team.platformEngineering`,
`team.frontendGuild`, etc. — cosmetic profile content, not privilege
sources). Only one row, `Customer-Service`, actually grants anything via
`user_teams_privileges`. Nothing distinguishes "this is a real privilege
team" from "this is decorative profile content" except which rows happen to
have matching `user_teams_privileges` entries. Harmless today (only one real
team exists), but a trap for later: assigning a user to `team.qaSquad` for
cosmetic reasons couldn't accidentally grant privileges only because no
`user_teams_privileges` row currently references it — that's incidental,
not structural, safety.

### 1.5 Why "add an `access:` string per section" is the wrong fix
The user's instinct here is correct and is the reason this is a plan, not a
quick patch: bolting one more hand-written boolean onto `access.ts` per
section (`canViewCustomers`, `canEditCustomers`, `canViewSysConfig`, ...)
recreates the exact copy-paste-per-section problem §1.2 already shows
happening on the backend, just on the frontend instead. It also invites
"infer it from the URL" shortcuts (e.g. "if path starts with `/admin/`,
require admin") which are implicit, fragile, and exactly what was flagged as
unacceptable — a route's required permission must be an explicit, named
declaration attached to that route, never parsed out of its own path string.

---

## 2. Design Principles

1. **One authorization primitive, not two.** Every route declares the
   `(sectionKey, actionKey)` it requires. The admin flag becomes a strict
   *superset* — an admin passes every check — rather than a separate parallel
   system a route author chooses instead of the real one.
2. **Single source of truth for the permission catalog.** `(sectionKey,
   actionKey)` pairs are declared once, in code, on both sides — not as
   loose string literals typed out fresh in every route file and every
   `routes.ts` entry (which is exactly how `'account_data'` vs
   `'accountData'`-style typos happen and silently fail open or closed).
3. **Explicit, not inferred.** A route's required permission is a named
   constant it references directly at registration. A menu entry's required
   permission is a named constant it references directly in `routes.ts`.
   Nothing is derived by pattern-matching a URL, a component path, or a menu
   label.
4. **Declaring a new privileged section is additive, not archaeological.**
   Today, adding one costs: a migration seed row, a bespoke `requireXxx`
   function, a route-body call to it, and (if anyone remembers) a
   hand-written `access.ts` boolean. The target: a migration seed row, one
   catalog entry (used by both front and back), one `preHandler` reference,
   one `routes.ts` `access:` reference. No new function, no bespoke
   frontend boolean.
5. **Keep team membership and privilege-granting decoupled in intent, even
   if they share a table for now.** Don't design the new catalog/primitive
   around the assumption that every `user_teams` row grants something.

---

## 3. Proposed Architecture

### 3.1 Shared permission catalog (single source of truth)
A new file, `server/src/core/permissions.ts`, declares every known
`(sectionKey, actionKey)` pair as a typed constant:
```typescript
// server/src/core/permissions.ts
export const PERMISSIONS = {
  CUSTOMERS_VIEW: { section: 'customers', action: 'view' },
  ACCOUNT_DATA_EDIT_CUSTOMERS: { section: 'account_data', action: 'edit_customers' },
  SYS_CONFIG_VIEW: { section: 'sys_config', action: 'view' },
  SYS_CONFIG_EDIT: { section: 'sys_config', action: 'edit' },
  // ... one entry per (section, action) that gates anything, ever.
} as const;
export type PermissionKey = keyof typeof PERMISSIONS;
```
This is the ONLY place `sectionKey`/`actionKey` string literals are typed by
hand. Everywhere else — route registration, migration seeds' comments,
frontend catalog — references `PERMISSIONS.CUSTOMERS_VIEW`, never a bare
string. (Seed data in `user_teams_privileges` still needs the raw
`section_key`/`action_key` column values, since SQL can't import a TS
constant — but the migration file's comment block should enumerate the
`PermissionKey` names it corresponds to, so the two stay auditable against
each other.)

A parallel, intentionally small, hand-mirrored file exists on the frontend
(`dashboard/src/access-catalog.ts`) — see §3.4. It is NOT auto-generated
from the backend file in phase 1 (no shared package between the two apps
today); keeping it manually mirrored is an accepted, explicit cost, with a
lint/test guard (§6, Phase 4) to catch drift.

### 3.2 One authorization primitive on the backend, decorated once
Mirrors how `app.authenticate` is already decorated once on the root
Fastify instance in `app.ts` (see `learned_lessons.md` Issue 9 — decorators
added inside a route plugin are invisible to sibling plugins, so this MUST
happen on the root instance before any route plugin registers).

```typescript
// server/src/core/authorization.ts
export function createRequirePrivilege(deps: AppDeps) {
  return function requirePrivilege(section: string, action: string) {
    return async (req: FastifyRequest, reply: FastifyReply) => {
      const userid = getSessionUserid(req);
      if (!userid) { reply.code(401).send({...}); return reply; }

      // Admin is a strict superset — passes every check without needing an
      // explicit user_teams_privileges row for every section.
      const locale = resolveLocale(req.headers['accept-language']);
      const profile = await deps.userRepo.findProfile(userid, locale);
      if (profile?.access === 'admin') return;

      const granted = await deps.privilegeRepo.hasPrivilege(userid, section, action);
      if (!granted) { reply.code(403).send({...}); return reply; }
    };
  };
}
```
Registered once in `app.ts`:
```typescript
app.decorate('requirePrivilege', createRequirePrivilege(deps));
```
Route registration becomes fully declarative — the permission requirement
lives at the route definition, not buried in the first lines of a handler
body:
```typescript
app.get(BASE, { preHandler: app.requirePrivilege('customers', 'view') }, async (req) => { ... });
app.patch(`${BASE}/:id`, { preHandler: app.requirePrivilege('account_data', 'edit_customers') }, async (req) => { ... });
```
This retires all four existing `requireAdmin`/`requirePrivilege`
implementations in favor of one. `customers.ts`'s existing behavior is
preserved exactly (team check); `llm-performance.ts`/`paymentFraudReviews.ts`/
`sysConfig.ts` keep their exact current behavior too, since "admin passes
everything" was already their entire check.

### 3.3 Expose the caller's resolved permissions
Extend `GET /api/currentUser`'s response (or add a small dedicated
`GET /api/me/permissions` if keeping `UserProfile` lean is preferred — pick
one during Phase 1 design review, not both) with the already-implemented
`listPermissions(userid)`, adjusted for the admin-superset rule:
```typescript
permissions: profile.access === 'admin' ? ['*'] : await privilegeRepo.listPermissions(userid)
```
`'*'` is an explicit, documented sentinel meaning "every check passes" —
not an empty array being misread as "no permissions" or a magic falsy value.

### 3.4 Frontend: generic, catalog-driven `access.ts`
```typescript
// dashboard/src/access-catalog.ts — mirrors server/src/core/permissions.ts by hand
export const ACCESS_CATALOG = {
  canViewCustomers: { section: 'customers', action: 'view' },
  canEditCustomerAccountData: { section: 'account_data', action: 'edit_customers' },
  canViewSysConfig: { section: 'sys_config', action: 'view' },
  canEditSysConfig: { section: 'sys_config', action: 'edit' },
} as const;
```
```typescript
// dashboard/src/access.ts
import { ACCESS_CATALOG } from '@/access-catalog';

export default function access(initialState) {
  const permissions = initialState?.currentUser?.permissions ?? [];
  const isAll = permissions.includes('*');
  const has = (section: string, action: string) =>
    isAll || permissions.includes(`${section}.${action}`);

  const derived = Object.fromEntries(
    Object.entries(ACCESS_CATALOG).map(([key, { section, action }]) => [key, has(section, action)]),
  );
  return {
    canAdmin: isAll, // kept for existing consumers (Admin menu, etc.)
    ...derived,
  };
}
```
`config/routes.ts` then gates explicitly by name, same pattern as the
existing `access: 'canAdmin'`:
```typescript
{ path: '/accounts', name: 'accounts', icon: 'idcard', access: 'canViewCustomers', routes: [...] }
```
Nothing here parses a URL or infers a permission from a path/component
name — every gate is a named key someone wrote down on purpose, exactly the
"explicit, not implicit" requirement.

### 3.5 What changes for Sys-Config specifically
Two real options, needs a decision in Phase 1 (§6), not assumed here:
- **(a)** Keep Sys-Config admin-only in *effect*, but express it through the
  SAME primitive as everything else: seed a `sys_config` / `view` + `edit`
  privilege pair granted only to admins-by-convention (or just rely on the
  admin-superset rule and never seed a team for it) — the route code becomes
  `app.requirePrivilege('sys_config', 'edit')` like everything else, instead
  of a bespoke `requireAdmin`.
- **(b)** Introduce a real `System-Admin` team distinct from the coarse
  `access==='admin'` flag, so "can log into the dashboard as admin" and "can
  edit currency rates" become separately revocable. More correct long-term,
  more migration/seed work now.
Recommendation: **(a)** for now — it unifies the mechanism without expanding
scope, and (b) is a natural follow-up once more than one section needs
admin-but-not-superadmin granularity.

---

## 4. Non-Goals (explicitly out of scope for this plan)

- Auto-generating the frontend catalog from the backend one (no shared
  package boundary exists between `server/` and `dashboard/` today — worth
  revisiting only if catalog drift actually becomes a recurring bug).
- Building a UI to manage `user_teams_privileges` rows (still hand-seeded /
  hand-migrated for now — this plan is about *consuming* the table
  correctly, not building CRUD for it).
- Solving §1.4 (team-membership vs. privilege-grant conflation) — flagged
  for awareness, not fixed here. Revisit if a cosmetic-only team ever
  accidentally gets a `user_teams_privileges` row.
- Row/record-level permissions (e.g. "can edit customers in region X only")
  — `permission_scope` column already exists on `user_teams_privileges` for
  this but nothing reads it anywhere yet; out of scope until a real
  requirement shows up.

---

## 5. Migration Impact on Existing Sections

| Section | Today | After |
|---|---|---|
| Customers | `requirePrivilege` (bespoke, in `customers.ts`) | `app.requirePrivilege('customers','view')` / `('account_data','edit_customers')` |
| LLM Performance | `requireAdmin` (bespoke) | `app.requirePrivilege('llm_performance','review')` (or keep admin-superset-only if no real team is ever needed here) |
| Payment Fraud Review | `requireAdmin` (bespoke) | same shape |
| Sys-Config | `requireAdmin` (bespoke) | `app.requirePrivilege('sys_config','edit')` per §3.5(a) |

Every existing test that currently asserts 401/403 behavior for these
sections should still pass unchanged — the *external* behavior (status
codes, who's let in) doesn't change in Phase 1, only *how* it's implemented
internally. New tests are needed for: the shared `requirePrivilege`
primitive itself (unit-level, mocking `privilegeRepo`), the
admin-superset-bypass behavior, and the new `permissions` field on
`GET /api/currentUser`.

---

## 6. Phased Rollout (each phase is a separate go/no-go, nothing here is pre-approved)

1. **Design review** — confirm the exact `PERMISSIONS` catalog contents
   (one entry per real gate that exists today, no speculative additions),
   decide §3.5's (a) vs (b), decide `GET /api/currentUser` vs. a dedicated
   `/api/me/permissions` endpoint.
2. **Backend primitive** — add `permissions.ts` + `authorization.ts`,
   decorate once in `app.ts`, migrate the 4 existing route files to use it,
   delete the 4 bespoke functions. Full test suite must stay green.
3. **Expose permissions to the client** — extend the chosen endpoint, add
   backend tests for the admin-superset/`'*'` behavior.
4. **Frontend catalog + `access.ts`** — add `access-catalog.ts`, rewrite
   `access.ts` to be catalog-driven, gate `/accounts` (and any other section
   that should be gated) in `routes.ts`. Add a lightweight test (or at
   minimum a code comment + checklist item in `claude-add-new-section.md`)
   asserting every `ACCESS_CATALOG` key has a corresponding `PERMISSIONS`
   entry on the backend, to catch the two catalogs drifting apart.
5. **Update `claude-add-new-section.md`** — the "Add New Full-Stack Section"
   playbook should reference this pattern explicitly (one `PERMISSIONS`
   entry + one `ACCESS_CATALOG` entry + one `preHandler` + one `access:`
   string, no bespoke function) so the next section built follows it
   automatically instead of reintroducing a fifth `requireXxx` variant.
