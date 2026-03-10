# GSD V3 Coding Conventions

## General
- Generate COMPLETE, PRODUCTION-READY code. No stubs, no placeholders, no TODO comments.
- Follow existing project conventions discovered during research.
- Use strongly-typed patterns (TypeScript strict mode, C# nullable reference types).
- Handle errors explicitly — no silent catches, no empty catch blocks.

## .NET / C#
- .NET 8, C# 12
- Dapper for data access (no Entity Framework)
- Stored procedures only (no inline SQL, no ORM queries)
- Repository pattern: Controller → Service → Repository → Stored Procedure
- DTOs for API contracts (never expose domain models directly)
- Input validation with FluentValidation
- Structured logging with Serilog
- appsettings.json for configuration (never hardcode connection strings)

## TypeScript / React
- TypeScript strict mode
- React 18 functional components with hooks
- React Query for server state (no Redux for API data)
- Zustand for client-only state
- Tailwind CSS for styling (use design tokens from Figma analysis)
- Named exports (no default exports)
- Barrel exports via index.ts files

## SQL Server
- Stored procedures for ALL data access
- Naming: `usp_Entity_Action` (e.g., `usp_Patient_GetById`)
- Always include `SET NOCOUNT ON`
- Use `TRY...CATCH` with `THROW` for error handling
- Foreign key constraints on all relationships
- Indexes on all foreign key columns and common query filters

## File Output Format
When generating code, output files with clear markers:

```
--- FILE: path/to/file.ts ---
// file content here

--- FILE: path/to/another-file.cs ---
// file content here
```

Each file must be complete and self-contained. Include all imports/usings.
