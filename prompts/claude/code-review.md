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

## Scoring Rubric (STRICT — apply consistently)

| Status | Definition | Examples |
|--------|-----------|----------|
| **satisfied** | File exists, function/component fully implemented, handles validation + error cases, matches spec/Figma, has proper types/contracts | API endpoint returns correct schema, stored proc handles all params, React component matches Figma frame with states |
| **partial** | File exists with real logic but incomplete: missing error handling, missing edge cases, stub TODO blocks, partial UI (layout exists but missing states/responsiveness), API exists but missing validation | Controller exists but no input validation, component renders but missing loading/error states, stored proc missing audit columns |
| **not_started** | No file, empty file, or only boilerplate/scaffold with no real logic | File not found, only has class declaration with no methods, only has import statements |

When in doubt between satisfied and partial, mark **partial** — false convergence wastes more iterations than conservative scoring.

## Incremental Review (iteration > 1)

When iteration > 1, use an incremental strategy to focus token budget on what matters:

1. **Run `git diff HEAD~1 --name-only`** to get the list of files changed in the last iteration
2. **Auto-confirm satisfied requirements** whose target files have NOT changed since last review — keep their status as-is without re-scanning
3. **Re-evaluate ALL partial and not_started requirements** — these are the priority
4. **Re-evaluate any satisfied requirement whose files WERE modified** this iteration — changes may have introduced regressions
5. **Spot-check 5-10 random satisfied requirements** as a sanity check (pick different ones each iteration)

This incremental approach lets you spend tokens deeply verifying the requirements that matter rather than shallowly scanning everything.

## Do
1. SCAN each requirement against the codebase (use incremental strategy above for iteration > 1)
2. UPDATE status in requirements-matrix.json using the scoring rubric above: satisfied | partial | not_started
3. For each requirement, set `last_reviewed_iteration` to {{ITERATION}}
4. CALCULATE health_score = (satisfied / total) * 100
5. WRITE health-current.json with: health_score, total_requirements, satisfied, partial, not_started, iteration
6. APPEND to health-history.jsonl: one JSON line with iteration, health_score, satisfied, partial, not_started, timestamp, delta (change from previous)
7. WRITE drift-report.md (keep SHORT - bullet points only, max 50 lines):
   - Group by status: critical gaps (not_started with dependencies satisfied), regressions (was satisfied, now partial), stuck (partial for 3+ iterations)
   - Include file:line refs for partial items explaining what's missing
8. WRITE review-current.md (findings with file:line refs, max 100 lines)

## Token Budget
You have ~5000 output tokens for this phase. Be surgical. No prose. Tables and bullets only.
Spend tokens proportionally: ~70% on partial/not_started requirements, ~20% on changed-file re-checks, ~10% on spot-checks.
If health >= 100, set status "passed" and stop.
