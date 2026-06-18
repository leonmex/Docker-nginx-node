ARG NODE_VERSION=22
ARG ALPINE_VERSION=3.20
ARG APP_ROUTE=./dashboard

FROM node:${NODE_VERSION}-alpine${ALPINE_VERSION} AS base
ARG APP_ROUTE
WORKDIR /usr/src/app
RUN apk add --no-cache git

# ---------------------------------------------------------------------------
# DEVELOPMENT: fast-iteration target.
# No build-time npm install — deps are installed at runtime (see docker-compose.yml)
# and cached in the named volume. Runs the Umi dev server with mock data.
# ---------------------------------------------------------------------------
FROM base AS webapp
ARG APP_ROUTE
WORKDIR /usr/src/app
COPY ${APP_ROUTE}/ /usr/src/app
EXPOSE 3000
# Umi dev server with mock data; PORT is provided via docker-compose.
CMD ["npm", "run", "start"]

# ---------------------------------------------------------------------------
# BUILDER: production asset build stage.
# Installs deps reproducibly from the lockfile and compiles static assets to ./dist.
# package.json + lockfile are copied first so the npm layer is cached across
# source-only changes.
# ---------------------------------------------------------------------------
FROM base AS builder
ARG APP_ROUTE
WORKDIR /usr/src/app
COPY ${APP_ROUTE}/package.json ${APP_ROUTE}/package-lock.json ${APP_ROUTE}/.npmrc ./
# `npm install` (not `npm ci`): the upstream lockfile drifts from package.json,
# which would make `npm ci` fail. install reconciles it the same way the dev path does.
RUN npm install --ignore-scripts
COPY ${APP_ROUTE}/ ./
RUN npm run build

# ---------------------------------------------------------------------------
# PRODUCTION: serve the compiled SPA with nginx. No Node.js, no node_modules.
# ---------------------------------------------------------------------------
FROM nginx:alpine AS production
COPY nginx/prod.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /usr/src/app/dist /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
