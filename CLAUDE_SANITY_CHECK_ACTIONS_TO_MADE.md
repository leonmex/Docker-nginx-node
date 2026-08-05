# Sanity Check — Ant Design Pro Template Fingerprints & Disclosure Risks

**Version:** 1.0
**Date:** 2026-08-01
**Scope:** Dashboard (`node-nginx-clean/dashboard`) — leftover Ant Design Pro template
artifacts that could help someone outside the company identify the exact
framework/version in use (fingerprinting), ahead of deployment. Server
(Fastify) response-header/error-handler disclosure and the nginx layer were
explicitly out of scope for this pass.

**Status:** Report only. Nothing below has been changed except item 0.

---

## 0. Already fixed this session

Login page placeholders/error text leaking the framework's known default
credentials (`admin` / `ant.design`) — removed from
`src/pages/user/login/index.tsx` and all 3 locale files (`en-US`, `de-DE`,
`es-ES`), including the Chinese hardcoded fallback strings. Test file and
snapshot (`login.test.tsx` / `login.test.tsx.snap`) updated to match.

---

## Findings — not yet actioned

### 1. Footer prints exact framework version numbers, pre-login
**File:** `src/components/Footer/index.tsx`

Renders "ver 6.0.2", "Umi 4.6.64", "Utoo 1.4.3" as plain text on every page,
including the login screen — before any authentication. Highest-value item:
an attacker doesn't need to fingerprint anything, the exact `antd` /
`@umijs/max` / `@utoo/pack` versions are printed on screen, letting them go
straight to CVE databases for those specific versions.

### 2. `package.json` identifies the project as the upstream template
**File:** `package.json`

- `name: "ant-design-pro"`
- `repository: "git@github.com:ant-design/ant-design-pro.git"` (points at
  the official upstream repo, not the real private repo)
- `version: "6.0.2"`

The version is embedded into the client bundle as `__APP_VERSION__` (via
`config/config.ts`'s `define` block) and rendered by the Footer (item 1) —
same disclosure, different source.

### 3. `public/CNAME` — dead GitHub Pages leftover
**File:** `public/CNAME`

Content: `preview.pro.ant.design`. Confirms Pages/ant-design-pro origin to
anyone who looks at `public/`. Serves no purpose for a Docker/nginx
deployment. (Discussed separately — still present per explicit instruction
not to remove it yet.)

### 4. `src/pages/Admin.tsx` — unmodified stock demo page
**File:** `src/pages/Admin.tsx`, routed at `/admin/sub-page`
(`config/routes.ts`)

Literal stock content: "This page can only be viewed by admin" / "Ant
Design Pro ❤ You" / links to `pro.ant.design/docs/block-cn`. Gated behind
`access: 'canAdmin'`, so exposure is limited to already-privileged users —
but it's pure template filler with zero product value sitting in a
production route.

### 5. `/chatbot` route — already self-flagged dead code
**File:** `config/routes.ts:588-599`, `src/pages/chatbot/*`

Comment dated 2026-07-29 already documents this: an unfinished AI-chat
feature explicitly called out as a potential injection risk and marked for
deletion. `hideInMenu: true`, but the route is still registered and
reachable by direct URL. No server route currently backs `/api/chat`, so
it's inert today — but it's dead code sitting exactly where it was already
decided it shouldn't be.

### 6. Root `README.md` — stock Ant Design Pro README
**File:** `README.md`

Stock badges/description/screenshots from the upstream template. Not
served over HTTP (not under `public/`), so this is a repo-access risk only,
not a runtime one. Lowest priority — worth swapping for real project docs
before repo access is ever shared outside the team.

### 7. `mock/*.ts` — stock template fixtures
**Files:** `mock/fakeList.ts`, `mock/notices.ts`, `mock/route.ts`,
`mock/user.ts`, `mock/listTableList.ts`

Umi's mock middleware is dev-only and excluded from production builds by
convention (`mock: false` in the openAPI plugin config in
`config/config.ts`), so this is not a runtime leak — just repo clutter left
over from the scaffold.

### 8. `config/proxy.ts` — points at the official demo backend
**File:** `config/proxy.ts`

Dev-only proxy targets: `preview.pro.ant.design` and
`pro-api.ant-design-demo.workers.dev` (the official Ant Design Pro demo
backend). Never shipped to the production bundle (proxy only runs in local
dev), so no runtime exposure — just a config-file tell for anyone with repo
access.

---

## Explicitly out of scope for this pass

- Fastify server response headers / error handler (stack-trace exposure,
  `X-Powered-By`-equivalent disclosure) — not checked in depth.
- nginx layer (server headers, TLS config, exposed ports/paths) — belongs
  to another team; would need sign-off before touching.

Flag if you want either of those covered in a follow-up pass.
