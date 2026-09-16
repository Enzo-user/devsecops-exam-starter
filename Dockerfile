# syntax=docker/dockerfile:1

# Base image: Node 24 (Active LTS) on Alpine 3.24, pinned to the exact tag
# behind node:24-alpine on 2026-09-16 so the build is reproducible.
# Multi-arch index digest at pin time:
#   sha256:be80f76cf40ec8e42b9bec49f60a55e0660f30af58d3e5a25530785b30ea67e2
# (Verify with: docker buildx imagetools inspect node:24.21.0-alpine3.24)

# ---------------------------------------------------------------------------
# Stage 1: deps — install production dependencies only.
# ---------------------------------------------------------------------------
FROM node:24.21.0-alpine3.24 AS deps
WORKDIR /app

# Copy only the manifests first: this layer is cached until package.json or
# package-lock.json changes, so a change to server.js never re-runs npm ci.
COPY package.json package-lock.json ./

# npm ci: install exactly what the lockfile says (fails if it disagrees with
# package.json). --omit=dev keeps jest/supertest out of the image.
# --ignore-scripts refuses to run install hooks from third-party packages.
RUN npm ci --omit=dev --ignore-scripts

# ---------------------------------------------------------------------------
# Stage 2: runtime — minimal, patched, non-root image.
# ---------------------------------------------------------------------------
FROM node:24.21.0-alpine3.24 AS runtime
ENV NODE_ENV=production

# 1. Pin the OpenSSL libraries to the fixed Alpine build (CVE-2026-14456 is
#    HIGH in the untouched base image; hadolint DL3017 forbids a blind
#    `apk upgrade`, so the fix is pinned explicitly).
# 2. Remove npm, npx, corepack and yarn: the runtime never needs a package
#    manager, and the npm bundled with the official image ships HIGH CVEs in
#    its own dependencies (tar, brace-expansion, ip-address). Deleting them
#    both shrinks the image and removes the findings instead of ignoring them.
# 3. Create the app directory owned by the unprivileged `node` user (uid 1000,
#    shipped by the official image).
RUN apk add --no-cache libcrypto3=3.5.8-r0 libssl3=3.5.8-r0 \
    && rm -rf /usr/local/lib/node_modules \
              /usr/local/bin/npm /usr/local/bin/npx \
              /usr/local/bin/corepack \
              /usr/local/bin/yarn /usr/local/bin/yarnpkg /opt/yarn-* \
    && mkdir -p /app && chown node:node /app

WORKDIR /app

# Copy exactly what the app needs and nothing else (no tests, no docs).
COPY --chown=node:node --from=deps /app/node_modules ./node_modules
COPY --chown=node:node package.json server.js ./

# Drop privileges: everything from here on (and at run time) runs as the
# `node` user. Numeric uid:gid (1000:1000 in the official image) so the
# runtime can verify non-root without resolving names (hadolint DL3066).
USER 1000:1000

EXPOSE 3000

# Health check with node itself so the image needs no curl/wget. It respects
# PORT the same way server.js does and exits 1 on any non-2xx or network error.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["node", "-e", "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]

# Run node directly (no npm wrapper) so it is PID 1 and receives signals.
CMD ["node", "server.js"]
