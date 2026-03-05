# Council: Stall Diagnosis (Gemini)

The pipeline has STALLED -- health is not improving. Analyze specs vs reality.

## Context
- Health: {{HEALTH}}% | Iteration: {{ITERATION}}
- Read: {{GSD_DIR}}\health\requirements-matrix.json, {{GSD_DIR}}\health\drift-report.md, specs

## Diagnose
1. Are spec requirements contradictory or impossible?
2. Are requirements too vague for the execute agent to implement?
3. Is the health scoring formula unfair (penalizing minor issues)?
4. Are there external dependencies (third-party APIs, database schema) blocking progress?
5. Should any requirements be decomposed or deprioritized?

## Output (max 2000 tokens)
JSON: { "vote": "approve|concern|block", "confidence": 0-100, "findings": [...], "strengths": [...], "summary": "Diagnosis + recommendation" }
