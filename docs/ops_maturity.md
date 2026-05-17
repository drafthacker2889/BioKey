# Operations Maturity Plan

## 1) Backups and Restore Reliability

Policy:
- Daily encrypted DB backup
- Weekly restore verification in a non-production environment
- Retention: 35 daily + 12 monthly snapshots

Controls:
- Store encrypted backups only
- Keep backup passphrases outside repository
- Track backup success/failure as an alertable signal

## 2) Incident Response

Minimum process:
1. Detect and classify severity (P1/P2/P3)
2. Assign incident commander
3. Mitigate (containment first)
4. Recover service and validate integrity
5. Run postmortem within 48 hours

Required artifacts:
- Incident timeline
- Impact statement
- Root cause and contributing factors
- Corrective actions with owners and due dates

## 3) On-Call Model

- Primary and secondary weekly rotations
- Escalation target within 10 minutes for P1
- Runbooks for auth outage, DB outage, Redis outage, and CI/CD rollback

## 4) Scaling and Capacity

- Define SLOs for availability and latency
- Quarterly load tests with realistic auth/admin traffic mix
- Capacity thresholds:
  - CPU sustained > 70%
  - Memory sustained > 75%
  - DB connection saturation > 80%

## 5) Patch and Dependency Management

- Weekly automated dependency update proposals (Dependabot)
- Weekly security-maintenance workflow checks
- Patch SLAs:
  - Critical: 24 hours
  - High: 7 days
  - Medium: 30 days

## 6) Disaster Recovery

- Define RTO and RPO targets
- Document failover sequence and ownership
- Run at least two DR exercises per year

Suggested baseline:
- RTO <= 2 hours
- RPO <= 15 minutes

## 7) Compliance and Governance

- Data retention enforcement by policy window
- Access review every quarter for admin credentials
- Audit logs retained and protected from tampering
- Privacy workflows for export, consent, deletion continuously tested

## 8) Operational Checklists

Weekly:
- Verify backup job success and restore sample
- Review security workflow findings
- Review auth failure anomaly trends

Monthly:
- Rotate admin control token and secrets where feasible
- Review open postmortem actions
- Validate runbook correctness

Quarterly:
- Threat model review
- DR exercise
- Dependency risk review and baseline update
