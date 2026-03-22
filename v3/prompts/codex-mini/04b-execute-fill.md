# Phase 4b: Execute - Fill Pass

Fill ALL implementation bodies. Generate COMPLETE, PRODUCTION-READY code.

## Requirement: {{REQ_ID}}

## Plan

{{PLAN}}

## Skeleton (from Pass 1)

{{SKELETON}}

## Instructions

1. Take the skeleton from Pass 1 and fill every `// FILL` comment with complete implementation.
2. Generate COMPLETE code — no stubs, no placeholders, no TODO comments.
3. Follow the plan exactly. Do not add features beyond what the plan specifies.
4. Ensure all imports are correct and complete.
5. Handle errors explicitly. No empty catch blocks.
6. Use the `--- FILE: path/to/file ---` marker format for each file.
7. Include ALL files from the skeleton, fully implemented.

## Design System Compliance

For ALL frontend files:
- Colors MUST use CSS custom properties (`var(--color-*)`) — NEVER hardcode hex, rgb, or hsl values.
- Shadows MUST use `var(--shadow-*)` — NEVER hardcode `box-shadow` values.
- Typography MUST use design token scale (`var(--font-size-*)`) — no arbitrary pixel sizes.
- Use Tailwind responsive prefixes (`sm:`, `md:`, `lg:`, `xl:`) for layout adaptation.
- Support dark mode via `dark:` Tailwind variants or `.dark` CSS variable overrides.
- If the plan includes `ThemeProvider`/`FluentProvider`, ensure it wraps the app root with the token configuration.

## SQL Server Compliance (MANDATORY for all .sql files)

- ALL SQL must be idempotent — every CREATE/ALTER guarded with IF NOT EXISTS / IF OBJECT_ID / COL_LENGTH checks.
- ALL stored procedures must have `SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON;` before CREATE OR ALTER.
- ALL stored procedures must have `SET NOCOUNT ON;` and `BEGIN TRY...END TRY` / `BEGIN CATCH...END CATCH` with `THROW`.
- ALL ALTER TABLE ADD column must be guarded: `IF COL_LENGTH('Table', 'Col') IS NULL`.
- ALL ALTER TABLE DROP column must be guarded: `IF COL_LENGTH('Table', 'Col') IS NOT NULL`.
- NO hardcoded database names — never `USE [DatabaseName]`.
- ALL reserved words used as identifiers MUST be bracketed: `[Plan]`, `[User]`, `[Key]`, `[Order]`, `[Group]`, `[Role]`, `[Type]`, `[Status]`, `[Level]`, `[Name]`, `[Value]`, `[Date]`, `[Action]`, `[State]`, `[Index]`, `[Description]`.
- FOREIGN KEY REFERENCES must verify referenced table exists (IF OBJECT_ID guard).
- Seed data: use MERGE or IF NOT EXISTS — never blind INSERT INTO.
- NEWSEQUENTIALID() only in DEFAULT constraints — use NEWID() elsewhere.
- Migration scripts: wrap in transactions, check __MigrationHistory.

## .NET Backend Compliance (MANDATORY for all .cs controller/service files)

- Every controller and service class must have exactly ONE public constructor. NEVER add a second constructor — ASP.NET Core DI cannot resolve ambiguous constructors.
- Every controller action MUST have an explicit route attribute: `[HttpGet("specific-path")]`, `[HttpPost("create")]`, etc.
- NEVER rely on `[Route("api/[controller]")]` alone without action-level route segments.
- Before declaring a route, verify no other controller already uses the same HTTP method + path combination. Duplicate routes break Swagger and cause runtime 500 errors.
- Health checks MUST include timeout: `.AddCheck("name", check, timeout: TimeSpan.FromSeconds(5))`.
- Health checks MUST have tags for probe separation: `tags: new[] { "ready" }` or `tags: new[] { "live" }`.
- Health checks for external services (Azure Storage, Redis, RabbitMQ, etc.) MUST be conditionally registered based on configuration — never assume localhost services are running.
- Pattern for conditional health checks: `if (!string.IsNullOrEmpty(config["ConnectionString"])) { builder.AddCheck(...); }`
- Every controller action MUST have `[ProducesResponseType]` annotations for all response codes (200, 400, 404, 500).
- Middleware pipeline order: `UseRouting()` -> `UseCors()` -> `UseAuthentication()` -> `UseAuthorization()` -> `MapControllers()`.
- `UseSwagger()`/`UseSwaggerUI()` must be wrapped in `if (app.Environment.IsDevelopment())`.

## Data Access Defensive Patterns (MANDATORY)

- ALL `GetById` stored procedures MUST return an empty result set for missing/deleted records — NEVER throw a SQL error for non-existent IDs.
- ALL repository methods calling `GetById` procs MUST handle empty results gracefully (return null, not throw).
- ALL frontend API calls for referenced/related records (e.g., fetching exam details from a result) MUST be best-effort: catch errors, build fallback objects from available data, and never crash the parent view.
- ALL frontend pages MUST use real API calls via useQuery/fetch/apiClient — `const mockData = [...]` or inline static arrays are BANNED.
- `Program.cs` MUST register every `IXxxService` and `IXxxRepository` with `AddScoped<>` — missing DI registrations cause runtime 500 errors.
- `appsettings.json` MUST have a populated `ConnectionStrings.DefaultConnection` — empty or placeholder connection strings are BANNED.

## Quality Checks

Before outputting each file, verify:
- All functions have implementations (not just signatures)
- All error paths are handled
- All imports resolve to real modules
- TypeScript types are correct and complete
- No `any` types unless absolutely necessary
- No hardcoded values that should be configurable
- No hardcoded colors, shadows, or font sizes in frontend files (use design tokens)

Generate the complete implementation now. Output ONLY file contents with `--- FILE: path ---` markers.
