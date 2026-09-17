# Base image: Node 24 (Active LTS) on Alpine 3.24, pinned to the exact tag
# behind node:24-alpine on 2026-09-16 so the build is reproducible.
# Multi-arch index digest at pin time:
#   sha256:be80f76cf40ec8e42b9bec49f60a55e0660f30af58d3e5a25530785b30ea67e2
# (Verify with: docker buildx imagetools inspect node:24.21.0-alpine3.24)
#
# No `# syntax=docker/dockerfile:1` directive on purpose: it would pull an
# unpinned BuildKit frontend image, and nothing here needs a newer syntax.

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

# 1. Patch OpenSSL: the base image ships libcrypto3/libssl3 3.5.7-r0, which
#    carry CVE-2026-14456 (HIGH); Alpine 3.24 serves the fix as 3.5.8-r0.
#    The constraint is a floor (>=), not an exact pin: it still fails the
#    build if the fix is not available, but it does not break the build the
#    day Alpine publishes 3.5.8-r1 or 3.5.9-r0 (the repository index only
#    keeps the newest build of a package). A blind `apk upgrade` was avoided
#    because it would silently change every package on the build day; this
#    line names the two packages and the reason, and `trivy image` in CI
#    checks the result. Drop it once the base tag itself contains the fix.
# 2. Install tini as PID 1. node does not install a SIGTERM handler and the
#    kernel ignores default-action signals for PID 1, so without an init
#    `docker stop` waits the full grace period and SIGKILLs the app. tini
#    forwards the signal to node (and reaps zombies) so shutdown is prompt.
#    Same version floor as OpenSSL: Alpine's index only serves the newest
#    build of a package, so an exact `=0.19.0-rN` pin would break the build
#    (on any machine, any day) the moment Alpine rebuilds tini. The floor
#    names the version this image was tested with and still installs if the
#    suffix moves. Reproducibility comes from the exact base tag; drift in
#    these three packages is caught by `trivy image` on every run.
# 3. Remove npm, npx, corepack and yarn: the runtime never needs a package
#    manager, and the npm bundled with the official image ships HIGH CVEs in
#    its own dependencies (tar, brace-expansion, ip-address). Deleting them
#    both shrinks the image and removes the findings instead of ignoring them.
RUN apk add --no-cache "libcrypto3>=3.5.8-r0" "libssl3>=3.5.8-r0" "tini>=0.19.0" \
    && rm -rf /usr/local/lib/node_modules \
              /usr/local/bin/npm /usr/local/bin/npx \
              /usr/local/bin/corepack \
              /usr/local/bin/yarn /usr/local/bin/yarnpkg /opt/yarn-*

# /app is created by WORKDIR as root:root 755. The app files below are
# copied without --chown on purpose: they land as root-owned, world-readable
# (644/755), so the unprivileged process can read and execute them but can
# not rewrite its own code or node_modules. server.js never writes to disk.
WORKDIR /app

# Copy exactly what the app needs and nothing else (no tests, no docs).
COPY --from=deps /app/node_modules ./node_modules
COPY package.json server.js ./

# Drop privileges: everything from here on (and at run time) runs as the
# `node` user. Numeric uid:gid (1000:1000 in the official image) so the
# runtime can verify non-root without resolving names (hadolint DL3066).
USER 1000:1000

EXPOSE 3000

# Health check with node itself so the image needs no curl/wget. It respects
# PORT the same way server.js does and exits 1 on any non-2xx or network error.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["node", "-e", "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]

# tini is PID 1 and forwards SIGTERM/SIGINT to node, which runs as its only
# child (no npm wrapper in between). server.js has no signal handler and the
# starter rules say not to add one, so the container level is where a clean
# `docker stop` (exit 143 in under a second, not SIGKILL after 10 s) is made.
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "server.js"]
