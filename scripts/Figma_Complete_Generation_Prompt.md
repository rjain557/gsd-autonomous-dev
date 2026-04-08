# Figma Make Prompt — Post-Prototype Deliverable Generation (GSD Engine Compatible)

**Purpose:** Run this prompt in Figma Make AFTER your frontend prototype is complete. It analyzes the existing prototype and generates all the documentation, stubs, and artifacts that the GSD Engine and AI coding agents (Claude Code, Codex, Cursor, etc.) need to build the full application matching the prototype exactly.

**Assumptions:**
- The frontend prototype already exists and is functional in Figma Make
- No backend, database, or storyboard folders exist yet
- The AI coding agent has never seen this prototype before

**How to use:**
1. Build your frontend prototype in Figma Make (screens, navigation, components, mock data)
2. Copy the prompt between `---START---` and `---END---` into a new Figma Make prompt
3. Run it — Figma Make will process one subtask at a time
4. Review each subtask's output, then type **"proceed"** to move to the next subtask
5. After all subtasks complete, export the generated files and place them in your project under `design\web\v##\src\`
6. Run `gsd-assess` — the engine will detect all deliverables automatically

**GSD Engine Integration:**
The GSD Engine auto-discovers the `_analysis/` and `_stubs/` folders wherever they are under your design version directory. It checks for exactly 12 analysis files (numbered 01-12) and validates stubs by pattern matching. All 12 analysis files must be present for the engine to report 12/12 deliverables.

**Subtask Breakdown:**
The prompt is divided into 27 subtasks (1 deliverable per subtask) to avoid context limits on large portals:

| Subtask | Deliverable | Description |
|---------|------------|-------------|
| 1 | 01-screen-inventory.md | Screen Inventory |
| 2 | 02-component-inventory.md (shared/layout) | Shared & Layout Components |
| 3 | 02-component-inventory.md (feature) | Feature-Specific Components |
| 4 | 03-design-system.md (colors & typography) | Colors & Typography Tokens |
| 5 | 03-design-system.md (spacing, borders, elevation, motion, icons) | Spacing, Borders, Elevation, Motion & Icons |
| 6 | 03-design-system.md (component tokens) | Per-Component Design Tokens |
| 7 | 04-navigation-routing.md | Navigation & Routing |
| 8 | 05-data-types.md (core entities) | Core Entity Types |
| 9 | 05-data-types.md (supporting entities, enums, relationships) | Supporting Types, Enums & Relationships |
| 10 | 06-api-contracts.md (GET endpoints) | API Contracts — Read Operations |
| 11 | 06-api-contracts.md (POST/PUT/DELETE endpoints) | API Contracts — Write Operations |
| 12 | 07-hooks-state.md (data fetching) | Data Fetching Hooks |
| 13 | 07-hooks-state.md (mutations & utilities) | Mutation & Utility Hooks |
| 14 | 08-mock-data-catalog.md (core entities) | Mock Data — Core Entities |
| 15 | 08-mock-data-catalog.md (supporting entities & rules) | Mock Data — Supporting Entities & Consistency Rules |
| 16 | 09-storyboards.md (auth & onboarding) | Storyboards — Auth & Onboarding Flows |
| 17 | 09-storyboards.md (primary CRUD) | Storyboards — Primary CRUD Flows |
| 18 | 09-storyboards.md (secondary & error flows) | Storyboards — Secondary, Navigation & Error Flows |
| 19 | 10-screen-state-matrix.md | Screen State Matrix |
| 20 | 11-api-to-sp-map.md | API-to-SP Traceability Map |
| 21 | 12-implementation-guide.md | Implementation Guide |
| 22 | Controllers (group A) | Controller Stubs — First Half of Entities |
| 23 | Controllers (group B) | Controller Stubs — Second Half of Entities |
| 24 | DTOs (group A) | DTO Stubs — First Half of Entities |
| 25 | DTOs (group B) | DTO Stubs — Second Half of Entities |
| 26 | 01-tables.sql | Database Table Definitions |
| 27 | 02-stored-procedures.sql (read SPs) | Stored Procedures — Read Operations |
| 28 | 02-stored-procedures.sql (write SPs) | Stored Procedures — Write Operations |
| 29 | 03-seed-data.sql (core entities) | Seed Data — Core Entities |
| 30 | 03-seed-data.sql (supporting entities) | Seed Data — Supporting Entities |
| 31 | Cross-Reference Validation | Full Traceability & Consistency Check |

---

---START---

```
You are analyzing an existing Figma Make frontend prototype and generating a complete set of deliverables that an AI coding agent will use to build the full production application. The AI agent has NEVER seen this prototype — your output is its ONLY reference for understanding the UI, data, flows, and architecture.

DO NOT modify any existing screens, components, or files. You are ONLY generating new documentation and stub files by analyzing what already exists.

---

## IMPORTANT: SUBTASK WORKFLOW

This prompt is divided into **31 subtasks**. Each subtask generates exactly ONE file or one section of a file. You will complete ONE subtask at a time.

**Workflow:**
1. Start with **Subtask 1** immediately
2. After completing each subtask, output:
   ```
   ✅ SUBTASK [N] of 31 COMPLETE
   Generated: [file or section created]
   
   📋 Next: Subtask [N+1] — [description]
   Type "proceed" to continue.
   ```
3. WAIT for the user to type **"proceed"** before starting the next subtask
4. Do NOT generate any deliverables from future subtasks until the user says "proceed"
5. Each subtask should reference outputs from previous subtasks to maintain consistency

**If the user types "proceed all"** — complete all remaining subtasks without pausing.
**If the user types "proceed 5"** — complete the next 5 subtasks without pausing (replace 5 with any number).
**If the user types "redo"** — regenerate the current subtask from scratch.
**If the user types "skip"** — skip the current subtask and move to the next one.

---

## QUALITY RULES (apply to ALL subtasks)

1. **Exhaustive:** If something exists in the prototype, it MUST appear in the deliverables. The AI agent builds from YOUR output only.
2. **Exact:** Use exact values (colors, sizes, spacing) — not approximations. Copy hex codes, pixel values, and text labels verbatim.
3. **Consistent:** IDs, type names, and field names must be identical across all deliverables. If the type is called `Project` in File 5, it must be `Project` in File 6, File 11, the controllers, DTOs, tables, stored procedures, and the API-to-SP map.
4. **Complete code:** All TypeScript in File 5 and C# in the stubs must be syntactically valid and complete. All SQL must be valid SQL Server syntax.
5. **No assumptions:** Do not invent features, screens, or data that don't exist in the prototype. Document only what IS there.
6. **Mock data fidelity:** The seed data must produce exactly the same data the prototype displays. An AI agent building the app from your deliverables should produce screens that are pixel-identical to the prototype.

