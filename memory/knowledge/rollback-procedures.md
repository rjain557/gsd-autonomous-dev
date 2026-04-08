---
type: knowledge
description: Step-by-step rollback runbook for deploy failures
---

# Rollback Procedures

## Alpha Environment Rollback

### Immediate Rollback (< 5 min after deploy)

1. **Stop IIS app pool**: `appcmd stop apppool /apppool.name:"DefaultAppPool"`
2. **Restore backend**: Copy previous artifacts from backup
   ```
   xcopy /E /Y "X:\deploy\alpha-backup\*" "X:\deploy\alpha\"
   ```
3. **Restore frontend**: Copy previous frontend build
   ```
   xcopy /E /Y "X:\deploy\alpha-backup\wwwroot\*" "X:\deploy\alpha\wwwroot\"
   ```
4. **Start IIS app pool**: `appcmd start apppool /apppool.name:"DefaultAppPool"`
5. **Health check**: `GET /api/health` → expect 200
6. **Verify**: `GET /api/auth/me` with test token → expect 200

### Git-based Rollback

1. `git revert HEAD --no-edit` — Revert the deploy commit
2. `git push origin main` — Push revert
3. Re-run deploy sequence with reverted code

### Database Rollback

Only needed if deploy included schema changes:
1. Run rollback migration script from `db/rollback/`
2. Verify data integrity with spot checks
3. Confirm no data loss from audit trail

## Pre-Rollback Checklist

- [ ] Identify the last known good commit SHA
- [ ] Verify backup exists at `X:\deploy\alpha-backup\`
- [ ] Notify team via ntfy notification
- [ ] Log rollback reason to vault

## Post-Rollback Verification

- Health endpoint returns 200
- No 500 errors in IIS logs
- Test user can log in
- Dashboard renders with data
- Write vault record: rollback timestamp, reason, evidence
