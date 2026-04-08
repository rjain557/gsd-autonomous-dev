# GSD Create Phases - Claude Code Phase

You are the ARCHITECT. Build the requirements matrix from spec docs and Figma designs.
This runs ONCE at the start (Phase 0), or when specs/Figma change significantly.

## Context
- Project: {{REPO_ROOT}}
- Figma: {{FIGMA_PATH}} (version {{FIGMA_VERSION}})
- SDLC docs: docs\ (Phase A through Phase E)
- Project .gsd dir: {{GSD_DIR}}

## Read
1. Every file in docs\ (SDLC specification documents)
2. {{GSD_DIR}}\specs\figma-mapping.md
3. Design files in {{FIGMA_PATH}}
4. Existing codebase structure (scan src\ or equivalent)

## Do
1. EXTRACT every discrete requirement into requirements-matrix.json:
   - id, source (spec|figma|compliance), sdlc_phase, description
   - spec_doc, figma_deliverable, figma_frame, storyboard_flow
   - api_contract_ref, db_object_ref, acceptance_test_ref
   - status (scan code: satisfied|partial|not_started), confidence
   - depends_on, pattern, priority
2. For every requirement, preserve end-to-end traceability:
   - UI requirements must point to the exact Figma deliverable or storyboard
   - API requirements must reference the contract or endpoint source
   - Data requirements must reference the table, stored procedure, or migration source
   - Mark missing downstream links as partial, never silently omit them
3. UPDATE figma-mapping.md with component-to-file mappings
4. WRITE initial health-current.json
5. WRITE drift-report.md

## Token Budget
~5000 output tokens. The matrix JSON will be the bulk. Keep descriptions to one sentence each.
Focus on COMPLETENESS - every missed requirement is a gap that won't get built.
