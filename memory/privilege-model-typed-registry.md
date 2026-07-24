---
name: privilege_model_typed_registry
description: Two-level (section, action) privilege model with a typed distributive union + canonical PRIVILEGES registry — call sites never pass raw strings
metadata:
  type: feedback
---

Server-side privilege checks (`user_teams_privileges`) must never be called with raw string literals at the call site — not even type-checked ones. Use `PRIVILEGES.*` constants from `server/src/domain/privilege.types.ts` instead (e.g. `requirePrivilege(req, reply, deps, PRIVILEGES.APPAREL_EDIT)`).

**Why:** Two different sections can legitimately share an action name (both `customers` and `apparel` have `'view'`). Passing two loose strings `(sectionKey, actionKey)` — even ones constrained by a mapped type — lets a copy-paste mistake swap which section you meant to gate without any compile error, because the action union collapses across sections. A single named constant per real, seeded privilege closes that gap: there's nothing else typed `Privilege` to reach for. Also caught mid-session: a first draft used `Privilege<SK> = { section: SK; action: PrivilegeActionKey<SK> }` with a *generic* default of the full section-key union — that shape is NOT actually distributive (indexed access over a union just unions the results), so `satisfies Record<string, Privilege>` silently accepted mismatched pairs. Fixed by making `Privilege` a properly distributive mapped-then-indexed union: `{ [SK in PrivilegeSectionKey]: {...} }[PrivilegeSectionKey]`.

**How to apply:** Adding any new gated section/action: (1) add it to `PrivilegeSectionActions` in `privilege.types.ts`, (2) add a named entry to the `PRIVILEGES` const registry there, (3) seed the matching `user_teams_privileges` row(s) in a new migration AND fold the same INSERT into `db/schema.sql`'s baseline (schema.sql is hand-folded, not auto-generated — see [[node-nginx-clean-learned-lessons]]), (4) reuse `requirePrivilege` from `routes/auth.ts` (shared, not duplicated per route file) rather than rolling a new check. Full design writeup lives in `server/.claude/skills/sr_backend/SKILL.md` section 1.

Related: API path prefixes follow the same "never hardcode, always centralize" rule — `config.apiPrefix`/`apiVersion` for versioned routes, a separate `config.adminPrefix` for privilege-gated admin routes, both mirrored dashboard-side in `src/config/api.ts` (`API_BASE`/`ADMIN_BASE`) with an explicit "MUST sync with server config.ts" comment.
