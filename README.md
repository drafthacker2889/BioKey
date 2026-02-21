# BioKey Project

BioKey is a multi-component biometric authentication prototype based on **keystroke dynamics**.

It includes:
- **Android client** (Jetpack Compose) for sending training/login timing samples
- **Ruby/Sinatra backend API** for profile training and login verification
- **PostgreSQL database** for user profiles and access logs
- **Native C math engine** for distance score calculation

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

### Timing Object Format
Each timing item:
```json
{
  "pair": "ab",
  "dwell": 103.0,
  "flight": 56.0
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
  password: tiger
  host: localhost
```

Then create DB and run schema from `database/schema.sql`.

## Option B: Docker Compose
`database/docker-compose.yml` is configured for:
- DB: `biokey_db`
- User: `postgres`
- Password: `tiger`
- Port: `5432`

Start it:
```bash
cd database
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
Project uses:
- Kotlin plugin: `1.9.20`
- Compose compiler extension: `1.5.4`

This pairing is already fixed in `android-client/app/build.gradle.kts`.

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

## `POST /train`
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
  "status": "Profile Updated"
}
```

## `POST /login`
Verifies attempt against stored profile.

### Request
Same shape as `/train`.

### Typical Response
```json
{
  "status": "SUCCESS",
  "score": 7.82
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
- SQL seeds file (`database/seeds.sql`) is currently empty.
- Android source is committed; generated artifacts (`.idea`, `.cxx`, build outputs) are ignored.

---

## Development Tips

- Keep backend logs visible while testing mobile requests.
- Test with `Train` first, then `Login` for same `user_id`.
- If DB schema changes, recreate DB or run migrations manually.

---

## Security Disclaimer

This is a prototype implementation for development/testing. Before production use, add:
- proper password hashing and auth flow
- HTTPS/TLS
- input validation hardening
- user management and role model
- robust biometric anti-spoofing controls

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
