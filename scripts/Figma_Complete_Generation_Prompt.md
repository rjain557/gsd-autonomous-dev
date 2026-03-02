# Figma Make Prompt — Post-Prototype Deliverable Generation (GSD Engine Compatible)

**Purpose:** Run this prompt in Figma Make AFTER your frontend prototype is complete. It analyzes the existing prototype and generates all the documentation, stubs, and artifacts that the GSD Engine and AI coding agents (Claude Code, Codex, Cursor, etc.) need to build the full application matching the prototype exactly.

**Assumptions:**
- The frontend prototype already exists and is functional in Figma Make
- No backend, database, or storyboard folders exist yet
- The AI coding agent has never seen this prototype before

**How to use:**
1. Build your frontend prototype in Figma Make (screens, navigation, components, mock data)
2. Copy the prompt between `---START---` and `---END---` into a new Figma Make prompt
3. Run it — Figma Make will analyze the existing prototype and generate all deliverables
4. Export the generated files and place them in your project under `design\web\v##\src\`
5. Run `gsd-assess` — the engine will detect all deliverables automatically

**GSD Engine Integration:**
The GSD Engine auto-discovers the `_analysis/` and `_stubs/` folders wherever they are under your design version directory. It checks for exactly 12 analysis files (numbered 01-12) and validates stubs by pattern matching. All 12 analysis files must be present for the engine to report 12/12 deliverables.

---

---START---

```
You are analyzing an existing Figma Make frontend prototype and generating a complete set of deliverables that an AI coding agent will use to build the full production application. The AI agent has NEVER seen this prototype — your output is its ONLY reference for understanding the UI, data, flows, and architecture.

DO NOT modify any existing screens, components, or files. You are ONLY generating new documentation and stub files by analyzing what already exists.

## YOUR TASK

Analyze every screen, component, route, type, hook, mock data shape, and interaction pattern in the existing prototype. Then generate ALL deliverables listed below. Be exhaustive — anything you omit, the AI agent will not know about.

You MUST generate all 12 analysis files and all stubs. Do not skip any deliverable.

---

## ANALYSIS DELIVERABLES (12 files — all required)

These go in the `_analysis/` folder. The GSD Engine validates all 12 by filename.

---

### FILE 1: `_analysis/01-screen-inventory.md`

Create a complete inventory of every screen in the prototype.

For EACH screen, document:

#### Screen: [Screen Name]
- **File path:** `components/screens/[filename].tsx`
- **Route:** `/path`
- **Layout type:** (e.g., 3-panel, single-column, grid, form, dashboard, wizard)
- **Panel breakdown:** (if multi-panel: panel names, widths, flex behavior, collapse rules)
- **Page header:** (title, subtitle, breadcrumb pattern, action buttons)
- **Sections:** List every distinct visual section from top to bottom, left to right
- **Interactive elements:** Every button, link, dropdown, toggle, tab, input, slider — with their labels and actions
- **Data displayed:** Every piece of data shown on screen (field name, format, source)
- **RBAC:** Which user roles can access this screen
- **Responsive behavior:** What changes at tablet (<1024px) and mobile (<768px) breakpoints

Also generate a summary table:

| # | Screen | Route | Layout | Auth Required | Roles |
|---|--------|-------|--------|---------------|-------|
| 1 | ... | ... | ... | ... | ... |

---

### FILE 2: `_analysis/02-component-inventory.md`

List every reusable component and screen-specific component in the prototype.

For EACH component, document:

#### Component: [ComponentName]
- **File path:** `components/[path]/[filename].tsx`
- **Purpose:** One-line description
- **Props interface:** Full TypeScript interface with types and descriptions
- **Internal state:** Any useState/useReducer state variables
- **Children components:** What it renders inside
- **External dependencies:** UI library components used (e.g., Fluent UI Dropdown, Radix Dialog)
- **Events emitted:** Callbacks passed up to parent
- **Variants:** Different visual modes (e.g., compact, expanded, skeleton)
- **States rendered:**
  | State | Visual Description |
  |-------|-------------------|
  | Default | ... |
  | Loading | ... |
  | Error | ... |
  | Empty | ... |
  | Disabled | ... |
  | Active/Selected | ... |

