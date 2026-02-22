# BioKey Project

BioKey is a multi-component biometric authentication prototype based on **keystroke dynamics**.

It includes:
- **Android client** (Jetpack Compose) for sending training/login timing samples
- **Ruby/Sinatra backend API** for profile training and login verification
- **PostgreSQL database** for user profiles and access logs
- **Native C math engine** for distance score calculation

Android client architecture is now **MVVM**:
- `MainActivity` (entry only)
- `ui/BioKeyApp.kt` (screens)
- `viewmodel/BioKeyViewModel.kt` (state + actions)
- `model/BioKeyModels.kt` (models + parsing + capture helpers)
- `data/BioKeyApiClient.kt` (network layer)

---

## Project Structure

- `android-client/` — Android app
- `backend-server/` — Sinatra API + auth logic
- `database/` — SQL schema, seeds, and Docker Compose for DB
- `native-engine/` — native C implementation of biometric distance math
- `verify_auth.rb` — test scaffold for auth service behavior

---

## How the System Works

1. Android app sends `{ user_id, timings[] }` to backend.
2. Backend `/train` stores or updates biometric profile by key pair.
3. Backend `/login` compares attempt timings vs stored profile.
4. `AuthService` calls native math (`MathEngine`) to compute a distance score.
5. Backend returns one of:
   - `SUCCESS` (good match)
   - `CHALLENGE` (suspicious)
   - `DENIED` (imposter)

### Timing Payload Formats
`timings` now supports both formats below.

#### A) Object format (key-pair aware)
Each timing item:
```json
{
  "pair": "ab",
  "dwell": 103.0,
  "flight": 56.0
}
```

#### B) Numeric format (auto-normalized on backend)
```json
{
  "user_id": 1,
  "timings": [120, 130, 125, 140]
}
```

---

## Prerequisites

### Backend / API
- Ruby `3.x`
- Bundler
- PostgreSQL (local) **or** Docker Desktop (for container DB)

### Android
- Android Studio (latest stable recommended)
- Android SDK configured
- Java 17+ (your environment uses JDK 21)

---

## 1) Database Setup

## Option A: Local PostgreSQL
Use these values in `backend-server/config/database.yml`:
```yaml
development:
  adapter: postgresql
  database: biokey_db
  user: postgres
  password: <set-your-password>
  host: localhost
```

Then create DB and run schema from `database/schema.sql`.

Optional (recommended for current backend):
```bash
cd backend-server
ruby db/migrate.rb
```

## Option B: Docker Compose
`database/docker-compose.yml` is configured for:
- DB: `biokey_db`
- User: `postgres`
- Password: from `POSTGRES_PASSWORD` env var (default placeholder: `change_me`)
- Port: `5432`

Start it:
```bash
cd database
set POSTGRES_PASSWORD=<set-your-password>
docker compose up -d
```

> If Docker fails with `dockerDesktopLinuxEngine` pipe error, start Docker Desktop first.

---

## 2) Backend Setup and Run

```bash
cd backend-server
bundle install
ruby app.rb
```

Backend is configured to listen on:
- Host: `0.0.0.0`
- Port: `4567`

### Quick Health Check
```bash
GET http://127.0.0.1:4567/login
```
Expected response:
```text
Hello World
```

---

## 3) Android App Setup and Run

Open `android-client/` in Android Studio and run app on emulator/device.

### Gradle CLI build
```bash
cd android-client
./gradlew :app:assembleDebug
```
(Windows: `gradlew.bat`)

### Compose/Kotlin Compatibility
Project is pinned to a stable, tested Android toolchain:
- AGP: `8.5.2`
- Gradle: `8.7`
- Kotlin: `1.9.24`
- Compose compiler extension: `1.5.14`
- NDK: `27.0.12077973` (set in app module via `ndkVersion`)

If sync/build fails after dependency or IDE updates, re-align these versions first.

### Build Troubleshooting
- If you see Kotlin daemon connection warnings, Gradle may fall back to non-daemon compilation; this is usually non-fatal.
- If NDK resolution errors appear, ensure Android SDK NDK `27.0.12077973` is installed and reload Gradle.
- Run:
  - `./gradlew --stop`
  - `./gradlew :app:assembleDebug`

---

## 4) Using Android App

The app now uses a multi-screen flow:
- **Login Screen** (professional login UI)
  - Server URL
  - User ID
  - Typing phrase
  - Login button
  - Popup/snackbar login message
- **Train Screen** (separate screen)
  - Server URL
  - User ID
  - Typing phrase
  - Train button
- **Home Screen**
  - Shown after successful login
  - Navigation to Train
  - Logout

### Login + Auto-Train Behavior
- A successful login (`status = SUCCESS`) automatically triggers an additional `/train` call.
- This means successful logins are also counted as training samples.
- Login result is shown as a popup/snackbar and in the Result card.

Current default backend URL comes from:
- `android-client/app/src/main/res/values/strings.xml`
- `backend_url = http://10.179.196.210:4567`

### On Emulator vs Real Phone
- Android emulator should typically use: `http://10.0.2.2:4567`
- Real phone on same Wi-Fi should use your PC LAN IP, e.g. `http://10.179.196.210:4567`

