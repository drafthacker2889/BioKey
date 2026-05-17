# Monitoring and Alerting

## Objectives

- Detect outages quickly
- Detect security regressions early
- Support incident triage with actionable telemetry

## Core Signals

### Availability
- `GET /health` for process liveness
- `GET /ready` for runtime readiness (DB/schema/Redis)

### Error Signals
- 5xx response rate
- Unauthorized spikes (401/403)
- DB connectivity failures

### Performance Signals
- Request latency p95/p99
- High-cost endpoint duration (`/v1/login`, `/admin/api/*`)
- Queue depth and async job age

### Security Signals
- Rate-limit hit growth
- Authentication failure spikes
- Admin API deny events

## Metrics Endpoint

`GET /metrics` (localhost/admin protected) exports:
- `biokey_requests_total`
- `biokey_request_duration_ms_avg`
- `biokey_request_duration_ms_max`
- `biokey_auth_failures_total`
- `biokey_rate_limit_hits_total`
- `biokey_responses_total{status="..."}`

## Recommended Alerts

Severity: P1
- `ready` endpoint failing for 3 consecutive checks
- 5xx ratio > 5% for 5 minutes

Severity: P2
- p95 latency > 800ms for 10 minutes
- auth failures increase > 3x baseline for 15 minutes

Severity: P3
- rate-limit hits > 2x baseline for 30 minutes
- queue processing lag > 5 minutes

## Uptime and Error Tracking Setup

1. Uptime checks:
- External monitor pings `/health` every 30s
- Internal monitor pings `/ready` every 30s

2. Error tracking:
- Route application logs to centralized log storage
- Build alerts on error patterns and 5xx spikes

3. Dashboards:
- Service health panel (health/ready)
- Auth panel (401/403/lockouts)
- Performance panel (p95/p99)
- Admin job panel (queued/running/failed)

## On-Call Routing

- P1 pages primary on-call immediately
- P2 creates urgent ticket + Slack/Pager notification
- P3 goes to daily triage queue
