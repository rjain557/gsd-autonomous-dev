---
type: architecture
description: Typed state definitions for the pipeline — all agent I/O contracts and orchestrator state
---

# State Schema

Full TypeScript definitions are in `src/harness/types.ts`.

## PipelineState (Orchestrator)

The central state object passed through all stages. Persisted to vault after each stage for `--from-stage` resume.

| Field | Type | Producer | Description |
|---|---|---|---|
| runId | string (UUID) | Orchestrator | Unique pipeline run identifier |
| triggeredBy | TriggerType | CLI | `manual` / `schedule` / `webhook` |
| blueprintVersion | string | Orchestrator | Version from requirements matrix |
| convergenceReport | ConvergenceReport \| null | BlueprintAnalysisAgent | Drift analysis output |
| reviewResult | ReviewResult \| null | CodeReviewAgent | Code quality assessment |
| patchSet | PatchSet \| null | RemediationAgent | Applied fixes |
| gateResult | GateResult \| null | QualityGateAgent | Build/test/security gate |
| deployRecord | DeployRecord \| null | DeployAgent | Deployment outcome |
| decisions | Decision[] | Orchestrator | Append-only routing log |
| currentStage | PipelineStage | Orchestrator | Current execution point |
| status | PipelineStatus | Orchestrator | `running` / `paused` / `failed` / `complete` |
| costAccumulator | CostEntry[] | Hooks | Per-agent token/cost tracking |
| startedAt | string (ISO) | Orchestrator | Run start timestamp |
| completedAt | string \| null | Orchestrator | Run end timestamp |

## ConvergenceReport (BlueprintAnalysisAgent)

| Field | Type | Description |
|---|---|---|
| aligned | string[] | Requirements that match implementation |
| drifted | DriftItem[] | Requirements with implementation drift (each has severity) |
| missing | string[] | Requirements with no implementation |
| riskLevel | RiskLevel | `low` (<5% drift), `medium` (5-15%), `high` (>15%) |

## ReviewResult (CodeReviewAgent)

| Field | Type | Description |
|---|---|---|
| passed | boolean | Overall pass/fail (no critical/high issues + coverage met) |
| issues | Issue[] | Each with id, file, line, severity, category, message |
| coveragePercent | number | Code coverage from test output |
| securityFlags | string[] | Security findings |

## PatchSet (RemediationAgent)

| Field | Type | Description |
|---|---|---|
| patches | Patch[] | Each with file, issueId, diff, description |
| testsPassed | boolean | Whether build succeeded after all patches |

## GateResult (QualityGateAgent)

| Field | Type | Description |
|---|---|---|
| passed | boolean | Hard gate — deploy cannot proceed if false |
| coverage | number | Line coverage percentage |
| securityScore | number | 0-100 score (100 - findings * 15) |
| evidence | string[] | Pass/fail strings for each check |

## DeployRecord (DeployAgent)

| Field | Type | Description |
|---|---|---|
| success | boolean | Overall deploy outcome |
| environment | string | Target environment (alpha/staging/production) |
| commitSha | string | Git commit deployed |
| deployedAt | string (ISO) | Deploy timestamp |
| steps | StepResult[] | Each with name, success, output, durationMs |
| rollbackExecuted | boolean | Whether rollback was triggered |

## E2EValidationResult (E2EValidationAgent)

| Field | Type | Description |
|---|---|---|
| passed | boolean | No critical category failures |
| totalFlows | number | Total test flows executed |
| passedFlows | number | Flows that passed |
| failedFlows | number | Flows that failed |
| categories | object | 6 categories: apiContract, screenRender, crudOperations, authFlows, mockDataDetection, errorStates |

## PostDeployValidationResult (PostDeployValidationAgent)

| Field | Type | Description |
|---|---|---|
| passed | boolean | No critical/high check failures |
| checks | PostDeployCheck[] | Each with name, category, passed, details, severity |
| spExistence | object | expected, found, missing[] |
| dtoValidation | object | tested, passed, mismatches[] |
| pageRender | object | tested, passed, failures[] |
| authFlow | object | passed, details |

## Example PipelineState JSON

```json
{
  "runId": "a1b2c3d4-...",
  "triggeredBy": "manual",
  "blueprintVersion": "1.0",
  "convergenceReport": { "aligned": ["REQ-001"], "drifted": [], "missing": [], "riskLevel": "low" },
  "reviewResult": { "passed": true, "issues": [], "coveragePercent": 85, "securityFlags": [] },
  "patchSet": null,
  "gateResult": { "passed": true, "coverage": 85, "securityScore": 100, "evidence": ["dotnet build: PASS"] },
  "deployRecord": null,
  "decisions": [{ "stage": "blueprint", "action": "complete", "reason": "Low risk", "evidence": "", "timestamp": "2026-04-09T..." }],
  "currentStage": "gate",
  "status": "running",
  "costAccumulator": [{ "agentId": "blueprint-analysis-agent", "stage": "blueprint", "inputTokens": 1200, "outputTokens": 800, "estimatedCostUsd": 0 }],
  "startedAt": "2026-04-09T10:00:00Z",
  "completedAt": null
}
```
