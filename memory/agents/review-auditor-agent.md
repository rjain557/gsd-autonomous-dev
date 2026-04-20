---
agent_id: review-auditor-agent
model: gemini
tools: [read-only]
forbidden_tools: [edit, write, deploy]
reads: [memory/sessions/, memory/decisions/, memory/observability/]
writes: []
max_retries: 1
timeout_seconds: 180
escalate_after_retries: false
type: pipeline-auditor
description: V6 cross-review gate — second-opinion reviewer between QualityGate and Deploy
---

# ReviewAuditorAgent

## Role

V6 cross-review gate. Runs after QualityGate passes and before DeployAgent executes. Second-opinion reviewer that scrutinizes the combined `ReviewResult + PatchSet + GateResult` for blind spots, contradictions, suspicious passes, and missing tests.

Designed to run on Gemini (1M context, $0 marginal under subscription). Heuristic checks run locally and unconditionally; an LLM second opinion is added if the harness provides a `callAuditLLM` override.

## Inputs

- `reviewResult` — CodeReviewAgent output
- `patchSet` — RemediationAgent output
- `gateResult` — QualityGateAgent output (must have `passed === true`)
- `convergenceSummary` — short text summary of the ConvergenceReport

## Output

```typescript
{
  passed: boolean;                   // false blocks deploy
  findings: AuditFinding[];          // structured concerns
  confidence: 'high' | 'medium' | 'low';
  recommendation: 'proceed' | 'fix-blocking' | 'halt';
  reviewerModel: string;             // 'heuristic' or 'llm'
}
```

## Heuristic Checks (always run)

1. **Contradiction** — gate passed but review has critical issue
2. **Suspicious pass** — coverage < 50% but gate passed (mis-configured threshold)
3. **Risk** — patches applied but tests did not pass for the patch set
4. **Missing test** — 3+ source files changed but zero test files touched

## Behavior

- If any finding is `critical`: recommend `halt`
- If any finding is `high`: recommend `fix-blocking`
- Otherwise: `proceed`
- `passed === false` blocks DeployAgent via the orchestrator's gate check

## Known Failure Modes

| Failure | Handling |
|---|---|
| LLM unreachable | Fall back to heuristics only — still returns actionable result |
| Malformed ReviewResult | Log warning, proceed with what can be parsed |

## Related

- `src/agents/review-auditor-agent.ts`
- `memory/architecture/agent-system-design.md` (Step 5.5)
