# BioKey Threat Model

## Scope

In-scope assets:
- Authentication API and admin API
- Keystroke biometric profiles and score history
- Session tokens and admin control credentials
- PostgreSQL and Redis data stores
- CI/CD workflows and deployment secrets

Out-of-scope:
- Device root/jailbreak hardening (tracked separately)
- Physical security controls

## Trust Boundaries

1. Client to API boundary (internet-facing)
2. API to database boundary (private network)
3. API to Redis boundary (private network)
4. CI/CD to runtime deployment boundary
5. Admin browser to dashboard boundary

## Key Threat Scenarios (STRIDE)

### Spoofing
- Stolen bearer token replay
- Forged admin token header
- Host header spoofing against upstream routing

Defenses:
- Hashed session tokens with pepper at rest
- Short session expiration and token refresh flow
- Required ADMIN_TOKEN_HASH in production
- APP_ALLOWED_HOSTS validation in production

### Tampering
- Modified biometric timing payloads
- Manipulated async job payloads
- DB row tampering by compromised service

Defenses:
- Payload hash validation for critical endpoints
- Input validation and strict allowlists
- DB least-privilege user and audit trails

### Repudiation
- Denying risky admin actions
- Missing traceability during incidents

Defenses:
- Request IDs on all responses
- Audit event logging for admin/user sensitive actions
- Immutable CI logs and deployment records

### Information Disclosure
- Leakage of biometric profiles
- Exposed secrets in logs/config
- Excessive error details

Defenses:
- Export endpoints require active user session
- Secrets sourced from environment/secret files only
- show_exceptions disabled outside development
- Security headers and strict CORS allowlist

### Denial of Service
- Auth brute force and flooding
- Admin export/evaluation abuse
- Expensive query amplification

Defenses:
- Endpoint rate limits (auth/admin)
- Redis-backed distributed limiting
- Async admin jobs and bounded request payloads

### Elevation of Privilege
- CSRF against cookie-authenticated admin session
- Misconfigured proxy allowing forged forwarding headers

Defenses:
- Same-origin checks for cookie-session admin operations
- TRUST_PROXY explicit opt-in and allowlisted proxy IPs
- Admin control endpoints require token/session checks

## Attack Path Priorities

Priority 0:
- Account takeover via credential stuffing + token replay
- Admin API abuse via leaked token

Priority 1:
- Exfiltration via over-broad export access
- Availability degradation via high-cost endpoint spam

Priority 2:
- Insider misuse of maintenance endpoints
- CI dependency compromise chain

## Security Test Plan

1. Authentication abuse tests:
- Replay expired token
- Brute force lockout verification
- Rate-limit bypass attempts

2. Admin control tests:
- CSRF simulation with cookie admin session
- Invalid/rotated admin token behavior

3. Data protection tests:
- Export endpoint authorization checks
- Delete-account cascades and residual record checks

4. Dependency and supply chain tests:
- Weekly dependency audit workflow
- Dependabot update cadence and merge policy

## Review Cadence

- Full threat model review every quarter
- Re-review after major auth, session, or admin API changes
- Add new threat scenarios for each new externally exposed endpoint
