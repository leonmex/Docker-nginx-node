# i18n Guide — Removing Hardcoded Text and Localizing (EN / DE / ES)

How to convert hardcoded UI strings (mostly Chinese, from the Ant Design Pro
template) into proper internationalized text, and how to build NEW pages with i18n
from the start. No emojis anywhere (project rule).

---

## 1. Goal & Constraint

- The dashboard must operate strictly in **en-US (default)**, **de-DE**, **es-ES**.
- Every user-visible string must come from the locale files via `intl.formatMessage`,
  never a hardcoded literal in a component.
- This is a **frontend** concern, independent of the PostgreSQL/Fastify backend.
  Reseeding the DB or clearing Redis does NOT change hardcoded UI text.

Why this matters (root cause we hit): pages like `src/pages/dashboard/analysis`
render literals such as `title="线上热门搜索"` directly in JSX. They ignore locale
and ignore the database. The fix is i18n, not data.

---

## 2. How i18n Works in This Project

Umi Max locale plugin (`@@/plugin-locale`), configured in `config/config.ts`:

```ts
locale: {
  default: 'en-US',
  antd: true,          // also localizes antd's own components
  baseNavigator: true, // browser language can override the default
},
```

Locale files live in `src/locales/`:

```
src/locales/
  en-US.ts        # aggregator: merges the namespaced files below into one object
  en-US/
    menu.ts          # menu.* keys (sidebar / route names)
    pages.ts         # pages.* keys (page content) <- most page text goes here
    globalHeader.ts  # header / search / notifications
    settings.ts, settingDrawer.ts, component.ts, network.ts
  de-DE.ts, de-DE/...   # same structure, German
  es-ES.ts, es-ES/...   # same structure, Spanish
```

The aggregator (`src/locales/en-US.ts`) spreads each namespace into one flat map:

```ts
import pages from './en-US/pages';
export default { ...menu, ...pages, /* ... */ };
```

Keys are **flat, dotted strings**, e.g. `'pages.login.accountLogin.tab'`.

**Every key MUST exist in all three locales** (`en-US`, `de-DE`, `es-ES`). A missing
key falls back to the `defaultMessage` passed at the call site (so always pass one).

---

## 3. Key Naming Convention

```
pages.<area>.<component-or-section>.<element>
```

Examples (follow the existing style in `pages.ts`):

| String | Key |
|--------|-----|
| Analysis "Online Top Search" card title | `pages.analysis.topSearch.title` |
| Analysis "Sales" tab | `pages.analysis.salesCard.tabSales` |
| Monitor "Activity forecast" | `pages.monitor.activityForecast` |

Rules:
- Lower camelCase segments, dotted. Keep the `pages.` prefix for page content and
  `menu.` for route/menu names.
- Group by page area so keys are easy to find and review.
- Reuse existing keys when the same label already exists (search `pages.ts` first).

---

## 4. Converting an Existing Page (step-by-step)

Worked example: `src/pages/dashboard/analysis`.

### Step 1 — Find every hardcoded literal
```bash
# from dashboard/
grep -rIno "[一-龥]\{1,\}" src/pages/dashboard/analysis | sort -u
```
(Or scan a single file.) List each literal and the JSX/attribute it lives in.

### Step 2 — Add keys to ALL THREE locale files
Add to `src/locales/en-US/pages.ts`, `de-DE/pages.ts`, `es-ES/pages.ts`:

```ts
// en-US/pages.ts
'pages.analysis.topSearch.title': 'Online Top Search',
'pages.analysis.salesCard.tabSales': 'Sales',
'pages.analysis.salesCard.tabVisits': 'Visits',
```
```ts
// de-DE/pages.ts
'pages.analysis.topSearch.title': 'Online-Top-Suche',
'pages.analysis.salesCard.tabSales': 'Umsatz',
'pages.analysis.salesCard.tabVisits': 'Besuche',
```
```ts
// es-ES/pages.ts
'pages.analysis.topSearch.title': 'Búsquedas principales en línea',
'pages.analysis.salesCard.tabSales': 'Ventas',
'pages.analysis.salesCard.tabVisits': 'Visitas',
```

### Step 3 — Use `formatMessage` in the component
```tsx
import { useIntl } from '@umijs/max';

const Comp = () => {
  const intl = useIntl();
  const t = (id: string, defaultMessage: string) => intl.formatMessage({ id, defaultMessage });
  return (
    <Card title={t('pages.analysis.topSearch.title', 'Online Top Search')}>
      {/* ... */}
    </Card>
  );
};
```
- Always pass `defaultMessage` (English) — it is the fallback and documents intent.
- For a component outside React render (rare), use `getIntl()` from `@umijs/max`.

### Step 4 — Handle the tricky spots
- **Attributes** (`title=`, `placeholder=`, `label=`, `tooltip=`): wrap with `t(...)`.
- **ProTable / antd Table `columns`**: `columns` are usually defined in render; map
  each `title` through `t(...)`. If defined at module scope, move them inside the
  component (so `intl` is available) or build them in a `useMemo`.
- **Static arrays of option labels**: localize the `label`, keep the `value` stable.
- **Dynamic text with values**: use placeholders, never string concatenation.
  ```ts
  // key:  'pages.analysis.storeRank': 'Store Sales Ranking {n}'
  intl.formatMessage({ id: 'pages.analysis.storeRank', defaultMessage: 'Store Sales Ranking {n}' }, { n: 7 });
  ```
