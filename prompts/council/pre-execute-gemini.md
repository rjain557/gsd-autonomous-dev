# Council: Pre-Execute Plan Review (Gemini)

Review the execution plan BEFORE code generation begins. Verify spec alignment.

## Context
- Health: {{HEALTH}}% | Iteration: {{ITERATION}}
- Read: {{GSD_DIR}}\generation-queue\queue-current.json, {{GSD_DIR}}\health\requirements-matrix.json, {{GSD_DIR}}\health\drift-report.md

## Review Focus
1. Do planned items map correctly to the requirements they claim to address?
2. Are there spec requirements being ignored that should be in this batch?
3. Will completing this batch meaningfully improve health score?
4. Are there any spec misinterpretations in the acceptance criteria?

## Output (max 1500 tokens)
JSON: { "vote": "approve|concern|block", "confidence": 0-100, "findings": [...], "strengths": [...], "summary": "..." }
