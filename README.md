# BioKey Project

BioKey is a keystroke-dynamics biometric authentication prototype.

## Repository Layout

- `android-client/` — Android app (Kotlin + Compose)
- `backend-server/` — Sinatra API + auth + dashboard + evaluation services
- `database/` — schema + Docker compose for PostgreSQL
- `native-engine/` — native biometric math module (legacy/optional path)
- `tools/` — dataset export + evaluation scripts
- `docs/` — dashboard and evaluation docs

## Prerequisites

- Ruby 3.x + Bundler
- PostgreSQL (local) or Docker Desktop
- Android Studio + Android SDK + Java 17+

## Quick Start

1. Start PostgreSQL (local install or Docker).
2. Apply migrations:

```bash
cd backend-server
ruby db/migrate.rb
```

3. Run backend:

```bash
cd backend-server
bundle install
ruby app.rb
```

4. Run Android app from `android-client/`.

### One-command local startup (Windows)

From repo root:

```powershell
.\run_local.ps1
```

This starts backend setup/migrations and opens `http://127.0.0.1:4567/admin` automatically.

Cmd/batch wrapper:

```bat
run_local.bat
```

Optional: also start Docker PostgreSQL first:

```powershell
.\run_local.ps1 -StartDockerDb -PostgresPassword change_me
```

Optional: skip auto-opening the dashboard browser tab:

```powershell
.\run_local.ps1 -OpenDashboard:$false
```

Health check:

```text
GET http://127.0.0.1:4567/login
```

Expected response: `Hello World`

## API (v1)

- `POST /v1/auth/register`
- `POST /v1/auth/login`
- `GET /v1/auth/profile`
- `POST /v1/auth/refresh`
- `POST /v1/auth/logout`
- `POST /v1/train`
- `POST /v1/login`

Responses include:

- `X-Request-Id`
- `X-Api-Version`

## Dashboard (Phase 11)

- Dashboard: `http://localhost:4567/admin`
- Admin login: `http://localhost:4567/admin/login`

Access model:

- Read-only dashboard access is allowed from localhost.
- Control actions require admin session or `X-Admin-Token`.
- Control actions are written to `audit_events`.

Admin env vars:

- `ADMIN_USER` (default `admin`)
- `ADMIN_PASSWORD_HASH` (bcrypt hash)
- `ADMIN_TOKEN` (optional)
- `APP_SESSION_SECRET` (must be strong; at least 64 chars)

### Demo admin credentials (current local setup)

- Username: `admin`
- Password: `jerryin2323`

PowerShell startup example:

```powershell
cd backend-server
$hash = ruby -rbcrypt -e "puts BCrypt::Password.create('jerryin2323')"
$env:ADMIN_USER='admin'
$env:ADMIN_PASSWORD_HASH=$hash.Trim()
$env:APP_SESSION_SECRET='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
ruby app.rb
```

Generate bcrypt hash:

```bash
ruby -rbcrypt -e "puts BCrypt::Password.create('change_me')"
```

## Evaluation

Export dataset and generate report (run from repo root):

```bash
ruby tools/export_dataset.rb json
ruby tools/evaluate_dataset.rb docs/evaluation.md
```

Phase 11 tables:

- `audit_events`
- `biometric_attempts`
- `evaluation_reports`

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
- Backend unit + integration tests via Bundler
- Android unit tests
- Android debug assemble build

## Security + Operations Notes

- Runtime schema creation is disabled in app boot; run migrations before starting backend.
- Dashboard proxy trust is gated by `TRUST_PROXY=1`. Without it, localhost checks use `request.ip` only.
- Attempt labeling APIs are available:
	- `POST /admin/api/attempt/:id/label`
	- `POST /admin/api/attempts/label-bulk`
- FAR/FRR reports only become meaningful when attempts are labeled as `GENUINE` or `IMPOSTER`.

## Prototype Notice

BioKey is a prototype and not fully production-hardened.
