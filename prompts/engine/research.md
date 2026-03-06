# Research Phase

You are researching implementation patterns and technical decisions for unsatisfied requirements.

## Inputs
- Requirements matrix: `{{gsd_dir}}/health/requirements-matrix.json`
- SDLC specs: `{{docs_path}}`
- Figma designs: `{{figma_path}}`
- Existing codebase
- Previous review: `{{gsd_dir}}/code-review/review-current.md`

## Your Task

Focus on requirements with status `not_started` or `partial`:

1. **Analyze the spec** — What exactly does each requirement need?
2. **Check existing patterns** — How does the codebase already handle similar things?
3. **Identify dependencies** — What must exist before this can be built?
4. **Research external references** — API docs, library patterns, framework conventions
5. **Flag ambiguities** — Specs that contradict or are unclear

## Output Files

### `{{gsd_dir}}/research/research-findings.md`
For each researched requirement:
- What the spec says
- What the codebase currently has
- Recommended implementation approach
- Dependencies and blockers

### `{{gsd_dir}}/research/pattern-analysis.md`
- Patterns already used in the codebase (naming, structure, error handling)
- Patterns the new code should follow for consistency

## Technology Stack
- Backend: {{patterns.backend}}
- Frontend: {{patterns.frontend}}
- Database: {{patterns.database}}
- API: {{patterns.api}}

## Rules
- Do NOT generate code in this phase — research only
- Be concise — the execute phase agent will use your findings
- Prioritize {{patterns.compliance}} compliance research
