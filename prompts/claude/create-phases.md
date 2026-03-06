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
5. **Figma Make _analysis/ deliverables** (if they exist under design\ interfaces):
   - 06-api-contracts.md: Every API endpoint, request/response shapes
   - 10-screen-state-matrix.md: Loading, error, empty states per screen
   - 03-design-system.md: Exact tokens, colors, typography
   - 05-data-types.md: TypeScript interfaces and data shapes
   - 09-storyboards.md: User flows and edge cases
   - 01-screen-inventory.md, 02-component-inventory.md, 04-navigation-routing.md
   - 07-hooks-state.md, 08-mock-data-catalog.md, 11-api-to-sp-map.md, 12-implementation-guide.md
   These are MACHINE-READABLE and contain exhaustive specs. Extract requirements from ALL of them.
6. {{GSD_DIR}}\assessment\ (if exists): detected-patterns.json, work-classification.json
   Use these to accurately set requirement statuses based on what code already exists.

## Do
1. EXTRACT every discrete requirement into requirements-matrix.json:
   - id, source (spec|figma|compliance), sdlc_phase, description
   - figma_frame (if UI), spec_doc (which doc defines it)
   - status (scan code: satisfied|partial|not_started)
   - depends_on, pattern, priority
2. UPDATE figma-mapping.md with component-to-file mappings
3. WRITE initial health-current.json
4. WRITE drift-report.md

## Health Score Calculation
Use PRIORITY-WEIGHTED scoring:
  health = (sum of priority_weight × satisfied) / (sum of priority_weight × total) × 100
  where: high=3, medium=2, low=1. Partial requirements get 0.5 weight credit.
  Store both health_score (weighted) and flat_health_score (simple %) in meta.
  Add "scoring_method": "priority-weighted" to meta.

## Token Budget
~5000 output tokens. The matrix JSON will be the bulk. Keep descriptions to one sentence each.
Focus on COMPLETENESS - every missed requirement is a gap that won't get built.
