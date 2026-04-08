# GSD Pipeline V4 Architecture

## Overview

9-phase pipeline that takes a codebase from requirements convergence through build verification, code review, runtime validation, and production-ready developer handoff. Designed for .NET 8 + React 18 + SQL Server projects with HIPAA/SOC2/PCI/GDPR compliance requirements.

## Phase Flow

```
Phase 1: CONVERGENCE ──> Phase 2: BUILD GATE ──> Phase 3: WIRE-UP
    |                       |                       |
    | (skip if 100%)        | dotnet build          | mock scan
    | gsd-existing.ps1      | npm run build         | route-role matrix
    |                       | auto-fix loop         | wire-up review
    v                       v                       v
Phase 4: CODE REVIEW ──> Phase 5: BUILD VERIFY ──> Phase 6: RUNTIME
    |                       |                          |
    | 3-model review        | re-run build gate        | start backend
    | Claude+Codex+Gemini   | confirm fixes compile    | start frontend
    | auto-fix loop         |                          | health checks
    |                       |                          | login tests
    v                       v                          | CRUD validation
Phase 7: SMOKE TEST ──> Phase 8: FINAL REVIEW ──> Phase 9: DEV HANDOFF
    |                       |                          |
    | 9-phase validation    | 2 cycles                 | PIPELINE-HANDOFF.md
    | cost-optimized tiers  | fix ALL severities       | phase results table
    | build/DB/API/auth     | Claude+Codex+Gemini      | output file index
    | routes/mock/RBAC      |                          |
```

## Phase Details

### Phase 1: CONVERGENCE
- **Script**: `gsd-existing.ps1`
- **What**: Runs the convergence loop to satisfy requirements from specs. Skipped if health score is already at 100%.
- **Inputs**: Repo root, specs, Figma exports
- **Outputs**: `.gsd/health/health-score.json`, requirements matrix
- **Models**: Sonnet 4.6 (spec gate, plan), Codex Mini (execute)
- **Time**: 30-120 min (depends on req count)
- **Cost**: $5-25 (depends on iterations)

### Phase 2: BUILD GATE
- **Script**: `gsd-build-gate.ps1`
- **What**: Finds .csproj and package.json files, runs `dotnet build --no-restore` and `npm run build`. If errors found, uses Claude to generate fixes. Loops up to MaxAttempts.
- **Inputs**: Repo root
- **Outputs**: `.gsd/build-gate/build-gate-report.json`
- **Models**: Claude (fix generation only, on error)
- **Time**: 1-3 min
- **Cost**: $0-2 (free if builds pass first try)

### Phase 3: WIRE-UP
- **Script**: Inline in `gsd-full-pipeline.ps1` + `gsd-codereview.ps1`
- **What**: Scans for mock data patterns, builds route-role matrix, runs a targeted code review focused on integration wiring (high severity only).
- **Inputs**: Repo root
- **Outputs**: `.gsd/smoke-test/mock-data-scan.json`, `.gsd/smoke-test/route-role-matrix.json`
- **Models**: Claude (wire-up review fix pass)
- **Time**: 3-8 min
- **Cost**: $1-3

### Phase 4: CODE REVIEW
- **Script**: `gsd-codereview.ps1`
- **What**: 3-model parallel review (Claude + Codex + Gemini) of satisfied requirements against actual code. Auto-fixes issues using Claude. Loops up to MaxCycles.
- **Inputs**: Repo root, traceability matrix
- **Outputs**: `.gsd/code-review/review-report.json`, `.gsd/code-review/review-summary.md`
- **Models**: Claude, Codex Mini, Gemini (review); Claude (fix)
- **Time**: 5-15 min
- **Cost**: $3-8

### Phase 5: BUILD VERIFY
- **Script**: `gsd-build-gate.ps1` (re-run)
- **What**: Re-runs the build gate to confirm that code review fixes still compile. Uses 2 max attempts.
- **Inputs**: Repo root (post-review)
- **Outputs**: `.gsd/build-gate/build-gate-report.json` (overwritten)
- **Models**: Claude (fix generation only, on error)
- **Time**: 1-2 min
- **Cost**: $0-1

### Phase 6: RUNTIME VALIDATION
- **Script**: `gsd-runtime-validate.ps1`
- **What**: Starts backend (dotnet run) and frontend (npm start) processes. Performs health checks, login tests with real credentials, API endpoint discovery from controller [Route] attributes, CRUD validation (GET endpoints with auth retry), and frontend route discovery.
- **Inputs**: Repo root, connection string, test users, Azure AD config
- **Outputs**: `.gsd/runtime-validation/runtime-validation-report.json`, `.gsd/runtime-validation/runtime-validation-summary.md`
- **Models**: None (pure runtime testing)
- **Time**: 2-5 min
- **Cost**: $0

