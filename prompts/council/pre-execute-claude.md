# Council: Pre-Execute Plan Review (Claude)

Review the execution plan BEFORE code generation begins. Catch bad plans early.

## Context
- Health: {{HEALTH}}% | Iteration: {{ITERATION}}
- Read: {{GSD_DIR}}\generation-queue\queue-current.json, {{GSD_DIR}}\agent-handoff\current-assignment.md

## Review Focus
1. Is the batch size appropriate? Too many items risks quality; too few wastes iterations.
2. Are item dependencies ordered correctly? (e.g., models before controllers, DB before API)
3. Are acceptance criteria clear enough for the execute agent to implement?
4. Does the plan address the highest-priority drift items?

## Output (max 1500 tokens)
JSON: { "vote": "approve|concern|block", "confidence": 0-100, "findings": [...], "strengths": [...], "summary": "..." }
