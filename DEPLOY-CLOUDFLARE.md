# Deploying this site to Cloudflare (Workers Static Assets)

This guide explains how to deploy **this Astro portfolio** — and any similar
**static front-end** — to Cloudflare. It covers the recommended **Git-connected**
deployment (Cloudflare builds & deploys on every push) plus the **CLI** path as an
alternative. All local commands are run **inside the `webapp` Docker container**.

---

## 0. What we're deploying and why this setup

- The site is an **Astro app with `output: "static"`** (see `astro.config.mjs`).
  The build pre-renders **every page, in every locale (en/de/fr/es), to plain HTML**
  into `dist/`. "Static" describes *how pages are rendered* (at build time, not per
  request) — it does **not** reduce languages or features.
- Because there's no per-request server logic, the natural Cloudflare target is
  **Workers Static Assets**: Cloudflare serves the files in `dist/` directly from its
  edge. This is **free** (Workers free plan), fast, and needs no container at runtime.
- **You do _not_ need Cloudflare Containers** for this site. Containers are for running
  a long-lived server process (SSR, a backend API, sockets) and require a **paid**
  Workers plan. See [When you actually need Containers / SSR](#when-you-actually-need-containers--ssr).

Key config file: [`wrangler.jsonc`](./wrangler.jsonc)
```jsonc
{
  "name": "nbarrera-personal-web",
  "compatibility_date": "2026-06-29",
  "assets": {
    "directory": "./dist",
    "not_found_handling": "404-page"
  }
}
```
There is **no `main`** key on purpose: a static build produces no Worker script
(`_worker.js`), so this is an *assets-only* Worker.

---

## 1. Prerequisites

- A **Cloudflare account** (free plan is enough for static assets).
- **Docker Desktop** running, with this project's `webapp` container up
  (`docker compose up -d webapp`). All Node/Wrangler commands run inside it.
- For the Git path: this repo pushed to **GitHub/GitLab**
  (current remote: `git@github.com:leonmex/Docker-nginx-node.git`).

`wrangler` is already a dev dependency (`package.json`), so no global install is needed.
Run everything through the container, e.g.:
```bash
docker exec webapp sh -c 'cd /usr/src/app && npx wrangler --version'
```

---

## 2. Recommended: Git-connected deployment (build on Cloudflare)

Cloudflare clones the repo, runs the build, and deploys — automatically on every push.
No API token or browser login is stored locally.

1. **Commit & push** the deployment files (`wrangler.jsonc`, `package.json`,
   `.gitignore`, this guide) to your branch and push to GitHub.
2. In the Cloudflare dashboard → **Workers & Pages → Create → Workers → Import a repository**
   (a.k.a. *Connect to Git*).
3. Authorize GitHub and select the repository (`leonmex/Docker-nginx-node`).
4. Configure the build:
   - **Production branch**: the branch you want live (e.g. `main`, or your
     `main-personal-web-for-claudflare-v1` branch).
   - **Build command**: `npm run build`
   - **Deploy command**: `npx wrangler deploy` (Cloudflare Workers Builds default;
     it reads `wrangler.jsonc` and uploads `dist/`).
   - **Root directory**: `/` (this repo's root contains `wrangler.jsonc`).
5. Save & deploy. Cloudflare builds and publishes to
   `https://nbarrera-personal-web.<your-subdomain>.workers.dev`.
6. Every subsequent push to the production branch redeploys automatically.

> **Package manager note:** this repo currently has **both** `package-lock.json` and
> `yarn.lock`. Cloudflare auto-detects the package manager and the presence of both can
> make it pick the wrong one (or fail to install `wrangler`). Keep only the lockfile you
> actually use (npm → keep `package-lock.json`, delete `yarn.lock`; or vice-versa), or
> set an explicit install/build command.

---

## 3. Alternative: deploy from the CLI (inside the container)

Useful for one-off deploys or when you don't want Git integration.

```bash
# Build the static site
docker exec webapp sh -c 'cd /usr/src/app && npm run build'

# Authenticate (choose ONE):
#  a) API token (best for Docker/CI) — create at Cloudflare → My Profile → API Tokens
#     → "Edit Cloudflare Workers" template, then:
docker exec -e CLOUDFLARE_API_TOKEN=<your-token> webapp \
  sh -c 'cd /usr/src/app && npx wrangler deploy'

#  b) Browser OAuth — requires exposing wrangler's callback port (8976) on the
#     container and opening the printed URL in your host browser:
docker exec -it webapp sh -c 'cd /usr/src/app && npx wrangler login'
```

`wrangler deploy` builds nothing itself here — it just uploads the existing `dist/`
per `wrangler.jsonc`. The `cf:deploy` script (`astro build && wrangler deploy`) does both.

---

## 4. Verify the deployment

After it's live (URL from the dashboard or CLI output):

```bash
URL=https://nbarrera-personal-web.<your-subdomain>.workers.dev

curl -sI "$URL"            # root: 200 + meta-refresh page redirecting to /en/
curl -sI "$URL/en/"        # 200
curl -sI "$URL/de/"        # 200  (repeat for /fr/ /es/)
curl -sI "$URL/no-such"    # 404  (default CF 404 unless you add src/pages/404.astro)
```
Then open the URL in a browser and switch languages to confirm all four locales load.

---

## 5. Optional improvements

- **Custom 404 page:** add `src/pages/404.astro`. The build emits `dist/404.html`,
  which `not_found_handling: "404-page"` will then serve.
- **Custom domain:** Workers & Pages → your Worker → **Settings → Domains & Routes →
  Add custom domain** (your domain must be on Cloudflare DNS).
- **Cleaner root redirect:** the `/` → `/en/` redirect is a 2s HTML meta-refresh
  generated by Astro i18n. For an instant redirect you can add a `_redirects` file or a
  small Worker script.

---

## When you actually need Containers / SSR

Switch away from static assets only if the site gains **request-time logic**, e.g.:

- Server-side rendering with per-request data (DB/API calls on each visit).
- A backend API, WebSockets, long-running processes, or non-JS runtimes.
- Server-side language detection from request headers (instead of pre-built locale URLs).

In those cases:
- **SSR on Workers:** add the `@astrojs/cloudflare` adapter, set Astro `output` to
  `"server"`/`"hybrid"`; the build then emits `dist/_worker.js` and `wrangler.jsonc`
  needs a `main` pointing to it.
- **Containers:** define a `containers` + Durable Object binding in `wrangler.jsonc`,
  add a production `Dockerfile` whose process listens on a port, and deploy with
  `wrangler deploy`. **Requires a paid Workers plan.**

This portfolio needs none of that today.