If phone cannot connect:
1. Confirm backend is running.
2. Confirm phone and PC are on same network.
3. Confirm Windows Firewall allows inbound port `4567`.
4. Confirm app URL is LAN IP (not localhost).

---

## API Reference

## `POST /v1/auth/register`
Creates a username/password account.

## `POST /v1/auth/login`
Returns session token + user details.

## `GET /v1/auth/profile`
Returns authenticated profile summary (`Authorization: Bearer <token>`).

## `POST /v1/auth/refresh`
Rotates session token and extends expiry (`Authorization: Bearer <token>`).

## `POST /v1/auth/logout`
Invalidates the current session token.

## `POST /v1/train`
Stores/updates biometric profile.

### Request
```json
{
  "user_id": 1,
  "timings": [
    {"pair": "ab", "dwell": 100, "flight": 50},
    {"pair": "bc", "dwell": 110, "flight": 60}
  ]
}
```

### Success Response
```json
{
  "status": "SUCCESS",
  "message": "Profile Updated",
  "request_id": "<id>",
  "api_version": "v1",
  "timestamp": "2026-02-22T10:00:00Z"
}
```

## `POST /v1/login`
Verifies attempt against stored profile.

### Request
Same shape as `/train`.

### Typical Response
```json
{
  "status": "SUCCESS",
  "score": 7.82,
  "request_id": "<id>",
  "api_version": "v1",
  "timestamp": "2026-02-22T10:00:00Z"
}
```
(or `CHALLENGE` / `DENIED`)

## `GET /login`
Simple route used for connectivity testing.

### Response
```text
Hello World
```

---

## Known Notes

- Native label `"Hello from C++"` in the app is a **status string from JNI**, not an error.
- `/train` foreign-key failure was fixed by ensuring `users` row exists for incoming `user_id`.
- `/train` and `/login` now accept both object timings and numeric timing arrays (backend normalizes either format).
- End-to-end API flow was validated on local backend: `register -> auth/login -> auth/profile -> train -> biometric login -> auth/logout`.
- Token refresh flow is available and validated: `auth/login -> auth/refresh -> auth/profile`.
- SQL seeds file (`database/seeds.sql`) is currently empty.
- Android source is committed; generated artifacts (`.idea`, `.cxx`, build outputs) are ignored.

---

## Development Tips

- Keep backend logs visible while testing mobile requests.
- Test with `Train` first, then `Login` for same `user_id`.
- If DB schema changes, recreate DB or run migrations manually.

---

## Security Disclaimer

This is explicitly a prototype. For real-world use, still harden and verify:
- enforce HTTPS/TLS end-to-end
- add account lockout/rate limiting and abuse monitoring
- expand user lifecycle management and role-based authorization
- add robust biometric anti-spoofing and liveness defenses

---

## Quick Start (End-to-End)

1. Start DB (local Postgres or Docker).
2. Start backend:
   ```bash
   cd backend-server
   bundle install
   ruby app.rb
   ```
3. Run Android app.
4. Set app URL:
   - Phone: `http://<PC_LAN_IP>:4567`
   - Emulator: `http://10.0.2.2:4567`
5. Tap **Train**, then **Login**.

---

## Phase Status

- ✅ Phase 1: Real typing-event capture (replaced synthetic timings)
- ✅ Phase 2: Account auth/session API + persistent session in app
- ✅ Phase 3: MVVM refactor (`ui`, `viewmodel`, `model`, `data` split)
- ✅ Phase 4: Networking hardening (`OkHttp`, centralized API error mapping, unauthorized session handling)
- ✅ Phase 5: Retrofit API service layer + `/auth/refresh` endpoint + stricter auth/timing validation
- ✅ Phase 6: `bcrypt` password hashing (with legacy hash migration) + single-session revocation policy
- ✅ Phase 7: auth abuse controls (per-IP rate limiting, login lockout policy, enriched audit events)
- ✅ Phase 8: variance-aware biometric scoring (normalization, weighting, outlier resistance, coverage gating, per-user threshold calibration)
- ✅ Phase 9: API/version contract hardening, request correlation headers, migration runner scaffold, and DB index reinforcement

---

## Phase 8/9/10 Roadmap

Target profile for this roadmap: **production-ish deployment path** while preserving current architecture (Sinatra + PostgreSQL + Android Compose).

### Phase 8 — Biometric Scoring Quality (classical ML/statistics)

**Deliverables**
- Feature normalization in scoring path (z-score or robust scaling using median/MAD fallback).
- Weighted distance scoring where stable key-pairs contribute more than noisy pairs.
- Variance-aware distance (diagonal Mahalanobis style) using per-feature variance.
- Coverage-aware scoring:
  - minimum matched pair threshold,
  - coverage ratio calculation,
  - low-coverage penalty.
- Outlier resistance (Huber/clipped error per feature).
- Profile model upgrade:
  - mean + std for dwell,
  - mean + std for flight,
  - sample count.
- Per-user threshold calibration from genuine score history:
  - `SUCCESS` below user-specific threshold,
  - `CHALLENGE` intermediate,
  - `DENIED` above upper bound.

