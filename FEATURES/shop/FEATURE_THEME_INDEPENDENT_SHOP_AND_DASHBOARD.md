# Shop Feature: Theme (Light/Dark/System) Independent of `/dashboard`

Status: **backlog — not started**. Captures a decision made during the login/register/verify + seller-dashboard + PWA build-out session, for a future session to pick up.

## 1. Problem

Dark mode was implemented (`shop/src/themes/dark.css`, `ThemeModeContext`, `data-color-mode` attribute on `<html>`, persisted to `localStorage['blablarags_theme_mode']`) with its only user-facing control — a System/Light/Dark `<select>` — placed on the seller dashboard's Settings page (`shop/src/app/[locale]/dashboard/settings/SettingsClient.tsx`). That page sits behind `RequireAuth`, under the `/dashboard/*` route group.

Net effect: a logged-out visitor browsing the public marketplace has **no way to change the theme at all** — they only ever get the OS-level `prefers-color-scheme` default. Theme is a general UI preference, not an account setting, and shouldn't require registering/logging in to control.

## 2. What's already correct (don't redo this)

The underlying mechanism is **already** independent of `/dashboard` — only the toggle's *location* is gated:

- `ThemeModeProvider` is mounted once in the true root layout (`shop/src/app/[locale]/layout.tsx`), which is an ancestor of every route, marketplace and dashboard alike.
- `data-color-mode` is set on `<html>` itself, not some dashboard-scoped wrapper.
- All theme tokens live in one place (`shop/src/themes/{default,dark,legacy-teal}.css`, imported once by `globals.css`); every route's Tailwind classes (`bg-primary`, `text-on-surface`, etc.) resolve from the same `var(--color-...)` chain regardless of which route rendered them.
- Verified live: toggling the mode from the dashboard Settings page correctly re-themed the public `/login` page in the same session — confirming the CSS/state layer has zero coupling to `/dashboard`.

## 3. Decision: one shared mechanism, not two CSS directories

Considered and rejected: giving `/dashboard/*` its own separate theme CSS directory, independently scoped. Rejected because:

- It would duplicate the full token set (~25 custom properties × light/dark × brand themes) into a second location, with real risk of drift (someone edits `--color-primary` in one file, forgets the other).
- The dashboard is a nested route inside the *same* Next.js app/bundle — there's no independent-deployment reason to split it.
- You'd still need one shared signal (localStorage or equivalent) for the choice to feel consistent across both halves of the site, so splitting the CSS doesn't even remove the shared-session dependency — it just adds a second stylesheet to keep in sync with it.

**Kept:** the single shared `ThemeModeContext` + one `themes/*.css` token set already built. Nothing about the CSS/state architecture needs to change.

## 4. Actual fix needed

Add a theme toggle that's reachable **without being logged in** — i.e., not gated behind `/dashboard`. Concretely:

1. **New `ThemeSwitcher` component** in `shop/src/blocks/topNav/`, mirroring `LanguageSwitcher.tsx`'s existing pattern exactly (button + click-to-open absolute-positioned list + click-outside-to-close overlay), so it's visually/behaviorally consistent with the language switcher already sitting next to it in the nav.
2. **New icons** needed (Feather, same stroke-based convention as the rest of `src/components/icons/`): `IconSun` (light), `IconMoon` (dark), `IconMonitor` (system) — none of these exist yet in the icon set.
3. **Wire into `topNav/index.tsx`**, placed next to `LanguageSwitcher` — available on every page, logged in or not.
4. **Settings → Theme**: decide whether to keep the existing dropdown there too (redundant-but-harmless, same shared context/state) or remove it now that topNav covers it. No strong reason either way; default to keeping both unless it looks cluttered once built.
5. **i18n**: new `topNav` dictionary keys for the switcher's accessible label + the three option labels (can reuse `dashboard.themeSystem/themeLight/themeDark` strings already added, or add topNav-scoped equivalents — check for naming collisions before adding new ones).
6. Re-verify: toggle from a logged-out session on the homepage, confirm persistence across reload, confirm the dashboard Settings dropdown (if kept) stays in sync with whatever topNav sets (same localStorage key + context, so this should be automatic — just needs a live check).

## 5. Also still open (from the original dark-mode backlog item, not yet done)

- Full contrast/legibility pass across every page in dark mode — only Settings, Dashboard overview, and Login were spot-checked so far. Home page, register/verify, mega menu, filter sidebar, product grid, editorial spotlight, footer, mobile drawer are all unverified in dark mode.
- Audit for any remaining hardcoded/raw-Tailwind-palette colors introduced elsewhere in the app that would break in dark mode (the two known/fixed instances were the status badges and the 3 `text-white` bugs on primary buttons — there may be others in blocks not touched this session).
- `legacy-teal` theme has no dark variant (deliberately skipped — it's dormant, nothing sets `data-theme="legacy-teal"` today). Revisit only if that theme is ever reactivated.