---

### FILE 3: `_analysis/03-design-system.md`

Extract the complete design system from the prototype.

#### Colors
Document every color used with CSS variable names and hex values:
- Primary palette (50 through 900)
- Neutral palette (50 through 900)
- Semantic colors (success, warning, danger, info — each with 50 through 900)
- Surface colors (backgrounds, cards, overlays)
- Text colors (primary, secondary, disabled, inverse)

#### Typography
- Font family stack
- Font sizes with use cases (body, label, heading 1-4, caption, overline)
- Font weights with use cases
- Line heights

#### Spacing
- Base grid unit
- Spacing scale with use cases (component padding, section gaps, page margins)

#### Border & Radius
- Border colors and widths
- Radius values with use cases (buttons, cards, inputs, pills, avatars)

#### Elevation / Shadows
- Shadow levels with use cases (cards, dropdowns, modals, popovers)

#### Motion
- Transition duration
- Easing curves
- Specific animations (loading pulse, skeleton shimmer, expand/collapse)

#### Icons
- Icon library used
- Icon sizes (sm, md, lg)
- Icon color rules

#### Component Tokens
For each base component (Button, Input, Card, Badge, etc.):
- Height, padding, font-size, border-radius at each size variant
- Color mappings for each tone variant (primary, neutral, success, etc.)
- State colors (hover, active, focus, disabled)

---

### FILE 4: `_analysis/04-navigation-routing.md`

Document the complete navigation and routing structure.

#### Navigation Structure
Reproduce the exact navigation tree as it appears in the sidebar/header:
```
- Item 1 (icon, route)
  - Child 1 (icon, route)
  - Child 2 (icon, route)
- Item 2 (icon, route)
...
```

#### Route Table
| Route | Screen Component | Auth | Role Guard | Parent Layout | Query Params | Notes |
|-------|-----------------|------|------------|---------------|--------------|-------|
| / | ... | ... | ... | ... | ... | ... |

#### Navigation Behavior
- Default route after login
- Route when unauthorized (403 behavior)
- Sidebar collapse behavior
- Active state indication (how is current route highlighted?)
- Mobile navigation pattern (bottom sheet, hamburger, etc.)
- Breadcrumb generation rules

#### Deep Linking
- Which screens support deep linking via URL params?
- What URL params does each screen accept?

---

### FILE 5: `_analysis/05-data-types.md`

Extract every TypeScript type and interface from the prototype.

For EACH type file, generate the complete TypeScript:

```typescript
// [filename].ts — [Description of what these types represent]

export interface EntityName {
  id: string;
  // ... every field with type and JSDoc comment explaining what it is
}

export type EnumName = 'value1' | 'value2' | 'value3';
```

Also generate a **Data Relationship Diagram** showing how entities relate:
```
User --< TenantAssignment >-- Tenant
Tenant --< Project
Project --< ProjectChat >-- ChatThread
...
```

And a **Field Format Reference** for any specially-formatted fields:
| Entity.Field | Format | Example |
|-------------|--------|---------|
| User.email | email | user@example.com |
| BillingRecord.amount | currency USD | $1,234.56 |
| AuditLog.timestamp | ISO 8601 | 2026-02-09T14:30:00Z |

---

### FILE 6: `_analysis/06-api-contracts.md`

Document every API call the frontend makes (from hooks, api client, or direct fetch calls).

For EACH endpoint:

#### `METHOD /api/path`
- **Called from:** Hook or component that calls this
- **Purpose:** What this endpoint does
- **Auth:** Bearer JWT required? Tenant header required?
- **Path params:** `{ paramName: type }` with description
- **Query params:** `{ paramName: type }` with description
- **Request body:**
```json
{
  "field": "type — description"
}
```
- **Response body (success):**
```json
{
  "field": "type — description"
}
```
- **Error responses:**
  - 400: When/why
  - 401: Unauthorized
  - 403: Forbidden (role check)
  - 404: Not found
  - 429: Rate limited
