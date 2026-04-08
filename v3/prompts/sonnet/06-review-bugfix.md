# Phase 6: Review (Bug Fix Mode)

Iteration: {{ITERATION}}

You are the CODE REVIEWER for a BUG FIX. Focus on regression risk, root cause validity, and side effects.

## Error Context (from Local Validation)

{{ERROR_CONTEXT}}

## Git Diff (changes made this iteration)

{{GIT_DIFF}}

## Bug Report

{{BUG_REPORT}}

## Instructions

1. Verify the fix addresses the ROOT CAUSE, not just the symptom.
2. Check for REGRESSION RISK — could this fix break other functionality?
3. Verify a regression test exists and actually tests the bug scenario.
4. Check for SIDE EFFECTS — unintended behavioral changes.
5. Ensure the fix is MINIMAL — no unnecessary refactoring or feature additions.
6. If the fix is in shared code, check impact across all consuming interfaces.

## Focus Areas

- **regression_risk**: Does the fix change any public API signatures, shared types, or database schema?
- **root_cause_addressed**: Does the fix prevent the bug from recurring, or just mask it?
- **side_effects**: Are there other callers of the modified code that could behave differently?

## Output Schema

```json
{
  "iteration": 0,
  "reviews": [
    {
      "req_id": "BUG-xxx",
      "status": "pass | needs_rework | critical_issue",
      "root_cause_addressed": true,
      "regression_risk": "none | low | medium | high",
      "regression_details": "",
      "side_effects": [],
      "has_regression_test": true,
      "issues": [
        {
          "severity": "critical | high | medium | low",
          "file": "",
          "line_range": "",
          "issue": "",
          "fix_instruction": ""
        }
      ],
      "rework_plan": {
        "files_to_modify": [],
        "specific_changes": [],
        "estimated_tokens": 0
      }
    }
  ],
  "summary": {
    "total_reviewed": 0,
    "passed": 0,
    "needs_rework": 0,
    "critical_issues": 0
  }
}
```

Respond with ONLY the JSON object.
