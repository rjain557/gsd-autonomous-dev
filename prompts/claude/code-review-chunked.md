# GSD Code Review - Chunk {{CHUNK_LABEL}} of {{TOTAL_CHUNKS}}

## Output Constraints
- Maximum output: 2000 tokens
- Format: JSON chunk results file ONLY
- You are reviewing a SUBSET of requirements, not all of them

## Context
- Iteration: {{ITERATION}}
- Current health: {{HEALTH}}%
- Target: 100%
- Project .gsd dir: {{GSD_DIR}}
- Chunk: {{CHUNK_LABEL}} of {{TOTAL_CHUNKS}} ({{CHUNK_COUNT}} requirements)

## Your Assignment
Review ONLY these requirement IDs — ignore all others:

{{CHUNK_REQUIREMENT_IDS}}

## Read
1. {{GSD_DIR}}\health\requirements-matrix.json (for requirement details + traceability fields)
2. Source code files referenced by each requirement's `satisfied_by` or relevant to the requirement description
3. {{GSD_DIR}}\specs\figma-mapping.md (if relevant to your chunk)

## CRITICAL: This is an ACTUAL CODE REVIEW
You MUST read and verify the actual source code for each requirement. Do NOT:
- Just check if files exist by name — open them and verify the implementation
- Copy previous scores or trust metadata — verify against actual code
- Skip reading source files to save tokens — reading code IS your job

## Do
1. For EACH requirement ID in your assignment:
   - Actually READ the source files that implement it (grep, open, check line numbers)
   - VERIFY the implementation matches what the requirement asks for
   - CHECK correctness: proper error handling, correct logic, working endpoints
   - Determine: **satisfied** (code genuinely implements it — record file:line proof), **partial** (some code exists but incomplete — note what's missing), or **not_started** (no meaningful implementation)
   - Record brief evidence (file:line or what's missing)

## Write
Write your findings to: `{{GSD_DIR}}\code-review\chunk-{{CHUNK_LABEL}}.json`

Format (strict JSON, no markdown fences):
```json
{
  "chunk": "{{CHUNK_LABEL}}",
  "iteration": {{ITERATION}},
  "reviewed_count": <number>,
  "results": [
    {"id": "XX-001", "status": "satisfied", "evidence": "Controller.cs:42 implements endpoint"},
    {"id": "XX-002", "status": "partial", "evidence": "Model exists but no controller route"},
    {"id": "XX-003", "status": "not_started", "evidence": "No implementation found"}
  ],
  "blockers": ["any critical issues found"]
}
```

Also write a brief markdown summary to: `{{GSD_DIR}}\code-review\chunk-{{CHUNK_LABEL}}-review.md`
- Max 30 lines, bullets only
- Include file:line references for findings

## CRITICAL
- Do NOT modify health-current.json
- Do NOT modify requirements-matrix.json
- ONLY write to the chunk files above
- The merge step handles health recalculation
