# Secret History Purge Runbook

This repository previously contained secret material in tracked files. The working tree has been hardened, but git history may still contain the original values.

## What to purge

- `.secrets/db_backup_passphrase.txt`
- any commits containing plaintext DB passwords or session/admin secrets
- any backups or generated exports that accidentally captured secrets

## Recommended workflow

1. Confirm the secret is no longer present in the working tree.
2. Rewrite history with `git filter-repo` or BFG.
3. Force-push the rewritten branch.
4. Rotate every exposed secret immediately.
5. Revoke any tokens generated before the purge.

## Example using git filter-repo

```bash
git filter-repo --path .secrets/db_backup_passphrase.txt --invert-paths
git push --force --all
git push --force --tags
```

## Rotation checklist

- `APP_SESSION_SECRET`
- `SESSION_TOKEN_PEPPER`
- `APP_AUTH_PEPPER`
- `DB_PASSWORD`
- `ADMIN_TOKEN_HASH` / admin secret material

## Verification

- Run `git log --stat -- .secrets/db_backup_passphrase.txt` and confirm it is removed from history.
- Search the repo for known leaked values before and after rotation.
- Rebuild and redeploy all environments using fresh secrets.