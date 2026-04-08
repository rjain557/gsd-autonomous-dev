# Phase 2: Research

Iteration: {{ITERATION}}

You are the RESEARCHER. Analyze the requirements below and discover implementation patterns, dependencies, and technical decisions.

## Requirements for This Batch

{{REQUIREMENTS}}

## Available Files in Repository

{{FILE_INVENTORY}}

## Instructions

1. For each requirement, identify existing code patterns that should be followed.
2. Discover dependencies between requirements (build order matters).
3. Identify shared components, hooks, types that can be reused.
4. Flag any technical decisions that need to be made.
5. Note risk factors (complex integrations, unclear requirements, etc.).
6. **Estimate implementation size** for each requirement: count files needed and layers touched (frontend, backend, database, docs/scripts). Mark any requirement that needs 5+ files or spans 3+ layers as `"needs_decomposition": true`.

## Output Schema

```json
{
  "iteration": 0,
  "batch_requirements": ["REQ-xxx"],
  "findings": [
    {
      "req_id": "REQ-xxx",
      "existing_patterns": [""],
      "dependencies_discovered": [""],
      "tech_decisions": [""],
      "risk_factors": [""],
      "interface": "web | mcp-admin | browser | mobile | agent | shared | backend",
      "size_estimate": {
        "files_needed": 0,
        "layers": ["backend", "frontend", "database"],
        "estimated_output_tokens": 0,
        "needs_decomposition": false
      }
    }
  ],
  "decompose": [
    {
      "parent_id": "REQ-xxx",
      "reason": "Spans 3 layers with 8 files needed",
      "sub_requirements": [
        {
          "id": "REQ-xxx-1",
          "description": "Atomic sub-requirement focusing on one layer",
          "interface": "backend",
          "priority": "high",
          "files": ["file1.cs", "file2.cs"]
        }
      ]
    }
  ],
  "shared_patterns": {
    "reusable_components": [""],
    "common_interfaces": [""],
    "naming_conventions_observed": [""]
  },
  "file_context_needed": {
    "files_to_read": [""],
    "files_to_modify": [""]
  }
}
```

Respond with ONLY the JSON object.