---

## SPLITTING RULE FOR LARGE PORTALS

Some subtasks generate "Group A" and "Group B" splits. Before starting those subtasks:
1. Count the total entities/endpoints from previous deliverables
2. Split them alphabetically at the midpoint into Group A (first half) and Group B (second half)
3. State the split at the top of each subtask output so the user can verify

If the prototype has MORE than 20 screens, MORE than 30 components, or MORE than 25 API endpoints, you MUST further subdivide:
- Split into thirds (A, B, C) instead of halves
- Announce the split breakdown before generating
- Each split should target ~8-12 items maximum

---

## OUTPUT FOLDER STRUCTURE (for reference across all subtasks)

```
_analysis/
  01-screen-inventory.md          (Subtask 1)
  02-component-inventory.md       (Subtasks 2-3, append)
  03-design-system.md             (Subtasks 4-6, append)
  04-navigation-routing.md        (Subtask 7)
  05-data-types.md                (Subtasks 8-9, append)
  06-api-contracts.md             (Subtasks 10-11, append)
  07-hooks-state.md               (Subtasks 12-13, append)
  08-mock-data-catalog.md         (Subtasks 14-15, append)
  09-storyboards.md               (Subtasks 16-18, append)
  10-screen-state-matrix.md       (Subtask 19)
  11-api-to-sp-map.md             (Subtask 20)
  12-implementation-guide.md      (Subtask 21)

_stubs/
  backend/
    Controllers/
      [Entity]Controller.cs       (Subtasks 22-23)
    Models/
      [Entity]DTOs.cs             (Subtasks 24-25)
  database/
    01-tables.sql                 (Subtask 26)
    02-stored-procedures.sql      (Subtasks 27-28, append)
    03-seed-data.sql              (Subtasks 29-30, append)
```

For multi-subtask files: the first subtask creates the file with its header. Subsequent subtasks APPEND to the same file. Always include a `<!-- SUBTASK N -->` marker at the start of each appended section so the user can verify completeness.

---

# ═══════════════════════════════════════════
# SUBTASK 1 of 31: Screen Inventory
# ═══════════════════════════════════════════

**Generate:** `_analysis/01-screen-inventory.md`

**Start this subtask immediately.** Analyze the entire prototype before generating output.

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

End with a summary table:

| # | Screen | Route | Layout | Auth Required | Roles |
|---|--------|-------|--------|---------------|-------|
| 1 | ... | ... | ... | ... | ... |

---

**After generating, output:**
```
✅ SUBTASK 1 of 31 COMPLETE
Generated: _analysis/01-screen-inventory.md
Screens found: [N]

📋 Next: Subtask 2 — Shared & Layout Components
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 2 of 31: Shared & Layout Components
# ═══════════════════════════════════════════

**Generate:** `_analysis/02-component-inventory.md` (PART 1 — shared and layout components only)

**Prerequisites:** Reference screen inventory from Subtask 1.

Document components that are used across multiple screens: layout shells, navigation components, headers, footers, sidebars, modals, dialogs, toasts, data tables, form controls, cards, badges, avatars, and any other shared/reusable components.

For EACH component:

#### Component: [ComponentName]
- **File path:** `components/[path]/[filename].tsx`
- **Category:** layout | navigation | data-display | form | feedback | overlay
- **Purpose:** One-line description
- **Used on screens:** List every screen that uses this component
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

**After generating, output:**
```
✅ SUBTASK 2 of 31 COMPLETE
Generated: _analysis/02-component-inventory.md (Part 1 — Shared & Layout)
Shared components documented: [N]

📋 Next: Subtask 3 — Feature-Specific Components
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 3 of 31: Feature-Specific Components
# ═══════════════════════════════════════════

**Generate:** APPEND to `_analysis/02-component-inventory.md` (PART 2 — feature-specific components)

**Prerequisites:** Reference Subtask 1 (screens) and Subtask 2 (shared components — do not duplicate).

Document components that belong to a specific feature or screen: dashboard widgets, entity-specific forms, detail panels, list views, charts, wizards, settings panels, etc. Exclude any component already documented in Subtask 2.

Use the same format as Subtask 2 for each component, but add:
- **Feature area:** Which feature/module this belongs to

End with a full component summary table covering BOTH subtask 2 and 3:

| # | Component | Category | Feature Area | Screens Used | Variants |
|---|-----------|----------|-------------|-------------|----------|
| 1 | ... | shared | - | 5 screens | 3 |
| 2 | ... | feature | Dashboard | 1 screen | 2 |

---

**After generating, output:**
```
✅ SUBTASK 3 of 31 COMPLETE
Generated: _analysis/02-component-inventory.md (Part 2 — Feature-Specific) — APPENDED
Feature components documented: [N]
Total components (shared + feature): [N]

📋 Next: Subtask 4 — Design System: Colors & Typography
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 4 of 31: Design System — Colors & Typography
# ═══════════════════════════════════════════

**Generate:** `_analysis/03-design-system.md` (PART 1 — colors and typography only)

**Prerequisites:** Reference components from Subtasks 2-3 to identify all color and type usage.

#### Colors
Document every color used with CSS variable names and hex values:
- Primary palette (50 through 900)
- Neutral palette (50 through 900)
- Semantic colors (success, warning, danger, info — each with 50 through 900)
- Surface colors (backgrounds, cards, overlays)
- Text colors (primary, secondary, disabled, inverse)
- Border colors
- Focus ring colors

For each color, note where it is used (e.g., "Primary-600: button backgrounds, active nav items, links").

#### Typography
- Font family stack (primary, monospace, display if different)
- Font sizes with use cases:
  | Token | Size | Weight | Line Height | Use Case |
  |-------|------|--------|-------------|----------|
  | heading-1 | ... | ... | ... | Page titles |
  | body | ... | ... | ... | Default text |
  | caption | ... | ... | ... | Help text, timestamps |
- Font weights with use cases
- Letter spacing rules

---

**After generating, output:**
```
✅ SUBTASK 4 of 31 COMPLETE
Generated: _analysis/03-design-system.md (Part 1 — Colors & Typography)
Colors documented: [N] unique values
Type scale entries: [N]

📋 Next: Subtask 5 — Design System: Spacing, Borders, Elevation, Motion & Icons
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 5 of 31: Design System — Spacing, Borders, Elevation, Motion & Icons
# ═══════════════════════════════════════════

