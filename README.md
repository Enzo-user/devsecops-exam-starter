# Macky Merch API — containerized, tested, scanned

This is my submission for the LSCS **Systems & Infrastructure (CQA / DevSecOps)** take-home. The starter is a tiny Express app with one `/health` endpoint and one Jest test; the backend code is deliberately untouched. What I built around it:

- a multi-stage, non-root, health-checked **Dockerfile** on a pinned Node 24 Alpine base, with a **.dockerignore** that keeps the build context to the lockfile and two source files;
- a **GitHub Actions** pipeline (`.github/workflows/ci.yml`) that tests, lints the Dockerfile, scans dependencies with two independent sources, scans every commit in the push or PR for secrets (the full-history sweep is a local `gitleaks` run before each push), builds and smoke-tests the image, scans the built image, and validates the compose stack;
- a **docker-compose.yml** that runs the API next to a Redis container on a private network;
- two demo branches that each plant one deliberate problem (a vulnerable `lodash`, a fake AWS key) so the pipeline can be seen failing for the right reason.

Every claim below comes with the command that produced it; the fenced blocks are real output from my machine (macOS arm64, Docker via Colima) on 16–17 Sep 2026.

## Contents

- [Quick start](#quick-start)
- [Pipeline overview](#pipeline-overview)
- [Architecture decisions](#architecture-decisions)
- [Security scanning](#security-scanning)
- [Vulnerability demonstration](#vulnerability-demonstration)
- [Branch protection](#branch-protection)
- [Challenges faced](#challenges-faced)
- [Submission checklist](#submission-checklist)

## Quick start

### Build and run the container

```sh
docker build -t macky-merch-api:local .
docker run -d --name api -p 3000:3000 macky-merch-api:local
curl -si http://localhost:3000/health
```

Expected response:

```http
HTTP/1.1 200 OK
Content-Type: application/json; charset=utf-8

{"status":"OK","message":"Macky Merch API is running smoothly."}
```

Things worth checking while it runs (output from my machine):

```sh
$ docker exec api whoami
node
$ docker exec api sh -c 'command -v npm npx yarn corepack || echo "no package manager in image"'
no package manager in image
$ docker exec api ls -l /app            # root-owned, read-only to the process
total 12
drwxr-xr-x   70 root     root          4096 Sep 16 22:22 node_modules
-rw-r--r--    1 root     root           411 Sep 16 15:09 package.json
-rw-r--r--    1 root     root           434 Sep 16 14:34 server.js
$ docker exec api ps -o pid,user,args   # tini is PID 1, node is its child
PID   USER     COMMAND
    1 node     /sbin/tini -- node server.js
    7 node     {MainThread} node server.js
$ docker inspect --format '{{.State.Health.Status}}' api
healthy
$ /usr/bin/time -p docker stop api      # SIGTERM reaches node: well under 1 s
api
real 0.09
$ docker inspect --format '{{.State.ExitCode}}' api
143
$ docker rm api
```

### Run the API plus Redis with Compose

```sh
docker compose up -d --wait        # builds the image, starts redis, waits for both health checks
curl http://localhost:3000/health
docker compose exec api sh -c 'getent hosts redis'   # prints the redis container's address; 172.18.0.2 on my machine, the subnet depends on the host's existing Docker networks
docker compose down -v             # also removes the redis volume
```

`server.js` does not use Redis; see [docker-compose.yml](#docker-composeyml) for why it is there.

### Run without Docker

```sh
npm ci          # exact install from package-lock.json
npm test        # jest, one test against /health
npm start       # http://localhost:3000/health
```

### Run each scanner locally

The versions are the ones the pipeline pins; the flags are the ones the pipeline uses.

| Check | Command |
|---|---|
| Dockerfile lint | `hadolint Dockerfile` (2.15.1) |
| Lockfile vulnerabilities | `trivy fs --scanners vuln --severity CRITICAL,HIGH --ignore-unfixed --exit-code 1 .` (0.74.0) |
| npm advisories | `npm audit --audit-level=high` |
| Secrets in history | `gitleaks git --redact --exit-code 1 --log-opts=main .` (8.30.1); drop `--log-opts` to sweep every local branch, which on a clone that has `demo/leaked-secret` will report the planted key |
| Image vulnerabilities | `trivy image --scanners vuln --severity CRITICAL,HIGH --ignore-unfixed --exit-code 1 macky-merch-api:local` |
| Workflow syntax | `actionlint .github/workflows/ci.yml` (1.7.12) |
| Compose file | `docker compose config -q` |

## Pipeline overview

`ci.yml` runs on every `push` to `main` and every `pull_request` targeting `main`.

```
push / pull_request (main)
        │
        ├── test ───────────────► docker  (needs: test)
        │                          ├─ buildx build (push: false, load: true, GHA cache)
        ├── lint-dockerfile        ├─ smoke test: /health 200, whoami == node, no npm, image size, docker stop → exit 143
        │                          ├─ trivy image  (HIGH/CRITICAL, fixed-only, exit 1)
        ├── dependency-scan        ├─ docker compose config -q
        │                          └─ compose smoke test (api + redis), reusing the built image
        └── secret-scan
```

Four jobs run in parallel; `docker` waits for `test` because building an image whose code fails its own tests is wasted minutes. All five are the checks the ruleset on `main` requires (see [Branch protection](#branch-protection)).

**test** — checkout, `actions/setup-node` with Node 24 and the npm cache, `npm ci`, `npm test -- --ci`. This is the "checkout → setup Node → npm install → npm test" sequence from the spec; `npm ci` is the reproducible form of `npm install` (it installs exactly what the lockfile says and fails if `package.json` disagrees, instead of silently rewriting the lockfile). `--ci` makes Jest refuse to write new snapshots on a CI box. It exists so a broken change can never reach the image build.

**lint-dockerfile** — `hadolint` on the Dockerfile with `failure-threshold: info`, i.e. any finding fails. It catches the classes of mistakes that are invisible in a green build: an unpinned `apk add` (DL3018), a missing `--no-cache` (DL3019), a `latest` tag (DL3007), a named instead of numeric `USER` (DL3066). The Dockerfile passes with zero findings and there is no `.hadolint.yaml` exception file.

**dependency-scan** — `trivy fs` over the repo (lockfile), `--scanners vuln`, severity `CRITICAL,HIGH`, `--ignore-unfixed`, `--exit-code 1`; then `npm audit --audit-level=high` as an independent second opinion from npm's own advisory database. Either one failing fails the job. It exists so a dependency with a known, fixable high-severity CVE cannot be merged; it is the job the `demo/vulnerable-dependency` branch breaks.

**secret-scan** — checkout with `fetch-depth: 0`, then `gitleaks/gitleaks-action`. I read the action's source at the pinned commit rather than assume: on a `push` it runs `gitleaks detect --log-opts="--no-merges --first-parent <first>^..<last>"` (`detect` is the older name of today's `git` subcommand) over exactly the pushed commits, and on a `pull_request` over the PR's commits, which it lists through the REST API; `fetch-depth: 0` is what makes those parent commits available. It scans commit diffs, not the working tree, so a secret added in one commit and deleted in a later commit of the same PR is still reported. It does not re-sweep the entire history on every run (the action does that only for `workflow_dispatch`/`schedule`); the full sweep is the local `gitleaks git` command in the table above, which I run on `main`'s history before every push. The action needs no `GITLEAKS_LICENSE` on a personal-account repo (its README says so explicitly). Because it lists the PR's commits through the API, the job grants itself `pull-requests: read` on top of the workflow-wide `contents: read`; I disabled PR comments so nothing needs write access. It is the job the `demo/leaked-secret` branch breaks.

**docker** — `docker/setup-buildx-action`, then `docker/build-push-action` with `push: false`, `load: true`, tag `macky-merch-api:ci` and the GitHub Actions layer cache. The built image is then actually run: the step waits for `/health` to return 200, asserts `docker exec … whoami` prints `node`, asserts no `npm`/`npx`/`yarn` binary exists in the image, prints the image size, then runs `docker stop -t 5` and asserts the container's exit code is 143 (128 + SIGTERM): the signal reached node through tini and the container stopped inside the grace period instead of being SIGKILLed (137). Then `trivy image` scans the image as built (Alpine packages plus `/app/node_modules`) with the same HIGH/CRITICAL, fixed-only, exit-1 policy. Finally `docker compose config -q` validates the compose file and `docker compose up -d --wait` brings up api + redis (reusing the image just built via `IMAGE_TAG`), curls `/health`, resolves `redis` from inside the api container and tears everything down. It exists so "the Dockerfile builds" also means "the container starts, answers, runs unprivileged, stops cleanly and is clean".

Global settings: `permissions: contents: read` at the top (nothing here writes to the repo; one job adds one read, see [Pipeline hygiene](#pipeline-hygiene-permissions-sha-pins-concurrency-timeouts)), a `concurrency` group per branch/PR with `cancel-in-progress` only for `pull_request` events, so a new push to a PR cancels the run it supersedes while every commit on `main` keeps its own status, `timeout-minutes` on every job, and `runs-on: ubuntu-24.04` rather than `ubuntu-latest` so the runner image does not silently change under the pipeline. `actionlint` (with shellcheck) passes.

## Architecture decisions

### Base image: `node:24.21.0-alpine3.24`

**Why Node 24.** Node 24 "Krypton" is the current Active LTS (LTS since October 2025, maintenance from October 2026, end-of-life April 2028). Node 22 is already in maintenance (EOL April 2027) and Node 20 reaches EOL in April 2026, so both would need a migration during the life of this project. Nothing in the app depends on a Node version; `/health` runs the same on all three.

**Why Alpine over Debian slim or `node:latest`.** `node:latest` is whatever the maintainers pushed last: a rebuild tomorrow can change the Node major version, and there is no way to say what I tested. Between Alpine and `bookworm-slim`, Alpine 3.24 ships 18 packages in the base layer versus 88 for `node:24-bookworm-slim` (counted with `apk info` and `dpkg -l`); fewer packages means fewer CVEs to track and a smaller pull. The known Alpine trade-off is musl instead of glibc, which matters for native addons; this app has none (`npm ci` runs with `--ignore-scripts` and nothing is compiled), so I take the smaller surface.

**Why the exact tag plus a recorded digest.** `24-alpine` moves every time Node or Alpine publishes a patch. `24.21.0-alpine3.24` is the exact tag behind it today, and the Dockerfile records the index digest (`sha256:be80f76c…`) in a comment. Pinning with `@sha256:` in `FROM` would be the strongest form, but it makes the Dockerfile unreadable for humans and Dependabot, and a digest pin also freezes *security* patches, so the honest position is: pin the exact tag, record the digest so anyone can verify it (`docker buildx imagetools inspect node:24.21.0-alpine3.24`), and bump the tag deliberately. Keeping it fresh is Dependabot's job, configured in `.github/dependabot.yml`: weekly checks of the base tag in the Dockerfile (`docker` ecosystem), the redis tag in the compose file (`docker-compose`, which GitHub treats as a separate ecosystem), the lockfile (`npm`) and the action SHAs (`github-actions`, which rewrites the SHA and the version comment together). Every Dependabot PR has to pass this same pipeline. What Dependabot does not watch is the apk versions inside the Dockerfile; `trivy image` on every run covers those.

**The trade-off in practice.** Pinning means I own the patch cadence. The very first `trivy image` on the untouched base showed that: Alpine's `libcrypto3`/`libssl3` 3.5.7-r0 carry CVE-2026-14456 (HIGH), fixed in 3.5.8-r0. The runtime stage therefore runs `apk add --no-cache "libcrypto3>=3.5.8-r0" "libssl3>=3.5.8-r0"`. Three ways to get the fix were on the table. A blind `apk upgrade` (hadolint does not object to it; I checked by linting one) would fix it, but it makes the image content depend on the build day for every package and leaves no record of which CVE was being fixed. An exact pin `=3.5.8-r0` is fully reproducible, but Alpine's repository index only carries the newest build of a package, so the day 3.5.8-r1 or 3.5.9-r0 is published the build fails with `unable to select packages`, on a grader's machine as much as in CI. The `>=` floor is the middle: the build still fails if the fixed version is not available, it never breaks because Alpine moved forward, only those two packages can drift, and `trivy image` in the `docker` job re-checks the result on every run. When the base tag is bumped to a build that already contains the fix, the line becomes a no-op and can be removed. The other apk package, `tini`, is an exact pin (`tini=0.19.0-r3`): it is a tool I chose, not a moving security fix, and a stale pin there fails the build loudly rather than changing it silently.

### Multi-stage layout, and why the runtime stage deletes npm

Stage `deps` copies only `package.json` and `package-lock.json`, then runs `npm ci --omit=dev --ignore-scripts`: the lockfile is the source of truth, `jest`/`supertest` never enter the image, and no third-party install hook runs during the build. Stage `runtime` starts again from the same pinned base and copies in exactly three things: `node_modules` from `deps`, `package.json` and `server.js`.

Then it removes `/usr/local/lib/node_modules`, `/usr/local/bin/{npm,npx,corepack,yarn,yarnpkg}` and `/opt/yarn-*`. Two reasons. First, the running app never needs a package manager, and a package manager in a production image is a tool for an attacker who gets a shell. Second, the npm bundled with the official image is itself vulnerable. This is the untouched base image today:

```
$ trivy image --severity HIGH,CRITICAL --ignore-unfixed --scanners vuln node:24.21.0-alpine3.24

node:24.21.0-alpine3.24 (alpine 3.24.1)
Total: 2 (HIGH: 2, CRITICAL: 0)
│ libcrypto3 │ CVE-2026-14456 │ HIGH │ fixed │ 3.5.7-r0 │ 3.5.8-r0 │ openssl: DoS via unbounded memory growth in QUIC server
│ libssl3    │                │      │       │          │          │

Node.js (node-pkg)    -- all under usr/local/lib/node_modules/npm/
Total: 4 (HIGH: 4, CRITICAL: 0)
│ brace-expansion │ CVE-2026-14257 │ HIGH │ fixed │ 5.0.7  │ 5.0.8, …  │ DoS via memory exhaustion in expand()
│                 │ CVE-2026-69152 │      │       │        │ 5.0.9, …  │ DoS via unbounded intermediate arrays
│ ip-address      │ CVE-2026-69192 │      │       │ 10.2.0 │ 10.3.1    │ Inconsistent IP parsing leads to SSRF
│ tar             │ CVE-2026-73566 │      │       │ 7.5.19 │ 7.5.21    │ DoS via crafted long-path tar archive
```

And the final image built from this Dockerfile:

```
$ trivy image --severity HIGH,CRITICAL --ignore-unfixed --scanners vuln --exit-code 1 macky-merch-api:local
macky-merch-api:local (alpine 3.24.1)   alpine     0
app/node_modules/**/package.json        node-pkg   0   (68 packages)
app/package.json                        node-pkg   0
```

Removing npm fixes the four `node-pkg` findings by removing the vulnerable code rather than adding them to an ignore list, and the `apk add` floor fixes the two OS findings. One honest caveat on size: the deletion happens in a new layer on top of the base, so the files are gone from the final filesystem (which is what Trivy and an attacker see) but the base layer that contains them still has to be pulled. The image is 62.5 MB versus 59.0 MB for the bare base (+6 MB for the patched OpenSSL plus tini layer, +4.7 MB `node_modules`, 16 kB of app code). Shrinking below the base would mean copying the `node` binary into a bare `alpine` image and creating the user by hand; I judged that not worth losing the official image's maintained `node` user and its tested Node build for a 60 MB image.

### Non-root user, and files the process cannot modify

`USER 1000:1000` is the `node` user the official image creates. It is numeric on purpose (hadolint DL3066): a numeric UID lets an orchestrator's `runAsNonRoot` check succeed without resolving names inside the image, and `whoami` still prints `node` because `/etc/passwd` maps it. `/app` and everything in it (`server.js`, `package.json`, `node_modules`) is copied *without* `--chown`, so it is root-owned and world-readable (644/755): the process can read and execute its own code but cannot rewrite it, even under a plain `docker run` (`echo >> /app/server.js` as `node` fails with `Permission denied`; the same goes for `node_modules`). The only writable place in the image is `/tmp`, which `server.js` never touches. The compose file goes further with `read_only: true` and a tmpfs `/tmp`; the same two flags work on `docker run` (`--read-only --tmpfs /tmp`), and the container was tested that way too.

### PID 1 and graceful shutdown: `tini`

`ENTRYPOINT ["/sbin/tini", "--"]` with `CMD ["node", "server.js"]`. Node does not install a SIGTERM handler, and the kernel does not apply default signal actions to PID 1, so running `node server.js` directly as PID 1 means `docker stop` waits the whole grace period (10 s) and then SIGKILLs it: exit code 137. I measured exactly that on my first image (see [Challenges faced](#challenges-faced)). `tini` (0.19.0-r3 from Alpine's `community` repository) runs as PID 1, forwards SIGTERM to node, which then exits through its default action, and reaps any zombie. Result: `docker stop` returns in under a second with exit 143 (128 + SIGTERM), and `docker compose down` is instant. A `process.on('SIGTERM', …)` in `server.js` would also work, but the starter's rule is not to touch the app code, and an init is the right layer regardless: it handles the same for anything node spawns. The `docker` job asserts the 143 on every run.

### Layer ordering and caching

Manifests are copied and installed before the source code, so editing `server.js` reuses the cached `npm ci` layer; only a lockfile change re-installs. In CI the same idea is applied across runs with `cache-from: type=gha` / `cache-to: type=gha,mode=max`.

### `.dockerignore`

It excludes `node_modules` (installed inside the image from the lockfile, so the host copy, possibly built for a different OS, must never be sent), `.git`, `.github`, the Docker and compose files themselves, docs, tests, coverage, `.env*` and editor clutter. `docker build --progress=plain` shows the result: `transferring context: 171.78kB`, about 171 kB, which is `package-lock.json` (170,776 bytes) plus two small files.

### `HEALTHCHECK`

The probe is `node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/health')…"`, so no `curl` or `wget` is installed just for health checks, and it follows `PORT` exactly the way `server.js` does. It exits 1 on a non-2xx response or a connection error. `docker inspect` reports `healthy` and `docker compose up --wait` blocks on it.

### `npm ci` versus `npm install`

`npm install` may resolve newer versions inside the `^` ranges and rewrite `package-lock.json`; two runs on two days can produce two different trees, and a scanner that passed on one may fail on the other. `npm ci` deletes `node_modules`, installs exactly the locked versions and fails if the lockfile is stale. The CI step is named "Install dependencies (npm ci)" so it is obviously the install step from the spec, with the substitution called out.

### Pipeline hygiene: permissions, SHA pins, concurrency, timeouts

The workflow-wide grant is `permissions: contents: read`. One job needs one more read: `secret-scan` adds `pull-requests: read`, because `gitleaks-action` lists the PR's commits through the REST API on `pull_request` events and the default token (`pull-requests: none`) would get a 403 there. Nothing has write access; I disabled the one feature (gitleaks PR comments) that would have needed `pull-requests: write`. Every `uses:` is pinned to a 40-character commit SHA with the release tag in a comment (`actions/checkout@3d3c42e5… # v7.0.1`), because a tag is a moveable pointer that a compromised or careless maintainer can repoint; a SHA is not. I resolved each tag through the GitHub API and read each action's `action.yml` at that commit before using any input; `.github/dependabot.yml` keeps the SHAs moving forward through reviewed PRs. `concurrency` with `cancel-in-progress: ${{ github.event_name == 'pull_request' }}` stops superseded PR runs burning minutes while never cancelling a run on `main` (each commit there keeps its own verdict), and `timeout-minutes` on every job means a hung container or scanner cannot hold a runner for six hours.

### `docker-compose.yml`

Two services on a user-defined bridge network `backend`: `api` (built from this Dockerfile, `PORT=3000`, `REDIS_URL=redis://redis:6379`, `restart: unless-stopped`, read-only root filesystem with a tmpfs `/tmp`, all capabilities dropped, `no-new-privileges`) and `redis` (`redis:7.4.11-alpine3.21`, the exact tag behind `redis:7.4-alpine` today with its digest in a comment, `redis-cli ping` health check, named volume, no host port). `api` has `depends_on: redis: condition: service_healthy`, so it does not start until Redis answers PING.

To be clear: `server.js` never opens a Redis connection. The bonus asks for a "dummy database container on a shared network", and that is what this is; the environment variable and the DNS name are wired so the app can use it the day it needs to, and my local compose run proves the wiring: `getent hosts redis` resolves, and `printf "PING\r\n" | nc redis 6379` from inside the api container returns `+PONG` (the CI compose step checks the DNS half). The read-only root filesystem was tested as well: `echo > /app/x` inside the container fails with `Read-only file system` and the app keeps serving.

## Security scanning

**Trivy** (`aquasecurity/trivy-action`, Trivy 0.74.0, pinned) is the primary scanner because one tool covers both places a vulnerability can live: the lockfile (`trivy fs`) and the image as built, OS packages plus `node_modules` (`trivy image`). It is free, actively maintained, works offline once its database is cached, and can emit SARIF for GitHub code scanning if wanted later. It is also the scanner that found the two real problems in this repo (the bundled npm CVEs and the OpenSSL CVE in the base image).

**`npm audit --audit-level=high`** is a second opinion from a different advisory source (GitHub Advisory Database via npm) that costs one command. Two databases disagree at the edges; the lodash demo below shows npm reporting six advisories where Trivy reports four CVEs, which is exactly why both run.

**gitleaks** (`gitleaks/gitleaks-action` v3, gitleaks 8.30.1) scans commit diffs (the pushed or PR commits in CI, the whole history locally) for credential shapes: AWS, GitHub, Stripe, generic high-entropy keys and so on. I chose it over TruffleHog or GitGuardian because it runs entirely inside the job (no data leaves the runner), needs no account or license for a personal repo, and has a CLI that behaves identically locally.

**hadolint** lints the Dockerfile for practices that a green build cannot verify (pinned packages, `--no-cache`, no `latest`, numeric user).

**Threshold: HIGH and CRITICAL, fixed-only, fail the job.** Medium and low findings are real but rarely actionable on the day; a gate that fails on them gets an ignore list within a week and then protects nothing. `--ignore-unfixed` drops findings that have no upstream fix yet, because the only possible response to those is "wait", which does not belong in a merge gate (they still show in a local run without the flag). HIGH/CRITICAL with a fix available is the set where the correct response is always "bump the package or the base image today", so that is the set that blocks.

**Triage of a real finding.** The failing job prints the table: package, CVE, installed and fixed version. If it is a direct dependency, bump it in `package.json`, `npm install`, re-run `trivy fs` locally, open a PR. If it is transitive, `npm audit fix` or an `overrides` entry in `package.json`, then the same. If it is an OS package, bump the base tag to a build that has the fix, or raise the apk version floor as the Dockerfile does for OpenSSL. Only if the CVE is genuinely unreachable (e.g. a DoS in a code path the app cannot execute) would a `.trivyignore` entry be acceptable, and it needs the CVE id, the reason and an expiry date.

## Vulnerability demonstration

`main` is green: `trivy fs`, `npm audit`, `gitleaks` and `trivy image` all report nothing. Two branches, each exactly one commit ahead of the final `main` commit, plant exactly one problem each, and each is opened as a PR against `main` so the failing check is visible on the PR itself.

### `demo/vulnerable-dependency` — fails `dependency-scan` (and `docker`)

The one change is `npm install lodash@4.17.15 --save-exact`: `package.json` gains `"lodash": "4.17.15"` and `package-lock.json` gains the resolved entry. `server.js` is not touched. Locally:

```
$ trivy fs --scanners vuln --severity CRITICAL,HIGH --ignore-unfixed --exit-code 1 .

package-lock.json (npm)
Total: 4 (HIGH: 4, CRITICAL: 0)
│ Library │ Vulnerability  │ Severity │ Status │ Installed │ Fixed     │ Title
│ lodash  │ CVE-2020-8203  │ HIGH     │ fixed  │ 4.17.15   │ 4.17.19   │ prototype pollution in zipObjectDeep
│         │ CVE-2021-23337 │          │        │           │ 4.17.21   │ command injection via template
│         │ CVE-2026-4800  │          │        │           │ 4.18.0    │ arbitrary code execution via template imports
│         │ NSWG-ECO-516   │          │        │           │ >=4.17.19 │ allocation of resources without limits
exit code 1

$ npm audit --audit-level=high
lodash  <=4.17.23
Severity: high
Command Injection in lodash - GHSA-35jh-r3h4-6jhm
Prototype Pollution in lodash - GHSA-p6mc-m468-83gw
Regular Expression Denial of Service (ReDoS) in lodash - GHSA-29mw-wpgm-hmr9
… (6 advisories)
1 high severity vulnerability
exit code 1
```

Because `lodash` is a production dependency it is also copied into the image, so `trivy image` on an image built from this branch reports the same CVEs under `app/node_modules/lodash/package.json` and the `docker` job fails too.

<!-- PR-LINK: vulnerable-dependency -->

### `demo/leaked-secret` — fails `secret-scan`

The one change is a new file `config/payments.js` exporting an AWS-access-key-shaped string, `AKIAFAKE…KEYX` (the full value is in the branch, not here, so `main`'s history stays clean). It contains the words FAKE, LSCS and DEMO, is not associated with any account, and the file's header comment says exactly what it is. Locally:

```
$ gitleaks git --redact --exit-code 1 --log-opts=main..demo/leaked-secret .

Finding:     paymentsApiKey: 'REDACTED',
Secret:      REDACTED
RuleID:      aws-access-token
Entropy:     3.508695
File:        config/payments.js
Line:        15
Commit:      <the branch's single commit: git log -1 demo/leaked-secret>
leaks found: 1
exit code 1
```

`gitleaks` scans commit diffs, so the leak is still reported if a later commit on the branch deletes the file; the only real fix is to rotate the credential and rewrite history.

<!-- PR-LINK: leaked-secret -->

The CI logs on the two PRs are the evidence; the blocks above are trimmed excerpts (columns and log noise removed) of what the failing jobs print, captured from the same commands on my machine.

<!-- CI-RUN-LINK: main -->

## Branch protection

`main` is protected by a ruleset (repository **Settings → Rules → Rulesets**, targeting `main`) with:

- pull request required before merging (no direct pushes);
- required status checks, all from the `CI` workflow: `test`, `lint-dockerfile`, `dependency-scan`, `secret-scan`, `docker`, with "require branches to be up to date" enabled;
- force pushes and branch deletion blocked.

The ruleset requires the checks; what each check asserts is described in [Pipeline overview](#pipeline-overview). With those in place the two demo PRs cannot be merged: the merge button stays disabled until the red check turns green, which for these branches means removing the planted problem.

## Challenges faced

**The official base image was not clean.** I expected the pinned `node:24-alpine` to pass `trivy image` and to spend my effort on the app layer. It did not: the very first scan showed six HIGH findings, none of them in the app. Four were in the npm client bundled at `/usr/local/lib/node_modules/npm` (`tar`, `brace-expansion`, `ip-address`), two were Alpine's OpenSSL libraries one patch release behind. Ignoring them with a `.trivyignore` would have made the scan meaningless. For npm the answer was to ask what the runtime actually needs: only `node`. So the runtime stage deletes npm, npx, corepack and yarn, which removes the vulnerable code entirely and also removes a tool an attacker would want. For OpenSSL I checked what the Alpine 3.24 repository actually serves (`apk policy libcrypto3` inside the image showed 3.5.8-r0) and set that as a version floor in `apk add`, rather than a blind `apk upgrade` (unrecorded, drifts every package) or an exact pin (breaks the build the day Alpine rebuilds OpenSSL); the reasoning is in the base image section. Result: 0 HIGH/CRITICAL on the final image, and hadolint still clean.

**`docker stop` took ten seconds.** My first image ran `node server.js` directly as PID 1, with a comment saying that made it "receive signals". Timing `docker stop` proved the opposite: it returned after 10.11 s with exit code 137, i.e. the SIGTERM was never acted on and Docker fell back to SIGKILL. The reason is a Linux rule I had not internalised: PID 1 gets no default signal actions, so a process that installs no handler (node does not) simply ignores SIGTERM there. Since the starter code must stay untouched, the fix belongs to the container: `tini` as `ENTRYPOINT` forwards the signal to node as a normal child. The same test now returns in under 0.1 s with exit 143, and the `docker` job asserts that exit code so the regression cannot come back silently. The lesson: a comment that says "handles signals" is a claim, and claims get a stopwatch.

**The starter itself failed its own audit.** `npm audit` on the untouched clone reported 3 moderate advisories in `qs` via `express@4.22.2`. That is below the HIGH gate, but shipping a pipeline whose baseline is already yellow felt wrong. `npm audit fix` moved express to 4.22.3 inside the existing `^4.18.2` range, which is a lockfile-only change (`package.json` untouched, tests still pass). I made it the first commit on its own so the history shows "starter as received → dependencies clean → everything else".

**Building on arm64 for an amd64 runner.** My laptop is Apple Silicon and Docker runs in a Colima VM, so every local image was `linux/arm64`, while `ubuntu-24.04` runners are `linux/amd64`. A Dockerfile can hide arch assumptions (a downloaded binary, a native module) that only surface in CI. I verified with `docker buildx build --platform linux/amd64 --load .`, which built under QEMU emulation, and then ran the amd64 image: `node -e 'console.log(process.arch)'` printed `x64` and `/health` returned 200. Nothing in the Dockerfile is arch-specific (the base is a multi-arch index and `npm ci --ignore-scripts` compiles nothing), so the CI build is the same build. The same session also taught me that gitleaks' default AWS rule has an entropy floor: my first fake key, `AKIAFAKEFAKEFAKEFAKE`, was too repetitive to fire, so the planted value had to be synthetic *and* varied enough to look like a real key to the rule.

## Submission checklist

| Exam item | Where |
|---|---|
| Starter repo forked | this repository (`origin` = my fork, `upstream` = `dlsu-lscs/devsecops-exam-starter`) |
| Dockerfile runs as non-root | `Dockerfile` (`USER 1000:1000`); the `docker` job asserts `docker exec … whoami` prints `node` |
| `.dockerignore` present | `.dockerignore`; context transfer is about 171 kB |
| `ci.yml` runs tests and builds the image | `.github/workflows/ci.yml` jobs `test` and `docker` |
| Security scanner in the workflow | `dependency-scan` (Trivy fs + npm audit), `secret-scan` (gitleaks), `docker` (Trivy image), `lint-dockerfile` (hadolint) |
| Deliberate vulnerability, documented | branches `demo/vulnerable-dependency` and `demo/leaked-secret`, section [Vulnerability demonstration](#vulnerability-demonstration) |
| README: setup, rationale, demonstration, challenges | this file |
| Bonus: docker-compose with a dummy DB | `docker-compose.yml` (api + redis on `backend` network) |
| Bonus: multi-stage Dockerfile | `Dockerfile` stages `deps` and `runtime` |
| Bonus: branch protection | ruleset on `main`, section [Branch protection](#branch-protection) |
