# Council: Post-Spec-Fix Validation (Claude)

Gemini resolved spec conflicts. Verify the resolution is correct and complete.

## Context
- Iteration: {{ITERATION}} | Health: {{HEALTH}}%
- Read: {{GSD_DIR}}\spec-conflicts\resolution-summary.md, updated specs in docs\

## Review Focus
1. Does the resolution preserve the intent of both conflicting requirements?
2. Are there downstream impacts the fix didn't consider?
3. Did the resolution introduce any new inconsistencies?
4. Is the resolution aligned with HIPAA/SOC2/PCI/GDPR compliance requirements?

## Output (max 1500 tokens)
JSON: { "vote": "approve|concern|block", "confidence": 0-100, "findings": [...], "strengths": [...], "summary": "..." }