**Generate:** APPEND to `_analysis/03-design-system.md` (PART 2)

#### Spacing
- Base grid unit
- Spacing scale with use cases:
  | Token | Value | Use Case |
  |-------|-------|----------|
  | spacing-xs | 4px | Inline icon gap |
  | spacing-sm | 8px | Component internal padding |
  | ... | ... | ... |

#### Border & Radius
- Border widths (thin, medium, thick) with use cases
- Radius values:
  | Token | Value | Use Case |
  |-------|-------|----------|
  | radius-sm | ... | Buttons, inputs |
  | radius-md | ... | Cards |
  | radius-lg | ... | Modals, panels |
  | radius-full | 9999px | Avatars, pills |

#### Elevation / Shadows
| Level | Value | Use Case |
|-------|-------|----------|
| elevation-1 | ... | Cards |
| elevation-2 | ... | Dropdowns, popovers |
| elevation-3 | ... | Modals, drawers |

#### Motion
- Transition durations (fast, normal, slow)
- Easing curves (ease-in, ease-out, spring)
- Specific animations (loading pulse, skeleton shimmer, expand/collapse, fade-in)

#### Icons
- Icon library used (e.g., Fluent UI Icons, Lucide, Heroicons)
- Icon sizes (sm, md, lg) with pixel values
- Icon color rules (inherit text color, specific overrides)
- List every icon used with its name and where it appears

---

**After generating, output:**
```
✅ SUBTASK 5 of 31 COMPLETE
Generated: _analysis/03-design-system.md (Part 2 — Spacing/Borders/Elevation/Motion/Icons) — APPENDED

📋 Next: Subtask 6 — Design System: Component Tokens
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 6 of 31: Design System — Component Tokens
# ═══════════════════════════════════════════

**Generate:** APPEND to `_analysis/03-design-system.md` (PART 3 — per-component design tokens)

For each base UI component (Button, Input, Select, Checkbox, Radio, Toggle, Card, Badge, Avatar, Table, Tab, Tooltip, Dialog, Drawer, Toast, etc.), document:

#### Component: [Name]
**Sizes:**
| Size | Height | Padding | Font Size | Icon Size | Border Radius |
|------|--------|---------|-----------|-----------|---------------|
| sm | ... | ... | ... | ... | ... |
| md | ... | ... | ... | ... | ... |
| lg | ... | ... | ... | ... | ... |

**Appearances/Variants:**
| Variant | Background | Text | Border | Hover BG | Active BG |
|---------|-----------|------|--------|----------|-----------|
| primary | ... | ... | ... | ... | ... |
| secondary | ... | ... | ... | ... | ... |
| ghost | ... | ... | ... | ... | ... |

**States:**
| State | Change from Default |
|-------|-------------------|
| Hover | BG darkens 10%, cursor pointer |
| Active/Pressed | BG darkens 20% |
| Focus | Focus ring: 2px primary-500, offset 2px |
| Disabled | Opacity 0.5, cursor not-allowed |
| Loading | Content replaced with spinner |

---

**After generating, output:**
```
✅ SUBTASK 6 of 31 COMPLETE
Generated: _analysis/03-design-system.md (Part 3 — Component Tokens) — APPENDED
Component token sets documented: [N]

📋 Next: Subtask 7 — Navigation & Routing
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 7 of 31: Navigation & Routing
# ═══════════════════════════════════════════

**Generate:** `_analysis/04-navigation-routing.md`

**Prerequisites:** Reference screen inventory from Subtask 1.

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

**After generating, output:**
```
✅ SUBTASK 7 of 31 COMPLETE
Generated: _analysis/04-navigation-routing.md
Routes documented: [N]

📋 Next: Subtask 8 — Core Entity Types
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 8 of 31: Core Entity Types
# ═══════════════════════════════════════════

**Generate:** `_analysis/05-data-types.md` (PART 1 — core/primary entity types)

**Prerequisites:** Reference screens (Subtask 1) and components (Subtasks 2-3) to identify all data shapes.

Identify the PRIMARY entities — those that have their own screens, CRUD operations, or are the main subjects of the application (e.g., User, Tenant, Project, Order, Patient, etc.).

For EACH core entity, generate the complete TypeScript:

```typescript
// [filename].ts — [Description]

export interface EntityName {
  id: string;
  // ... every field with type and JSDoc comment explaining what it is
}
```

List the core entities you are documenting at the top so Subtask 9 knows what remains.

---

**After generating, output:**
```
✅ SUBTASK 8 of 31 COMPLETE
Generated: _analysis/05-data-types.md (Part 1 — Core Entities)
Core entities documented: [list names]

📋 Next: Subtask 9 — Supporting Types, Enums & Relationships
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 9 of 31: Supporting Types, Enums & Relationships
# ═══════════════════════════════════════════

**Generate:** APPEND to `_analysis/05-data-types.md` (PART 2 — supporting types, enums, relationships)

Document:
1. **Supporting/junction entities** — entities that support core entities (e.g., Address, Attachment, AuditLog, Permission, RoleAssignment, etc.)
2. **All enum/union types** — every string union or enum used across the application
3. **Request/response wrapper types** — pagination, API response wrappers, error types
4. **Data Relationship Diagram:**
```
User --< TenantAssignment >-- Tenant
Tenant --< Project
Project --< ProjectChat >-- ChatThread
...
```
5. **Field Format Reference:**
| Entity.Field | Format | Example |
|-------------|--------|---------|
| User.email | email | user@example.com |
| BillingRecord.amount | currency USD | $1,234.56 |

---

**After generating, output:**
```
✅ SUBTASK 9 of 31 COMPLETE
Generated: _analysis/05-data-types.md (Part 2 — Supporting Types & Relationships) — APPENDED
Supporting entities: [N], Enums: [N], Total types: [N]

📋 Next: Subtask 10 — API Contracts: Read Operations
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 10 of 31: API Contracts — Read Operations (GET)
# ═══════════════════════════════════════════

**Generate:** `_analysis/06-api-contracts.md` (PART 1 — GET endpoints only)

**Prerequisites:** Reference data types (Subtasks 8-9) and hooks/components to find all data fetching.

For EACH GET endpoint:

#### `GET /api/path`
- **Called from:** Hook or component that calls this
- **Purpose:** What this endpoint does
- **Auth:** Bearer JWT required? Tenant header required?
- **Path params:** `{ paramName: type }` with description
- **Query params:** `{ paramName: type }` with description (pagination, filters, search, sort)
- **Response body (success):**
```json
{
  "field": "type — description"
}
```
- **Error responses:**
  - 401: Unauthorized
  - 403: Forbidden (role check)
  - 404: Not found
  - 429: Rate limited
- **SSE/Streaming:** If this is a streaming endpoint, document the event format
- **Caching:** Any cache headers or stale-while-revalidate behavior observed

Start with a summary table of all GET endpoints, then document each one.

---

**After generating, output:**
```
✅ SUBTASK 10 of 31 COMPLETE
Generated: _analysis/06-api-contracts.md (Part 1 — GET Endpoints)
GET endpoints documented: [N]

