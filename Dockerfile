# bolt.diy publishes no image for its releases (ghcr `latest` is 109 commits older than
# v1.0.1), and building it needs a 4 GB heap. So it is built here once, in CI, and a
# deploy pulls the finished image.
FROM node:22-bookworm-slim AS build
# upgrade: github stackblitz-labs/bolt.diy
ARG BOLT_VERSION=v1.0.1
WORKDIR /app
ENV HUSKY=0 CI=true
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && corepack enable && corepack prepare pnpm@9.15.9 --activate
RUN git clone --depth 1 --branch "$BOLT_VERSION" https://github.com/stackblitz-labs/bolt.diy.git . \
  && pnpm install --frozen-lockfile \
  && NODE_OPTIONS=--max-old-space-size=4096 pnpm run build \
  && rm -rf .git docs e2e-tests electron benchmarks tests \
  && pnpm store prune
# No `pnpm prune --prod` here, unlike upstream's Dockerfile: the app is served by
# `vite preview`, and vite and its Cloudflare plugin are devDependencies. Pruned, the
# container dies at start with "vite: No such file or directory".

FROM node:22-bookworm-slim
# Caddy owns the public port: bolt.diy has no login, and its server refuses
# requests whose Host is not localhost.
COPY --from=caddy:2.10 /usr/bin/caddy /usr/local/bin/caddy
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git tini \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app /app
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
ENV NODE_ENV=production RUNNING_IN_DOCKER=true WRANGLER_SEND_METRICS=false \
    VITE_LOG_LEVEL=info PORT=8080
EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
