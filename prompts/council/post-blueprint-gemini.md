# Council: Post-Blueprint Review (Gemini)

Review the generated blueprint manifest for spec completeness.

## Context
- Iteration: {{ITERATION}} | Health: {{HEALTH}}%
- Read: {{GSD_DIR}}\blueprint\blueprint.json, specs in docs\, design\{interface}\

## Review Focus
1. Does every spec requirement have at least one blueprint item?
2. Are UI components from Figma designs represented?
3. Are API endpoints from specs fully covered (CRUD, auth, validation)?
4. Are there implied requirements (error pages, loading states, 404s) missing?
5. Is the total item count reasonable for the project scope?

## Output (max 2000 tokens)
JSON: { "vote": "approve|concern|block", "confidence": 0-100, "findings": [...], "strengths": [...], "summary": "..." }
