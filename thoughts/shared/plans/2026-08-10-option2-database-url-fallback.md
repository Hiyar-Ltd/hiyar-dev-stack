---
date: 2026-08-10T15:13:09+10:00
researcher: Claude Opus 5
git_commit: 9258204de9d40db68b75058a62b699ab1c9b72a2
branch: claude/full-backend-compose
repository: hiyar-dev-stack (cross-repo: hiyar-go-common + 8 SQL-backed services)
topic: "Option 2 — DATABASE_URL fallback for local Postgres, shared via hiyar-go-common"
tags: [plan, cross-repo, database, cloudsql, local-dev, hiyar-go-common]
status: complete
last_updated: 2026-08-10
last_updated_by: Claude Sonnet 5
last_updated_note: "hiyar-go-common#7 shipped and merged as PR #8 (dbconn package). Corrected this doc's precedence rule to match what actually landed: EngLeadBot's review addendum changed 'DATABASE_URL wins if both set' to 'fatal if both set' (fail loudly rather than silently prefer a plaintext DSN over IAM if DATABASE_URL ever leaks into a real environment). Also recorded the known cmd/migrate gap (out of scope for the 8 adoption issues, needs a follow-up) and confirmed ai-service/admin-service have no Postgres dependency (EngLeadBot's flag on this was a false alarm)."
---

# Option 2: `DATABASE_URL` Fallback for Local Postgres (Cross-Repo)

## Overview

