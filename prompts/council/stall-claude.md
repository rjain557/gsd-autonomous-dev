# Council: Stall Diagnosis (Claude)

The pipeline has STALLED -- health is not improving. Diagnose why.

## Context
- Health: {{HEALTH}}% | Iteration: {{ITERATION}}
- Read: {{GSD_DIR}}\health\*, {{GSD_DIR}}\logs\errors.jsonl, {{GSD_DIR}}\health\stall-diagnosis.md

## Diagnose
1. Are requirements impossible to satisfy given the tech stack constraints?
2. Is the code review scoring incorrectly (requirements marked not_started that are actually done)?
3. Are there circular issues (fix A breaks B, fix B breaks A)?
4. Is the execute agent failing silently (committing but not actually implementing)?
5. Recommend a specific recovery action.

## Output (max 2000 tokens)
JSON: { "vote": "approve|concern|block", "confidence": 0-100, "findings": [...], "strengths": [...], "summary": "Diagnosis + recommended action" }
