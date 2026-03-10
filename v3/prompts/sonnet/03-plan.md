# Phase 3: Plan

Iteration: {{ITERATION}}

You are the PLANNER. Create detailed, actionable implementation plans for each requirement. These plans are consumed directly by the code generator.

## Requirements

{{REQUIREMENTS}}

## Research Findings

{{RESEARCH}}

## Existing Source Files

{{FILE_INVENTORY}}

## Instructions

1. For each requirement, create a step-by-step implementation plan.
2. List ALL files to create and modify with their target paths.
3. Route files to correct interface directories (src/web/, src/mcp-admin/, src/browser/, src/mobile/, src/agent/, src/shared/, backend/, database/).
4. Assign a confidence score (0.0-1.0) based on complexity and risk.
5. Define acceptance tests that can be run locally.
6. Shared code (types, hooks, utils) goes in src/shared/ — no platform imports allowed there.
7. Backend code (controllers, services) goes in backend/ — shared across all interfaces.

## Confidence Scoring

- Complexity small: +0.3 | medium: +0.1 | large: -0.1
- Category trivial (CRUD, DTO, config, seed_data): +0.3
- Zero dependencies: +0.2 | few (1-2): +0.1 | many (3+): -0.1
- No prior rework: +0.1 | has rework history: -0.2

Items with confidence >= 0.9 AND local validation PASS will skip LLM review entirely.

## Output Schema

```json
{
  "iteration": 0,
  "plans": [
    {
      "req_id": "REQ-xxx",
      "interface": "web | mcp-admin | browser | mobile | agent | shared | backend",
      "complexity": "small | medium | large",
      "confidence": 0.0,
      "implementation_order": [
        {
          "step": 1,
          "action": "create | modify",
          "file_path": "src/web/pages/Example.tsx",
          "description": "",
          "preserve": [],
          "dependencies": []
        }
      ],
      "files_to_create": [
        {
          "path": "src/web/pages/Example.tsx",
          "type": "component | hook | service | controller | repository | dto | migration | sp | test | config",
          "interface": "web",
          "estimated_tokens": 0,
          "description": ""
        }
      ],
      "files_to_modify": [
        {
          "path": "",
          "changes": "",
          "preserve": []
        }
      ],
      "acceptance_tests": [
        {
          "type": "file_exists | pattern_match | build_check | dotnet_test | npm_test",
          "target": "",
          "expected": ""
        }
      ]
    }
  ],
  "batch_summary": {
    "total_files_to_create": 0,
    "total_files_to_modify": 0,
    "estimated_total_output_tokens": 0,
    "interfaces_involved": [],
    "parallel_safe": true
  }
}
```

Respond with ONLY the JSON object.