Every SQL-backed Hiyar service currently connects to Postgres exclusively through
`hiyar-go-gcp/cloudsql.NewPool`, which always dials via the real Cloud SQL IAM connector
(`cloudsqlconn.NewDialer(..., WithIAMAuthN())`). This cannot target an arbitrary
host:port Postgres container, so none of these services can boot against
`hiyar-dev-stack`'s local `postgres` container as currently coded. This plan adds a small,
shared, consistently-adopted fallback, now implemented in `hiyar-go-common`'s new `dbconn`
package (`hiyar-go-common` PR #8, merged, closes issue #7):

1. **Fatal** if `DATABASE_URL` and `CLOUD_SQL_INSTANCE` are both set, regardless of
   `HIYAR_ENV` — never a silent precedence rule. If `DATABASE_URL` ever leaks into a real
   Cloud Run revision, the service must fail loudly rather than silently swap the
   passwordless/IAM connection for a plaintext DSN.
2. `DATABASE_URL` set **and** `HIYAR_ENV=local`, and `CLOUD_SQL_INSTANCE` unset → plain pgx
   DSN via `pgxpool.New`, logged at **WARN** (deliberately not INFO, so an unexpected
   passwordless connection is easy to spot in Cloud Logging if it ever happens somewhere
   unexpected).
3. `CLOUD_SQL_INSTANCE`+`DB_USER`+`DB_NAME` all set (no `DATABASE_URL`) → Cloud SQL IAM
   connector, unchanged production behavior, logged at **INFO**.
4. **Fatal** otherwise — including `DATABASE_URL` set without `HIYAR_ENV=local`. The opt-in
   gate is real, not decorative: that combination falls through to this branch rather than
   silently connecting. The error names both `DATABASE_URL` (with the `HIYAR_ENV=local`
   requirement) and `CLOUD_SQL_INSTANCE` explicitly.

`HIYAR_ENV=local` is an explicit, additional gate on top of `DATABASE_URL` — Hiyar's
Terraform never sets `HIYAR_ENV` (or sets it to something other than `local`) in any
deployed environment, so `DATABASE_URL` being present alone can never flip a real Cloud Run
service onto the local-DSN path, even by accident (e.g. a leaked/stale env var) — and if it
somehow did coincide with a leaked `CLOUD_SQL_INSTANCE`-shaped config, rule 1 fails the
service rather than guessing. This decision and its logging live in one place
(`hiyar-go-common`'s `dbconn` package) so all 8 services adopt identical behavior instead of
8 divergent implementations.

This plan spans 10 repositories: `hiyar-go-common` (the shared mechanism) and 9 SQL-backed
repos that adopt it (`hiyar-user-service`, `hiyar-listing-service`, `hiyar-search-service`,
`hiyar-booking-service`, `hiyar-payment-service`, `hiyar-handover-service`,
`hiyar-review-service`, `hiyar-risk-service`, and `hiyar-outbox-relay` — the last discovered
and filed as a follow-up (issue #18) after the original 8 were scoped; it has the identical
`cloudsql.NewPool`-only blocker and was simply missed in the first pass). It is scoped and
tracked via the 10 GitHub issues listed in "References" below; this document is the shared
design context all 10 issues point back to.

## Current State Analysis

### Key Discoveries

- **Every SQL-backed service's `cmd/server` binary opens its DB pool through
  `cloudsql.NewPool` exclusively** — confirmed by reading each service's `internal/db/db.go`
  (or equivalent) and `internal/config/config.go`:
  - `hiyar-user-service/internal/db/db.go:27-38` — `db.Open()` calls
    `cloudsql.NewPool(ctx, cloudsql.Config{Instance, User, DBName}, nil)`. No DSN path.
  - Config loaders read `CLOUD_SQL_INSTANCE` / `DB_USER` / `DB_NAME` as **required**
    (`env.MustGet`) in `hiyar-user-service`, `hiyar-search-service`, `hiyar-payment-service`,
    `hiyar-handover-service`, `hiyar-review-service`, `hiyar-risk-service`
    (`getEnvDefault`, effectively required in practice) — and as optional-but-unused-without-DSN
    in `hiyar-listing-service` (`env.GetOr("CLOUD_SQL_INSTANCE", "")`) and
    `hiyar-booking-service` (`envOrDefault("DB_NAME", "hiyar")`).
  - A `NewTestPool(pool *pgxpool.Pool)` helper exists in `hiyar-user-service/internal/db/db.go:43-45`
    but is only used by test code that builds its own DSN-based pool directly — the compiled
    server binary never takes that path.
- **`hiyar-go-gcp/cloudsql.NewPool`** (`hiyar-go-gcp@v0.2.7/cloudsql/cloudsql.go:93-119`) is
  the single shared implementation of the IAM-only path — the mechanism this plan
  supplements, not replaces.
- **Implemented as recommended, confirmed via the merged PR**: `dbconn.Open` takes the
  Cloud-SQL dial step as an injected `CloudSQLDialer func(ctx, instance, user, dbName string) (*pgxpool.Config, io.Closer, error)`
  rather than importing `hiyar-go-gcp` directly — each adopter service passes a one-line
  closure around `cloudsql.NewConfig`. The PR verified via `go list -deps ./...` that no
  `cloud.google.com/go/*` package is compiled into `hiyar-go-common`, preserving the
  dep-hygiene principle in `auth/auth.go:98-104`. The logger is also injected (a `*zap.Logger`
  parameter, matching `otel.Init`'s existing DI shape) rather than constructed internally,
  since this repo's `CLAUDE.md` forbids one package importing another within the module
  (`dbconn` cannot import `hiyar-go-common/logging`).
- **`hiyar-dev-stack`'s `.env.example` already has unused per-service DSN vars**
  (`USER_SERVICE_DSN`, `LISTING_SERVICE_DSN`, etc.) — once this mechanism lands, those
  become the actual `DATABASE_URL` values passed to each service container, finally used by
  the compiled binaries rather than sitting unused.
- **Per-service `DB_NAME` defaults are inconsistent between "database" and "schema"
  framing**: `hiyar-listing-service` defaults to `"listings"`, `hiyar-risk-service` to
  `"risk"`, `hiyar-booking-service` to `"hiyar"` (shared DB name, presumably schema-scoped).
  This plan does not change per-service `DB_NAME` semantics — whatever a service already
  treats as its database/schema name continues to apply; `DATABASE_URL` for local dev should
  point at this repo's single `hiyar` database (matching `hiyar-dev-stack`'s existing
  schema-per-service Postgres layout in `seed/00-init.sh`), with the per-service schema
  reached via the DSN's `search_path` or the service's own schema-qualification — this needs
  per-service verification during implementation, called out in each service's issue.

## Desired End State

Each of the 8 SQL-backed services' `cmd/server` binary, when given both `HIYAR_ENV=local`
and a `DATABASE_URL` env var pointing at a plain Postgres connection string (and
`CLOUD_SQL_INSTANCE` left unset), connects successfully without touching Cloud SQL / IAM at
all, and logs a single WARN-level line identifying the DSN path was taken. When `HIYAR_ENV`
is not `local` (including when it's unset, as in every real deployment today),
`DATABASE_URL` is ignored and behavior is unchanged from today (Cloud SQL IAM connector,
requiring `CLOUD_SQL_INSTANCE`/`DB_USER`/`DB_NAME`, logged at INFO). If both `DATABASE_URL`
and `CLOUD_SQL_INSTANCE` are set at the same time — any `HIYAR_ENV` value — the service
fails fast at startup with an error naming both variables, rather than picking one
silently. If neither path is satisfied, the service also fails fast with the same
dual-variable error message.

**Known gap, not yet closed**: `cmd/migrate` in each adopter service still requires
`CLOUD_SQL_INSTANCE` unconditionally — the same `DATABASE_URL`/`HIYAR_ENV=local` fallback
has not been extended to migration tooling. This means an adopter service's application
server can start locally via `dbconn`, but running that service's migrations against the
same local database cannot yet use this mechanism. A follow-up issue per adopter repo is
needed before `hiyar-dev-stack` can run migrations end-to-end locally — tracked as a gap for
now, not yet filed.

### Verification
- `go test ./...` passes in `hiyar-go-common` (confirmed — PR #8 merged, 9 test cases, all
  green) and all 8 service repos after adoption.
- Each service repo's existing integration tests (which already construct a DSN-based pool
  via `hiyar-go-testutils`) continue to pass unchanged — this plan does not touch test code
  paths, only the production `cmd/server` path.
- Manually: running any one service locally with `HIYAR_ENV=local` and `DATABASE_URL` set
  (no `CLOUD_SQL_INSTANCE`) against `hiyar-dev-stack`'s `postgres` container succeeds and the
  startup log names the DSN path at WARN.
- Manually: setting `DATABASE_URL` **without** `HIYAR_ENV=local` does not take the DSN path
  — confirms the gate actually gates.
- Manually: setting **both** `DATABASE_URL` and `CLOUD_SQL_INSTANCE` (any `HIYAR_ENV`)
  produces the fatal dual-variable error, not a silently-chosen path.
- Manually: unsetting `DATABASE_URL`/`HIYAR_ENV` and `CLOUD_SQL_INSTANCE` both produces the
  same clear fatal message (not a generic nil-pointer or timeout).

## What We're NOT Doing

- Not changing the Cloud Run / Terraform deployment path — production continues to set only
  `CLOUD_SQL_INSTANCE`/`DB_USER`/`DB_NAME`, never `DATABASE_URL` or `HIYAR_ENV=local`. This
  is purely an additive local-dev capability, and the `HIYAR_ENV=local` gate is specifically
  designed so Terraform never needing to change is also a safety guarantee, not just a
  convenience — there's no code path by which a real deployment could accidentally satisfy
  the gate.
- Not resolving the `DB_NAME`-as-database-vs-schema inconsistency across services — each
  service's issue calls out verifying this locally, but changing the convention itself is
  out of scope.
- Not changing `hiyar-go-testutils` — its DSN-based test pool construction is already
  independent of `cloudsql.NewPool` and doesn't need this mechanism.
- Not adding a `DATABASE_URL` fallback to `hiyar-search-service`'s or any service's
  migration tooling (`cmd/migrate`) unless a given service's issue explicitly says so — scope
  is the runtime server path only, decided per-issue.
- Not touching `hiyar-messaging-service` (Firestore, no Postgres) or `hiyar-media-service`/
  `hiyar-notification-service` (no direct Postgres dependency) — out of scope, they don't use
  `cloudsql.NewPool`.

## Implementation Approach

1. ~~Land the shared mechanism in `hiyar-go-common`~~ — **done**: `dbconn.Open(ctx, cfg, dialCloudSQL, log) (*pgxpool.Pool, io.Closer, error)`
   merged in PR #8 (closes issue #7), implementing the fatal-if-both / WARN-DSN / INFO-IAM /
   fatal-if-neither precedence described in the Overview above. Deviated from this plan's
   originally suggested "DATABASE_URL wins if both set" per an EngLeadBot review addendum —
   fail loudly on conflicting config instead of silently preferring one.
2. ~~Cut a new `hiyar-go-common` release tag~~ — **done**: `v0.5.3`, confirmed in progress via
   `hiyar-user-service` PR #45 (open, not yet merged as of this update).
3. Each of the 8 services bumps its `hiyar-go-common` dependency and swaps its
   `internal/db` (or equivalent) call site to use the new shared helper instead of calling
   `cloudsql.NewPool` directly, passing `cloudsql.NewConfig` as the injected dial function.
   Each service's own `DATABASE_URL` env var is read the same way in every repo (same env
   var name, same log message shape) — this consistency is the point of centralizing in
   `hiyar-go-common` rather than letting each repo invent its own fallback. **Confirmed
   pattern from `hiyar-user-service` PR #45** (first adopter, open for review):
   - `CloudSQLInstance`/`DBUser`/`DBName` must switch from `env.MustGet` to `env.GetOr` in
     each service's own `config.Load()` — otherwise config loading panics before
     `dbconn.Open` ever gets a chance to accept a `DATABASE_URL`+`HIYAR_ENV=local`-only local
     config with no Cloud SQL vars set. `dbconn.Open` itself still fails fast if the Cloud
     SQL vars are missing on that path — the fail-fast-at-startup guarantee moves one layer
     down, it doesn't weaken. Every adopter issue's checklist item "Add `DATABASE_URL` to
     this repo's config loader" should be read as including this `MustGet`→`GetOr` change
     where applicable.
   - `dbconn.Open`'s Cloud SQL path calls `cloudsql.NewConfig` + `pgxpool.NewWithConfig`
     directly — it does **not** reproduce `cloudsql.NewPool`'s own `pool.Ping` startup health
     check (structural: `dbconn` cannot import `cloudsql` at all, only the config it
     returns). Each adopter's `dialCloudSQL` closure should apply the same pool tuning
     (`MaxConns`/`MinConns`/`MaxConnLifetime`) `cloudsql.NewPool` used to apply, inside the
     closure, since that tuning is lost otherwise. Whether the missing ping matters depends
     on whether a given service's own `/readyz` (or equivalent) already does its own
     `pool.Ping` independently — verify per service rather than assuming it's covered.
   - Not every adopter has a `cmd/migrate` binary — `hiyar-user-service` runs migrations
     in-process via `internal/db.RunMigrations` from `main.go`, so the "migrate gap" noted
     above doesn't apply to it at all. Confirm per-repo whether a standalone `cmd/migrate`
     exists before assuming the gap applies.
4. Each service's own integration/unit tests for its `db`/`config` package get a small
   addition confirming both branches log and connect (or panic) as expected — scoped per
   service issue.
5. Once all 8 adopt it (and the `cmd/migrate` gap above is closed for each, if migrations
   need to run locally too), revisit the original full-backend-compose plan's Phase 1/2 to
   use plain DSNs again (no Cloud SQL auth/ADC mounting needed) — each SQL-backed service's
   compose block sets **both** `HIYAR_ENV: local` and `DATABASE_URL: ${..._DSN}` in its
   `environment:` block, and must **not** also set `CLOUD_SQL_INSTANCE` (setting both is now
   a fatal startup error, not a fallback — the compose service definitions for these 8
   services must omit `CLOUD_SQL_INSTANCE`/`DB_USER` entirely, unlike the placeholder shape
   sketched in the original compose plan's Phase 1). Omitting `HIYAR_ENV: local` while
   `CLOUD_SQL_INSTANCE` is also unset falls through to the same fatal error — a deliberate
   fail-closed behavior, not a bug to work around. That compose revision happens after this
   plan and its 8 dependents are implemented, tracked separately.

## What We're NOT Doing (implementation-detail level)

- Not mandating the exact package name/shape in `hiyar-go-common` — the issue proposes
  `dbconn.Open` with dependency-injected Cloud SQL dial as a starting point; the assignee
  may refine it, but the *behavior* (env var names, log lines, panic condition) must stay
  identical across all 8 adopting services — that consistency is non-negotiable per the
  user's explicit ask.

## Testing Strategy

### Automated (per repo):
- `hiyar-go-common`: **done** — `dbconn/dbconn_test.go` has 9 table-driven cases covering the
  DSN path, the IAM path, both-set fatal, both-set-with-`HIYAR_ENV=local`-still-fatal,
  neither-set fatal, `DATABASE_URL`-without-flag fatal, wrong-flag-value fatal, dialer-error
  passthrough, and DSN-pool-open-failure passthrough — all with a fake dialer/pool-opener, no
  real network I/O.
- Each service repo: existing `go test ./...` / `make test-integration` continues to pass;
  add a small unit test on the config/db wiring confirming the DSN path requires
  `HIYAR_ENV=local` and `DATABASE_URL` together with `CLOUD_SQL_INSTANCE` absent, and that
  setting `CLOUD_SQL_INSTANCE` alongside `DATABASE_URL` fails fast rather than picking one
  (matches `dbconn`'s documented precedence, not an assumption to re-derive per service).

### Manual:
- Run one service locally against `hiyar-dev-stack`'s Postgres with `HIYAR_ENV=local` and
  `DATABASE_URL` set — confirm it boots and logs the DSN path.
- Run the same service with `DATABASE_URL` set but `HIYAR_ENV` unset — confirm it does NOT
  take the DSN path (falls through to requiring `CLOUD_SQL_INSTANCE`, or panics).
- Confirm the Cloud Run deployment path is untouched (staging deploy still works with no
  `DATABASE_URL` or `HIYAR_ENV` set anywhere in Terraform).

## References

- `hiyar-user-service/internal/db/db.go:27-45` — the IAM-only `db.Open()` this plan adds a
  fallback branch to.
- `hiyar-go-gcp@v0.2.7/cloudsql/cloudsql.go:59-119` — existing `NewConfig`/`NewPool`, reused
  (not replaced) via dependency injection.
- `hiyar-go-common@v0.5.2/auth/auth.go:98-104` — the dep-hygiene principle motivating the
  dependency-injection design over a direct `hiyar-go-gcp` import.
- `hiyar-dev-stack/.env.example:14-23` — existing unused per-service DSN vars this plan
  finally activates.
- https://github.com/Hiyar-Ltd/hiyar-go-common/pull/8 — merged implementation of issue #7
  (`dbconn` package), including the fatal-if-both precedence correction, WARN/INFO log
  levels, the `cmd/migrate` known-gap note, and confirmation that `ai-service`/
  `admin-service` have no Postgres dependency (no adoption issue needed for either).
- GitHub issues tracking this plan:
  1. https://github.com/Hiyar-Ltd/hiyar-go-common/issues/7 — "Add DATABASE_URL fallback mechanism for local/dev Postgres connections" (closed, merged as PR #8)
  2. https://github.com/Hiyar-Ltd/hiyar-user-service/issues/44 — "Adopt hiyar-go-common DATABASE_URL fallback for local dev"
  3. https://github.com/Hiyar-Ltd/hiyar-listing-service/issues/45 — same title
  4. https://github.com/Hiyar-Ltd/hiyar-search-service/issues/15 — same title
  5. https://github.com/Hiyar-Ltd/hiyar-booking-service/issues/51 — same title
  6. https://github.com/Hiyar-Ltd/hiyar-payment-service/issues/53 — same title
  7. https://github.com/Hiyar-Ltd/hiyar-handover-service/issues/14 — same title
  8. https://github.com/Hiyar-Ltd/hiyar-review-service/issues/10 — same title
  9. https://github.com/Hiyar-Ltd/hiyar-risk-service/issues/10 — same title
  10. https://github.com/Hiyar-Ltd/hiyar-outbox-relay/issues/18 — same title, filed as a
      follow-up after discovering this repo has the identical blocker and was missed in the
      original 8-repo scoping pass
- `thoughts/shared/plans/2026-08-09-full-backend-compose.md` — the original compose plan
  this unblocks; its Phase 1/2 will be revised after this plan's 9 issues land.