📋 Next: Subtask 11 — API Contracts: Write Operations
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 11 of 31: API Contracts — Write Operations (POST/PUT/DELETE)
# ═══════════════════════════════════════════

**Generate:** APPEND to `_analysis/06-api-contracts.md` (PART 2 — POST, PUT, PATCH, DELETE endpoints)

For EACH write endpoint:

#### `METHOD /api/path`
- **Called from:** Hook or component that calls this
- **Purpose:** What this endpoint does
- **Auth:** Bearer JWT required? Tenant header required?
- **Path params:** `{ paramName: type }` with description
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
  - 400: Validation errors — list specific validations
  - 401: Unauthorized
  - 403: Forbidden (role check)
  - 404: Not found
  - 409: Conflict (duplicate, version mismatch)
  - 429: Rate limited
- **Side effects:** What else happens (notifications, audit log, cache invalidation)
- **Optimistic update:** Does the UI update optimistically before server confirms?

End with a COMPLETE summary table of ALL endpoints (both GET from Subtask 10 and write from this subtask):

| # | Method | Path | Purpose | Auth | Streaming |
|---|--------|------|---------|------|-----------|
| 1 | GET | /api/... | ... | Yes | No |

---

**After generating, output:**
```
✅ SUBTASK 11 of 31 COMPLETE
Generated: _analysis/06-api-contracts.md (Part 2 — Write Endpoints) — APPENDED
Write endpoints documented: [N]
Total endpoints (read + write): [N]

📋 Next: Subtask 12 — Data Fetching Hooks
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 12 of 31: Data Fetching Hooks
# ═══════════════════════════════════════════

**Generate:** `_analysis/07-hooks-state.md` (PART 1 — data fetching hooks only)

**Prerequisites:** Reference API contracts (Subtasks 10-11) and data types (Subtasks 8-9).

Document every custom hook that FETCHES data (calls GET endpoints, manages query state, handles loading/error/caching).

For EACH hook:

#### `useHookName(params)`
- **File:** `hooks/useHookName.ts`
- **Purpose:** What data this fetches
- **Parameters:** Input params with types
- **Returns:**
```typescript
{
  data: Type;           // Description
  isLoading: boolean;   // True during initial fetch
  isFetching: boolean;  // True during background refetch
  error: Error | null;  // Error state
  refetch: () => void;  // Manual refetch trigger
}
```
- **API endpoint called:** `GET /api/...`
- **Query key pattern:** e.g., `['entity', tenantId, filters]`
- **Refetch triggers:** What causes this to refetch (filter change, interval, focus, etc.)
- **Cache behavior:** Stale time, cache time, placeholder data
- **Mock data used:** What mock data this currently returns

---

**After generating, output:**
```
✅ SUBTASK 12 of 31 COMPLETE
Generated: _analysis/07-hooks-state.md (Part 1 — Data Fetching Hooks)
Fetching hooks documented: [N]

📋 Next: Subtask 13 — Mutation & Utility Hooks
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 13 of 31: Mutation & Utility Hooks
# ═══════════════════════════════════════════

**Generate:** APPEND to `_analysis/07-hooks-state.md` (PART 2 — mutation hooks and utility hooks)

Document every custom hook that WRITES data (calls POST/PUT/DELETE) or manages non-data state (UI state, auth, navigation, local storage, etc.).

For EACH mutation hook:

#### `useHookName()`
- **File:** `hooks/useHookName.ts`
- **Purpose:** What this mutates
- **Returns:**
```typescript
{
  mutate: (args: Type) => void;     // Trigger mutation
  mutateAsync: (args: Type) => Promise<Type>; // Async version
  isPending: boolean;                // Mutation in progress
  error: Error | null;               // Error state
}
```
- **API endpoint called:** `POST/PUT/DELETE /api/...`
- **Optimistic update:** Does it update local cache before server responds? How?
- **Cache invalidation:** Which query keys are invalidated on success?
- **Success behavior:** Toast, redirect, refetch, etc.
- **Error behavior:** Toast, form validation display, retry, etc.

For EACH utility hook:

#### `useHookName()`
- **File:** `hooks/useHookName.ts`
- **Purpose:** What UI state or behavior this manages
- **Parameters:** Input params with types
- **Returns:** Full return type
- **Side effects:** Timers, event listeners, localStorage, subscriptions

---

**After generating, output:**
```
✅ SUBTASK 13 of 31 COMPLETE
Generated: _analysis/07-hooks-state.md (Part 2 — Mutation & Utility Hooks) — APPENDED
Mutation hooks: [N], Utility hooks: [N], Total hooks: [N]

📋 Next: Subtask 14 — Mock Data: Core Entities
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 14 of 31: Mock Data — Core Entities
# ═══════════════════════════════════════════

**Generate:** `_analysis/08-mock-data-catalog.md` (PART 1 — core entity mock data)

**Prerequisites:** Reference core entity types from Subtask 8.

For each PRIMARY entity's mock data:

#### Mock: [Entity Name]
- **Location:** File path where mock data is defined
- **Count:** Number of mock records
- **Shape matches type:** `types/[file].ts` -> `InterfaceName`
- **Sample record (complete):**
```json
{
  // One COMPLETE record with all fields and realistic values
}
```
- **All records summary:**
| ID | Key fields... | Notes |
|----|--------------|-------|
| 1 | ... | ... |

- **Foreign keys:** Which IDs reference other entity mock data

---

**After generating, output:**
```
✅ SUBTASK 14 of 31 COMPLETE
Generated: _analysis/08-mock-data-catalog.md (Part 1 — Core Entity Mock Data)
Core entity mock sets: [N], Total mock records: [N]

📋 Next: Subtask 15 — Mock Data: Supporting Entities & Consistency Rules
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 15 of 31: Mock Data — Supporting Entities & Consistency Rules
# ═══════════════════════════════════════════

**Generate:** APPEND to `_analysis/08-mock-data-catalog.md` (PART 2 — supporting entities and data consistency rules)

Document mock data for supporting/junction entities (same format as Subtask 14).

Then add a **Data Consistency Rules** section:

