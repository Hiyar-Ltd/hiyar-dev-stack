# CLAUDE.md — hiyar-dev-stack

## What this repo is

Docker Compose stack for Hiyar local development and CI integration tests.
Starts emulators and stubs for all backing services used by Hiyar backend Go services.

This repo contains no application code. It is an operations/infrastructure artifact.

---

## Profiles

Start only what a given service needs:

| Profile | Services started |
|---|---|
| `minimal` | postgres, redis |
| `notification` | postgres, redis, pubsub, firestore, firebase |
| `payment` | postgres, redis, stripe-mock, temporal, temporal-ui |
| `gcs` | postgres, redis, gcs |
| `gateway` | postgres, redis, firebase |
| `observability` | otel-collector, jaeger |
| `full` | everything |

```bash
docker compose --profile minimal up -d
docker compose --profile full up -d
docker compose down -v   # tear down + delete volumes
```

---

## Port reference

| Service | Port | Protocol |
|---|---|---|
| PostgreSQL | 5432 | TCP |
| Redis | 6379 | TCP |
| Cloud Pub/Sub emulator | 8085 | HTTP |
| Cloud Firestore emulator | 8088 | HTTP |
| Cloud Storage (fake-gcs-server) | 4443 | HTTP |
| Firebase Auth emulator | 9099 | HTTP |
| Stripe Mock | 12111 | HTTP |
| Temporal | 7233 | gRPC |
| Temporal UI | 8233 | HTTP |
| OTel Collector (gRPC) | 4317 | gRPC |
| OTel Collector (HTTP) | 4318 | HTTP |
| Jaeger UI | 16686 | HTTP |

---

## Environment wiring

Copy `.env.example` to `.env` and adjust if needed. Service code reads env vars at startup.
For integration tests, use `hiyar-go-testutils` helpers — they start their own ephemeral containers
via testcontainers-go, so you do **not** need this Compose stack running for CI integration tests.

---

## Non-negotiable rules

- Do not add application code here.
- Do not change ports without updating `.env.example`, `README.md`, and the port table in CLAUDE.md.
- Do not add a service that is not already used by a Hiyar backend service in production.
- Image versions: pin major.minor where possible. Update in a PR, not inline.
- The seed scripts in `seed/` mirror production IAM: one role per service, access restricted to own schema.
  Keep them in sync with any schema additions.

---

## Adding a new service

1. Add the container to `compose.yaml` with a named profile
2. Add the port to the port tables in this file and `README.md`
3. Add env vars to `.env.example`
4. Update `seed/00-init.sh` if a new PostgreSQL schema/role is needed
5. Update the profile table in this file and `README.md`
