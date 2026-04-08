# Phase 7: Verify (Feature Update Mode)

Iteration: {{ITERATION}}
Mode: feature_update

You are the VERIFIER for a FEATURE UPDATE. In addition to standard verification, you must detect regressions in previously-satisfied requirements.

## Current Requirements Matrix

{{REQUIREMENTS_MATRIX}}

## Pre-Update Snapshot (baseline)

{{BASELINE_SNAPSHOT}}

## Instructions

1. For each requirement, determine its current status based on:
   - Were all planned files created?
   - Did local validation pass?
   - Were acceptance criteria met?
2. Update statuses: not_started → partial → satisfied
3. Calculate health score: (satisfied * 1.0 + partial * 0.5) / total * 100
4. Detect drift (files modified outside the plan, broken dependencies).

## CRITICAL: Regression Detection

Compare current statuses against the baseline snapshot:
- If ANY previously-satisfied requirement is now NOT satisfied, flag it as a REGRESSION.
- Regressions are BLOCKING — they must be fixed before proceeding.
- Set `regression_detected: true` and list all regressed requirements.
- If regressions exist, set `halt_recommended: true`.

## Output Schema

```json
{
  "iteration": 0,
  "health_score": 0,
  "health_delta": 0,
  "requirements_status": [
    {
      "req_id": "REQ-xxx",
      "status": "not_started | partial | satisfied | regressed",
      "satisfaction_pct": 0,
      "blocking_issues": [],
      "was_previously_satisfied": false
    }
  ],
  "regression_detected": false,
  "regressions": [
    {
      "req_id": "REQ-xxx",
      "previous_status": "satisfied",
      "current_status": "partial",
      "likely_cause": "",
      "caused_by_requirement": ""
    }
  ],
  "drift_detected": [],
  "next_iteration": {
    "recommended_batch_size": 0,
    "priority_requirements": [],
    "rework_requirements": [],
    "regression_fixes": [],
    "skip_research": false,
    "escalate_to_opus": [],
    "spec_fix_needed": false,
    "halt_recommended": false
  },
  "convergence": {
    "converged": false,
    "stall_detected": false,
    "stall_reason": "",
    "iterations_remaining_estimate": 0
  }
}
```

Respond with ONLY the JSON object.
