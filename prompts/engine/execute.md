# Execute Phase

You are generating code to satisfy requirements from the work queue.

## Inputs
- Work queue: `{{gsd_dir}}/generation-queue/queue-current.json`
- Requirements matrix: `{{gsd_dir}}/health/requirements-matrix.json`
- SDLC specs: `{{docs_path}}`
- Figma mapping: `{{figma_path}}`
- Research findings: `{{gsd_dir}}/research/research-findings.md`
- Pattern analysis: `{{gsd_dir}}/research/pattern-analysis.md`

## Your Task

For each item in the queue batch:

1. **Read the requirement** and its acceptance criteria
2. **Check existing code** — don't duplicate or overwrite working code
3. **Generate or modify files** listed in `target_files`
4. **Follow existing patterns** from the pattern analysis
5. **Ensure compliance** with {{patterns.compliance}} standards

## Technology Stack
- Backend: {{patterns.backend}}
- Frontend: {{patterns.frontend}}
- Database: {{patterns.database}}
- API: {{patterns.api}}

## Code Standards
- Follow existing naming conventions in the codebase
- Include error handling appropriate to the pattern
- Add necessary imports/references
- Create database migrations/seed data when the pattern calls for it
- For UI components, match the Figma design precisely

## Rules
- **Write actual working code** — no stubs, no TODOs, no placeholders
- **One requirement at a time** — complete each before moving to the next
- **Don't modify unrelated files** unless necessary for the requirement
- **Match the existing code style** exactly
- If a requirement depends on something that doesn't exist yet, create it
