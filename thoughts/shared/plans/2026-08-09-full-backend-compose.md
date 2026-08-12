---
date: 2026-08-09T08:40:54+10:00
researcher: Claude Opus 5
git_commit: 9258204de9d40db68b75058a62b699ab1c9b72a2
branch: main
repository: hiyar-dev-stack
topic: "Full-backend Compose profile for client (mobile) testing against a complete Hiyar backend"
tags: [plan, docker-compose, api-gateway, artifact-registry, local-dev]
status: complete
last_updated: 2026-08-09
last_updated_by: Claude Opus 5
last_updated_note: "Corrected service inventory after discovering stale local checkouts (messaging-service, risk-service, admin-service were pulled April 2026 locally, weeks-to-months behind origin/main); added messaging-service as a 14th real service, documented risk-service's Cloud-SQL-IAM-only blocker, admin-service's stub-only status, and the service-to-service OIDC auth limitation for gateway-bypassing calls."
---

# Full-Backend Compose Profile Implementation Plan

## Overview

Extend `hiyar-dev-stack/compose.yaml` with a new `backend` profile that runs api-gateway
plus 14 Hiyar domain services with working Dockerfiles (13 from the original scope plus
messaging-service, confirmed implemented after re-syncing a stale local checkout), wired
to the existing GCP-emulator services already in this repo. Each service is independently
switchable between pulling a tagged image from Artifact Registry and building from a
sibling local checkout, so a client (Android/iOS/web) can point at
`http://localhost:<gateway-port>` and exercise a complete backend end-to-end.