#### Data Consistency Rules
- **Cross-entity ID references:** List every ID that must match across mock data sets
  | Source Entity.Field | Target Entity | Example Value |
  |-------------------|--------------|---------------|
  | Project.tenantId | Tenant.id | "tenant-001" |
- **Enum consistency:** List enum values that appear in mock data and must match type definitions
- **Calculated fields:** List fields derived from other data (e.g., totalCost = sum of line items)
- **Chronological consistency:** List any date/time fields that must be in logical order
- **Status consistency:** List any status fields and valid transitions represented in mock data

---

**After generating, output:**
```
✅ SUBTASK 15 of 31 COMPLETE
Generated: _analysis/08-mock-data-catalog.md (Part 2 — Supporting Entities & Rules) — APPENDED
Supporting entity mock sets: [N], Consistency rules: [N]

📋 Next: Subtask 16 — Storyboards: Auth & Onboarding
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 16 of 31: Storyboards — Auth & Onboarding Flows
# ═══════════════════════════════════════════

**Generate:** `_analysis/09-storyboards.md` (PART 1 — authentication and onboarding flows)

**Prerequisites:** Reference screens (Subtask 1), routes (Subtask 7), API contracts (Subtasks 10-11).

Document these flow categories:

1. **Login flow** (email/password, SSO, MFA if present)
2. **Registration / signup flow**
3. **First-time user onboarding** (setup wizard, profile completion, etc.)
4. **Password reset / forgot password**
5. **Role switching / tenant switching** (if multi-tenant)
6. **Session expiry / token refresh**
7. **Logout flow**

For EACH flow:

#### Flow: [Flow Name]
**Actor:** [User role]
**Goal:** [What the user is trying to accomplish]
**Preconditions:** [What must be true before this flow starts]

| Step | User Action | System Response | Screen | Screen State | API Call | Data Changed |
|------|-------------|-----------------|--------|--------------|----------|--------------|
| 1 | User navigates to /login | Login form displayed | Login | Default | - | - |
| 2 | User enters email | Field validates format | Login | Validating | - | - |
| 3 | User clicks "Sign In" | Spinner shown, API called | Login | Loading | POST /api/auth/login | session token |
| 4 | ... | ... | ... | ... | ... | ... |

**Happy path result:** [What happens when everything works]
**Error paths:**
- If [condition]: [what happens, which screen state]

---

**After generating, output:**
```
✅ SUBTASK 16 of 31 COMPLETE
Generated: _analysis/09-storyboards.md (Part 1 — Auth & Onboarding)
Auth/onboarding flows documented: [N]

📋 Next: Subtask 17 — Storyboards: Primary CRUD Flows
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 17 of 31: Storyboards — Primary CRUD Flows
# ═══════════════════════════════════════════

**Generate:** APPEND to `_analysis/09-storyboards.md` (PART 2 — CRUD operations on primary entities)

For EACH core entity, document all CRUD flows:
- **Create** — filling and submitting the creation form
- **Read/View** — navigating to and viewing entity details
- **Update** — editing an existing entity
- **Delete** — removing an entity (soft delete, confirmation dialog, etc.)
- **List/Search/Filter** — browsing entities with search, filters, pagination, sorting

Use the same detailed step-by-step table format as Subtask 16 (Step, User Action, System Response, Screen, Screen State, API Call, Data Changed).

Include:
- Validation error paths for each form
- Optimistic update behavior
- Success confirmations (toasts, redirects)
- Empty state -> first item creation transition

---

**After generating, output:**
```
✅ SUBTASK 17 of 31 COMPLETE
Generated: _analysis/09-storyboards.md (Part 2 — Primary CRUD Flows) — APPENDED
CRUD flow sets documented: [N] entities × [N] operations

📋 Next: Subtask 18 — Storyboards: Secondary, Navigation & Error Flows
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 18 of 31: Storyboards — Secondary, Navigation & Error Flows
# ═══════════════════════════════════════════

**Generate:** APPEND to `_analysis/09-storyboards.md` (PART 3 — secondary features, navigation, and error recovery)

Document:
1. **Secondary feature flows** — any feature that isn't simple CRUD (e.g., chat, file upload, export, import, bulk operations, approval workflows, dashboards with interactive widgets)
2. **Navigation flows** — tab switching, breadcrumb navigation, deep linking, back button behavior
3. **Error recovery flows** — what happens when API calls fail, network goes down, session expires mid-action
4. **Empty state -> populated state** — for each screen, the flow from first visit (no data) to having data
5. **Notification / real-time flows** — if the app has real-time updates, SSE, or polling

Use the same detailed step-by-step table format.

End with a **Flow Summary Table** covering ALL flows from Subtasks 16-18:

| # | Flow Name | Category | Actor | Screens Involved | API Calls | Happy Path Steps |
|---|-----------|----------|-------|-----------------|-----------|-----------------|
| 1 | Login | Auth | Any | Login, Dashboard | 1 | 4 |

---

**After generating, output:**
```
✅ SUBTASK 18 of 31 COMPLETE
Generated: _analysis/09-storyboards.md (Part 3 — Secondary & Error Flows) — APPENDED
Secondary flows: [N], Error flows: [N], Total flows across all parts: [N]

📋 Next: Subtask 19 — Screen State Matrix
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 19 of 31: Screen State Matrix
# ═══════════════════════════════════════════

**Generate:** `_analysis/10-screen-state-matrix.md`

**Prerequisites:** Reference screens (Subtask 1), storyboards (Subtasks 16-18).

Create a comprehensive matrix of every screen crossed with every possible state.

| Screen | Default | Loading | Empty | Error | Forbidden (403) | Rate Limited (429) | Streaming | Saving | Offline | Notes |
|--------|---------|---------|-------|-------|-----------------|-------------------|-----------|--------|---------|-------|
| [Screen 1] | What user sees | Skeleton/spinner details | Empty message + CTA | Error message + retry | Access denied card | Cooldown timer | If applicable | If applicable | If applicable | |

For each NON-EMPTY cell, describe:
- **Visuals:** What the user sees (skeleton shapes, spinner placement, message text, icon)
- **Interactions:** What the user can do in this state (retry button, navigate away, dismiss)
- **Transitions:** What state comes next and what triggers it

---

