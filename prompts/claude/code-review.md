# GSD Code Review - Claude Code Phase

## Output Constraints
- Maximum output: 3000 tokens
- Format: JSON health update + markdown drift report
- Truncate least-critical findings if approaching limit

## Input Context
You will receive: full repository access, requirements-matrix.json
Previous phase output: execute phase committed code to git

You are the REVIEWER in a convergence loop. Your output must be CONCISE to conserve tokens.

## Context
- Iteration: {{ITERATION}}
- Current health: {{HEALTH}}%
- Target: 100%
- Project .gsd dir: {{GSD_DIR}}

## Read
1. {{GSD_DIR}}\health\requirements-matrix.json
2. Source code files — YOU MUST ACTUALLY READ the source files referenced by each requirement
3. {{GSD_DIR}}\specs\figma-mapping.md (if exists)

## CRITICAL: This is an ACTUAL CODE REVIEW
You MUST read and verify the actual source code for each requirement. Do NOT:
- Just check if files exist by name — open them and verify the implementation
- Copy previous scores or trust metadata — verify against actual code
- Skip reading source files to save tokens — reading code IS your job
- Change the health formula — always use: (satisfied + 0.5 * partial) / total * 100

For each requirement, you must:
1. READ the actual source file(s) that implement it
2. VERIFY the implementation matches what the requirement asks for
3. CHECK for correctness: proper error handling, correct logic, working endpoints
4. Mark as satisfied ONLY if the code genuinely implements the requirement
5. Mark as partial if some code exists but is incomplete or has issues
6. Mark as not_started if no meaningful implementation exists

## Do
1. READ source code files for each requirement — grep, open files, check line numbers
2. UPDATE status in requirements-matrix.json: satisfied | partial | not_started
3. For satisfied: record the file:line evidence in satisfied_by field
4. For partial: note specifically what is missing or broken
5. CALCULATE health_score = (satisfied + 0.5 * partial) / total * 100 (ALWAYS this formula)
6. WRITE health-current.json, append to health-history.jsonl
7. WRITE drift-report.md (keep SHORT - bullet points only, max 50 lines)
8. WRITE review-current.md (findings with file:line refs, max 100 lines)

## Health Formula (DO NOT CHANGE)
health_score = (satisfied + 0.5 * partial) / total * 100
- satisfied counts as 1.0
- partial counts as 0.5
- not_started counts as 0.0

## Token Budget
You have ~3000 output tokens for this phase. Be surgical. No prose. Tables and bullets only.
If health >= 100, set status "passed" and stop.


## AI Code Generation Metrics
Read `.gsd/costs/loc-metrics.json` if it exists. Report in your review:
- Lines added/deleted this iteration vs previous iterations
- Running cost-per-line trend (is each iteration getting more or less efficient?)
- Flag any iteration that consumed significant tokens but produced few lines (possible stall/rework)

Include a one-line LOC summary in your review output:
`LOC this iter: +N / -N net N | Total: +N net N | $X.XX/line`