**risk-service is excluded** (its Cloud SQL access is hardcoded to the IAM connector, no
plain-DSN path exists) and **admin-service is excluded** (its current code is a bare
healthz stub with no business logic and isn't reachable via api-gateway). See "Key
Discoveries" and "What We're NOT Doing" below.

## Current State Analysis

`compose.yaml` today only starts infrastructure dependencies (Postgres, Redis, Pub/Sub
emulator, Firestore emulator, fake-gcs-server, Temporal, stripe-mock, Firebase Auth
emulator, otel-collector, Jaeger) behind profiles `minimal` / `notification` / `payment` /
`gcs` / `gateway` / `observability` / `full`. It does not run any Hiyar Go service
container. No other compose file or prior art exists anywhere in the workspace for
running the actual services together (`hiyar-infra` has Terraform only).

### Key Discoveries

- **Local checkouts were stale during initial research** — nearly every `hiyar-{service}`
  repo under `~/Projects/hiyar` was weeks to months behind `origin/main` (e.g.
  `hiyar-messaging-service` and `hiyar-risk-service` were 3.5 months behind;
  `hiyar-ai-service` and `hiyar-media-service` were also months behind). All findings below
  reflect `origin/main` after re-fetching each repo. Two repos still have **uncommitted
  local changes** blocking a fast-forward pull as of this research —
  `hiyar-notification-service` (`internal/listingsvc/server.go`, `server_test.go`,
  `templates.go`) and `hiyar-api-gateway` (`go.mod`, `go.sum`) — these were left untouched;
  resolve them (commit/stash) before relying on those repos' current `HEAD` for build mode.
- **Services with a Dockerfile** (all `EXPOSE 8080`, distroless final stage): api-gateway,
  user-service, listing-service, search-service, booking-service, payment-service,
  handover-service, review-service, ai-service, notification-service, media-service,
  messaging-service, temporal-worker, outbox-relay, admin-service. 14 of these are runnable
  as real services; `admin-service` is excluded (stub — see below) and `risk-service` is
  excluded despite having a Dockerfile (Cloud SQL blocker — see below).
- **`messaging-service` is fully implemented** (`hiyar-messaging-service/cmd/server/main.go`,
  Firestore-backed conversation/message store, publisher, screening) — include it as a
  first-class service.
- **`risk-service` is fully implemented but cannot connect to a plain Postgres container**:
  its DB access goes exclusively through `hiyar-go-gcp/cloudsql.NewPool`
  (`hiyar-go-gcp@v0.2.7/cloudsql/cloudsql.go:42-47`), which always calls
  `cloudsqlconn.NewDialer(ctx, cloudsqlconn.WithIAMAuthN(), ...)` — a real Cloud SQL IAM
  connector requiring a live GCP Cloud SQL instance and IAM credentials. There is no
  `DATABASE_URL`/DSN code path (`hiyar-risk-service/internal/config/config.go:31-36` only
  exposes `CloudSQLInstance`/`DBUser`/`DBName`, by design — "primer Rule 31": no DSN, no DB
  password). Making risk-service run against this repo's local Postgres would require a
  code change in `hiyar-risk-service` itself, which is out of scope here (`CLAUDE.md`: "Do
  not add application code" in `hiyar-dev-stack`). risk-service is excluded from the
  `backend` profile.
- **`admin-service`'s current code is a stub**: `hiyar-admin-service/cmd/server/main.go` is
  24 lines — a bare `/healthz` handler, no business logic. api-gateway's config has no
  `ADMIN_SERVICE_URL` (grepped `hiyar-api-gateway/internal/home/config.go` — no match), so
  it isn't even reachable via the gateway. Excluded — nothing to test yet.
- **Service-to-service calls that bypass the gateway require a real Google-signed OIDC ID
  token**, which cannot be minted in local Docker (no GCP metadata server). Per
  `hiyar-go-common/auth/auth.go:1-113`, a receiving service's Interceptor accepts either (a)
  the gateway's trusted `X-Hiyar-User-Id` header (no cryptographic check — this is the path
  every gateway-fanned-out call uses, and it works fine locally) or (b) a validated OIDC
  bearer token (used for direct service-to-service calls that don't go through the
  gateway). This means the following **will not work locally** and are documented as a
  known limitation rather than solved:
  - messaging-service's outbound calls to media-service (`GetMediaObjectStatus` deep
    media-ownership check) and ai-service (`ScreenContent` contact-info screening) —
    `hiyar-messaging-service/internal/config/config.go:46-70`.
  - temporal-worker's internal RPCs into messaging-service (`BootstrapConversation`,
    `InjectSystemMessage`), gated by `MESSAGING_INTERNAL_CALLER_SA` allowlist-of-emails on
    top of the same OIDC check.
  - risk-service's outbound calls to listing-service/ai-service/media-service (moot locally
    anyway since risk-service itself is excluded).
  - The primary client-facing flows (anything routed through api-gateway's fan-out, e.g.
    login → browse listings → view booking → send a chat message) are unaffected — they use
    the trusted-header path, not OIDC.
- **Image registry convention**: `australia-southeast1-docker.pkg.dev/hiyar-staging/containers/{service}:{git-sha-7}`
  (service name drops the `hiyar-` prefix, e.g. `user-service`). No `latest` tag exists —
  every image is tagged with a 7-char short SHA from CI (`.github/workflows/deploy.yml` in
  each service repo).
- **Every service, including api-gateway, listens on `PORT` (default 8080)** internally —
  confirmed via `hiyar-user-service/internal/config/config.go:74` and Cloud Run Terraform
  (`container_port = 8080` in every per-service `main.tf`).
- **api-gateway is the single client-facing endpoint** (ADR-013): it exposes intent-level
  Buf Connect RPCs and fans out internally to domain services over plain `http://` via 11
  `*_SERVICE_URL` env vars, all `mustEnv` (panics if unset) —
  `hiyar-api-gateway/internal/home/config.go:26-38`. It also needs `USER_SERVICE_URL`
  separately for JWKS verification (`cmd/server/main.go:459-469`), plus `REDIS_ADDR`,
  `TEMPORAL_HOST_PORT`, `MEDIA_BUCKET`.
