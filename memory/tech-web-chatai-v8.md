---
name: tech-web-chatai-v8
description: Active recovery notes for the tech-web-chatai.v8 pipeline and runtime fixes
type: project
---

# tech-web-chatai.v8 Recovery Notes

## Updated
2026-03-25 12:32 America/Los_Angeles

## Current status
- App repo: `D:\vscode\tech-web-chatai.v8\tech-web-chatai.v8`
- Workspace junction: `d:\vscode\gsd-autonomous-dev\gsd-autonomous-dev\external\tech-web-chatai.v8`
- Frontend build passes from the real repo path.
- API build passes.
- Runtime validation passes cleanly: 178 passed, 0 failed, 0 skipped.
- Latest corrected visible pipeline run was `full-pipeline-2026-03-25_120636.log`.
- That run finally executed `RUNTIME` first and passed, but `API-CONTRACT` still skipped because it was launched before the later `-KeepServicesRunning` patch.
- The stale smoke-test cycle then produced massive false positives and unsafe autofixes, so the pipeline was stopped intentionally.
- Follow-up process check found no matching `run-tech-web-chatai-pipeline.ps1` or `gsd-full-pipeline.ps1` process still running from this session.

## App fixes applied
- Restored root app routing to use the real router in `src\App.tsx`.
- Added missing backend route aliases and endpoint coverage for runtime validation.
- Registered missing workflow page service DI and added `WorkflowRunsPageService`.
- Fixed `AuditLogRepository` logging namespace and `AgentCommandAuditRecord` contract mismatch.
- Added development-safe OAuth state fallback and Azure AD dev `ClientId`.
- Fixed `ConfigController` DI constructor ambiguity with `ActivatorUtilitiesConstructor`.

## Pipeline/tooling fixes applied
- `v3\scripts\gsd-runtime-validate.ps1`
- Added native `curl.exe` probing instead of `bash` loopback checks.
- Added explicit startup pass/fail accounting for backend/frontend.
- Backend startup now uses `--no-launch-profile` with runtime env overrides.
- Frontend startup now uses non-interactive `CI=1` dev-server launch.
- Absolute action routes are now discovered correctly.
- Login validation now accepts OAuth-initiation responses using `authorizationUrl`.
- Startup validation now checks `127.0.0.1` and `localhost`.
- `v3\scripts\gsd-api-contract.ps1`
- Replaced `bash`-based Swagger fetching with native PowerShell HTTP requests.
- Added localhost and `127.0.0.1` Swagger URL probing.
- `v3\scripts\gsd-test-generation.ps1`
- Prefers the real backend test project instead of the first recursive `.csproj` match.
- Prefers the root frontend package and active screen roots instead of `design\web\*` drift.
- Avoids duplicate test generation when matching test files already exist elsewhere in the repo.
- Uses native npm invocation instead of `bash` for Playwright install and frontend test execution.
- Supports `vitest` test execution and no longer uses `dotnet test --no-build` immediately after generating files.
- `v3\scripts\gsd-codereview.ps1`
- Prefers `src\Server\Technijian.Api\Technijian.Api.csproj` for build validation.
- Prefers the root `package.json` and stops treating warning-only Vite output as build failures.
- Reduces truncation-driven false positives by passing head+tail file evidence and explicitly forbidding speculation on missing context.
- `v3\scripts\gsd-build-gate.ps1`
- Prefers the real backend/frontend targets and no longer depends on restore-less dotnet builds.
- `v3\scripts\gsd-full-pipeline.ps1`
- `DONE` is no longer logged as an error.
- Final banner now distinguishes clean completion from warnings/failures.
- Fixed phase-order/start-index mismatch so `-StartFrom runtime` actually executes the runtime phase before later gates.
- Runtime now keeps backend/frontend alive for `API-CONTRACT` when that phase is enabled.

## Latest pipeline evidence
- `runtime-validate-2026-03-25_120708.log`: runtime passed with `178 passed, 0 failed`.
- `api-contract-2026-03-25_120908.log`: skipped because Swagger extraction could not reach a live service in the pre-patch run.
- `smoketest-2026-03-25_121045.log`: false-positive-heavy run that escalated into unsafe autofixes.

## Known cleanup risk before next rerun
- Review and likely revert smoke-test autofixes made to dependency or design paths before trusting the next pipeline.
- Files explicitly touched in the bad run:
- `src\Server\Technijian.Api\Repositories\Connectors\ConnectorRepository.cs`
- `tests\rbac\rbac-regression.spec.tsx`
- `db\stored-procedures\usp_Search_CommandPalette.sql`
- `db\stored-procedures\usp_SoftDelete_CheckEligibility.sql`
- `db\seeds\prod\20260315_seed_tenants_prod.sql`
- `node_modules\react-router\dist\development\index-react-server-client.mjs`
- `design\web\v7\src\components\screens\Assistants.tsx`
- `src\web\node_modules\gensync\test\index.test.js`
- `src\web\node_modules\react-router\dist\react-router.production.min.js`
- `tests\Unit\Frontend\Components\Switch.test.tsx`
- `db\StoredProcedures\SoftDelete\usp_SoftDelete_User.sql`

## Next step
- From the new session, inspect and clean up the stale smoke-test edits first, especially anything under `node_modules` or `design`.
- Relaunch exactly one visible PowerShell pipeline from `runtime` after cleanup.
- Monitor the fresh log every minute and verify `runtime -> api-contract -> smoke-test -> test-generation -> compliance -> deploy-prep -> final-review` runs in the corrected order.