**After generating, output:**
```
✅ SUBTASK 19 of 31 COMPLETE
Generated: _analysis/10-screen-state-matrix.md
Screens × states: [N] × [N] = [N] cells documented

📋 Next: Subtask 20 — API-to-SP Traceability Map
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 20 of 31: API-to-SP Traceability Map
# ═══════════════════════════════════════════

**Generate:** `_analysis/11-api-to-sp-map.md`

**Prerequisites:** Reference API contracts (Subtasks 10-11), hooks (Subtasks 12-13), data types (Subtasks 8-9).

Create a mapping table connecting frontend -> API -> stored procedure -> database table.

This is the end-to-end traceability map that the GSD Engine uses to verify every layer is connected.

| # | Frontend Hook/Call | HTTP Method | API Route | Controller.Method | Stored Procedure | Tables Read | Tables Written | Notes |
|---|-------------------|-------------|-----------|-------------------|-----------------|-------------|---------------|-------|
| 1 | useEntity().getAll | GET | /api/entity | EntityController.GetAll | usp_Entity_GetAll | Entity | - | Paginated |
| 2 | useEntity().create | POST | /api/entity | EntityController.Create | usp_Entity_Create | - | Entity | Returns new ID |

**CRITICAL:** Every API endpoint from File 6 MUST appear in this table. Every stored procedure name you define here MUST appear in Subtasks 27-28. Every table name MUST appear in Subtask 26. No orphans.

---

**After generating, output:**
```
✅ SUBTASK 20 of 31 COMPLETE
Generated: _analysis/11-api-to-sp-map.md
Traceability rows: [N]
Unique SPs defined: [N]
Unique tables referenced: [N]

📋 Next: Subtask 21 — Implementation Guide
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 21 of 31: Implementation Guide
# ═══════════════════════════════════════════

**Generate:** `_analysis/12-implementation-guide.md`

**Prerequisites:** This subtask synthesizes ALL previous outputs (Files 1-11).

#### Build Order
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
- Authentication pattern (JWT, session, etc.)
- Multi-tenancy pattern (header, URL, claim)
- State management approach (hooks, context, store)
- Error handling pattern
- Loading state pattern

#### Design Fidelity Checklist
- Exact pixel dimensions for layouts, panels, headers
- Exact color values for every element type
- Exact spacing between elements
- Exact typography for every text element
- Animation/transition details
- Icon choices and sizes
- Border styles and radii

#### Entity-to-Deliverable Cross-Reference
For each core entity, list every file that references it:
| Entity | Types | API | Hook | Mock | Controller | DTO | Table | SPs | Seed |
|--------|-------|-----|------|------|-----------|-----|-------|-----|------|
| Project | 05 | 06 | 07 | 08 | ✓ | ✓ | ✓ | ✓ | ✓ |

---

**After generating, output:**
```
✅ SUBTASK 21 of 31 COMPLETE — All 12 analysis files generated!
Generated: _analysis/12-implementation-guide.md

📋 Next: Subtask 22 — Controller Stubs (Group A)
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 22 of 31: Controller Stubs — Group A
# ═══════════════════════════════════════════

**Generate:** `_stubs/backend/Controllers/[Entity]Controller.cs` for the FIRST HALF of entities

**Prerequisites:** Reference API contracts (Subtasks 10-11) and API-to-SP map (Subtask 20).

**Before generating:** List all entities alphabetically, split at midpoint. State which entities are in Group A.

For EACH entity in Group A, generate a .NET 8 Web API controller stub:
- Use `[ApiController]` and `[Route("api/[route]")]` attributes
- Include `[HttpGet]`, `[HttpPost]`, `[HttpPut]`, `[HttpDelete]` action methods
- Method signatures only (body returns `NotImplemented()`)
- Parameter types match the TypeScript types from File 5
- Include `[FromBody]`, `[FromQuery]`, `[FromRoute]` annotations
- Include XML doc comments describing what each endpoint does

Example:
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

**After generating, output:**
```
✅ SUBTASK 22 of 31 COMPLETE
Generated: _stubs/backend/Controllers/ [list files]
Group A entities: [list]
Remaining for Group B: [list]

📋 Next: Subtask 23 — Controller Stubs (Group B)
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 23 of 31: Controller Stubs — Group B
# ═══════════════════════════════════════════

**Generate:** `_stubs/backend/Controllers/[Entity]Controller.cs` for the SECOND HALF of entities

Same format and requirements as Subtask 22, for the remaining entities.

---

**After generating, output:**
```
✅ SUBTASK 23 of 31 COMPLETE
Generated: _stubs/backend/Controllers/ [list files]
Total controllers (A + B): [N]

📋 Next: Subtask 24 — DTO Stubs (Group A)
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 24 of 31: DTO Stubs — Group A
# ═══════════════════════════════════════════

**Generate:** `_stubs/backend/Models/[Entity]DTOs.cs` for the FIRST HALF of entities

**Prerequisites:** Reference data types (Subtasks 8-9).

Use the same Group A / Group B split as the controllers (Subtasks 22-23).

For each entity in Group A, generate:
- Request DTOs (for POST/PUT bodies)
- Response DTOs (for GET responses)
- List/paginated response DTOs
- Use `System.Text.Json` serialization attributes where needed
- Include data annotations (`[Required]`, `[StringLength]`, `[Range]`)
- Property names in PascalCase with `[JsonPropertyName("camelCase")]`

---

**After generating, output:**
```
✅ SUBTASK 24 of 31 COMPLETE
Generated: _stubs/backend/Models/ [list files]

📋 Next: Subtask 25 — DTO Stubs (Group B)
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 25 of 31: DTO Stubs — Group B
# ═══════════════════════════════════════════

**Generate:** `_stubs/backend/Models/[Entity]DTOs.cs` for the SECOND HALF of entities

Same format and requirements as Subtask 24, for the remaining entities.

---

**After generating, output:**
```
✅ SUBTASK 25 of 31 COMPLETE
Generated: _stubs/backend/Models/ [list files]
Total DTO files (A + B): [N]

📋 Next: Subtask 26 — Database Tables
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 26 of 31: Database Table Definitions
# ═══════════════════════════════════════════

**Generate:** `_stubs/database/01-tables.sql`

**Prerequisites:** Reference data types (Subtasks 8-9), mock data (Subtasks 14-15), API-to-SP map (Subtask 20).

Generate SQL Server CREATE TABLE statements for every entity.

Requirements:
- SQL Server syntax (NVARCHAR, DATETIME2, BIT, DECIMAL, etc.)
- Primary keys (NVARCHAR(50) for IDs, or INT IDENTITY)
- Foreign key constraints with named FK_ constraints
- NOT NULL constraints where appropriate
- DEFAULT values where the mock data suggests defaults
- Audit columns on every table:
  ```sql
  CreatedAt   DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
  CreatedBy   NVARCHAR(100) NOT NULL,
  UpdatedAt   DATETIME2 NULL,
  UpdatedBy   NVARCHAR(100) NULL,
  IsDeleted   BIT NOT NULL DEFAULT 0
  ```
- TenantId NVARCHAR(50) NOT NULL on every tenant-scoped table
- Named indexes: `IX_{Table}_{Columns}` on foreign keys and frequently-filtered columns
- Named unique constraints: `UQ_{Table}_{Columns}`

Order tables by dependency (referenced tables first, junction tables last).

---

**After generating, output:**
```
✅ SUBTASK 26 of 31 COMPLETE
Generated: _stubs/database/01-tables.sql
Tables created: [N]
Foreign keys: [N]
Indexes: [N]

