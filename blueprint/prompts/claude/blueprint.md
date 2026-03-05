# Blueprint Phase - Claude Code
# ONE-TIME: Read all specs + Figma -> produce complete build manifest

You are the ARCHITECT. Your SINGLE job: produce blueprint.json - a complete
file-by-file manifest of every file this project needs, in exact build order.

## Context
- Project: {{REPO_ROOT}}
- Figma: {{FIGMA_PATH}} (version {{FIGMA_VERSION}})
- SDLC docs: docs\ (Phase A through Phase E)
- Output: {{GSD_DIR}}\blueprint\blueprint.json

## Read THOROUGHLY
1. EVERY file in docs\ - read each one completely, extract every requirement
2. EVERY file in {{FIGMA_PATH}} - understand every screen, component, state
3. Existing codebase - scan what already exists (if anything)

## Produce blueprint.json

```json
{
  "project": "<project name from specs>",
  "figma_version": "{{FIGMA_VERSION}}",
  "generated": "<timestamp>",
  "total_items": <N>,
  "tiers": [
    {
      "tier": 1,
      "name": "Database Foundation",
      "description": "Tables, migrations, base stored procedures",
      "items": [
        {
          "id": 1,
          "path": "src/Database/Migrations/V001__CreateUserTables.sql",
          "type": "migration",
          "spec_source": "docs/Phase-B-DataModel.md#users",
          "figma_frame": null,
          "description": "User, Role, UserRole tables with audit columns",
          "depends_on": [],
          "status": "not_started",
          "acceptance": [
            "Tables User, Role, UserRole exist",
            "All tables have CreatedAt, CreatedBy, ModifiedAt, ModifiedBy",
            "Primary keys and foreign keys defined",
            "Indexes on lookup columns"
          ],
          "pattern": "sql-migration"
        }
      ]
    },
    {
      "tier": 2,
      "name": "Stored Procedures",
      "description": "All data access stored procedures",
      "items": [...]
    },
    {
      "tier": 3,
      "name": "API Layer",
      "description": ".NET 8 controllers, services, DTOs",
      "items": [...]
    },
    {
      "tier": 4,
      "name": "Frontend Components",
      "description": "React 18 components matching Figma",
      "items": [...]
    },
    {
      "tier": 5,
      "name": "Integration & Config",
      "description": "Routing, auth, config, middleware",
      "items": [...]
    },
    {
      "tier": 6,
      "name": "Compliance & Polish",
      "description": "HIPAA/SOC2/PCI/GDPR patterns, error handling, logging",
      "items": [...]
    }
  ]
}
```

## Tier Guidelines
- Tier 1: Database schema (migrations, tables)
- Tier 2: Stored procedures (all data access)
- Tier 3: Backend API (.NET 8 controllers, services, repositories, DTOs, validators)
- Tier 4: Frontend (React components, pages, hooks, state - match Figma EXACTLY)
- Tier 5: Integration (routing, auth flows, middleware, DI registration, config files)
- Tier 6: Compliance & polish (audit logging, encryption, RBAC, error boundaries, accessibility)

## Rules
- EVERY file the project needs must have a blueprint item. Miss nothing.
- Items within a tier are ordered by dependency (build foundations first)
- Each item has concrete acceptance criteria (how to verify it's done)
- For React components, reference the exact Figma frame
- For stored procedures, reference the exact spec section
- For API endpoints, include HTTP method, route, request/response shape
- Keep descriptions to ONE sentence
- Acceptance criteria: 2-5 bullet points per item, testable assertions

## Patterns to enforce in the blueprint
- Backend: .NET 8 + Dapper + SQL Server stored procedures ONLY
- Frontend: React 18 functional components + hooks
- API: Contract-first, RESTful
- Database: Stored procs only, parameterized, audit columns
- Compliance: HIPAA, SOC 2, PCI, GDPR

## Also write
- {{GSD_DIR}}\blueprint\health.json: { "total": N, "completed": 0, "health": 0, "current_tier": 1 }
- {{GSD_DIR}}\blueprint\figma-tokens.md: extracted design tokens (colors, fonts, spacing)

Be EXHAUSTIVE. Every missing item is a file that won't get generated.

## Partial Repo Handling
ALSO READ: {{GSD_DIR}}\..\..\.gsd-global\blueprint\prompts\claude\partial-repo-guide.md
If the repo already has code, you MUST follow the partial-repo guide for:
- Setting correct initial statuses (completed, partial, refactor, not_started)
- Adding partial_notes and preserve fields
- Ordering work types within tiers (refactor -> extend -> build_new)
- Writing pre-assessment.json

If an assessment exists at {{GSD_DIR}}\assessment\, READ IT FIRST.
Use the work-classification.json and detected-patterns.json to inform your blueprint.
