# Code Review Phase

You are reviewing a codebase against its specification documents and requirements matrix.

## Inputs
- Full repository scan
- Requirements matrix: `{{gsd_dir}}/health/requirements-matrix.json`
- SDLC specs: `{{docs_path}}`
- Figma mapping: `{{figma_path}}`

## Your Task

1. **Scan every file** in the repository
2. **Compare against each requirement** in the requirements matrix
3. **Score each requirement** as: `satisfied`, `partial`, or `not_started`
4. **Identify drift** — code that doesn't match any spec requirement
5. **Calculate health score** = (satisfied / total_requirements) × 100

## Output Files

### `{{gsd_dir}}/health/health-current.json`
```json
{
  "health_score": <number 0-100>,
  "total_requirements": <count>,
  "satisfied": <count>,
  "partial": <count>,
  "not_started": <count>,
  "iteration": {{iteration}}
}
```

### `{{gsd_dir}}/health/requirements-matrix.json`
Update the `status` and `satisfied_by` fields for each requirement.

### `{{gsd_dir}}/code-review/review-current.md`
Write a concise review with:
- Top issues found
- Requirements that regressed
- Recommendations for next iteration

## Rules
- Be strict: only mark `satisfied` if the requirement is fully implemented
- `partial` means some code exists but it's incomplete or has bugs
- Check {{patterns.compliance}} compliance requirements thoroughly
- Flag any security concerns immediately