📋 Next: Subtask 27 — Stored Procedures: Read Operations
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 27 of 31: Stored Procedures — Read Operations
# ═══════════════════════════════════════════

**Generate:** `_stubs/database/02-stored-procedures.sql` (PART 1 — SELECT/read stored procedures)

**Prerequisites:** Reference API-to-SP map (Subtask 20) — generate SPs for every GET endpoint row.

For each read SP:

```sql
CREATE PROCEDURE usp_Entity_GetAll
    @TenantId NVARCHAR(50),
    @PageNumber INT = 1,
    @PageSize INT = 20
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        -- TODO: SELECT columns from Entity
        -- WHERE TenantId = @TenantId AND IsDeleted = 0
        -- ORDER BY CreatedAt DESC
        -- OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
        -- Returns: [list exact columns matching DTO]
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

GRANT EXECUTE ON dbo.usp_Entity_GetAll TO [AppRole];
GO
```

Include:
- GetAll (paginated, filtered)
- GetById
- GetBy{Filter} for any non-standard queries
- Search SPs if search functionality exists
- Lookup/dropdown SPs

---

**After generating, output:**
```
✅ SUBTASK 27 of 31 COMPLETE
Generated: _stubs/database/02-stored-procedures.sql (Part 1 — Read SPs)
Read SPs created: [N]

📋 Next: Subtask 28 — Stored Procedures: Write Operations
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 28 of 31: Stored Procedures — Write Operations
# ═══════════════════════════════════════════

**Generate:** APPEND to `_stubs/database/02-stored-procedures.sql` (PART 2 — INSERT/UPDATE/DELETE stored procedures)

For each write SP:

```sql
CREATE PROCEDURE usp_Entity_Create
    @TenantId NVARCHAR(50),
    @Field1 NVARCHAR(200),
    @Field2 INT,
    @CreatedBy NVARCHAR(100),
    @NewId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        -- TODO: INSERT INTO Entity (TenantId, Field1, Field2, CreatedBy)
        -- VALUES (@TenantId, @Field1, @Field2, @CreatedBy)
        -- SET @NewId = SCOPE_IDENTITY()
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

GRANT EXECUTE ON dbo.usp_Entity_Create TO [AppRole];
GO
```

Include:
- Create SPs with OUTPUT parameter for new ID
- Update SPs with optimistic concurrency (check UpdatedAt)
- Delete SPs (soft delete: SET IsDeleted = 1)
- Any bulk operation SPs
- Any status transition SPs

End with a **SP Summary Table**:
| # | SP Name | Operation | Entity | Tables | Matches API Route |
|---|---------|-----------|--------|--------|-------------------|
| 1 | usp_Entity_GetAll | SELECT | Entity | Entity | GET /api/entity |

---

**After generating, output:**
```
✅ SUBTASK 28 of 31 COMPLETE
Generated: _stubs/database/02-stored-procedures.sql (Part 2 — Write SPs) — APPENDED
Write SPs created: [N]
Total SPs (read + write): [N]

📋 Next: Subtask 29 — Seed Data: Core Entities
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 29 of 31: Seed Data — Core Entities
# ═══════════════════════════════════════════

**Generate:** `_stubs/database/03-seed-data.sql` (PART 1 — core entity seed data)

**Prerequisites:** Reference mock data catalog (Subtasks 14-15) and tables (Subtask 26).

Generate INSERT statements for core/primary entities. These must be inserted FIRST because supporting entities reference them.

Requirements:
- Data must match the mock data from File 8 EXACTLY
- Use MERGE or IF NOT EXISTS pattern to be idempotent
- Insert order must respect foreign key dependencies
- Include comments grouping seed data by entity
- Dates should use realistic recent timestamps
- Include audit column values (CreatedAt, CreatedBy)

```sql
-- =============================================
-- SEED DATA: [Entity Name]
-- Source: _analysis/08-mock-data-catalog.md
-- Records: [N]
-- =============================================

IF NOT EXISTS (SELECT 1 FROM dbo.Entity WHERE Id = 'entity-001')
BEGIN
    INSERT INTO dbo.Entity (Id, TenantId, Field1, Field2, CreatedAt, CreatedBy)
    VALUES ('entity-001', 'tenant-001', 'Value1', 42, '2026-01-15T10:00:00', 'seed-script');
END
```

---

**After generating, output:**
```
✅ SUBTASK 29 of 31 COMPLETE
Generated: _stubs/database/03-seed-data.sql (Part 1 — Core Entities)
Core entity seed sets: [N], Total INSERT statements: [N]

📋 Next: Subtask 30 — Seed Data: Supporting Entities
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 30 of 31: Seed Data — Supporting Entities
# ═══════════════════════════════════════════

**Generate:** APPEND to `_stubs/database/03-seed-data.sql` (PART 2 — supporting/junction entity seed data)

Generate INSERT statements for supporting entities, junction tables, and lookup data. These reference the core entity IDs from Subtask 29.

Same format and requirements as Subtask 29.

After all inserts, add a **Seed Data Verification** section:
```sql
-- =============================================
-- VERIFICATION QUERIES
-- Run these after seeding to confirm data integrity
-- =============================================

-- Check record counts
SELECT 'Entity' AS TableName, COUNT(*) AS Records FROM dbo.Entity WHERE IsDeleted = 0
UNION ALL
SELECT 'OtherEntity', COUNT(*) FROM dbo.OtherEntity WHERE IsDeleted = 0
-- ... one row per table

-- Check foreign key integrity
SELECT 'Orphaned Entity.ParentId' AS Issue, COUNT(*) AS Count
FROM dbo.Entity e
WHERE NOT EXISTS (SELECT 1 FROM dbo.Parent p WHERE p.Id = e.ParentId)
-- ... one check per foreign key
```

---

**After generating, output:**
```
✅ SUBTASK 30 of 31 COMPLETE
Generated: _stubs/database/03-seed-data.sql (Part 2 — Supporting Entities) — APPENDED
Supporting entity seed sets: [N], Total INSERT statements: [N]

