# Council: Stall Diagnosis (Codex)

The pipeline has STALLED -- health is not improving. Analyze the code.

## Context
- Health: {{HEALTH}}% | Iteration: {{ITERATION}}
- Read: source code, {{GSD_DIR}}\health\drift-report.md, {{GSD_DIR}}\logs\errors.jsonl

## Diagnose
1. Are there build errors preventing progress?
2. Is generated code being overwritten each iteration (no persistence)?
3. Are there dependency issues (missing packages, wrong versions)?
4. Is the execute prompt too vague, causing random changes?
5. What specific code changes would unblock progress?

## Output (max 2000 tokens)
JSON: { "vote": "approve|concern|block", "confidence": 0-100, "findings": [...], "strengths": [...], "summary": "Diagnosis + recommended fix" }
