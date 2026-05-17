# BioKey Production Deployment Guide

## Overview

This guide covers deploying BioKey to production with containerization, orchestration, monitoring, and best practices implemented.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Local Development Setup](#local-development-setup)
3. [Docker Deployment](#docker-deployment)
4. [Environment Configuration](#environment-configuration)
5. [Database Management](#database-management)
6. [Monitoring & Observability](#monitoring--observability)
7. [Security Hardening](#security-hardening)
8. [CI/CD Pipeline](#cicd-pipeline)
9. [Troubleshooting](#troubleshooting)

---

## Prerequisites

- Docker & Docker Compose 20.10+
- Ruby 3.2+ (for local development)
- PostgreSQL 15+ client tools
- Git
- curl or similar HTTP client

---

## Local Development Setup

### 1. Install Dependencies

```bash
cd backend-server
bundle install
```

### 2. Configure Environment

```bash
cp .env.example .env
# Edit .env with environment-specific settings
```

### 3. Initialize Database

```bash
ruby db/migrate.rb
```

### 4. Run Tests

```bash
bundle exec ruby -I lib:test test/**/*_test.rb
```

### 5. Start Development Server

```bash
ruby app.rb        # Basic
# or
puma -c puma.rb    # Production server
```

---

## Docker Deployment

### Build Images

```bash
# Build backend image
docker build -t biokey-backend:latest ./backend-server

# Or use docker-compose
docker-compose -f docker-compose.prod.yml build
```

### Deploy Stack

```bash
# Start all services
docker-compose -f docker-compose.prod.yml up -d

# Check status
docker-compose -f docker-compose.prod.yml ps

# View logs
docker-compose -f docker-compose.prod.yml logs -f backend
```

### Initialize Database in Container

```bash
docker-compose -f docker-compose.prod.yml exec backend \
  ruby db/migrate.rb
```

### Stop Stack

```bash
docker-compose -f docker-compose.prod.yml down

# Remove persistent volumes (WARNING: deletes data!)
docker-compose -f docker-compose.prod.yml down -v
```

---

## Environment Configuration

Create `.env` file from `.env.example`:

```bash
# Database
DB_NAME=biokey_db
DB_USER=biokey
DB_PASSWORD=<strong_password_here>
DB_HOST=postgres          # Use service name in Docker
DB_PORT=5432
DB_POOL_SIZE=10
DB_TIMEOUT=5

# API
API_PORT=4567
API_BIND=0.0.0.0
APP_ENV=production
APP_SESSION_SECRET=<generate_with_SecureRandom.hex(32)>
APP_REQUIRE_HTTPS=true
REQUIRE_ADMIN_TOKEN_HASH=true
ADMIN_TOKEN_HASH=<sha256_of_strong_admin_token>
REDIS_URL=redis://redis:6379/0
ENABLE_ASYNC_ADMIN_JOBS=true
DATA_RETENTION_DAYS=365

# Logging
LOG_LEVEL=INFO
LOG_FORMAT=json

# Security
BCRYPT_COST=12
TOKEN_EXPIRY_MINUTES=60

# Features
ENABLE_PROTOTYPE=true
ENABLE_ADMIN_DASHBOARD=true
ENABLE_STRUCTURED_LOGGING=true
```

### Generate Secrets

```ruby
# In Ruby console
require 'securerandom'
SecureRandom.hex(32)  # For APP_SESSION_SECRET
```

---

## Database Management

### Backup

```bash
# Export entire database
docker-compose -f docker-compose.prod.yml exec postgres \
  pg_dump -U biokey biokey_db > backup_$(date +%Y%m%d_%H%M%S).sql

# Encrypted backup (using BioKey tools)
cd tools
ruby encrypt_db_backup.rb /path/to/backup.sql
```

### Restore

```bash
# Import from SQL file
docker-compose -f docker-compose.prod.yml exec postgres \
  psql -U biokey biokey_db < backup_20260227_122444.sql
```

### Migrations

```bash
# Run migrations
docker-compose -f docker-compose.prod.yml exec backend \
  ruby db/migrate.rb
```

### Connection Pooling

Connection pooling is automatically managed by `ConnectionPool` class with:
- Pool size: configurable via `DB_POOL_SIZE` (default: 10)
- Connection timeout: configurable via `DB_TIMEOUT` (default: 5s)
- Automatic connection validation before reuse

---

## Monitoring & Observability

### Structured Logging

The system logs all requests as JSON with:
- `request_id` - Unique request identifier for correlation
- `user_id` - Authenticated user (if applicable)
- `timestamp` - ISO 8601 formatted time
- `level` - Log level (DEBUG, INFO, WARN, ERROR, FATAL)
- Custom context fields

Example:
```json
{
  "timestamp": "2026-02-27T12:34:56.789Z",
  "level": "INFO",
  "message": "Authentication attempt",
  "request_id": "abc123def456",
  "user_id": 42,
  "api_version": "v1",
  "matched_pairs": 8,
  "score": 1.25
}
```

### Health Checks

```bash
# Backend health
curl -f http://localhost:4567/health

# Backend readiness (DB/schema and Redis if configured)
curl -f http://localhost:4567/ready

# Backend metrics (localhost or admin auth)
curl -f http://localhost:4567/metrics

# Database health (from container)
docker-compose -f docker-compose.prod.yml exec postgres \
  pg_isready -U biokey
```

### Request Tracing

All requests include `X-Request-Id` header for end-to-end tracing:
```bash
curl -H "X-Request-Id: my-trace-id" http://localhost:4567/v1/auth/login
```

### Performance Monitoring

Monitor key metrics:
- `response_time` - Add to structured logs via middleware
- `database_query_time` - Log slow queries (>1s)
- `connection_pool_usage` - Monitor pool exhaustion
- `rate_limit_hits` - Track rate limiting incidents

CI also runs a release smoke/performance gate on backend changes using `backend-server/tools/perf_smoke_gate.rb`.

---

## Security Hardening

### SSL/TLS

Enable HTTPS enforcement:
```env
APP_REQUIRE_HTTPS=true
```

The server will reject non-HTTPS requests with HTTP 426.

### Distributed Rate Limiting and Async Jobs

When `REDIS_URL` is set, BioKey uses Redis for cross-process rate limiting and queued admin jobs.

- Keep `ENABLE_ASYNC_ADMIN_JOBS=true` to queue expensive exports/evaluations.
- Query job state with `GET /admin/api/jobs/:job_id`.
- Set `DATA_RETENTION_DAYS` to control automatic purge windows.

### Retention

Run `POST /admin/api/apply-retention` as an admin to delete old biometric attempts, access logs, and score history.

### Security Headers

Automatically set on all responses:
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `Referrer-Policy: no-referrer`
- `Strict-Transport-Security` (when HTTPS enabled)

### Rate Limiting

Built-in rate limiting protects auth endpoints:
- 30 failed attempts per 60 seconds triggers account lockout
- Lockout remains for 15 minutes
- Based on IP + username combination

### Password Security

- Minimum 8 characters required
- BCrypt hashing with configurable cost (default: 12)
- No plaintext storage

### Database Access

- Use strong credentials from `.env`
- Connection encryption recommended (enable `sslmode`)
- Restrict network access to PostgreSQL (Docker network isolation)

---

## CI/CD Pipeline

### GitHub Actions Workflows

Automated on every push and pull request:

1. **Tests** - Run full test suite with PostgreSQL
2. **Linting** - RuboCop for code style
3. **Security** - Brakeman for security vulnerabilities

### Running Locally

```bash
# Run tests locally (requires test env)
APP_ENV=test bundle exec ruby -I lib:test test/**/*_test.rb

# Run linter
rubocop lib/ app.rb models/

# Run security scan
brakeman
```

### Pre-commit Checks

```bash
# Verify code before committing
ruby -c app.rb
ruby -c lib/*.rb
bundle exec ruby -I lib:test test/**/*_test.rb
```

---

## Advanced Deployments

### Kubernetes

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: biokey-backend
spec:
  replicas: 3
  selector:
    matchLabels:
      app: biokey-backend
  template:
    metadata:
      labels:
        app: biokey-backend
    spec:
      containers:
      - name: backend
        image: biokey-backend:latest
        ports:
        - containerPort: 4567
        env:
        - name: DB_HOST
          value: postgres
        - name: APP_ENV
          value: production
        livenessProbe:
          httpGet:
            path: /login
            port: 4567
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /login
            port: 4567
          initialDelaySeconds: 5
          periodSeconds: 5
```

### AWS ECS

[See AWS deployment guide in `/docs/aws-deployment.md`]

---

## Troubleshooting

### Database Connection Failed

```bash
# Check PostgreSQL is running
docker-compose -f docker-compose.prod.yml ps postgres

# Check credentials
docker-compose -f docker-compose.prod.yml logs postgres

# Test connection
docker-compose -f docker-compose.prod.yml exec postgres \
  psql -U biokey -d biokey_db -c "SELECT 1"
```

### High Memory Usage

- Increase `DB_POOL_SIZE` if many connections pending
- Check for connection leaks (verify releases after queries)
- Monitor worker process count

### Slow Queries

Enable query logging in PostgreSQL:
```sql
SET log_min_duration_statement = 1000; -- Log queries > 1s
```

### Rate Limiting Blocking Users

Check `.env` settings:
```env
AUTH_RATE_LIMIT_MAX=30                # Requests per window
AUTH_RATE_LIMIT_WINDOW_SECONDS=60     # Window duration
AUTH_LOCKOUT_WINDOW_MINUTES=15        # Lockout duration
```

---

## Support & Documentation

- API Docs: `openapi.yml` (OpenAPI 3.0)
- Architecture: `/docs/architecture.md`
- Evaluation Guide: `/docs/evaluation.md`
- Security Policy: `/SECURITY.md`

