# GSD Create Phases - Claude Code Phase

You are the ARCHITECT. Build the requirements matrix from spec docs and Figma designs.
This runs ONCE at the start (Phase 0), or when specs/Figma change significantly.

## Context
- Project: {{REPO_ROOT}}
- Figma: {{FIGMA_PATH}} (version {{FIGMA_VERSION}})
- SDLC docs: docs\ (Phase A through Phase E)
- Project .gsd dir: {{GSD_DIR}}

## Read
1. Every file in docs\ (SDLC specification documents) — read EACH file completely, do not skim
2. {{GSD_DIR}}\specs\figma-mapping.md
3. Design files in {{FIGMA_PATH}}
4. Existing codebase structure (scan src\ or equivalent)

## Do
1. EXTRACT every discrete requirement into requirements-matrix.json:
   - id, source (spec|figma|compliance), sdlc_phase, description
   - figma_frame (if UI), spec_doc (which doc defines it)
   - status (scan code: satisfied|partial|not_started)
   - depends_on, pattern, priority
   - type (backend|frontend|database|compliance|infrastructure|integration)
   - target_files (predicted file paths where this will be implemented)
   - last_reviewed_iteration: 0, last_attempted_iteration: 0
2. UPDATE figma-mapping.md with component-to-file mappings
3. WRITE initial health-current.json
4. WRITE drift-report.md

## Completeness Self-Check (MANDATORY)

After building requirements-matrix.json, run these verification checks before finishing:

### 1. Coverage by SDLC Phase
Count requirements per SDLC phase (A through E). If ANY phase has 0 requirements, re-read that doc — you likely missed extracting from it.

### 2. Coverage by Type
Count requirements by type. A typical project should have requirements across ALL of these categories:
- **backend**: API endpoints, services, business logic (should be > 0)
- **frontend**: React components, pages, forms (should be > 0)
- **database**: Stored procedures, migrations, schemas (should be > 0)
- **compliance**: HIPAA, SOC 2, PCI, GDPR controls (should be > 0)
If any category is 0, re-scan the specs for that category.

### 3. Cross-Reference Consistency
- Every API endpoint in Phase-B specs should have a corresponding stored procedure requirement
- Every Figma frame should map to a React component requirement
- Every data entity should have CRUD stored procedures (or explicit reason why not)
- Every form in the UI should have a corresponding validation requirement

### 4. Dependency Completeness
- For each requirement with `depends_on`, verify the dependency actually exists in the matrix
- Ensure no circular dependencies
- Foundation requirements (auth, DB setup, project scaffold) should have no dependencies

### 5. Requirement Granularity for Scale
- Each requirement should be implementable in a SINGLE iteration (1-2 files max)
- If a requirement touches 4+ files, decompose it into sub-requirements
- For large projects (50+ requirements), ensure IDs follow a consistent pattern (e.g., PHASE-NNN)
- Add a `complexity` field: low (1 file), medium (2-3 files), high (4+ files, should be decomposed)

Write the self-check results as a summary at the top of drift-report.md:
```
## Phase 0 Self-Check
- Total requirements: N
- By phase: A=N, B=N, C=N, D=N, E=N
- By type: backend=N, frontend=N, database=N, compliance=N
- Cross-ref issues: [list any found, or "none"]
- Dependency issues: [list any found, or "none"]
```

## Token Budget
~8000 output tokens. The matrix JSON will be the bulk. Keep descriptions to one sentence each.
Focus on COMPLETENESS — every missed requirement is a gap that won't get built.
For large projects, ensure you extract ALL requirements even if there are hundreds.
Use systematic extraction: go spec-by-spec, section-by-section, never skip ahead.
