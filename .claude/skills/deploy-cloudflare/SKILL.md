---
name: deploy-cloudflare
description: Deploy a static front-end (Astro/Vite/SPA built to a dist folder) to Cloudflare Workers Static Assets. Use when the user wants to ship a static site to Cloudflare, set up Git-connected Cloudflare builds, configure wrangler.jsonc, or debug a Cloudflare static deploy. Covers Docker-based workflows. Not for SSR/backend apps (note when Containers are needed instead).
---

# Deploy a static front-end to Cloudflare Workers

Repeatable checklist for deploying a **statically built** site (Astro `output:"static"`,
Vite, CRA, plain SPA — anything that compiles to a `dist/` of HTML/JS/CSS) to
**Cloudflare Workers Static Assets**. Free plan, no container at runtime.

## Decide first: static assets vs Containers/SSR
- **Static assets (this skill):** no per-request server logic. Just serve files. Free.
- **Containers / SSR:** needed only for request-time rendering, a backend, sockets, or
  non-JS runtimes. Requires a **paid** Workers plan. → see "When Containers are needed".
- A purely static, multi-language site is still static — locales are pre-built HTML, not
  a reason to use SSR.

## Steps

1. **Install wrangler** as a project dev dependency (prefer over global for reproducibility):
   `npm install -D wrangler`. In a Docker workflow, run inside the app container:
   `docker exec <container> sh -c 'cd /usr/src/app && npm install -D wrangler'`.

2. **Write `wrangler.jsonc`** for an assets-only Worker (NO `main` key):
   ```jsonc
   {
     "name": "<project-name>",
     "compatibility_date": "<today YYYY-MM-DD>",
     "assets": {
       "directory": "./dist",
       "not_found_handling": "404-page"   // multi-page site; use "single-page-application" only for true SPAs
     }
   }
   ```

3. **Build** → produces `dist/`: `npm run build` (in Docker: `docker exec <c> sh -c 'cd /usr/src/app && npm run build'`).
   Verify the build emitted the expected pages (and `dist/404.html` if you set `404-page`).

4. **Prep the repo:** ensure `dist/`, `node_modules/`, `.wrangler/`, `.dev.vars` are
   gitignored. Keep only ONE lockfile (`package-lock.json` XOR `yarn.lock`).

5. **Deploy — choose a path:**
   - **Git-connected (recommended):** push repo → Cloudflare dashboard → Workers & Pages
     → Create → Workers → *Import a repository*. Set production branch,
     **build command** `npm run build`, **deploy command** `npx wrangler deploy`,
     root dir = folder containing `wrangler.jsonc`. Redeploys automatically on push.
   - **CLI:** authenticate then `npx wrangler deploy` (uploads existing `dist/`):
     - API token (best for Docker/CI): `docker exec -e CLOUDFLARE_API_TOKEN=<tok> <c> sh -c 'cd /usr/src/app && npx wrangler deploy'`
     - Browser OAuth: `npx wrangler login` (needs a browser; from a container, expose port 8976).

6. **Verify:** `curl -sI <workers.dev URL>` → 200; check each route/locale; check an
   unknown path returns 404; open in a browser.

## When Containers are needed (paid plan)
SSR with per-request data, backend API, WebSockets, non-JS runtime. Then either add the
`@astrojs/cloudflare` adapter for SSR-on-Workers (build emits `dist/_worker.js`; set
`main` to it), or define `containers` + a Durable Object binding in `wrangler.jsonc` with
a production Dockerfile whose process listens on a port.

## Troubleshooting / known gotchas
- **`TypeError: Cannot read properties of undefined (reading 'call')` at
  `EnvironmentPluginContainer.transform` (Astro dev/build).** A **Vite major-version
  mismatch** between Astro and a framework integration. The integration's bundled
  `@vitejs/plugin-*` targets a different Vite than Astro's, so its `transform` hook is
  undefined. Fix: align the integration to Astro's Vite line. For Astro 6 (Vite 7) use
  `@astrojs/react@5`; `@astrojs/react@4` is Astro 5/Vite 6, `@astrojs/react@6` is
  Astro 7/Vite 8. Check with `npm ls vite` — it should dedupe to ONE version. After
  fixing: `rm -rf node_modules/.vite .astro/.vite` and restart dev. (The prod `build`
  may limp through while dev fails — always test `astro dev` too, not just `build`.)
- **`main: ./dist/_worker.js` on a static site → deploy fails.** A static build never
  produces `_worker.js`. Remove `main` for assets-only deploys.
- **Wrong 404 behavior.** Use `not_found_handling: "404-page"` for multi-page sites,
  `"single-page-application"` for SPAs. With `"404-page"` but no `dist/404.html`,
  Cloudflare serves its default 404 (add `src/pages/404.astro` to customize).
- **Two lockfiles** (`package-lock.json` + `yarn.lock`) confuse Cloudflare's package
  manager detection → wrangler may not install / build fails. Keep one.
- **`wrangler login` from a container** can't open a browser and uses a `localhost:8976`
  OAuth callback. Prefer `CLOUDFLARE_API_TOKEN` for containerized/CI deploys.
- **Containers require a paid Workers plan** — not available on free. Don't reach for
  them for static sites.
- **Astro i18n `redirectToDefaultLocale`** makes `/` a 2s HTML meta-refresh to the
  default locale; works on static hosting but isn't an instant redirect.
- Keep `dist/` and `.wrangler/` gitignored; commit `wrangler.jsonc`.
