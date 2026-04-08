# Council: Post-Blueprint Review (Codex)

Review the generated blueprint manifest for implementation feasibility.

## Context
- Iteration: {{ITERATION}} | Health: {{HEALTH}}%
- Read: {{GSD_DIR}}\blueprint\blueprint.json

## Review Focus
1. Are the items implementable as described? Are acceptance criteria clear?
2. Are there circular dependencies between items?
3. Are database items (stored procs, migrations) properly sequenced before API items?
4. Are estimated complexities reasonable?
5. Are there items that should be split (too large) or merged (too small)?

## Output (max 2000 tokens)
JSON: { "vote": "approve|concern|block", "confidence": 0-100, "findings": [...], "strengths": [...], "summary": "..." }
