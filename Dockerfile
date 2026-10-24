# syntax=docker/dockerfile:1.7

ARG NODE_IMAGE=node:22.23.4-alpine3.24

FROM ${NODE_IMAGE} AS base
WORKDIR /app

# ---------- dev: todas as dependências, reload automático ----------
FROM base AS dev
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci
COPY --chown=node:node . .
RUN chown node:node /app
USER node
EXPOSE 3000
CMD ["npm", "run", "dev"]

# ---------- build: compila TypeScript para dist/ ----------
FROM base AS build
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# ---------- prod-deps: somente dependências de produção ----------
FROM base AS prod-deps
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev

# ---------- production: imagem final enxuta ----------
FROM ${NODE_IMAGE} AS production

ARG VERSION=1.0.0
ARG SOURCE=https://github.com/henriqueholtz/fc4-desafio-docker-node-api

LABEL org.opencontainers.image.title="flags-api" \
      org.opencontainers.image.description="API REST de CRUD de feature flags em Node.js + TypeScript com PostgreSQL" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.source="${SOURCE}"

# npm/yarn/corepack não são necessários em runtime: removê-los reduz superfície de ataque e CVEs
RUN rm -rf /usr/local/lib/node_modules /usr/local/bin/npm /usr/local/bin/npx \
           /usr/local/bin/corepack /opt/yarn-* /usr/local/bin/yarn /usr/local/bin/yarnpkg

ENV NODE_ENV=production
WORKDIR /app

COPY --from=prod-deps --chown=root:root /app/node_modules ./node_modules
COPY --from=build --chown=root:root /app/dist ./dist
COPY package.json ./

USER node
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["node", "-e", "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]

CMD ["node", "dist/server.js"]
