ARG NODE_VERSION=22
ARG NGINX_VERSION=1.21
ARG ALPINE_VERSION=3.20
ARG APP_ROUTE=.

FROM node:${NODE_VERSION}-alpine${ALPINE_VERSION} as base
ARG APP_ROUTE
WORKDIR /usr/src/app
COPY ${APP_ROUTE}/package*.json /usr/src/app

RUN set -eux \
    && apk add \
    --no-cache \
    git \
    wget \
    ;
RUN if [ -f package.json ]; then yarn install; fi

FROM base AS graphql
WORKDIR /usr/src/app

RUN if [ -f package.json ]; then npm install; fi
RUN npm install -g pnpm

COPY ./graphql/ /usr/src/app

COPY docker/node/graphql/docker-entrypoint.sh /usr/local/bin/docker-entrypoint
RUN chmod +x /usr/local/bin/docker-entrypoint

# ENTRYPOINT ["docker-entrypoint"]
CMD ["tail", "-f", "/dev/null"]

FROM base as webapp
ARG APP_ROUTE

RUN if [ -f package.json ]; then npm install; fi

COPY ${APP_ROUTE}/ /usr/src/app

COPY docker/node/app/docker-entrypoint.sh /usr/local/bin/docker-entrypoint
RUN chmod +x /usr/local/bin/docker-entrypoint

ENTRYPOINT ["docker-entrypoint"]
CMD ["tail", "-f", "/dev/null"]

FROM base as typescript

RUN if [ -f package.json ]; then npm install; fi

COPY ./typescript /usr/src/app

COPY docker/node/typescript/docker-entrypoint.sh /usr/local/bin/docker-entrypoint
RUN chmod +x /usr/local/bin/docker-entrypoint

# ENTRYPOINT ["docker-entrypoint"]
CMD ["tail", "-f", "/dev/null"]
