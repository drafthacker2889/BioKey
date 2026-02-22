# Dashboard (Phase 11)

## Access model

- Read-only routes (`/admin`, `/admin/api/*` GET) are allowed from localhost by default.
- Control routes (`/admin/api/*` POST) require admin auth (`/admin/login`) or `X-Admin-Token`.
- Every control action is recorded in `audit_events`.
- Forwarded headers are only trusted when `TRUST_PROXY=1`.

## Admin setup

Set environment variables before starting backend:

- `ADMIN_USER` (default: `admin`)
- `ADMIN_PASSWORD_HASH` (bcrypt hash)
- optional `ADMIN_TOKEN` for API-based automation

Generate a bcrypt hash from Ruby:

```bash
ruby -rbcrypt -e "puts BCrypt::Password.create('change_me')"
```

### Demo admin credentials (local)

- Username: `admin`
- Password: `jerryin2323`

## Dashboard routes

- `GET /admin`
- `GET /admin/api/overview`
- `GET /admin/api/feed`
- `GET /admin/api/user/:user_id`
- `POST /admin/api/recalibrate/:user_id`
- `POST /admin/api/reset-user/:user_id`
- `POST /admin/api/export-dataset`
- `POST /admin/api/run-evaluation`
- `POST /admin/api/cleanup-sessions`
- `POST /admin/api/attempt/:id/label`
- `POST /admin/api/attempts/label-bulk`