**Backend scope**
- `backend-server/lib/auth_service.rb`
- `database/schema.sql` (+ migration path for new columns/tables)
- optional `native-engine` updates if scoring remains in C layer

**Acceptance checks**
- Reduced false rejects on same-user re-logins across sessions.
- Coverage failures return explicit backend reason.
- Thresholds are user-specific and persisted.

### Phase 9 — Security + Data + API Reliability

**Deliverables**
- TLS deployment path documented and enforced for non-local environments.
- DB migration framework introduced (replace manual schema-only changes).
- DB constraints/index hardening:
  - session token lookup,
  - user/session expiry access,
  - biometric profile lookup by `(user_id, key_pair)`.
- Consistent versioned API contract (`/v1/...`) with unified JSON error shape.
- Secrets and environment policy formalized (`APP_AUTH_PEPPER`, DB credentials, deploy config).
- Expanded audit/event model with request correlation IDs.

**Acceptance checks**
- Cold setup reproducible via migrations.
- API responses are contract-consistent across success/error paths.
- Security-sensitive values are not hard-coded.

### Phase 10 — Test, Ops, and Productization

**Deliverables**
- Backend automated tests:
  - auth/session unit tests,
  - integration tests for critical endpoints.
- Android tests:
  - ViewModel/state tests,
  - API client/mock-server tests.
- CI pipeline on push/PR for backend + Android checks.
- Containerized deployment baseline (backend + DB) with env-based config.
- Observability baseline:
  - structured logs,
  - error/latency metrics,
  - backup/restore runbook.
- Product UX polish:
  - training progress guidance,
  - clearer auth failure messaging,
  - recovery UX for session expiry/network failures.

**Acceptance checks**
- CI must pass before merge.
- One-command local bring-up works from clean machine.
- Basic operational dashboards/log review are available.

---

## Detailed Phase Breakdown (What Exactly We Will Do)

This section explains the exact engineering work for each upcoming phase, why it matters, and how success will be measured.

### Phase 8 — Biometric Scoring Quality

**Objective**
- Improve biometric decision quality (fewer false rejects/false accepts) without changing the app UX flow.

**Exact implementation plan**
1. Replace raw-only distance scoring with normalized feature scoring so overall typing speed shifts do not dominate the score.
2. Add variance-aware weighting per feature/key-pair (stable pairs matter more, noisy pairs matter less).
3. Enforce match quality rules:
  - minimum matched key-pair count,
  - minimum coverage ratio,
  - explicit low-coverage penalty/failure reason.
4. Upgrade profile statistics from simple averages to distribution stats:
  - mean + std for dwell,
  - mean + std for flight,
  - reliable sample count.
5. Add per-user threshold calibration from observed genuine scores instead of fixed global constants.

**Main files expected to change**
- `backend-server/lib/auth_service.rb`
- `database/schema.sql` (or migration files once migration framework is introduced)
- `native-engine/src/biometric_math.c` (optional, if variance-aware math is moved into native layer)

**Success criteria**
- Same-user relogins are accepted more consistently across sessions.
- Backend responses include clear reasons for low-coverage/insufficient-data failures.
- Thresholds are persisted and differ by user behavior profile.

### Phase 9 — Security, Data, and API Reliability

**Objective**
- Make backend behavior predictable and safe for internet-facing deployment scenarios.

**Exact implementation plan**
1. Introduce migration-based schema changes and stop relying on manual SQL evolution.
2. Enforce and verify critical DB constraints/indexes for auth/session/performance paths.
3. Introduce API versioning (`/v1/...`) and standardize error contracts across all endpoints.
4. Formalize environment/secret policy (pepper, DB credentials, deploy variables) and remove implicit defaults where needed.
5. Add request correlation IDs and extend audit context for incident/debug analysis.
6. Define TLS deployment baseline and document mandatory production networking settings.

**Main files expected to change**
- `backend-server/app.rb`
- `database/schema.sql` and/or migrations directory
- deployment docs and environment examples in `README.md`

**Success criteria**
- Fresh environment can be bootstrapped with migrations only.
- API clients can rely on one consistent error schema.
- Security-sensitive runtime settings are explicit and environment-driven.

### Phase 10 — Testing, Operations, and Productization

**Objective**
- Move from “works locally” to “maintainable service with release confidence.”

**Exact implementation plan**
1. Add backend unit + integration tests for auth/session/biometric decision paths.
2. Add Android tests for ViewModel logic and network behavior using mocked backend responses.
3. Add CI pipeline gates so pushes/PRs must pass backend and Android checks.
4. Standardize deployment/runtime with containerized backend + database configuration.
5. Add baseline observability (structured logs, latency/error metrics, backup/restore runbook).
6. Improve UX quality points (training guidance, better failure messages, offline/session recovery flow).

**Main files expected to change**
- backend test files and test config in `backend-server/`
- Android test files in `android-client/app/src/test` and `android-client/app/src/androidTest`
- CI configuration and deployment docs

**Success criteria**
- CI blocks regressions before merge.
- Local and deploy environments are reproducible.
- Operational debugging can be done from logs/metrics without ad-hoc manual tracing.
