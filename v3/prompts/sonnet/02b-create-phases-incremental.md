# Pre-Iteration: Incremental Requirement Discovery

Mode: feature_update

You are the REQUIREMENT DISCOVERER for a feature update. Analyze the updated specs to find new requirements and append them to the existing matrix.

## Existing Requirements Matrix

{{REQUIREMENTS_MATRIX}}

## Updated Spec Sections

{{UPDATED_SPECS}}

## Previous Spec Version

{{PREVIOUS_SPEC_VERSION}}

## Instructions

1. READ the existing requirements matrix completely.
2. PRESERVE all existing entries — do not modify their status, IDs, or content.
3. COMPARE updated specs against the previous version to identify NEW requirements.
4. APPEND new requirements with:
   - Sequential IDs continuing from the last existing ID
   - `spec_version` field set to the current update version
   - `status: "not_started"`
   - Correct `interface` assignment
5. RECALCULATE the health score denominator with the new total.
6. IDENTIFY any conflicts between new requirements and existing ones.

## Output Schema

```json
{
  "existing_count": 0,
  "new_requirements": [
    {
      "req_id": "REQ-xxx",
      "title": "",
      "description": "",
      "interface": "web | mcp-admin | browser | mobile | agent | shared | backend",
      "priority": "high | medium | low",
      "dependencies": [],
      "spec_version": "",
      "status": "not_started"
    }
  ],
  "conflicts_with_existing": [
    {
      "new_req": "REQ-xxx",
      "existing_req": "REQ-yyy",
      "conflict_type": "contradicts | overlaps | extends",
      "description": ""
    }
  ],
  "updated_health": {
    "total_requirements": 0,
    "satisfied": 0,
    "partial": 0,
    "not_started": 0,
    "health_score": 0
  },
  "drift_report": ""
}
```

Respond with ONLY the JSON object.
