# Phase 7: Verify

Iteration: {{ITERATION}}
Mode: {{MODE}}

You are the VERIFIER. Update requirement statuses, calculate health, detect drift, and gate the next iteration.

## Current Requirements Matrix

{{REQUIREMENTS_MATRIX}}

## Instructions

1. For each requirement in the matrix above, determine its current status based on the evidence provided below.
2. **CRITICAL: Be AGGRESSIVE about promoting statuses.** The evidence block below shows what happened THIS iteration:
   - If files were written for a requirement → promote to at least "partial"
   - If files were written AND local validation passed → promote to "satisfied"
   - If files were written AND validation had only warnings (non-blocking) → promote to "satisfied"
   - Only keep "not_started" if NO files were generated for the requirement
3. Update statuses: not_started → partial → satisfied
4. **You MUST include a status entry for EVERY requirement that had files written or validation results this iteration.** Do not skip any.
5. Calculate health score: (satisfied * 1.0 + partial * 0.5) / total * 100
6. Detect drift (files modified outside the plan, broken dependencies).
7. Recommend next iteration priorities.
8. If health_score >= 100, set converged = true.
9. If 3+ iterations with no improvement, set stall_detected = true.

## Mode-Specific Rules

- **greenfield**: Standard verification.
- **bug_fix**: Check that fix addresses root cause, not just symptoms. Verify regression test exists.
- **feature_update**: Check for regression — if any previously-satisfied requirement is no longer satisfied, flag it. But DO NOT demote satisfied reqs unless you have clear evidence of regression.

## Output Schema

```json
{
  "iteration": 0,
  "health_score": 0,
  "health_delta": 0,
  "requirements_status": [
    {
      "req_id": "REQ-xxx",
      "status": "not_started | partial | satisfied",
      "satisfaction_pct": 0,
      "blocking_issues": []
    }
  ],
  "drift_detected": [],
  "next_iteration": {
    "recommended_batch_size": 0,
    "priority_requirements": [],
    "rework_requirements": [],
    "skip_research": false,
    "escalate_to_opus": [],
    "spec_fix_needed": false
  },
  "convergence": {
    "converged": false,
    "stall_detected": false,
    "stall_reason": "",
    "iterations_remaining_estimate": 0
  }
}
```

## Integration Completeness Verification

**CRITICAL**: File existence is NOT sufficient for "satisfied" status. Before promoting any
requirement to "satisfied", verify these integration criteria:

1. **Frontend requirements**: Component must call real API (not mock/static data). Check for:
   - `useState` with hardcoded arrays → NOT satisfied (still partial)
   - Mock service imports → NOT satisfied
   - API calls to placeholder URLs → NOT satisfied
   - Component exists but not in router → NOT satisfied

2. **Backend requirements**: Controller must use injected services calling real DB. Check for:
   - Controller returning hardcoded data → NOT satisfied
   - Repository with `NotImplementedException` → NOT satisfied
   - Missing DI registration → NOT satisfied
   - No stored procedure calls in repository → NOT satisfied

3. **Integration requirements**: End-to-end data flow must work. Check for:
   - Frontend calls mock hook but real API exists → partial (not satisfied)
   - Backend exists but connection string is placeholder → partial
   - Auth guard missing on protected route → partial

4. **Status rules with integration awareness**:
   - `not_started`: No files generated
   - `partial`: Files exist BUT contain mock data, stubs, or broken wiring
   - `satisfied`: Files exist AND use real API calls, real DB queries, real auth

Add an `integration_issues` field to any requirement that has wiring problems:
```json
{
  "req_id": "REQ-xxx",
  "status": "partial",
  "satisfaction_pct": 60,
  "blocking_issues": ["Frontend uses mock data instead of real API"],
  "integration_issues": ["mock_data", "placeholder_url"]
}
```

Respond with ONLY the JSON object.
