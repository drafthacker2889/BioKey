# BioKey Project

BioKey is a keystroke-dynamics biometric authentication prototype with:

- API auth + biometric verification
- Admin dashboard and evaluation tooling
- Social-style typing-capture prototype
- Synthetic human-like data generation
- Encrypted database backup workflow

## Repository Layout

- `android-client/`  Android app (Kotlin + Compose)
- `backend-server/`  Sinatra API + auth + dashboard + prototype routes
- `database/`  schema + Docker compose for PostgreSQL
- `native-engine/`  native biometric math module (legacy/optional)
- `tools/`  generation/export/encryption scripts
- `docs/`  dashboard and evaluation docs
- `secure-backups/`  encrypted DB backups (`.enc`) safe to keep in repo

## Prerequisites

- Ruby 3.x + Bundler
- PostgreSQL (local install) or Docker Desktop
- Android Studio + Android SDK + Java 17+

## Quick Start

1. Start PostgreSQL.
2. Run backend migrations and app:

```bash
cd backend-server
bundle install
ruby db/migrate.rb
set APP_SESSION_SECRET=replace_with_min_32_char_secret
set SESSION_TOKEN_PEPPER=replace_with_min_32_char_secret
set APP_AUTH_PEPPER=replace_with_min_16_char_secret
ruby app.rb
```

3. Open:

- Dashboard: `http://127.0.0.1:4567/admin`
- Prototype login: `http://127.0.0.1:4567/prototype/login`

### Windows Helper Script

From repo root:

```powershell
.\run_local.ps1
```

Batch wrapper:

```bat
run_local.bat
```

Health check:

```text
GET http://127.0.0.1:4567/health
```

Expected response: JSON status `ok`

Readiness check:

```text
GET http://127.0.0.1:4567/ready
```

Expected response: JSON status `ready` when DB/schema (and Redis, if configured) are healthy.

Metrics endpoint (localhost/admin protected):

```text
GET http://127.0.0.1:4567/metrics
```

## API Overview

### Auth + Biometric (v1)

- `POST /v1/auth/register`
- `POST /v1/auth/login`
- `POST /v1/auth/intelligence`
- `GET /v1/auth/profile`
- `GET /v1/auth/export-data`
- `POST /v1/auth/consent`
- `POST /v1/auth/delete-account`
- `POST /v1/auth/refresh`
- `POST /v1/auth/logout`
- `POST /v1/train`
- `POST /v1/login`

### Prototype Typing Capture

- `GET /prototype/login`
- `GET /prototype/feed`
- `GET /prototype/api/profile` (bearer token required)
- `POST /prototype/api/typing-events` (bearer token required)

### Admin APIs

- `GET /admin/api/overview`
- `GET /admin/api/feed`
- `GET /admin/api/live-feed`
- `GET /admin/api/auth-feed`
- `GET /admin/api/typing-capture`
- `POST /admin/api/attempt/:id/label`
- `POST /admin/api/attempts/label-bulk`
- `POST /admin/api/export-dataset`
- `POST /admin/api/run-evaluation`
- `POST /admin/api/apply-retention`
- `GET /admin/api/jobs/:job_id`

Responses include:

- `X-Request-Id`
- `X-Api-Version`

### Intelligence Layer

Biometric verification now includes an intelligence layer that computes:

- entropy-based anomaly signals
- temporal consistency signals
- profile uniqueness and spoofability risk
- action recommendation (`allow`, `challenge_or_monitor`, `step_up_auth`)

The intelligence payload is included in `/v1/login` responses and is available as a standalone analysis endpoint at `/v1/auth/intelligence`.

## Synthetic Data Generation

### Human-like Biometric + Typing Capture

Script: `tools/generate_human_synthetic_40.rb`

Examples:

```bash
# default preset
cd backend-server
ruby ../tools/generate_human_synthetic_40.rb

# heavy preset
ruby ../tools/generate_human_synthetic_40.rb heavy

# custom: mode users train_repetitions logins_per_user typing_batches_per_user typing_chars_per_batch
ruby ../tools/generate_human_synthetic_40.rb heavy 100 6 60 18 70
```

Generated typing events are tagged with `metadata.synthetic = true`.

## Dataset Export

```bash
# biometric attempt export + report
ruby tools/export_dataset.rb json
ruby tools/evaluate_dataset.rb docs/evaluation.md

# typing capture export
ruby tools/export_typing_dataset.rb
```

## Database Backup (Safe for Public Repo)

Raw DB dumps are **not** committed. Use encrypted backups.

### 1) Create raw dump locally (ignored by git)

Output location: `exports/db_backups/*.dump`

### 2) Encrypt dump (commit-safe)

```bash
set DB_BACKUP_PASSPHRASE=replace-with-strong-secret
ruby tools/encrypt_db_backup.rb exports/db_backups/biokey_db_YYYYMMDD_HHMMSS.dump
```

Encrypted output goes to `secure-backups/*.enc`.

### 3) Decrypt when needed

```bash
set DB_BACKUP_PASSPHRASE=replace-with-strong-secret
ruby tools/decrypt_db_backup.rb secure-backups/biokey_db_YYYYMMDD_HHMMSS.dump.enc
```

Important:

- Keep passphrase out of git (for example in local `.secrets/` or a secure password manager).
- `.secrets/` and `exports/` are ignored by `.gitignore`.

## Tests

Backend:

```bash
cd backend-server
bundle exec ruby -Itest test/auth_service_test.rb
bundle exec ruby -Itest test/evaluation_service_test.rb
bundle exec ruby -Itest test/integration_api_test.rb
```

Android:

```bash
cd android-client
./gradlew testDebugUnitTest --no-daemon
./gradlew :app:assembleDebug --no-daemon
```

## CI

Workflow: `.github/workflows/ci.yml`

On push/PR to `main`:

- Backend syntax check (`bundle exec ruby -c app.rb`)
- Backend migration run (`bundle exec ruby db/migrate.rb`)
- Backend unit + integration tests
- Android unit tests
- Android assemble debug build

## Security + Operations Notes

- Runtime schema creation is disabled in app boot; run migrations before app start.
- Dashboard read access is allowed on localhost.
- Dashboard control actions require admin session or `X-Admin-Token`.
- Proxy trust is gated by `TRUST_PROXY=1`.
- Required runtime secrets: `APP_SESSION_SECRET`, `SESSION_TOKEN_PEPPER`, `APP_AUTH_PEPPER`.
- Production control token hash: `ADMIN_TOKEN_HASH` (lowercase SHA-256 hex digest).
- FAR/FRR report quality depends on labeled attempts (`GENUINE` / `IMPOSTER`).
- Session tokens are stored as SHA-256 digests at rest (token hashing with pepper).
- With `REDIS_URL` set, rate limiting and admin async jobs are coordinated across processes.

## Performance Gate

CI includes a lightweight backend performance gate script:

```bash
cd backend-server
ruby tools/perf_smoke_gate.rb
```

Supported environment knobs:

- `PERF_GATE_URL` (default `http://127.0.0.1:4567/health`)
- `PERF_GATE_REQUESTS` (default `30`)
- `PERF_GATE_P95_MS` (default `350`)

## Prototype Notice

BioKey is a prototype and is not fully production-hardened.