- **Secrets are not a blocker for local dev**:
  - `JWT_SIGNING_KEY_PATH` and `STRIPE_API_KEY_PATH` / `STRIPE_WEBHOOK_SECRET_PATH` are
    read with plain `os.ReadFile` (`hiyar-user-service/cmd/server/main.go:100-120`) — any
    local file works, no Secret Manager call.
  - `SECRET_KMS_KEY_NAME` (CMEK) is optional — leaving it unset skips KMS entirely
    (`main.go:154-160`); no KMS emulator is needed.
  - Firebase Admin SDK auto-redirects to `FIREBASE_AUTH_EMULATOR_HOST` when set — no need
    to fake a service-account JSON file. This repo's existing `firebase` service already
    provides that emulator.
  - `FIREBASE_ADMIN_SDK_PATH`, `GOOGLE_OAUTH_CLIENT_SECRETS_PATH`, `APPLE_OAUTH_CONFIG_PATH`
    are declared in Terraform but not read by any current service code — skip wiring them.
  - Only `GOOGLE_CLIENT_ID` / `APPLE_CLIENT_ID` (plain env, not secret-mounted) matter today.
- **Database-backed services** already have per-service DSNs in `.env.example`
  (user/listing/search/booking/payment/handover/review/risk/ai). `media-service` and
  `notification-service` are not in that list, consistent with them using
  fake-gcs-server / Firestore rather than a Postgres schema.
- **Pulling images requires host-level `gcloud` auth**: the Artifact Registry repo is
  private (`hiyar-staging` project). A developer must run
  `gcloud auth login && gcloud auth configure-docker australia-southeast1-docker.pkg.dev`
  once per machine, with Artifact Registry Reader on that project, before `docker compose
  pull`/`up` will succeed for any service in pull mode. This is a documented prerequisite,
  not something the compose file can automate.
- **Build mode requires sibling checkouts**: each service's `Dockerfile` lives at
  `~/Projects/hiyar/hiyar-{service}/Dockerfile`. `hiyar-api-gateway`'s Dockerfile mounts a
  BuildKit secret (`--mount=type=secret,id=netrc`) for private Go module access — build
  mode for that service requires `DOCKER_BUILDKIT=1` and a local `.netrc` with GitHub
  module access.

## Desired End State

Running `docker compose --profile backend up -d` (after `gcloud auth configure-docker`
and `cp .env.example .env`) starts api-gateway and all 13 domain services alongside the
existing emulators, fully wired so a mobile client pointed at
`http://localhost:${GATEWAY_PORT}` can complete a real end-to-end flow (e.g. login via
Firebase emulator → fetch listings → view a booking) against real Go service code, with
GCP/third-party dependencies satisfied by emulators/mocks already in this repo.

Any individual service can be switched to build-from-source by running
`docker compose build <service>` before `up`, without editing the compose file — a
`${SERVICE}_TAG` env var picks the pulled tag, and Compose's `build:` + `image:` co-existence
handles the mode switch.

### Verification
- `docker compose --profile backend up -d` reaches `healthy`/`running` for every new
  service.
- `docker compose --profile backend build user-service && docker compose --profile backend up -d user-service`
  rebuilds and runs that one service from the sibling checkout instead of pulling.
- A manual RPC through api-gateway (e.g. `curl` or the Android dev client) reaches at
  least one domain service and gets a real (non-mocked) response.

## What We're NOT Doing

- Not adding `admin-service` — current code is a stub with no business logic and isn't
  reachable via api-gateway.
- Not adding `risk-service` — its Cloud SQL access requires the real IAM connector; no
  plain-DSN fallback exists in current code, and adding one is an app-code change outside
  this repo's scope. Its `RISK_SERVICE_URL` requirement on api-gateway is satisfied with a
  placeholder pointing at another running container (see Phase 2) purely so api-gateway
  boots; RPCs that route to risk-service will fail at the handler level, permanently, until
  `hiyar-risk-service` adds local-dev DB support.
