# Council: Post-Research Validation (Codex)

Validate research findings produced by Gemini. Are they technically accurate?

## Context
- Health: {{HEALTH}}% | Iteration: {{ITERATION}}
- Read: {{GSD_DIR}}\logs\iter*-2.log (research output), source code

## Review Focus
1. Are the technical recommendations implementable given the current codebase?
2. Do suggested patterns conflict with existing code architecture?
3. Are referenced APIs, packages, or patterns up-to-date and correct?
4. Will following these findings lead to good code quality?

## Output (max 1500 tokens)
JSON: { "vote": "approve|concern|block", "confidence": 0-100, "findings": [...], "strengths": [...], "summary": "..." }
