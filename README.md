# hiyar-dev-stack

Docker Compose stack for Hiyar local development. Starts emulators and stubs for all GCP backing services and third-party providers used by Hiyar backend services.

> **Integration tests in CI do not need this stack.** CI integration tests use [hiyar-go-testutils](https://github.com/Hiyar-Ltd/hiyar-go-testutils) which starts ephemeral testcontainers automatically.
> This Compose stack is for **local development** — running services end-to-end on your laptop.

---

## Prerequisites

- Docker Desktop (or Docker Engine + Compose plugin)
- `docker compose version` ≥ 2.20 (profiles support)

---

## Quick start

```bash
git clone git@github.com:Hiyar-Ltd/hiyar-dev-stack.git
cd hiyar-dev-stack
cp .env.example .env   # includes COMPOSE_PROFILES=full

# Start everything (default — no --profile flag needed after cp .env.example .env)
docker compose up -d

# Verify everything is healthy
docker compose ps
```

To override for a single run without editing `.env`:

```bash
docker compose --profile minimal up -d
```

---

## Profiles

Each profile starts the subset of services needed for a given domain area. Always start the profile for the service you're developing, not `full` (unless you need everything).

| Profile | Use when developing | Services |
|---|---|---|
| `minimal` | user-service, listing-service, search-service, booking-service, review-service, risk-service | postgres, redis |
| `notification` | notification-service, messaging-service | + pubsub, firestore, firebase |
| `payment` | payment-service, handover-service, temporal-worker | + stripe-mock, temporal, temporal-ui |
| `gcs` | media-service | + gcs (fake-gcs-server) |
| `gateway` | api-gateway | + firebase |
| `observability` | any service (adds trace UI) | otel-collector, jaeger |
| `backend` | client (mobile/web) testing against a full backend | api-gateway + all 15 domain services (see "Full backend for client testing" below) |
| `full` | integration end-to-end | all of the above, **including `backend`** |

> **Note**: `.env.example` sets `COMPOSE_PROFILES=full` by default, so a plain `docker compose up -d`
> now also starts the entire Go backend (16 additional containers). Use `--profile minimal` (or
> whichever profile matches what you're working on) for a lighter footprint — see "Performance"
> below.

```bash
# Single profile
docker compose --profile minimal up -d

# Multiple profiles
docker compose --profile notification --profile observability up -d

# Tear down (removes containers + named volumes)
docker compose down -v
```

---

## Port reference

| Service | Port | UI / Notes |
|---|---|---|
| PostgreSQL | `5432` | `psql -U hiyar -h localhost hiyar` |
| Redis | `6379` | `redis-cli -h localhost` |
| Cloud Pub/Sub emulator | `8085` | Set `PUBSUB_EMULATOR_HOST=localhost:8085` |
| Cloud Firestore emulator | `8088` | Set `FIRESTORE_EMULATOR_HOST=localhost:8088` |
| Cloud Storage (fake-gcs-server) | `4443` | Set `STORAGE_EMULATOR_HOST=http://localhost:4443` |
| Firebase Auth emulator | `9099` | Set `FIREBASE_AUTH_EMULATOR_HOST=localhost:9099` |
| Stripe Mock | `12111` | Set `STRIPE_BASE_URL=http://localhost:12111` |
| Temporal | `7233` | gRPC — `TEMPORAL_ADDRESS=localhost:7233` |
| Temporal UI | `8233` | [http://localhost:8233](http://localhost:8233) |
| OTel Collector (gRPC) | `4317` | `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317` |
| OTel Collector (HTTP) | `4318` | |
| Jaeger UI | `16686` | [http://localhost:16686](http://localhost:16686) |
| api-gateway | `8080` | Client entry point — point your mobile/web app here |
| user-service | `8081` | |
| listing-service | `8082` | |
| search-service | `8083` | |
| booking-service | `8084` | |
| handover-service | `8086` | |
| review-service | `8087` | |
| notification-service | `8089` | |
| media-service | `8090` | |
| payment-service | `8091` | |
| messaging-service | `8092` | |
| risk-service | `8093` | |
| ai-service | `8094` | |

`temporal-worker` and the `outbox-relay` sidecars have no published port (background workers).

---

## Full backend for client testing

The `backend` profile runs api-gateway plus all 15 domain services with a working
Dockerfile, so a mobile (Android/iOS) or web client can point at
`http://<host-ip>:8080` and exercise a complete backend end-to-end, instead of running
one service at a time against emulators.

### Prerequisites

1. **Artifact Registry pull auth** (one-time per machine, for pull mode):
   ```bash
   gcloud auth login
   gcloud auth configure-docker australia-southeast1-docker.pkg.dev
   ```
   You need `Artifact Registry Reader` on the `hiyar-staging` project.

2. **Sibling checkouts up to date** (for build mode): each service builds from
   `../hiyar-{service}` relative to this repo. Local checkouts can silently drift
   behind `origin/main` — `git pull` each one before relying on it for build mode.

3. **Current blocker — `DATABASE_URL`/`HIYAR_ENV=local` support is not yet merged.**
   All 8 SQL-backed services (user, listing, search, booking, payment, handover, review,
   risk) plus `outbox-relay` need `hiyar-go-common`'s `dbconn` fallback
   (see `thoughts/shared/plans/2026-08-10-option2-database-url-fallback.md`) to boot against
   this stack's plain Postgres container instead of requiring a real Cloud SQL IAM
   connector. As of this writing, `hiyar-go-common`'s `dbconn` package is tagged
   (`v0.5.3`), but all 9 adopter PRs are open and unmerged:
   - https://github.com/Hiyar-Ltd/hiyar-user-service/pull/45
   - https://github.com/Hiyar-Ltd/hiyar-listing-service/pull/46
   - https://github.com/Hiyar-Ltd/hiyar-search-service/pull/16
   - https://github.com/Hiyar-Ltd/hiyar-booking-service/pull/53
   - https://github.com/Hiyar-Ltd/hiyar-payment-service/pull/54
   - https://github.com/Hiyar-Ltd/hiyar-handover-service/pull/15
   - https://github.com/Hiyar-Ltd/hiyar-review-service/pull/11
   - https://github.com/Hiyar-Ltd/hiyar-risk-service/pull/11
   - `hiyar-outbox-relay` — issue filed (https://github.com/Hiyar-Ltd/hiyar-outbox-relay/issues/18), PR not yet opened

   Until these merge, `--profile backend` will crash-loop those 9 services (pull-mode
   images are built from merged `main`, which doesn't have the fallback; build-mode only
   works if you manually check out the specific PR branch instead of `main`).

4. **Local secrets**: `secrets/jwt-signing-key.pem` (RSA PEM, `hiyar-user-service`'s
   `internal/auth.LoadSigningKeyFromPEM` requires RSA, not EC/ed25519) and
   `secrets/stripe-api-key` / `secrets/stripe-webhook-secret` (plain text, stripe-mock
   doesn't validate contents) already exist in this repo's `secrets/` directory
   (gitignored except `.gitkeep` — regenerate with
   `openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out secrets/jwt-signing-key.pem`
   if missing).

### Usage

```bash
docker compose --profile backend up -d
docker compose --profile backend ps   # confirm healthy/running
```

Switch one service to build mode instead of pulling:
```bash
docker compose --profile backend build user-service
docker compose --profile backend up -d user-service
```

Pin a specific pulled tag instead of the compose-file default, in `.env`:
```
USER_SERVICE_TAG=abc1234
```

### Known limitations (not bugs — read before filing an issue)

- **`admin-service` is excluded** — current code is a bare `/healthz` stub with no business
  logic, and api-gateway has no route to it anyway.
- **`payment-service`'s Stripe integration is not testable locally** — this repo's
  `stripe-go` client always targets the real Stripe API (no base-URL override exists to
  redirect it at `stripe-mock`). `STRIPE_SECRET_KEY_RESOURCE`/`STRIPE_WEBHOOK_SECRET_RESOURCE`
  are left unset so the service boots with payment routes cleanly disabled, rather than
  failing against `api.stripe.com`.
- **`ai-service` needs a real Gemini API key** — no local emulator exists for Gemini. Set
  `GEMINI_API_KEY` in `.env` to exercise real classification/moderation; leave it empty to
  boot the service without a working AI client.
- **`temporal-worker`'s downstream service calls don't work locally** — it mints a real
  Google-signed OIDC token for every configured `*_SERVICE_URL` and fails fast at startup
  if ADC/the metadata server is unavailable (neither exists in local Docker). All its
  `*_SERVICE_URL` vars are left empty in compose, so the worker boots and registers
  workflows/activities, but any workflow that actually calls a downstream service fails
  when that activity runs.
- **Service-to-service calls that bypass api-gateway require a real OIDC token, which
  can't be minted locally.** This affects: messaging-service's calls to media-service
  (deep media-ownership check) and ai-service (contact-info screening); risk-service's
  calls to listing/ai/media-service; and temporal-worker's internal calls into
  messaging-service. **Client flows routed through api-gateway are unaffected** — they
  use a trusted-header path, not OIDC (e.g. login → browse listings → view booking → send
  a chat message all work normally).
- **`notification-service`'s FCM/email clients may not tolerate empty credentials** —
  `FCM_CREDENTIALS_JSON` is left unset (no local Firebase Admin SDK JSON exists) and
  `EMAIL_PROVIDER_API_KEY` uses the same Postmark sandbox token as elsewhere in this repo;
  neither path has been verified end-to-end.

---

## Environment variables

Copy `.env.example` to `.env`:

```bash
cp .env.example .env
```

The `.env` file is gitignored. Source it before running a service locally:

```bash
export $(grep -v '^#' .env | xargs)
```

Or use `direnv` with an `.envrc` that sources `.env`.

---

## Per-service quick start

### user-service / listing-service / search-service / booking-service

```bash
docker compose --profile minimal up -d
export $(grep -v '^#' .env | xargs)
cd ~/Projects/Hiyar/hiyar-user-service
go run ./cmd/server
```

### notification-service

```bash
docker compose --profile notification up -d
export $(grep -v '^#' .env | xargs)
cd ~/Projects/Hiyar/hiyar-notification-service
go run ./cmd/server
```

### payment-service / handover-service / temporal-worker

```bash
docker compose --profile payment up -d
export $(grep -v '^#' .env | xargs)
cd ~/Projects/Hiyar/hiyar-payment-service
go run ./cmd/server
```

### api-gateway

```bash
docker compose --profile gateway up -d
export $(grep -v '^#' .env | xargs)
cd ~/Projects/Hiyar/hiyar-api-gateway
go run ./cmd/server
```

### media-service

```bash
docker compose --profile gcs up -d
export $(grep -v '^#' .env | xargs)
cd ~/Projects/Hiyar/hiyar-media-service
go run ./cmd/server
```

### With distributed tracing

```bash
docker compose --profile minimal --profile observability up -d
# Jaeger UI: http://localhost:16686
```

---

## PostgreSQL schemas and roles

The `seed/00-init.sh` script runs automatically on first container start. It creates:

- One PostgreSQL schema per service (`users`, `listings`, `search`, `bookings`, `payments`, `handovers`, `reviews`, `risk`, `ai`)
- One role per service with access restricted to its own schema (mirrors production Cloud SQL IAM)
- `admin_svc` role with read-only access to all schemas

Per-service DSNs are in `.env.example`. Those DSNs use `localhost` and are meant for
**host-side** use (`export $(grep -v '^#' .env | xargs)` then `go run ./cmd/server`
directly on your machine, reaching Postgres via its published port). The `backend`
profile's compose services connect to the **same** roles/schemas but use the `postgres`
Compose service name as host instead, with an explicit `search_path` query parameter
(e.g. `postgres://user_svc:user_svc@postgres:5432/hiyar?sslmode=disable&search_path=users`)
since all services share one `hiyar` database with one schema each, not a separate
database per service.

Service migrations run against the per-service DSN. The `hiyar` superuser DSN is for emergency access only.

---

## Postmark (email)

No local stub is needed. Use Postmark's sandbox API key (`POSTMARK_API_TEST`) — it accepts all emails and routes them to your Postmark dashboard sandbox inbox without delivering to real recipients.

```
POSTMARK_SERVER_TOKEN=POSTMARK_API_TEST
```

---

## Integration tests

Integration tests **do not use this Compose stack**. They use [hiyar-go-testutils](https://github.com/Hiyar-Ltd/hiyar-go-testutils) which starts isolated containers per test via testcontainers-go.

```bash
# Run integration tests in any service repo
make test-integration
# = go test -tags=integration -timeout=5m ./...
```

See `readme/tech/engineering/integration-testing.md` for the full guide.

---

## Performance

Running `--profile backend` or `--profile full` starts ~25 containers (9 infra + 16 Go
services/workers). This is heavier than any single-purpose profile — prefer `minimal`,
`notification`, `payment`, etc. for single-service development, and reserve
`backend`/`full` for client-integration testing sessions.

---

## Troubleshooting

**Port already in use:**
```bash
docker compose down  # stop any running stack first
lsof -i :5432        # find what's using the port
```

**Postgres data inconsistent after schema changes:**
```bash
docker compose down -v  # wipe volumes
docker compose --profile minimal up -d  # fresh start; seed re-runs
```

**Pub/Sub emulator not ready:**
The emulator takes ~10s to start. Wait for the healthcheck to pass:
```bash
docker compose ps  # check "healthy" status
```

**Temporal not starting:**
`temporalio/auto-setup` runs schema migrations against postgres on first start — allow ~30s. The temporal-ui service waits for the healthcheck automatically.
