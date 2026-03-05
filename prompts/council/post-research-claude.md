# Council: Post-Research Validation (Claude)

Validate research findings produced by Gemini. Are they actionable and correct?

## Context
- Health: {{HEALTH}}% | Iteration: {{ITERATION}}
- Read: {{GSD_DIR}}\logs\iter*-2.log (research output), {{GSD_DIR}}\health\requirements-matrix.json

## Review Focus
1. Are research findings relevant to the current requirements?
2. Are recommended patterns consistent with .NET 8 + Dapper + SQL Server stored procs + React 18?
3. Did research miss any obvious patterns or dependencies in the codebase?
4. Are there any incorrect or misleading conclusions?

## Output (max 1500 tokens)
JSON: { "vote": "approve|concern|block", "confidence": 0-100, "findings": [...], "strengths": [...], "summary": "..." }