📋 Next: Subtask 31 — Cross-Reference Validation
Type "proceed" to continue.
```

---

# ═══════════════════════════════════════════
# SUBTASK 31 of 31: Cross-Reference Validation
# ═══════════════════════════════════════════

**Generate:** Validation report (no file — output directly)

Verify ALL of the following. Report each check as **PASS** or **FAIL** with specific details for any failures.

#### Forward Traceability (nothing orphaned in prototype)
- [ ] Every screen in the prototype appears in `01-screen-inventory.md`
- [ ] Every component appears in `02-component-inventory.md`
- [ ] Every color/font/spacing value appears in `03-design-system.md`
- [ ] Every route appears in `04-navigation-routing.md`
- [ ] Every TypeScript type/interface appears in `05-data-types.md`
- [ ] Every API call appears in `06-api-contracts.md`
- [ ] Every custom hook appears in `07-hooks-state.md`
- [ ] Every mock data record appears in `08-mock-data-catalog.md`
- [ ] Every user flow appears in `09-storyboards.md`
- [ ] Every screen × state combination appears in `10-screen-state-matrix.md`
- [ ] Every API endpoint has a row in `11-api-to-sp-map.md`
- [ ] The build order in `12-implementation-guide.md` references all other files

#### Backward Traceability (nothing missing downstream)
- [ ] Every API endpoint in File 6 has a controller in `_stubs/backend/Controllers/`
- [ ] Every TypeScript interface in File 5 has a DTO in `_stubs/backend/Models/`
- [ ] Every entity in File 5 has a table in `_stubs/database/01-tables.sql`
- [ ] Every API endpoint in File 6 has a stored procedure in `_stubs/database/02-stored-procedures.sql`
- [ ] Every mock record in File 8 has a seed INSERT in `_stubs/database/03-seed-data.sql`
- [ ] Every row in `11-api-to-sp-map.md` connects a real hook -> endpoint -> SP -> table

#### Consistency Checks
- [ ] Entity names are identical across all 12 analysis files and all stubs
- [ ] Field names match between TypeScript types, C# DTOs, and SQL columns
- [ ] Route paths match between screen inventory, navigation, and API contracts
- [ ] Mock data IDs match between the catalog, seed data, and foreign key references
- [ ] SP names in `02-stored-procedures.sql` match exactly the names in `11-api-to-sp-map.md`
- [ ] Table names in `01-tables.sql` match exactly the names in `11-api-to-sp-map.md`

#### Completeness Counts
| Deliverable | Expected | Found | Status |
|------------|----------|-------|--------|
| Screens | [N from prototype] | [N documented] | PASS/FAIL |
| Components | [N from prototype] | [N documented] | PASS/FAIL |
| Routes | [N from prototype] | [N documented] | PASS/FAIL |
| Types/Interfaces | [N from prototype] | [N documented] | PASS/FAIL |
| API Endpoints | [N from prototype] | [N documented] | PASS/FAIL |
| Hooks | [N from prototype] | [N documented] | PASS/FAIL |
| Mock Data Sets | [N from prototype] | [N documented] | PASS/FAIL |
| Storyboard Flows | [N expected] | [N documented] | PASS/FAIL |
| SPs | [N from map] | [N in SQL] | PASS/FAIL |
| Tables | [N from types] | [N in SQL] | PASS/FAIL |

---

**After completing validation, output:**
```
✅ SUBTASK 31 of 31 COMPLETE — ALL DELIVERABLES GENERATED!

📊 VALIDATION RESULTS:
  Forward traceability:  [X/12 PASS]
  Backward traceability: [X/6 PASS]
  Consistency checks:    [X/6 PASS]

  [List any FAIL items with what's missing]

📦 FINAL DELIVERABLE SUMMARY:
  _analysis/ files:    12/12 (generated across 21 subtasks)
  Controller stubs:    [N] files
  DTO stubs:           [N] files
  Database scripts:    3/3
  
  Total files generated: [N]

🚀 Export all files and place under design\web\v##\src\
   Then run: gsd-assess
```
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

### Subtask-to-File Mapping

Files generated across multiple subtasks use append mode. The final file is the concatenation of all parts:

| File | Subtasks | Parts |
|------|----------|-------|
| 01-screen-inventory.md | 1 | 1 |
| 02-component-inventory.md | 2, 3 | Shared + Feature |
| 03-design-system.md | 4, 5, 6 | Colors/Type + Spacing/Motion + Component Tokens |
| 04-navigation-routing.md | 7 | 1 |
| 05-data-types.md | 8, 9 | Core Entities + Supporting/Enums/Relationships |
| 06-api-contracts.md | 10, 11 | GET + POST/PUT/DELETE |
| 07-hooks-state.md | 12, 13 | Fetching + Mutations/Utilities |
| 08-mock-data-catalog.md | 14, 15 | Core Entities + Supporting/Rules |
| 09-storyboards.md | 16, 17, 18 | Auth + CRUD + Secondary/Error |
| 10-screen-state-matrix.md | 19 | 1 |
| 11-api-to-sp-map.md | 20 | 1 |
| 12-implementation-guide.md | 21 | 1 |
| Controllers/*.cs | 22, 23 | Group A + Group B |
| Models/*.cs | 24, 25 | Group A + Group B |
| 01-tables.sql | 26 | 1 |
| 02-stored-procedures.sql | 27, 28 | Read SPs + Write SPs |
| 03-seed-data.sql | 29, 30 | Core Entities + Supporting |
| Validation | 31 | Report only |

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

### User Commands During Subtask Workflow
| Command | Effect |
|---------|--------|
| **proceed** | Move to next subtask |
| **proceed all** | Complete all remaining subtasks without pausing |
| **proceed 5** | Complete next 5 subtasks without pausing |
| **redo** | Regenerate current subtask from scratch |
| **skip** | Skip current subtask, move to next |

### Adaptive Splitting for Very Large Portals
The prompt includes a splitting rule: if the prototype has >20 screens, >30 components, or >25 API endpoints, Group A/B splits become Group A/B/C (thirds). This keeps each subtask under Figma Make's context limit even for enterprise-scale portals.

### Customization
- If your project uses a different backend (e.g., Node.js, Python), modify the stub sections to generate Express routes / FastAPI endpoints instead of .NET controllers
- If your project uses a different database (e.g., PostgreSQL), modify the database stubs for that SQL dialect
- The 12 analysis documents (Files 1-12) are stack-agnostic and should always be generated regardless of backend technology