### Phase 7: SMOKE TEST
- **Script**: `gsd-smoketest.ps1`
- **What**: 9-phase integration validation with cost-optimized model tiers. Phases: Build, DB, API, Frontend Routes, Auth Flow, Module Completeness, Mock Data (with ripgrep), RBAC Matrix, Integration Gap Report. Auto-fixes issues.
- **Inputs**: Repo root, connection string, test users, Azure AD config
- **Outputs**: `.gsd/smoke-test/smoke-test-report.json`, `.gsd/smoke-test/smoke-test-summary.md`, `.gsd/smoke-test/gap-report.md`
- **Models**: Tiered (local/cheap/mid/premium depending on phase)
- **Time**: 5-15 min
- **Cost**: $2-6

### Phase 8: FINAL REVIEW
- **Script**: `gsd-codereview.ps1`
- **What**: Post-smoke-test verification pass. 2 cycles, fixes ALL severities (including low). Ensures smoke test fixes did not introduce new issues.
- **Inputs**: Repo root (post-smoke-test)
- **Outputs**: `.gsd/code-review/review-report.json` (overwritten)
- **Models**: Claude, Codex Mini, Gemini (review); Claude (fix)
- **Time**: 3-8 min
- **Cost**: $2-5

### Phase 9: DEV HANDOFF
- **Script**: Inline in `gsd-full-pipeline.ps1`
- **What**: Generates PIPELINE-HANDOFF.md with phase results table, total duration, and output file index.
- **Inputs**: Phase results from all previous phases
- **Outputs**: `PIPELINE-HANDOFF.md` in repo root
- **Models**: None
- **Time**: <1 min
- **Cost**: $0

## Cost Optimization

| Tier | Models | Cost/1M tokens | Used For |
|------|--------|----------------|----------|
| Local | None (regex/build) | $0 | Build validation, mock data scan, route matrix, runtime tests |
| Cheap | DeepSeek, Kimi, MiniMax | $0.14-0.28 | DB validation, frontend route check |
| Mid | Codex Mini | $1.50 | Module completeness, RBAC matrix |
| Premium | Claude Sonnet 4.6 | $9.00 | API smoke test, auth flow, fix generation |

### Estimated Total Pipeline Cost
- **Best case** (builds pass, few issues): $8-15
- **Typical** (moderate fixes needed): $15-30
- **Worst case** (many iterations): $30-50

## Parameters

### Full Pipeline (`gsd-full-pipeline.ps1`)
| Parameter | Default | Description |
|-----------|---------|-------------|
| `-RepoRoot` | (required) | Repository root path |
| `-ConnectionString` | (none) | SQL Server connection string |
| `-AzureAdConfig` | (none) | Azure AD config JSON |
| `-TestUsers` | (none) | Test user credentials JSON |
| `-StartFrom` | convergence | Resume from phase |
| `-MaxCycles` | 3 | Review-fix cycles per phase |
| `-MaxReqs` | 50 | Requirements per review batch |
| `-BackendPort` | 5000 | Backend server port |
| `-FrontendPort` | 3000 | Frontend dev server port |
| `-SkipConvergence` | false | Skip convergence phase |
| `-SkipBuildGate` | false | Skip build gate phases (2 and 5) |
| `-SkipWireUp` | false | Skip wire-up phase |
| `-SkipCodeReview` | false | Skip code review phase |
| `-SkipRuntime` | false | Skip runtime validation |
| `-SkipSmokeTest` | false | Skip smoke test phase |
| `-SkipFinalReview` | false | Skip final review phase |

## Known Patterns and Optimizations

1. **Blocked files disease**: Files with 2+ failed writes get added to skip list, blocking requirements that depend on them. Solution: direct fix by Claude Code for shared files (App.tsx, Program.cs).

2. **Decomposition spiral**: Requirements failing on blocked files get decomposed into sub-requirements that also need the same blocked files. Inflates requirement count with zero progress. Prevention: unblock key files before pipeline runs.

3. **Spec drift contamination**: Requirements from wrong project specs can contaminate the matrix. Prevention: spec alignment guard agent verifies reqs match specs before pipeline starts.

4. **Build-review-build sandwich**: Code review fixes can break compilation. The BUILD GATE (phase 2) and BUILD VERIFY (phase 5) sandwich ensures the codebase compiles both before and after review.

5. **Runtime validation gap**: Static analysis (code review + smoke test) misses runtime issues like startup failures, missing middleware, broken auth flows. Phase 6 catches these by actually starting services.

6. **Mock data persistence**: Mock/stub data survives code review because it is syntactically valid code. The dedicated mock data scanner (phase 7 in smoke test, phase 3 in wire-up) catches these with regex and ripgrep.

7. **Cost tiering**: Cheap models ($0.14/1M) handle simple validation; premium models ($9/1M) handle complex fix generation. 4-tier system (local/cheap/mid/premium) reduces costs by 60-80%.

8. **Route-role matrix gaps**: Generated code often has routes without guards or guards without role checks. The wire-up phase (3) builds a complete matrix and the smoke test RBAC phase (8) validates it.

9. **Auth token propagation**: Runtime validation discovers endpoints that return 401, then retries with real auth tokens from login tests. This distinguishes "broken endpoint" from "needs authentication".

10. **Handoff documentation**: Every phase writes structured JSON reports. The final handoff phase aggregates them into a single PIPELINE-HANDOFF.md that developers can use as a status dashboard.
