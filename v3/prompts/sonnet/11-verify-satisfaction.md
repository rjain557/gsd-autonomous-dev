# Phase: Satisfaction Verification

Verify whether existing code ACTUALLY implements each requirement.

## Rules
- File existence alone is NOT proof of satisfaction
- You must verify the code contains real implementation logic
- Check for: stubs, TODOs, empty method bodies, missing parameters
- A requirement is SATISFIED only if the code fully implements the described behavior
- A requirement is PARTIAL if code exists but is incomplete
- A requirement is NOT_STARTED if no relevant code exists

## Input
- Requirements list with descriptions
- Code inventory with file statuses
- File contents for verification

## Output (JSON)
```json
{
  "verifications": [
    {
      "requirement_id": "...",
      "status": "satisfied | partial | not_started",
      "evidence_files": ["..."],
      "gaps": "description of what's missing (if partial/not_started)"
    }
  ]
}
```

Respond with ONLY the JSON object. No markdown, no explanation.
