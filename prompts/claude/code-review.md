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
2. UPDATE status in requirements-matrix.json: satisfied | partial | not_started
3. CALCULATE health_score using PRIORITY-WEIGHTED formula:
   health = (sum of priority_weight × satisfied) / (sum of priority_weight × total) × 100
   where: high=3, medium=2, low=1. Partial requirements get 0.5 weight credit.
   Also store flat_health_score = (satisfied / total) * 100 and scoring_method = "priority-weighted" in meta.
4. WRITE health-current.json, append to health-history.jsonl
5. WRITE drift-report.md (keep SHORT - bullet points only, max 50 lines)
6. WRITE review-current.md (findings with file:line refs, max 100 lines)
7. FLAG any discovered components, endpoints, or patterns NOT in the matrix using this format:
   "missing component: ComponentName" or "missing endpoint: /api/path" or "no test for: FeatureName"
   These will be auto-detected and added to the requirements matrix.

## Token Budget
You have ~3000 output tokens for this phase. Be surgical. No prose. Tables and bullets only.
If health >= 100, set status "passed" and stop.
