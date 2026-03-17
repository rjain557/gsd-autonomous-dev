# Phase: Deep Requirements Extraction

You are extracting GRANULAR requirements from specification documents for an EXISTING codebase.

## Rules
- Requirements come from SPECS and FIGMA only, NEVER from code
- Code is EVIDENCE of satisfaction, not a source of requirements
- Every Given/When/Then scenario = one requirement
- Every API endpoint in OpenAPI spec = one requirement
- Every stored procedure in DB plan = one requirement
- Every screen in UI contract = one requirement with its features
- Every acceptance criterion sub-item = one requirement

## Input
- Specification documents (functional requirements, non-functional requirements)
- Acceptance criteria documents (Given/When/Then scenarios)
- Phase E contracts (OpenAPI, DB plan, UI contract, test plan, CI gates)
- Figma deliverables (screen inventory, component inventory)

## Output (JSON)
```json
{
  "requirements": [
    {
      "id": "AC-EXAM-001a",
      "description": "Exam creation form with title, description, type fields",
      "interface": "web | backend | database | mcp | mcp-admin | test | devops | compliance",
      "category": "implementation | testing | infrastructure | compliance",
      "priority": "critical | high | medium | low",
      "status": "not_started",
      "source": "AC-ExamManagement.md, Scenario 1"
    }
  ],
  "total": 0,
  "by_interface": {}
}
```

## Granularity Guidelines
- Functional requirements (FR001-FR009): Decompose EACH into 5-10 sub-requirements per interface (DB, API, Web, MCP)
- Acceptance criteria: Extract EVERY bullet point, EVERY scenario as a separate requirement
- Phase E endpoints: ONE requirement per API operation
- Phase E SPs: ONE requirement per stored procedure
- UI screens: ONE requirement per screen with its specific features and states
- Tests: ONE requirement per test category
- CI gates: ONE requirement per gate

Target: 400-600 requirements for a typical full-stack project.

Respond with ONLY the JSON object. No markdown, no explanation.
