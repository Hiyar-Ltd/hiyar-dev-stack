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
cp .env.example .env

# Start the services your repo needs (see profile table below)
docker compose --profile minimal up -d

# Verify everything is healthy
docker compose ps
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
| `full` | integration end-to-end | all of the above |

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

Per-service DSNs are in `.env.example`.

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
`temporalio/auto-setup:1.24` with `DB=sqlite` requires ~20s. The temporal-ui service waits for the healthcheck automatically.
