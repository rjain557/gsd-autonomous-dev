---
type: architecture
description: All hooks in the agent system with registration details
---

# Hook Registry

## Hook Events

| Event | Fires When | Args |
|---|---|---|
| `onBeforeRun` | Before agent run() | agentId, input, state |
| `onAfterRun` | After agent run() succeeds | agentId, input, output, state, durationMs |
| `onError` | Agent run() throws | agentId, input, error, state, attempt |
| `onRetry` | Before retry attempt | agentId, attempt, maxRetries |
| `onVaultWrite` | Any vault write | path, content |
| `onDeployStart` | DeployAgent begins | deployConfig, commitSha |
| `onDeployComplete` | DeployAgent succeeds | deployRecord |
| `onDeployRollback` | DeployAgent rolls back | deployRecord, rollbackReason |

## Default Hooks

| Name | Events | Purpose |
|---|---|---|
| logger | onBeforeRun | `[AGENT START] {agentId} run={runId}` |
| cost-tracker | onBeforeRun, onAfterRun | Estimate and accumulate token costs |
| vault-run-logger | onAfterRun | Write run record to sessions/ |
| result-validator | onAfterRun | Validate output matches expected schema |
| retry-with-backoff | onError | Wait 2^attempt * 1000ms, retry up to maxRetries |
| escalation-alert | onError (after retries) | Write alert to vault, set status=paused |
| deploy-audit | onDeployStart, onDeployComplete, onDeployRollback | Immutable deploy records |
