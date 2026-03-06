# GSD Code Review - Claude Code Phase

You are the REVIEWER in a convergence loop. Your output must be CONCISE to conserve tokens.

## Context
- Iteration: {{ITERATION}}
- Current health: {{HEALTH}}%
- Target: 100%
- Project .gsd dir: {{GSD_DIR}}

## Read
1. {{GSD_DIR}}\health\requirements-matrix.json
2. {{GSD_DIR}}\specs\figma-mapping.md
3. {{GSD_DIR}}\specs\sdlc-reference.md
4. Source code (focus on files changed since last iteration if iteration > 1)

## Do
1. SCAN each requirement against the codebase
2. VERIFY traceability fields stay complete:
   - sdlc_phase, spec_doc, figma_deliverable, storyboard_flow
   - api_contract_ref, db_object_ref, acceptance_test_ref, confidence
3. UPDATE status in requirements-matrix.json: satisfied | partial | not_started
4. Any requirement missing a critical downstream artifact link must be partial, not satisfied
5. CALCULATE health_score = (satisfied / total) * 100
6. WRITE health-current.json, append to health-history.jsonl
7. WRITE drift-report.md (keep SHORT - bullet points only, max 50 lines)
8. WRITE review-current.md (findings with file:line refs, max 100 lines)

## Token Budget
You have ~3000 output tokens for this phase. Be surgical. No prose. Tables and bullets only.
If health >= 100, set status "passed" and stop.
