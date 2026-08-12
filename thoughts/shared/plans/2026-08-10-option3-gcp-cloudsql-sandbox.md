---
date: 2026-08-10T15:13:09+10:00
researcher: Claude Opus 5
git_commit: 9258204de9d40db68b75058a62b699ab1c9b72a2
branch: claude/full-backend-compose
repository: hiyar-dev-stack
topic: "Option 3 — on-demand real GCP Cloud SQL sandbox instance for local backend testing"
tags: [plan, gcp, cloudsql, local-dev, sandbox]
status: complete
last_updated: 2026-08-10
last_updated_by: Claude Opus 5
---

# Option 3: On-Demand GCP Cloud SQL Sandbox Instance

## Overview

Instead of changing any service's code (Option 2), provision a real, throwaway Cloud SQL
instance in a dedicated GCP sandbox project on demand (`make cloudsql-up` /
`make cloudsql-down`), and point every SQL-backed service container at it via the existing
Cloud SQL IAM connector — no code changes anywhere. Local containers authenticate using the
developer's own `gcloud` Application Default Credentials (ADC), mounted read-only into each
container. This preserves every service's current code path exactly as it runs in
production; the only thing that changes is which Cloud SQL instance and IAM principal they
point at.

This plan lives entirely within `hiyar-dev-stack` (Makefile, compose wiring, docs) plus a
one-time manual GCP project setup step. No other repo is touched.

## Current State Analysis

### Key Discoveries

- **The Cloud SQL connector cannot target an arbitrary Postgres host:port** — confirmed via
  `hiyar-go-gcp@v0.2.7/cloudsql/cloudsql.go:42-47`
  (`cloudsqlconn.NewDialer(ctx, cloudsqlconn.WithIAMAuthN(), ...)`). It only dials real Cloud
  SQL instances via the Cloud SQL Admin API, which is why Option 2 (or this option) is
  needed at all — see `thoughts/shared/plans/2026-08-09-full-backend-compose.md` for the
  full discovery trail.
