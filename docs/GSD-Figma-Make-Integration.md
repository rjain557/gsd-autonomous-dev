# Figma Make Integration Guide

## Overview

GSD Phase C validates deliverables produced by Figma Make — an AI code generation tool inside Figma that analyzes your UI prototype and generates documentation, stubs, and code artifacts.

## Workflow

1. **Build prototype** in Figma Make (screens, navigation, components, mock data)
2. **Run the generation prompt** (`scripts/Figma_Complete_Generation_Prompt.md`) inside Figma Make
3. **Export** the generated files to your project under `design/web/v##/src/`
4. **Run GSD** to validate and continue: `gsd run figma-uploaded --design-path design/web/v1/src/`

## Expected Export Structure

After Figma Make generates deliverables, export them to this structure:

```
design/web/v1/src/
  _analysis/
    01-screen-inventory.md          Screen routes, layouts, roles
    02-component-inventory.md       Shared + feature components
    03-design-system.md             Colors, typography, spacing, tokens
    04-navigation-routing.md        Route table, nav hierarchy
    05-data-types.md                TypeScript interfaces for all entities
    06-api-contracts.md             GET/POST/PUT/DELETE endpoints
    07-hooks-state.md               React Query hooks, mutations
    08-mock-data-catalog.md         Mock data per entity
    09-storyboards.md               User flow step-by-step tables
    10-screen-state-matrix.md       Screen x state matrix (5 states)
    11-api-to-sp-map.md             Frontend hook -> API -> SP -> table
    12-implementation-guide.md      Build order, architecture decisions
  _stubs/
    backend/
      Controllers/*.cs              .NET 8 controller stubs per entity
      Models/*.cs                   DTO stubs (Create/Update/Response patterns)
    database/
      01-tables.sql                 SQL Server CREATE TABLE statements
      02-stored-procedures.sql      SP stubs (usp_Entity_Action naming)
      03-seed-data.sql              INSERT statements matching mock data
```

## What GSD Phase C Validates

The FigmaIntegrationAgent checks:

1. **12/12 analysis files present** — all must exist
2. **DTO naming conventions** — classes follow `Create{Entity}Dto`, `Update{Entity}Dto`, `{Entity}ResponseDto`
3. **Optional build verification** — `dotnet build` and `npm build` pass

## Version Numbering

Use incrementing version numbers for multiple design iterations:
- `design/web/v1/src/` — first prototype
- `design/web/v2/src/` — revised after Phase A/B reconciliation
- Pass the correct path: `--design-path design/web/v2/src/`

## Generation Prompt

The full 31-subtask Figma Make generation prompt is at:
`scripts/Figma_Complete_Generation_Prompt.md`

This prompt is designed to be pasted into Figma Make after your prototype is complete. It generates all 12 analysis files + 5 stub deliverables one subtask at a time.

## GSD Engine Auto-Discovery

The GSD engine auto-discovers `_analysis/` and `_stubs/` wherever they are under your design version directory. It checks for exactly 12 analysis files (numbered 01-12).

## Troubleshooting

| Issue | Solution |
|---|---|
| Phase C reports 0/12 | Figma Make output not exported yet. Export files to --design-path |
| Phase C reports <12 | Partial generation. Re-run Figma Make prompt for missing subtasks |
| DTO naming violations | Edit .cs stubs to follow Create/Update/Response naming |
| Build verification fails | Expected on first run — stubs may have missing references |
