# Spec Alignment Check

You are verifying alignment between project specifications and the requirements matrix.

## Input
- Spec documents (design docs, Figma deliverables, SDLC phases)
- Requirements matrix (all current requirements with statuses)
- File inventory (what actually exists in the codebase)

## Task
Compare specs vs requirements vs codebase and identify:
1. Requirements that reference features NOT in any spec document
2. Spec features that have NO corresponding requirements
3. Code files that implement features not in specs or requirements

## Output (JSON)
```json
{
  "drift_pct": 0,
  "status": "pass",
  "missing_in_code": [{ "spec_feature": "...", "expected_files": "..." }],
  "orphaned_requirements": [{ "req_id": "...", "description": "...", "not_in_spec": true }],
  "orphaned_code": [{ "file": "...", "feature": "...", "not_in_spec": true }],
  "summary": "..."
}
```

## Rules
- drift_pct = (orphaned_requirements + orphaned_code) / total_requirements * 100
- status = "block" if drift_pct > 20, "warn" if > 5, "pass" otherwise
- Focus on FEATURES, not implementation details
- Ignore internal .gsd/ files

Respond with ONLY the JSON object.
