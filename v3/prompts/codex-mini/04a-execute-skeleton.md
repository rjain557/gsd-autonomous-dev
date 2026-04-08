# Phase 4a: Execute - Skeleton Pass

Generate type signatures, interfaces, function stubs, class structure, and imports ONLY. No implementation bodies.

## Requirement: {{REQ_ID}}

## Plan

{{PLAN}}

## Instructions

1. Create ALL files listed in the plan.
2. For each file, generate:
   - All import/using statements
   - Type definitions and interfaces
   - Function signatures with parameter types and return types
   - Class structure with property declarations
   - No implementation bodies — use `// FILL` comment as placeholder
3. Use the `--- FILE: path/to/file ---` marker format.
4. Follow the coding conventions provided in the system prompt.
5. For SQL files (stored procedures, migrations, schema):
   - Every CREATE TABLE must have `IF OBJECT_ID(...) IS NULL` guard.
   - Every CREATE PROCEDURE/VIEW/FUNCTION must use `CREATE OR ALTER`.
   - Every ALTER TABLE ADD column must have `IF COL_LENGTH(...) IS NULL` guard.
   - Include `SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON;` at the top.
   - Bracket ALL reserved words used as identifiers: `[Plan]`, `[User]`, `[Key]`, `[Order]`, `[Group]`, `[Role]`, `[Type]`, `[Status]`, `[Level]`, `[Name]`, `[Value]`, `[Date]`, `[Action]`, `[State]`.
   - No `USE [DatabaseName]` — scripts run against the connected DB.
   - Stored procedure skeleton must include `BEGIN TRY...END TRY` / `BEGIN CATCH...END CATCH` structure.
   - Include `SET NOCOUNT ON;` in every procedure body.
6. For .NET backend files (controllers, services, middleware):
   - Every controller/service class must have exactly ONE public constructor — never add a second.
   - Every controller action must have an explicit route attribute: `[HttpGet("specific-path")]`, `[HttpPost("specific-path")]`, etc.
   - NEVER rely on `[Route("api/[controller]")]` alone — always specify the action route segment.
   - Before declaring a route, verify no other controller already uses the same HTTP method + path.
   - Health checks must include `timeout: TimeSpan.FromSeconds(5)` and `tags: new[] { "ready" }`.
   - Health checks for external services (storage, Redis, etc.) must be conditionally registered.
   - Add `[ProducesResponseType(typeof(T), StatusCodes.Status200OK)]` on every action method.
   - Add `[ProducesResponseType(StatusCodes.Status404NotFound)]` and other error response types as appropriate.
7. For frontend files (React components, pages, layouts):
   - Import design tokens: `import '../styles/tokens.css'` or reference CSS variables.
   - Use `var(--token-name)` for all colors, shadows, and typography — NEVER hardcode hex/rgb.
   - Include responsive Tailwind classes (`sm:`, `md:`, `lg:`) in component structure.
   - Reference `_analysis/03-design-system.md` for the correct token names.
8. For data access patterns (repositories, stored procedures):
   - GetById stored procedures must return empty result sets for missing IDs (no THROW for not-found).
   - Repository methods must handle null/empty results from GetById calls.
   - Frontend API calls for referenced records must be wrapped in try/catch with fallback objects.
9. For configuration files (appsettings.json, .env):
   - Include a `ConnectionStrings` section with `DefaultConnection` placeholder.
   - Include DI registration stubs for all interfaces in the skeleton Program.cs.

## Example Output

```
--- FILE: src/shared/types/patient.ts ---
export interface Patient {
  id: string;
  firstName: string;
  lastName: string;
  email: string;
  dateOfBirth: string;
}

export interface PatientSearchParams {
  query: string;
  page: number;
  pageSize: number;
}

export interface PatientSearchResult {
  patients: Patient[];
  totalCount: number;
}

--- FILE: src/shared/hooks/usePatientSearch.ts ---
import { useQuery } from '@tanstack/react-query';
import type { PatientSearchParams, PatientSearchResult } from '../types/patient';
import { apiClient } from '../api/client';

export function usePatientSearch(params: PatientSearchParams) {
  // FILL
}

--- FILE: src/web/pages/PatientSearch.tsx ---
import { useState } from 'react';
import { usePatientSearch } from '../../shared/hooks/usePatientSearch';
import type { PatientSearchParams } from '../../shared/types/patient';

export function PatientSearch() {
  // FILL
}
```

Generate the skeleton now. Output ONLY file contents with `--- FILE: path ---` markers.