- **Cloud SQL IAM auth ties the Postgres role name to the exact authenticating IAM
  principal.** For a user account (as opposed to a service account), the database username
  Cloud SQL expects is the full email address; for a service account it's the SA email minus
  `.gserviceaccount.com` (this second convention is documented directly in
  `hiyar-risk-service/internal/config/config.go:34-35`). Authenticating via a developer's own
  `gcloud auth application-default login` means every service that connects locally
  authenticates as that same person — **per-service schema isolation (the
  `user_svc`/`listing_svc`/... role-per-service pattern `hiyar-dev-stack/seed/00-init.sh`
  already implements for the local Postgres container) cannot be replicated 1:1** without
  juggling distinct impersonated credentials per container. Per the user's explicit call
  (2026-08-09 clarification), this plan uses **one shared local-dev IAM database user (the
  developer's own Google account) for all services**, granted access across all per-service
  schemas/databases in the sandbox instance. This is a deliberate, documented departure from
  prod's isolation model — acceptable for local client testing, not for anything
  resembling a shared/multi-developer environment.
- **`cloudsqlconn.NewDialer` picks up Application Default Credentials automatically** — no
  application code needs to reference `GOOGLE_APPLICATION_CREDENTIALS` explicitly; the
  Google Cloud Go SDK's standard credential-resolution chain finds it. Mounting the ADC JSON
  file into each container and setting the env var is suffient; no code changes anywhere.
- **Per-service `DB_NAME` defaults differ** (`listings`, `risk`, `hiyar`, etc. — see the
  Option 2 plan's "Key Discoveries" for the full list) — the sandbox instance needs one
  `CREATE DATABASE` per distinct name actually required, not a single shared database.
- **Instance creation is slow and not free**: a `db-f1-micro` Cloud SQL Postgres instance
  takes several minutes to provision via `gcloud sql instances create` and bills hourly
  while running — "on demand" here means an explicit, deliberate `make cloudsql-up` /
  `make cloudsql-down` pair, not something wired into `docker compose up` implicitly.
- **Project choice**: per the user's explicit decision (2026-08-09), this uses a **dedicated
  new GCP sandbox project**, isolated from `hiyar-staging`'s billing and IAM surface. Project
  creation itself (linking a billing account, enabling the Cloud SQL Admin API) is a one-time
  manual step outside this plan's automation — Terraform/`gcloud` for project creation
  touches billing account IDs and org-level IAM that are the user's call, not something to
  automate blindly.

## Desired End State

Running `make cloudsql-up` creates a Cloud SQL Postgres instance in the sandbox project,
creates one database per service that needs one, creates the shared local-dev IAM database
user, and grants it access. Running `docker compose --profile backend up -d` (after this)
starts every SQL-backed service pointed at that instance via `CLOUD_SQL_INSTANCE`/`DB_USER`/
`DB_NAME`, with ADC mounted into each container, and each connects successfully — no code
changes in any service repo. `make cloudsql-down` deletes the instance to stop billing.

### Verification
- `make cloudsql-up` completes and prints the instance connection name.
- `docker compose --profile backend up -d` — every SQL-backed service reaches
  `running`/`healthy` and its logs show a successful Cloud SQL IAM connection (not a
  connection-refused or auth error).
- `make cloudsql-down` deletes the instance; a subsequent `gcloud sql instances list`
  confirms it's gone.

## What We're NOT Doing

- Not automating GCP sandbox *project* creation (billing account linkage, initial API
  enablement) — one-time manual setup, documented as a prerequisite.
- Not attempting per-service credential isolation locally — one shared IAM DB user for all
  services, explicitly and permanently (for this sandbox use case).
- Not changing any service's code — this is the whole point of choosing this option over
  Option 2.
- Not making the sandbox instance highly available, backed up, or long-lived — it's
  ephemeral, zonal, minimum tier, recreated per testing session.
- Not wiring `cloudsql-up`/`down` into any CI pipeline — manual/local only.

## Implementation Approach

### Phase 1: One-time GCP sandbox project setup (manual, documented)
- Create the dedicated sandbox GCP project (via GCP Console or `gcloud projects create`),
  link a billing account, enable the Cloud SQL Admin API
  (`gcloud services enable sqladmin.googleapis.com`).
- Grant the developer's own account `roles/cloudsql.admin` on the project (already confirmed
  available per the user's 2026-08-09 answer).
- Document these steps in `README.md` as a one-time prerequisite, analogous to the existing
  Artifact Registry `gcloud auth configure-docker` prerequisite.

### Phase 2: Makefile automation
- `make cloudsql-up`: wraps
  - `gcloud sql instances create $(CLOUDSQL_INSTANCE_NAME) --project=$(GCP_SANDBOX_PROJECT_ID) --region=$(GCP_SANDBOX_REGION) --database-version=POSTGRES_18 --tier=db-f1-micro --availability-type=zonal --no-backup`
  - `gcloud sql databases create <name>` for each distinct per-service `DB_NAME` value
    (`users`, `listings`, `search` or equivalent, `bookings`, `payments`, `handovers`,
    `reviews`, `risk` — exact list confirmed against each service's actual default during
    implementation).
  - `gcloud sql users create $(LOCAL_DEV_IAM_USER_EMAIL) --instance=... --type=cloud_iam_user`
  - A `psql`/Cloud SQL Auth Proxy step granting the shared IAM user `CONNECT`/schema
    privileges on each database.
  - Prints the instance connection name (`project:region:instance`) for use in `.env`.
- `make cloudsql-down`: `gcloud sql instances delete $(CLOUDSQL_INSTANCE_NAME) --quiet`.
- New `.env.example` vars: `GCP_SANDBOX_PROJECT_ID`, `GCP_SANDBOX_REGION`,
  `CLOUDSQL_INSTANCE_NAME`, `LOCAL_DEV_IAM_USER_EMAIL`.

### Phase 3: Compose wiring
- Each SQL-backed service's compose block sets:
  ```yaml
  environment:
    CLOUD_SQL_INSTANCE: ${GCP_SANDBOX_PROJECT_ID}:${GCP_SANDBOX_REGION}:${CLOUDSQL_INSTANCE_NAME}
    DB_USER: ${LOCAL_DEV_IAM_USER_EMAIL}
    DB_NAME: <service-specific value, matching each service's own default>
    GOOGLE_APPLICATION_CREDENTIALS: /gcp/adc.json
  volumes:
    - ${HOME}/.config/gcloud/application_default_credentials.json:/gcp/adc.json:ro
  ```
- Document the one-time host step `gcloud auth application-default login` in the README
  alongside the Artifact Registry auth prerequisite.

### Phase 4: Documentation + verification
- README section: sandbox project setup, `make cloudsql-up`/`down`, cost/time expectations
  (instance creation ~5-10 min, hourly billing while running, always run `cloudsql-down`
  when done), and the shared-IAM-user isolation caveat.
- End-to-end: bring up the sandbox, bring up `--profile backend`, confirm each SQL-backed
  service connects (log line, not a crash loop), tear both down.

### Success Criteria

#### Automated Verification:
- [ ] `make cloudsql-up` exits 0 and prints a connection name matching
  `<project>:<region>:<instance>`
- [ ] `docker compose --profile backend config` resolves `CLOUD_SQL_INSTANCE`/`DB_USER` with
  no empty values
- [ ] `make cloudsql-down` exits 0; `gcloud sql instances list --project=$(GCP_SANDBOX_PROJECT_ID)`
  shows no instances afterward

#### Manual Verification:
- [ ] Each SQL-backed service's container logs show a successful Cloud SQL connection
- [ ] A write from one service (e.g. creating a listing) is visible via `psql` against the
  sandbox instance directly
- [ ] Cost is bounded — instance torn down at the end of every session, confirmed via GCP
  Console billing view once

## Testing Strategy

### Automated:
- `make cloudsql-up`/`down` idempotency (re-running `up` twice doesn't error if the instance
  already exists; `down` on a non-existent instance doesn't error the whole target)

### Manual:
- Full session: `cloudsql-up` → `docker compose --profile backend up -d` → exercise a real
  client flow → `docker compose --profile backend down -v` → `cloudsql-down` → confirm no
  lingering billed resources

## References

- `hiyar-go-gcp@v0.2.7/cloudsql/cloudsql.go:42-47` — the IAM-only connector this plan targets
  unchanged, using a real instance instead of a plain container.
- `hiyar-risk-service/internal/config/config.go:34-35` — IAM DB username convention comment.
- `hiyar-dev-stack/seed/00-init.sh` — existing per-service schema/role pattern this plan
  deliberately does not replicate (shared IAM user instead).
- `thoughts/shared/plans/2026-08-09-full-backend-compose.md` — the original compose plan;
  its Phase 1/2 would be revised to use this instance instead of a local DSN, if this option
  is chosen over Option 2.
- `thoughts/shared/plans/2026-08-10-option2-database-url-fallback.md` — the alternative
  (code-change) approach being compared against this one.