- **SSE/Streaming:** If this is a streaming endpoint, document the event format

Also generate a summary table:

| # | Method | Path | Purpose | Auth | Streaming |
|---|--------|------|---------|------|-----------|
| 1 | GET | /api/... | ... | Yes | No |

---

### FILE 7: `_analysis/07-hooks-state.md`

Document every custom hook in the prototype.

For EACH hook:

#### `useHookName(params)`
- **File:** `hooks/useHookName.ts`
- **Purpose:** What state/behavior this manages
- **Parameters:** Input params with types
- **Returns:**
```typescript
{
  data: Type;           // Description
  isLoading: boolean;   // Description
  error: Error | null;  // Description
  mutate: (args) => void; // Description
  // ... every returned value
}
```
- **API calls made:** Which endpoints this hook calls
- **Side effects:** Timers, event listeners, subscriptions
- **Mock data:** Summary of what mock data this hook returns (or reference to mock data section)

---

### FILE 8: `_analysis/08-mock-data-catalog.md`

Document ALL mock data in the prototype with exact shapes and values.

For EACH mock data set:

#### Mock: [Entity Name]
- **Location:** File path where mock data is defined
- **Count:** Number of mock records
- **Shape matches type:** `types/[file].ts` -> `InterfaceName`
- **Sample record:**
```json
{
  // One complete record with realistic values
}
```
- **All records summary:**
| ID | Key fields... | Notes |
|----|--------------|-------|
| 1 | ... | ... |

- **Relationships:** How this mock data connects to other mock data (foreign keys, references)

#### Data Consistency Rules
- List any IDs that must match across mock data sets
- List any enum values that must be consistent
- List any calculated fields (e.g., totalCost = sum of line items)

---

### FILE 9: `_analysis/09-storyboards.md`

Document every user flow through the application.

For EACH major feature, create a numbered storyboard:

#### Flow: [Flow Name]
**Actor:** [User role]
**Goal:** [What the user is trying to accomplish]
**Preconditions:** [What must be true before this flow starts]

| Step | User Action | System Response | Screen State | Data Changed |
|------|-------------|-----------------|--------------|--------------|
| 1 | User clicks... | Screen shows... | [state name] | [entity.field] |
| 2 | User types... | Field validates... | ... | ... |
| 3 | User submits... | API call fires... | Loading | ... |
| 4 | ... | ... | Success/Error | ... |

**Happy path result:** [What happens when everything works]
**Error paths:**
- If [condition]: [what happens]
- If [condition]: [what happens]

Generate flows for at minimum:
1. First-time user experience (onboarding)
2. Every CRUD operation on every entity
3. Every navigation path
4. Authentication and role-switching
5. Error recovery flows
6. Empty state -> populated state transitions

---

### FILE 10: `_analysis/10-screen-state-matrix.md`

Create a comprehensive matrix of every screen crossed with every possible state.

| Screen | Default | Loading | Empty | Error | Forbidden (403) | Rate Limited (429) | Streaming | Saving | Notes |
|--------|---------|---------|-------|-------|-----------------|-------------------|-----------|--------|-------|
| [Screen 1] | Describe what user sees | Skeleton/spinner details | Empty message + CTA | Error message + retry | Access denied card | Cooldown timer | If applicable | If applicable | |
| [Screen 2] | ... | ... | ... | ... | ... | ... | ... | ... | |

For each cell, describe:
- What the user sees visually
- What interactions are available
- What the next possible state transitions are

---

### FILE 11: `_analysis/11-api-to-sp-map.md`

Create a mapping table connecting frontend -> API -> stored procedure -> database table.

This is the end-to-end traceability map that the GSD Engine uses to verify every layer is connected.