- Not fixing the service-to-service OIDC auth gap for gateway-bypassing calls (messaging→
  media/ai deep checks, temporal-worker→messaging internal RPCs) — this requires either a
  GCP metadata-server emulator or a local-dev bypass in `hiyar-go-common/auth`, both outside
  this repo. Documented as a known limitation.
- Not resolving the uncommitted local changes found in `hiyar-notification-service` or
  `hiyar-api-gateway`, or fast-forwarding any other stale checkout — that's the developer's
  call, flagged for awareness only.
- Not building or wiring a KMS emulator — CMEK stays disabled in local dev.
- Not implementing Firebase Admin SDK JSON / OAuth client-secret file support — current
  service code doesn't read those paths.
- Not automating `gcloud auth configure-docker` — documented as a manual one-time
  prerequisite.
- Not changing any existing profile's behavior (`minimal`, `notification`, `payment`,
  `gcs`, `gateway`, `observability`, `full` keep their current service sets).
- Not adding CI for this new profile — it's for local/manual client testing only.

## Implementation Approach

Add 15 services (api-gateway + 14 domain services, including messaging-service) to the
existing single `compose.yaml`, each carrying both `image:` (Artifact Registry path +
per-service tag variable) and `build:` (sibling repo context), under a new `backend`
profile. Wire inter-service and emulator env vars per service. Add a `secrets/` directory
with dummy local files for JWT/Stripe. Update `.env.example`, README, and CLAUDE.md tables.
Verify end-to-end.

---

## Phase 1: Per-Service Compose Blocks

### Overview
Add one Compose service per repo with a Dockerfile, each supporting both pull and build
modes and a distinct host port.

### Changes Required:

#### 1. `compose.yaml` — new services + `backend` profile
**File**: `compose.yaml`
**Changes**: Add 14 service blocks (api-gateway + 13 domain services). Each follows this
shape:

```yaml
  user-service:
    image: ${USER_SERVICE_IMAGE:-australia-southeast1-docker.pkg.dev/hiyar-staging/containers/user-service}:${USER_SERVICE_TAG:-latest-known-good}
    build:
      context: ../hiyar-user-service
    profiles: [backend, full]
    restart: unless-stopped
    ports:
      - "8081:8080"
    env_file:
      - .env
    environment:
      PORT: "8080"
      DATABASE_URL: ${USER_SERVICE_DSN}
      JWT_SIGNING_KEY_PATH: /secrets/jwt-signing-key.pem
      STRIPE_API_KEY_PATH: /secrets/stripe-api-key
      FIREBASE_AUTH_EMULATOR_HOST: firebase:9099
      REDIS_ADDR: redis:6379
      PUBSUB_EMULATOR_HOST: pubsub:8085
      PUBSUB_PROJECT_ID: hiyar-local
    volumes:
      - ./secrets:/secrets:ro
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started
```

(exact env vars per service determined by each service's `config.go` — api-gateway,
media-service, notification-service, ai-service each have a different subset; see Phase 2.)

Assign sequential host ports 8081–8094 (gateway gets 8080, colliding with nothing since no
existing service in this compose uses 8080) to avoid clashing with the existing port table.
Add `backend` to every relevant existing infra service's `profiles:` list (postgres, redis,
pubsub, firestore, gcs, temporal, temporal-ui, stripe-mock, firebase) so `--profile backend`
alone brings up everything needed, without requiring `full`.

Host port assignment (`payment-service` moved off `8085` to avoid clashing with the
existing Pub/Sub emulator port):

| Service | Host port |
|---|---|
| api-gateway | 8080 |
| user-service | 8081 |
| listing-service | 8082 |
| search-service | 8083 |
| booking-service | 8084 |
| handover-service | 8086 |
| review-service | 8087 |
| ai-service | 8088 |
| notification-service | 8089 |
| media-service | 8090 |
| payment-service | 8091 |
| messaging-service | 8092 |
| temporal-worker | (no exposed port — worker only) |
| outbox-relay | (no exposed port — background relay; run one `outbox-relay` container per service that has one in prod: user, booking, listing) |

