---
type: architecture
description: Task graph and agent system design for the GSD V6 pipeline
version: 6.0.0
status: Active
---

# GSD V6 — Agent System Design

## Task Graph (Pipeline Stages within a Slice)

Under V6, this 7-stage graph runs within each Slice of a Milestone. The orchestrator reads this table at startup to determine the pipeline flow within a slice. To change the pipeline, edit this table.

| Step | Agent | Depends On | On Success | On Failure | Max Retries |
|---|---|---|---|---|---|
| 1 | blueprint-analysis-agent | (trigger) | Step 2 | Retry 3x then HALT | 3 |
| 2 | code-review-agent | Step 1 | If passed: Step 4; If failed: Step 3 | Retry 3x then HALT | 3 |
| 3 | remediation-agent | Step 2 (pre: mechanical-fix band) | Step 4 | Retry 2x then HALT | 2 |
| 4 | quality-gate-agent | Step 3 | If passed: Step 4.5; If failed: Step 3 (loop max 3, StuckDetector enforced) | Retry 2x then HALT | 2 |
| 4.5 | review-auditor-agent (V6) | Step 4 passed | If passed: Step 5; If failed: HALT | Retry 1x, heuristic-only fallback | 1 |
| 5 | e2e-validation-agent | Step 4.5 | If passed: Step 6; If failed: Step 3 | Retry 2x then HALT | 2 |
| 6 | deploy-agent | Step 5 (gate.passed === true) | Step 7 | Rollback then HALT | 1 |
| 7 | post-deploy-validation-agent | Step 6 | COMPLETE | Log failures, recommend rollback | 2 |

## Agent Roster

| Agent | File | Responsibility |
|---|---|---|
| Orchestrator | src/harness/orchestrator.ts | Route work, decide retry/escalate/halt, log decisions |
| BlueprintAnalysisAgent | src/agents/blueprint-analysis-agent.ts | Read specs, detect drift, produce ConvergenceReport |
| CodeReviewAgent | src/agents/code-review-agent.ts | Review code quality, run linters, produce ReviewResult |
| RemediationAgent | src/agents/remediation-agent.ts | Fix issues with validation, backup, rollback |
| QualityGateAgent | src/agents/quality-gate-agent.ts | Run tests/security/coverage + npm audit + dotnet vulnerability check |
| E2EValidationAgent | src/agents/e2e-validation-agent.ts | Test API contracts, SP existence, mock data, page render, auth flows |
| DeployAgent | src/agents/deploy-agent.ts | Deploy with mandatory rollback, produce DeployRecord |
| PostDeployValidationAgent | src/agents/post-deploy-validation-agent.ts | Validate live env: SPA cache, DI health, no 500s, auth flow |

## Remediation Loop

Steps 3 and 4 form a loop with max 3 iterations:
1. RemediationAgent fixes issues from ReviewResult
2. QualityGateAgent validates fixes
3. If gate fails: back to RemediationAgent
4. After 3 iterations without passing: HALT with full evidence
