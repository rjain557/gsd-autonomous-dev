# Blueprint Phase - Claude Code (Figma Make Edition)
# Reads Figma Make _analysis/ deliverables as PRIMARY specification source

You are the ARCHITECT. Produce blueprint.json from specs, Figma Make analysis, and stubs.

## Context
- Project: {{REPO_ROOT}}
- SDLC docs: docs\ (Phase A through Phase E)
- Output: {{GSD_DIR}}\blueprint\blueprint.json

{{INTERFACE_CONTEXT}}

## CRITICAL: Figma Make _analysis/ Is Your Primary Spec

For each interface that has _analysis/ deliverables, these are MACHINE-READABLE,
EXHAUSTIVE specifications. They are MORE RELIABLE than raw design files because
they contain exact values, complete type definitions, and API contracts.

### Reading Priority (highest to lowest):
1. **_analysis/ deliverables** - screen inventory, components, design system, API contracts,
   types, hooks, storyboards, state matrix, implementation guide
2. **_stubs/ files** - controller stubs, DTO stubs, SQL table/SP/seed scripts
3. **docs\ SDLC specs** - business logic, compliance, architecture decisions
4. **Raw design files** - only if _analysis/ is incomplete

### How to Use Each Deliverable:

| Deliverable | Blueprint Use |
|---|---|
| 01-screen-inventory.md | One blueprint item per screen (React component) |
| 02-component-inventory.md | One blueprint item per reusable component |
| 03-design-system.md | Extract as figma-tokens.md - Codex references for exact values |
| 04-navigation-routing.md | Blueprint items for routing config, nav components, guards |
| 05-data-types.md | Blueprint items for TypeScript type files |
| 06-api-contracts.md | Blueprint items for .NET controllers + services per endpoint group |
| 07-hooks-state.md | Blueprint items for each custom hook (real API version) |
| 08-mock-data-catalog.md | Blueprint items for seed data SQL matching mock data exactly |
| 09-storyboards.md | Validation criteria - each flow must work end-to-end |
| 10-screen-state-matrix.md | Blueprint items for loading/error/empty states per screen |
| 11-api-to-sp-map.md | Blueprint items for stored procedures, maps controller->SP->table |
| 12-implementation-guide.md | Use the build order directly as your tier structure |

### If _stubs/ Exist:
The stubs are STARTING POINTS, not final code. Blueprint items that have stubs should:
- Set status to "partial" (stub exists but needs implementation)
- Reference the stub file as existing_file
- Set work_type to "extend" (fill in the stub bodies)

## Produce blueprint.json

Use the implementation guide (D12) build order as your tier structure.
Each tier maps to a phase from the guide.

For EACH interface detected, prefix items with the interface key:
- Blueprint item IDs: web-001, mcp-001, browser-001, mobile-001, agent-001
- File paths include the interface context: src\Web\..., src\MCP\..., etc.

### Multi-Interface Shared Components
Some items are shared across interfaces:
- Database tables and stored procedures (shared backend)
- DTOs and service layer (shared backend)
- Type definitions may be shared

These get their own tier (Tier 0: Shared Backend) with no interface prefix.

```json
{
  "project": "...",
  "interfaces": ["web", "mcp", "browser"],
  "tiers": [
    {
      "tier": 0,
      "name": "Shared Backend",
      "description": "Database, stored procedures, services shared by all interfaces",
      "items": [...]
    },
    {
      "tier": 1,
      "name": "Database Foundation",
      "interface": "shared",
      "items": [
        {
          "id": "shared-001",
          "path": "src/Database/Migrations/V001__CreateTables.sql",
          "type": "migration",
          "spec_source": "design/web/v03/_analysis/05-data-types.md",
          "stub_source": "design/web/v03/_stubs/database/01-tables.sql",
          "status": "partial",
          "work_type": "extend",
          "existing_file": "design/web/v03/_stubs/database/01-tables.sql",
          "description": "Create all tables from type definitions",
          "acceptance": ["All entities from 05-data-types.md have corresponding tables", "Audit columns on every table", "Foreign keys match data relationship diagram"]
        }
      ]
    },
    {
      "tier": 3,
      "name": "Web Frontend Components",
      "interface": "web",
      "items": [
        {
          "id": "web-042",
          "path": "src/Web/ClientApp/src/components/Dashboard/CardGrid.tsx",
          "type": "react-component",
          "spec_source": "design/web/v03/_analysis/02-component-inventory.md#CardGrid",
          "figma_states": "design/web/v03/_analysis/10-screen-state-matrix.md#Dashboard",
          "design_tokens": "design/web/v03/_analysis/03-design-system.md",
          "description": "Dashboard card grid with responsive breakpoints",
          "acceptance": [
            "Matches component inventory: props interface, all states rendered",
            "Responsive breakpoints from design system",
            "Loading skeleton matches state matrix",
            "Colors/spacing/typography from design tokens"
          ]
        }
      ]
    }
  ]
}
```

## Also Write
- {{GSD_DIR}}\blueprint\health.json
- {{GSD_DIR}}\blueprint\figma-tokens.md (extracted from 03-design-system.md for each interface)
- {{GSD_DIR}}\blueprint\interface-map.json (which interfaces exist, their versions, analysis status)

Be EXHAUSTIVE. Cross-reference every screen in 01-screen-inventory with every
component in 02-component-inventory with every API call in 06-api-contracts
with every stored procedure in 11-api-to-sp-map. Nothing should be missed.