- **Dates / numbers**: prefer `intl.formatDate` / `intl.formatNumber` for locale-aware
  formatting where it matters.

### Step 5 — Do NOT touch generated/auto files
- Never edit `src/services/ant-design-pro/` (regenerate with `npm run openapi`).
- `src/.umi` / `src/.umi-production` are generated — ignore them.

### Step 6 — Verify (see Section 7).

---

## 5. Creating a NEW Page / Section (i18n from the start)

When adding a brand-new section, wire i18n in the same commit. Do NOT introduce any
literal strings.

### What to create and where
1. **Page directory** (co-located): `src/pages/<area>/<name>/`
   - `index.tsx` (the page; uses `useIntl` from the first line of UI text)
   - `service.ts` (API calls via `request` from `@umijs/max`)
   - `data.d.ts` (types)
   - optional `components/`, `*.style.ts`
2. **Route**: add an entry in `config/routes.ts` with a `name` that maps to a
   `menu.*` i18n key (e.g. `name: 'reports'` -> `menu.reports`). `access` gates it.
3. **Menu label**: add `menu.<name>` to `en-US/menu.ts`, `de-DE/menu.ts`, `es-ES/menu.ts`.
4. **Page strings**: add `pages.<name>.*` keys to all three `pages.ts` files.
5. **Backend data (database-first)**: do NOT add a Umi mock. Add the endpoint to the
   Fastify server (`server/src/routes/`), backed by a repository + (if persistent)
   a table in `server/db/schema.sql` + `server/db/fixtures.ts` + `server/db/seed.ts`,
   wrapped by a cache decorator. nginx already routes `/api/*` to the backend.
   Seed content must be English/neutral (the EN/DE/ES constraint).

### How (skeleton)
```tsx
// src/pages/reports/index.tsx
import { useIntl, useRequest } from '@umijs/max';
import { PageContainer } from '@ant-design/pro-components';
import { fetchReports } from './service';

export default () => {
  const intl = useIntl();
  const { data } = useRequest(fetchReports);
  return (
    <PageContainer title={intl.formatMessage({ id: 'pages.reports.title', defaultMessage: 'Reports' })}>
      {/* render data; every label via intl.formatMessage */}
    </PageContainer>
  );
};
```
```ts
// src/pages/reports/service.ts
import { request } from '@umijs/max';
export const fetchReports = () => request('/api/reports'); // served by the Fastify backend
```

Checklist for a new section: route added, `menu.*` in 3 locales, `pages.*` in 3
locales, no literals, backend endpoint (no mock), English seed, lint + build pass.

---

## 6. Backend Endpoints Behind Pages (avoid 404s)

Some template pages call mock endpoints that were never migrated and now 404 with
mocks off (e.g. `/api/fake_analysis_chart_data`, `/api/monitor/map-geo`). When you
convert a page, migrate its data endpoint to the Fastify backend the same way the
other endpoints were done (route -> repository -> optional table/seed -> cache
decorator). Keep seed data English/neutral. Track remaining endpoints in
`migration_progress.md`.

---

## 7. Verification (container-first — never run on the host)

```bash
# Lint (Biome) + type-check
docker compose run --rm webapp npm run lint
# antd-specific deprecation/API checks (must pass)
docker compose run --rm webapp npx antd lint ./src
# Production build sanity
docker compose run --rm webapp npm run build
```
Manual check:
1. `docker compose up -d` and open `http://localhost/<page>`.
2. Switch language in the header (or set browser language) to en-US / de-DE / es-ES
   and confirm every string changes and none remain Chinese.
3. Confirm no console warning "missing key" (means a key is absent in a locale).

Tip: a quick "did I miss any literal" scan per page:
```bash
grep -rIno "[一-龥]" src/pages/<area>/<name> || echo "clean"
```

---

## 8. Per-Page Conversion Checklist

- [ ] All literals found (grep) and listed.
- [ ] Keys added to `en-US/pages.ts`, `de-DE/pages.ts`, `es-ES/pages.ts` (same keys).
- [ ] Component uses `useIntl()` + `formatMessage` with `defaultMessage` everywhere.
- [ ] Attributes, table columns, option labels, dynamic strings all localized.
- [ ] Data endpoint migrated to the backend if it was a mock (no 404).
- [ ] No edits to `src/services/ant-design-pro/` or `.umi`.
- [ ] `npm run lint` and `npx antd lint ./src` pass; `npm run build` succeeds.
- [ ] Manually verified in en-US / de-DE / es-ES with no leftover Chinese.

---

## 9. Pitfalls & Rules

- Biome only (no ESLint/Prettier). Both `npm run lint` and `npx antd lint ./src`
  must pass before commit.
- Run `npx antd info <Component>` before writing antd code — do not guess props.
- Keys must exist in all three locales; always pass `defaultMessage` as a safety net.
- Do not concatenate translated fragments; use placeholders (`{name}`).
- Keep `value`/keys stable when localizing option `label`s (don't break logic).
- `npm run simple` is irreversible — commit/branch first.

---

## 10. Suggested Order of Work

1. Pilot: `src/pages/dashboard/analysis` (the reported page) end to end, including
   migrating `/api/fake_analysis_chart_data` to the backend.
2. `src/pages/dashboard/monitor`, `src/pages/dashboard/workplace`.
3. Remaining `src/pages/**` (run the grep below to enumerate; ~53 files affected):
   ```bash
   grep -rIl "[一-龥]" src/pages | sort
   ```
Track progress in `migration_progress.md` (or a dedicated i18n checklist) so the
team can see which pages are done.