| Frontend Hook/Call | HTTP Method | API Route | Controller.Method | Stored Procedure | Tables Read | Tables Written | Notes |
|-------------------|-------------|-----------|-------------------|-----------------|-------------|---------------|-------|
| useEntity().getAll | GET | /api/entity | EntityController.GetAll | usp_Entity_GetAll | Entity | - | Paginated |
| useEntity().create | POST | /api/entity | EntityController.Create | usp_Entity_Create | - | Entity | Returns new ID |

Every API endpoint from File 6 MUST appear in this table. Every stored procedure from the stubs MUST appear here. Every table from the database stubs MUST be referenced. No orphans.

---

### FILE 12: `_analysis/12-implementation-guide.md`

Generate a prioritized implementation guide for the AI coding agent.

#### Build Order
List the recommended order to build the full application, based on dependencies:

| Phase | What to Build | Depends On | Deliverables to Reference |
|-------|--------------|------------|--------------------------|
| 1 | Database tables and seed data | Nothing | 01-tables.sql, 03-seed-data.sql |
| 2 | Stored procedures | Phase 1 | 02-stored-procedures.sql, 11-api-to-sp-map.md |
| 3 | Backend DTOs | Nothing | Models/*.cs |
| 4 | Backend controllers + services | Phase 2, 3 | Controllers/*.cs, 11-api-to-sp-map.md |
| 5 | Frontend API client (real endpoints) | Phase 4 | 06-api-contracts.md |
| 6 | Frontend hooks (swap mock -> real) | Phase 5 | 07-hooks-state.md |
| 7 | Integration testing | Phase 6 | 09-storyboards.md |

#### Architecture Decisions to Preserve
List any architectural patterns observed in the prototype that the backend must follow:
- Authentication pattern (JWT, session, etc.)
- Multi-tenancy pattern (header, URL, claim)
- State management approach (hooks, context, store)
- Error handling pattern
- Loading state pattern

#### Design Fidelity Checklist
List specific visual details the AI agent must match exactly:
- Exact pixel dimensions for layouts, panels, headers
- Exact color values for every element type
- Exact spacing between elements
- Exact typography for every text element
- Animation/transition details
- Icon choices and sizes
- Border styles and radii

---

## STUB DELIVERABLES (backend + database)

These go in the `_stubs/` folder. The GSD Engine pattern-matches controllers, DTOs, and SQL files.

---

### STUBS A: `_stubs/backend/Controllers/[Entity]Controller.cs`

For EACH API endpoint group identified in File 6, generate a .NET 8 Web API controller stub.

Requirements:
- Use `[ApiController]` and `[Route("api/[route]")]` attributes
- Include `[HttpGet]`, `[HttpPost]`, `[HttpPut]`, `[HttpDelete]` action methods
- Method signatures only (body returns `NotImplemented()`)
- Parameter types match the TypeScript types from File 5
- Include `[FromBody]`, `[FromQuery]`, `[FromRoute]` annotations
- Include XML doc comments describing what each endpoint does
- Group related endpoints into logical controllers

Example pattern:
```csharp
[ApiController]
[Route("api/tenants/{tenantId}/[entity]")]
public class EntityController : ControllerBase
{
    /// <summary>Get all entities for tenant</summary>
    [HttpGet]
    public Task<ActionResult<List<EntityDto>>> GetAll(string tenantId)
        => Task.FromResult<ActionResult<List<EntityDto>>>(StatusCode(501));
}
```

---

### STUBS B: `_stubs/backend/Models/[Entity]DTOs.cs`

Generate C# DTO classes matching every TypeScript interface from File 5.

Requirements:
- One file per entity group
- Request DTOs (for POST/PUT bodies)
- Response DTOs (for GET responses)
- Use `System.Text.Json` serialization attributes where needed
- Include data annotations (`[Required]`, `[StringLength]`, `[Range]`)
- Property names in PascalCase (C# convention) with `[JsonPropertyName("camelCase")]`

---

### STUBS C: `_stubs/database/01-tables.sql`

Generate SQL Server CREATE TABLE statements for every entity type from File 5.

Requirements:
- SQL Server syntax (NVARCHAR, DATETIME2, BIT, DECIMAL, etc.)
- Primary keys (NVARCHAR(50) for IDs, or INT IDENTITY)
- Foreign key constraints
- NOT NULL constraints where appropriate
- DEFAULT values where the mock data suggests defaults
- CreatedAt/UpdatedAt audit columns on every table
- TenantId column on every tenant-scoped table
- Indexes on foreign keys and frequently-filtered columns

---

### STUBS D: `_stubs/database/02-stored-procedures.sql`

Generate stored procedure stubs for every API endpoint from File 6.

Requirements:
- SP-Only pattern: every API endpoint maps to exactly one stored procedure
- Naming convention: `usp_[Entity]_[Operation]` (e.g., `usp_Project_GetAll`, `usp_Project_Create`)
- Parameters match the DTO fields
- Include TenantId parameter for tenant-scoped operations
- Body contains only a comment describing what the SP should do
- Include TRY/CATCH error handling skeleton
- Include OUTPUT parameter for identity returns on INSERT operations

Example pattern:
```sql
CREATE PROCEDURE usp_Entity_GetAll
    @TenantId NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        -- TODO: SELECT all entities for tenant
        -- Returns: EntityDto columns
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO
```

---

### STUBS E: `_stubs/database/03-seed-data.sql`

Generate INSERT statements that reproduce the exact mock data from the prototype.

Requirements:
- Data must match the mock data from File 8 exactly
- Foreign key references must be consistent
- Use MERGE or IF NOT EXISTS pattern to be idempotent
- Include comments grouping seed data by entity
- Dates should use realistic recent timestamps

---

## OUTPUT STRUCTURE

Generate all files in this exact folder structure:

```
_analysis/
  01-screen-inventory.md          (File 1)
  02-component-inventory.md       (File 2)
  03-design-system.md             (File 3)
  04-navigation-routing.md        (File 4)
  05-data-types.md                (File 5)
  06-api-contracts.md             (File 6)
  07-hooks-state.md               (File 7)
  08-mock-data-catalog.md         (File 8)
  09-storyboards.md               (File 9)
  10-screen-state-matrix.md       (File 10)
  11-api-to-sp-map.md             (File 11)
  12-implementation-guide.md      (File 12)

_stubs/
  backend/
    Controllers/
      [Entity]Controller.cs       (Stubs A — one per entity group)
    Models/
      [Entity]DTOs.cs             (Stubs B — one per entity group)
  database/
    01-tables.sql                 (Stubs C)
    02-stored-procedures.sql      (Stubs D)
    03-seed-data.sql              (Stubs E)
```

Total: 12 analysis documents + N controller stubs + N DTO files + 3 database scripts.

ALL 12 ANALYSIS FILES ARE REQUIRED. Do not skip any. The GSD Engine validates the presence of all 12 by exact filename.

---

## QUALITY RULES

1. **Exhaustive:** If something exists in the prototype, it MUST appear in the deliverables. The AI agent builds from YOUR output only.
2. **Exact:** Use exact values (colors, sizes, spacing) — not approximations. Copy hex codes, pixel values, and text labels verbatim.
3. **Consistent:** IDs, type names, and field names must be identical across all deliverables. If the type is called `Project` in File 5, it must be `Project` in File 6, File 11, the controllers, DTOs, tables, stored procedures, and the API-to-SP map.
4. **Complete code:** All TypeScript in File 5 and C# in the stubs must be syntactically valid and complete. All SQL must be valid SQL Server syntax.
5. **No assumptions:** Do not invent features, screens, or data that don't exist in the prototype. Document only what IS there.
6. **Mock data fidelity:** The seed data must produce exactly the same data the prototype displays. An AI agent building the app from your deliverables should produce screens that are pixel-identical to the prototype.

---

## CROSS-REFERENCE VALIDATION

Before outputting, verify these cross-references are complete:

### Forward traceability (nothing orphaned)
- [ ] Every screen in the prototype appears in `01-screen-inventory.md`
- [ ] Every component appears in `02-component-inventory.md`
- [ ] Every color/font/spacing value appears in `03-design-system.md`
- [ ] Every route appears in `04-navigation-routing.md`
- [ ] Every TypeScript type/interface appears in `05-data-types.md`
- [ ] Every API call appears in `06-api-contracts.md`
- [ ] Every custom hook appears in `07-hooks-state.md`
- [ ] Every mock data record appears in `08-mock-data-catalog.md`
- [ ] Every user flow appears in `09-storyboards.md`
- [ ] Every screen x state combination appears in `10-screen-state-matrix.md`
- [ ] Every API endpoint has a row in `11-api-to-sp-map.md`
- [ ] The build order in `12-implementation-guide.md` references all other files

### Backward traceability (nothing missing downstream)
- [ ] Every API endpoint in File 6 has a controller in `_stubs/backend/Controllers/`
- [ ] Every TypeScript interface in File 5 has a DTO in `_stubs/backend/Models/`
- [ ] Every entity in File 5 has a table in `_stubs/database/01-tables.sql`
- [ ] Every API endpoint in File 6 has a stored procedure in `_stubs/database/02-stored-procedures.sql`
- [ ] Every mock record in File 8 has a seed INSERT in `_stubs/database/03-seed-data.sql`
- [ ] Every row in `11-api-to-sp-map.md` connects a real hook -> endpoint -> SP -> table

### Consistency checks
- [ ] Entity names are identical across all 12 analysis files and all stubs
- [ ] Field names match between TypeScript types, C# DTOs, and SQL columns
- [ ] Route paths match between screen inventory, navigation, and API contracts
- [ ] Mock data IDs match between the catalog, seed data, and foreign key references
```

---END---

## Notes for Users

### What this prompt does NOT do
- It does not modify your existing prototype
- It does not generate frontend code (that already exists in the prototype)
- It does not make design decisions — it documents decisions already made in the prototype

### What to do with the output
1. Export all generated files from Figma Make
2. Place the `_analysis/` and `_stubs/` folders in your design version directory (e.g., `design\web\v8\src\`)
3. Run the GSD Engine:

```powershell
cd C:\path\to\your\repo
gsd-assess              # Detects interfaces, generates file map, runs assessment
gsd-blueprint           # Generates code from specs to 100% health
```

The engine will detect all 12 analysis files and report `_analysis/ (12/12 deliverables)`.

### GSD Engine Expected Filenames
The engine checks for these exact filenames in `_analysis/`:

| # | Filename | Key | What the Engine Uses It For |
|---|----------|-----|---------------------------|
| 1 | `01-screen-inventory.md` | screens | Blueprint item generation, screen-level work items |
| 2 | `02-component-inventory.md` | components | Component-level work items, dependency ordering |
| 3 | `03-design-system.md` | design_system | Design token validation, style consistency |
| 4 | `04-navigation-routing.md` | navigation | Route scaffolding, navigation component generation |
| 5 | `05-data-types.md` | types | Type generation, DTO mapping, schema validation |
| 6 | `06-api-contracts.md` | api | Controller scaffolding, endpoint verification |
| 7 | `07-hooks-state.md` | hooks | Hook generation, state management wiring |
| 8 | `08-mock-data-catalog.md` | mock_data | Seed data validation, test data generation |
| 9 | `09-storyboards.md` | storyboards | Storyboard-aware verification, flow testing |
| 10 | `10-screen-state-matrix.md` | states | State coverage verification, edge case detection |
| 11 | `11-api-to-sp-map.md` | api_sp_map | End-to-end traceability, layer connectivity check |
| 12 | `12-implementation-guide.md` | impl_guide | Build ordering, architecture constraint enforcement |

### Customization
- If your project uses a different backend (e.g., Node.js, Python), modify the stub sections to generate Express routes / FastAPI endpoints instead of .NET controllers
- If your project uses a different database (e.g., PostgreSQL), modify the database stubs for that SQL dialect
- The 12 analysis documents (Files 1-12) are stack-agnostic and should always be generated regardless of backend technology
