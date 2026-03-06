# Plan Phase

You are prioritizing which requirements to implement next and creating the work queue.

## Inputs
- Requirements matrix: `{{gsd_dir}}/health/requirements-matrix.json`
- Research findings: `{{gsd_dir}}/research/research-findings.md`
- Drift report: `{{gsd_dir}}/code-review/review-current.md`
- Current health: {{health_score}}%
- Batch size: {{batch_size}}

## Your Task

1. **Filter** — Only consider requirements with status `partial` or `not_started`
2. **Rank by priority** — critical > high > medium > low
3. **Respect dependencies** — Don't queue items whose dependencies aren't satisfied
4. **Select a batch** of up to {{batch_size}} requirements
5. **Write implementation instructions** for each — specific enough for the execute agent

## Output File

### `{{gsd_dir}}/generation-queue/queue-current.json`
```json
{
  "iteration": {{iteration}},
  "health_before": {{health_score}},
  "batch_size": <number>,
  "priority_order": 1,
  "batch": [
    {
      "req_id": "REQ-NNN",
      "description": "What to build",
      "priority": "critical|high|medium|low",
      "depends_on": [],
      "target_files": ["src/path/to/file.ext"],
      "pattern": "api-endpoint|stored-procedure|react-component|...",
      "acceptance_criteria": "How to verify this is done",
      "figma_reference": null,
      "estimated_effort": "low|medium|high"
    }
  ],
  "timestamp": "{{timestamp}}"
}
```

## Rules
- Prefer items that unblock the most other requirements
- Group related items together (e.g., model + controller + route)
- Include specific file paths in `target_files`
- Write `acceptance_criteria` that the verify phase can check mechanically
- If health > 90%, prioritize remaining `partial` items over `not_started`
