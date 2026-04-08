---
name: session-state
description: Crash recovery state - active PIDs, cron IDs, progress snapshot
type: project
---

# Session State (crash recovery)

## tech-web-chatai.v8
- **App repo**: `D:\vscode\tech-web-chatai.v8\tech-web-chatai.v8`
- **Workspace junction**: `d:\vscode\gsd-autonomous-dev\gsd-autonomous-dev\external\tech-web-chatai.v8`
- **Pipeline status**: stopped intentionally; no matching pipeline process found after stop
- **Latest good validation**: `runtime-validate-2026-03-25_120708.log` -> `178 passed, 0 failed`
- **Latest visible pipeline**: `full-pipeline-2026-03-25_120636.log`

## Recovery snapshot
- `RUNTIME` ordering bug is fixed in `v3\scripts\gsd-full-pipeline.ps1`.
- Runtime service persistence for `API-CONTRACT` is fixed in `v3\scripts\gsd-runtime-validate.ps1`.
- The `12:10` smoke-test run is not trustworthy because it generated false positives and wrote unsafe autofixes.

## Files to review before next rerun
- `node_modules\react-router\dist\development\index-react-server-client.mjs`
- `src\web\node_modules\gensync\test\index.test.js`
- `src\web\node_modules\react-router\dist\react-router.production.min.js`
- `design\web\v7\src\components\screens\Assistants.tsx`
- `src\Server\Technijian.Api\Repositories\Connectors\ConnectorRepository.cs`
- `tests\rbac\rbac-regression.spec.tsx`
- `tests\Unit\Frontend\Components\Switch.test.tsx`
- `db\stored-procedures\usp_Search_CommandPalette.sql`
- `db\stored-procedures\usp_SoftDelete_CheckEligibility.sql`
- `db\StoredProcedures\SoftDelete\usp_SoftDelete_User.sql`
- `db\seeds\prod\20260315_seed_tenants_prod.sql`

## Next action
- New session should review/revert the stale smoke-test edits, then launch one visible pipeline from `runtime` and monitor it minute by minute.

## Last Updated
2026-03-25 12:32 PM America/Los_Angeles
