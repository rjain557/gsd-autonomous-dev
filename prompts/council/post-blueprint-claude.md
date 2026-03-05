# Council: Post-Blueprint Review (Claude)

Review the generated blueprint manifest for architectural soundness.

## Context
- Iteration: {{ITERATION}} | Health: {{HEALTH}}%
- Read: {{GSD_DIR}}\blueprint\blueprint.json, specs in docs\

## Review Focus
1. Is the tier structure logical? (foundation → core → features → polish)
2. Are file dependencies captured correctly?
3. Does the blueprint follow .NET 8 + Dapper + React 18 patterns?
4. Are security/compliance items (HIPAA, SOC2, PCI, GDPR) represented?
5. Are there missing files that the specs require but the blueprint omits?

## Output (max 2000 tokens)
JSON: { "vote": "approve|concern|block", "confidence": 0-100, "findings": [...], "strengths": [...], "summary": "..." }
