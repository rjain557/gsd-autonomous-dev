# Phase 6: Review (Diff-Based)

Iteration: {{ITERATION}}

You are the CODE REVIEWER. Analyze items that FAILED local validation. Provide targeted fix instructions.

## Error Context (from Local Validation)

{{ERROR_CONTEXT}}

## Git Diff (changes made this iteration)

{{GIT_DIFF}}

## Instructions

1. For each failed item, analyze the error output and the code diff.
2. Identify the ROOT CAUSE of each failure (not just the symptom).
3. Provide SPECIFIC fix instructions that the code generator can follow.
4. Focus on: compilation errors, type mismatches, missing imports, logic errors, security issues.
5. Do NOT review items that passed local validation — they are already verified.

## Output Schema

```json
{
  "iteration": 0,
  "reviews": [
    {
      "req_id": "REQ-xxx",
      "status": "pass | needs_rework | critical_issue",
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