`risk-service` and `admin-service` are not included (see "Key Discoveries" / "What We're
NOT Doing").

#### 2. `outbox-relay` sidecar instances
**File**: `compose.yaml`
**Changes**: Add three named services — `user-service-outbox`, `booking-service-outbox`,
`listing-service-outbox` — each built/pulled from the `outbox-relay` image, with
`OUTBOX_DB_SCHEMA` set to `users` / `bookings` / `listings` respectively and
`CLOUD_SQL_INSTANCE`-equivalent replaced by the local `DATABASE_URL`/DSN, matching the
per-service DSNs already in `.env.example`. No exposed ports (background workers).

### Success Criteria:

#### Automated Verification:
- [ ] `docker compose --profile backend config` validates without error
- [ ] `docker compose --profile backend pull` succeeds for all 14 services (after `gcloud auth configure-docker`)

#### Manual Verification:
- [ ] `docker compose --profile backend up -d` brings every new service to `running`/`healthy`
- [ ] `docker compose ps` shows no restart loops after 60s

---

## Phase 2: Environment Wiring (gateway routing, secrets, per-service vars)

### Overview
Wire api-gateway's 11 `*_SERVICE_URL` vars and each service's DSN/emulator/secret env vars
so the whole stack functions as one backend.

### Changes Required:

#### 1. `secrets/` directory with dummy local files
**File**: `secrets/jwt-signing-key.pem`, `secrets/stripe-api-key`, `secrets/stripe-webhook-secret`
**Changes**: Generate a throwaway RSA/EC PEM key for JWT signing (e.g.
`openssl genpkey -algorithm ed25519 -out secrets/jwt-signing-key.pem`) and plain text files
with placeholder values for the Stripe key/webhook secret (stripe-mock does not validate
key contents). Add `secrets/` to `.gitignore` alongside `.env`; commit a
`secrets/.gitkeep` and a generation note in the README instead of the generated files
themselves.

#### 2. `compose.yaml` — api-gateway environment
**File**: `compose.yaml`
**Changes**:
```yaml
  api-gateway:
    environment:
      PORT: "8080"
      USER_SERVICE_URL: http://user-service:8080
      LISTING_SERVICE_URL: http://listing-service:8080
      SEARCH_SERVICE_URL: http://search-service:8080
      BOOKING_SERVICE_URL: http://booking-service:8080
      PAYMENT_SERVICE_URL: http://payment-service:8080
      HANDOVER_SERVICE_URL: http://handover-service:8080
      REVIEW_SERVICE_URL: http://review-service:8080
      NOTIFICATION_SERVICE_URL: http://notification-service:8080
      MESSAGING_SERVICE_URL: http://messaging-service:8080
      MEDIA_SERVICE_URL: http://media-service:8080
      RISK_SERVICE_URL: http://user-service:8080  # placeholder: risk-service is excluded (Cloud SQL IAM blocker) — see Key Discoveries
      REDIS_ADDR: redis:6379
      TEMPORAL_HOST_PORT: temporal:7233
      MEDIA_BUCKET: hiyar-local-media
    depends_on:
      - user-service
      - listing-service
      - search-service
      - booking-service
      - payment-service
      - handover-service
      - review-service
      - notification-service
      - media-service
      - messaging-service
```

**Placeholder note**: `RISK_SERVICE_URL` is `mustEnv`-required by api-gateway, but
risk-service is excluded from this profile (Cloud SQL IAM blocker, see "Key Discoveries").
Point it at an already-running container (any valid `http://host:8080` satisfies startup);
calls that actually reach risk-scoped routes will fail at the RPC level, which is expected
and permanent until `hiyar-risk-service` supports a local DSN. Document this explicitly in
the README so it's not mistaken for a working integration. `MESSAGING_SERVICE_URL` now
points at the real messaging-service container — no placeholder needed.

#### 3. `compose.yaml` — messaging-service environment
**File**: `compose.yaml`
**Changes**:
```yaml
  messaging-service:
    environment:
      PORT: "8080"
      GCP_PROJECT_ID: hiyar-local
      FIRESTORE_DATABASE: messaging
      FIRESTORE_EMULATOR_HOST: firestore:8088
      EXPECTED_AUDIENCE: http://messaging-service:8080   # dummy — only used to validate inbound OIDC tokens, which don't exist locally; gateway-header path is unaffected
      MEDIA_BUCKET: hiyar-local-media
      MEDIA_SERVICE_URL: http://media-service:8080
      AI_SERVICE_URL: http://ai-service:8080
      MESSAGING_INTERNAL_CALLER_SA: temporal-worker-runtime@hiyar-local.iam.gserviceaccount.com  # dummy — internal RPCs from temporal-worker aren't reachable locally anyway (OIDC limitation)
      OTLP_ENDPOINT: http://otel-collector:4318
    depends_on:
      firestore:
        condition: service_healthy
      media-service:
        condition: service_started
      ai-service:
        condition: service_started
```

#### 3. `.env.example` — add missing DSNs and image/tag variables
**File**: `.env.example`
**Changes**: Add `NOTIFICATION_SERVICE_DSN` only if that service's config requires one
(confirmed not required — uses Firestore); add per-service `${SERVICE}_TAG` and
`${SERVICE}_IMAGE` override variables (empty by default, compose falls back to the
`latest-known-good` default and the Artifact Registry path), e.g.:
```
USER_SERVICE_TAG=
USER_SERVICE_IMAGE=
LISTING_SERVICE_TAG=
...
GATEWAY_PORT=8080
```

### Success Criteria:

#### Automated Verification:
- [ ] `docker compose --profile backend config` shows resolved env vars with no `<no value>` placeholders for required vars
- [ ] `docker compose --profile backend up -d && docker compose --profile backend logs api-gateway` shows no `mustEnv` panic on startup

#### Manual Verification:
- [ ] `curl` (or Buf Connect client) through `http://localhost:8080` reaches user-service and returns a real response (e.g. a health or listing-fetch RPC)
- [ ] JWT-signed request round-trips correctly using the dummy local signing key

---

## Phase 3: Documentation Updates

### Overview
Bring README.md, compose.yaml header comment, and CLAUDE.md's profile/port tables in line
with the new `backend` profile, per this repo's non-negotiable rule that port/profile
changes must be reflected in both files.

### Changes Required:

#### 1. `README.md`
**File**: `README.md`
**Changes**: Add `backend` row to the profile table; add new port rows (8080–8092) to the
port reference table; add a "Full backend for client testing" section documenting:
- prerequisite `gcloud auth login && gcloud auth configure-docker australia-southeast1-docker.pkg.dev` (+ Artifact Registry Reader on `hiyar-staging`)
- prerequisite: `git pull` each sibling `hiyar-{service}` checkout before using build mode — local checkouts can silently drift behind `origin/main` (discovered during this plan's research)
- `docker compose --profile backend up -d`
- how to switch one service to build mode: `docker compose --profile backend build <service> && docker compose --profile backend up -d <service>`
- the risk-service exclusion (Cloud SQL IAM blocker) and its `RISK_SERVICE_URL` placeholder
- the admin-service exclusion (stub only)
- the service-to-service OIDC auth limitation for gateway-bypassing calls (messaging↔media/ai deep checks, temporal-worker→messaging internal RPCs)

#### 2. `compose.yaml` header comment
**File**: `compose.yaml`
**Changes**: Add `docker compose --profile backend up -d` to the usage comment block at the top.

#### 3. `/Users/ronsteiner/Projects/hiyar/hiyar-dev-stack/CLAUDE.md`
**File**: `CLAUDE.md`
**Changes**: Add `backend` row to the profile table; add the new services' ports to the
port reference table, per the file's own "Non-negotiable rules" (port changes must update
`.env.example`, `README.md`, and the CLAUDE.md port table together).

### Success Criteria:

#### Automated Verification:
- [ ] `grep -c backend README.md CLAUDE.md compose.yaml` all non-zero

#### Manual Verification:
- [ ] Port tables in README.md and CLAUDE.md match compose.yaml exactly (manual diff read-through)

---

## Phase 4: End-to-End Verification

### Overview
Confirm the full stack boots, both build and pull modes work, and a real client request
traverses gateway → domain service.

### Changes Required:
None (verification only).

### Success Criteria:

#### Automated Verification:
- [ ] `docker compose --profile backend up -d` — all services `running`, healthchecked infra services `healthy`
- [ ] `docker compose --profile backend ps` shows zero restart loops after 2 minutes
- [ ] `docker compose --profile backend build user-service && docker compose --profile backend up -d user-service` succeeds and the container's image ID differs from the pulled one

#### Manual Verification:
- [ ] Point the Android app's `dev` flavor `DevHostGate` at `http://<host-ip>:8080` and complete a login (via Firebase Auth emulator) followed by at least one listing/booking read through api-gateway
- [ ] Send a chat message end-to-end through api-gateway → messaging-service (Firestore-backed) and confirm it persists and is readable
- [ ] Confirm risk-scoped RPCs fail cleanly (not a crash) given the `RISK_SERVICE_URL` placeholder — expected, not a regression
- [ ] Repeat the same flow with `user-service` running in build mode instead of pull mode — no behavior difference
- [ ] Tear down cleanly: `docker compose --profile backend down -v`

---

## Testing Strategy

### Automated:
- `docker compose config` validation after each phase
- `docker compose logs` grep for panics/fatal errors on startup

### Manual:
- End-to-end client flow (login → read → write) through api-gateway against real service code
- Build-mode vs. pull-mode parity check for at least one service

## Performance Considerations

Running all 14 services plus existing emulators concurrently is heavier than any existing
profile; document a rough RAM/CPU expectation in the README so developers know to use
`minimal`/`payment`/etc. for single-service work and reserve `backend`/`full` for
client-integration testing.

## Migration Notes

No data migration — this is a new profile touching no existing service definitions or
volumes.

## References

- `compose.yaml:1-236` — existing profiles and infra services
- `.env.example:1-59` — existing DSNs and emulator env vars
- `hiyar-api-gateway/internal/home/config.go:26-38` — required `*_SERVICE_URL` vars
- `hiyar-api-gateway/cmd/server/main.go:459-469` — JWKS `USER_SERVICE_URL` usage
- `hiyar-user-service/cmd/server/main.go:100-160` — secret-loading pattern (JWT, Stripe, KMS)
- `hiyar-user-service/internal/config/config.go:74` — `PORT` env convention
- `hiyar-messaging-service/internal/config/config.go:1-125` — required env vars, Firestore/media/AI wiring
- `hiyar-risk-service/internal/config/config.go:1-98` — Cloud SQL IAM-only config, no DSN path
- `hiyar-go-gcp@v0.2.7/cloudsql/cloudsql.go:42-47` — `cloudsqlconn.NewDialer(..., WithIAMAuthN())`, the risk-service blocker
- `hiyar-go-common@v0.5.2/auth/auth.go:1-113,302-351` — gateway-header vs. OIDC caller-identity paths
- `hiyar-admin-service/cmd/server/main.go:1-24` — stub-only implementation
- `hiyar-infra/terraform/environments/staging/containers.tf:1-4` — Artifact Registry repo definition
- `hiyar-infra/terraform/environments/staging/user-service/main.tf:5-6,111-137` — image path convention, secret volume mounts
- `readme/tech/architecture/ADR-013-gateway-intent-api.md:24,103` — gateway as sole client-facing endpoint
- `readme/tech/architecture/ADR-011-native-mobile-strategy.md:23,49` — Buf Connect client generation for mobile
- `hiyar-android-app/app/src/dev/java/com/hiyar/app/di/DevNetworkModule.kt`, `.../dev/DevHostGate.kt` — Android dev-flavor gateway host configuration
