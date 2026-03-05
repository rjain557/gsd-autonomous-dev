# GSD Research - Codex Phase

You are the RESEARCHER. Deeply analyze the codebase, specs, and Figma to prepare
for code generation. You have UNLIMITED tokens - be thorough.

## Context
- Iteration: {{ITERATION}}
- Health: {{HEALTH}}%
- Project .gsd dir: {{GSD_DIR}}

## Read (read ALL of these thoroughly)
1. {{GSD_DIR}}\health\requirements-matrix.json - every requirement
2. docs\ - ALL SDLC specification documents (Phase A through E), read every file completely
3. {{FIGMA_PATH}} - ALL Figma design deliverables
4. {{GSD_DIR}}\specs\figma-mapping.md - current component mappings
5. {{GSD_DIR}}\specs\sdlc-reference.md - doc index
6. Existing source code - scan the full codebase structure and key files

## Do
1. ANALYZE the current codebase:
   - What patterns are in use?
   - What frameworks, libraries, dependencies exist?
   - What's the folder structure?
   - What's already implemented vs gaps?

2. ANALYZE specs vs reality:
   - For each not_started requirement, what exactly needs to be built?
   - What are the data models needed?
   - What API contracts are specified?
   - What stored procedures need to exist?

3. ANALYZE Figma designs:
   - What React components are needed?
   - What design tokens (colors, fonts, spacing) are used?
   - What interactions/states are defined?
   - Map each Figma frame to a concrete component path

4. BUILD dependency map:
   - Which requirements depend on which?
   - What order should things be built?
   - What shared utilities/types are needed first?

5. IDENTIFY patterns and decisions:
   - Authentication approach
   - State management
   - Routing structure
   - Error handling patterns
   - Compliance implementation specifics

## Write
1. {{GSD_DIR}}\research\research-findings.md - comprehensive analysis
2. {{GSD_DIR}}\research\dependency-map.json - requirement dependency graph
3. {{GSD_DIR}}\research\pattern-analysis.md - detected and recommended patterns
4. {{GSD_DIR}}\research\tech-decisions.md - technical decisions and rationale
5. {{GSD_DIR}}\research\figma-analysis.md - detailed Figma-to-code mapping
6. UPDATE {{GSD_DIR}}\specs\figma-mapping.md with any new component mappings found

## Boundaries
- DO NOT modify source code in this phase
- DO NOT modify health/ or code-review/ files
- ONLY write to {{GSD_DIR}}\research\ and update specs\figma-mapping.md
