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

### Route Declaration Rules
- Every controller action MUST have an explicit route attribute ([HttpGet("specific-path")])
- NEVER rely on [Route("api/[controller]")] alone for action routes — always specify the action path
- Before adding a route, verify no other controller already declares the same HTTP method + path
- Use API versioning consistently (all v1/api/... or all /api/... — never mix)

### Dependency Injection Rules
- Controllers and services MUST have exactly ONE public constructor
- All dependencies injected via constructor parameters
- NEVER add a second constructor for "convenience" or testing — use a different pattern

### Health Check Rules
- Health checks MUST have a timeout (e.g., .AddCheck("name", check, timeout: TimeSpan.FromSeconds(5)))
- Health checks MUST have tags for liveness vs readiness separation
- Health checks depending on external services MUST be conditionally registered based on configuration
- NEVER assume localhost services (Azurite, Redis, etc.) are running — check configuration first
- Pattern: if (string.IsNullOrEmpty(connectionString)) { skip health check registration }

### Middleware Pipeline Order
- UseRouting() before UseAuthentication() before UseAuthorization() before MapControllers()
- UseCors() before UseAuthentication()
- UseSwagger()/UseSwaggerUI() wrapped in if (app.Environment.IsDevelopment())

## TypeScript / React
- TypeScript strict mode
- React 18 functional components with hooks
- React Query for server state (no Redux for API data)
- Zustand for client-only state
- Tailwind CSS for styling (use design tokens from Figma analysis)
- Named exports (no default exports)
- Barrel exports via index.ts files

## Design System Requirements

All frontend code MUST adhere to the project's design system. These rules are non-negotiable.

### Color Tokens
- All colors MUST use CSS custom properties: `var(--color-primary)`, `var(--color-surface)`, etc.
- NEVER hardcode hex (`#3B82F6`), rgb (`rgb(59,130,246)`), or hsl values in components or stylesheets.
- Tailwind arbitrary values (`text-[#3B82F6]`) are BANNED. Use extended theme tokens instead.

### Theme Provider
- `ThemeProvider` (or `FluentProvider` for Fluent UI projects) MUST wrap the app root in the entry point (e.g., `App.tsx` or `main.tsx`).
- The provider must load design tokens from a central `theme.ts` or `tokens.ts` file.

### Design Token Coverage
- ALL design tokens extracted from Figma analysis (`_analysis/03-design-system.md`) must be present as CSS custom properties in a global stylesheet (e.g., `tokens.css` or `theme.css`).
- Token categories: colors, typography scale, spacing scale, border-radius, elevation/shadows, z-index layers.

### Responsive Design
- Use Tailwind responsive breakpoints: `sm:`, `md:`, `lg:`, `xl:`, `2xl:`.
- Every page and layout component must be usable at mobile (320px) through desktop (1440px+).
- Use `container` and `max-w-*` utilities for content width constraints.

### Dark Mode
- Support dark mode via the `.dark` class on the root element (Tailwind `darkMode: 'class'`).
- All color tokens must have dark-mode overrides in a `.dark { }` block or via `dark:` Tailwind variants.
- Never assume a light background — always use semantic token names (e.g., `--color-surface`, `--color-on-surface`).

### Elevation / Shadows
- Use CSS custom properties for all shadows: `var(--shadow-sm)`, `var(--shadow-md)`, `var(--shadow-lg)`.
- NEVER hardcode `box-shadow` values in components.
- Define elevation levels (0-5) mapping to shadow tokens.

### Typography
- Use the design token type scale: `var(--font-size-xs)` through `var(--font-size-4xl)`.
- NEVER use arbitrary font sizes (`text-[13px]`). Map to the nearest token.
- Font weights and line heights must also come from tokens.

## Frontend Completeness Rules

These rules are MANDATORY for any project with Figma designs. Violations will cause the pipeline to demote requirements back to "partial" or "not_started".

### Screen Implementation
- Every Figma screen (from `01-screen-inventory.md`) MUST have a corresponding React page component (.tsx file).
- Every page component MUST handle all states: loading, error, empty data, and populated data.
- Every page component MUST be routed in App.tsx (or the project's router config).
- Page components MUST NOT render placeholder content like "Coming soon" or empty divs.

### API Wiring (CRITICAL)
- Every page MUST use real API calls via the service layer (apiClient, fetch, axios, React Query hooks).
- `const mockData = [...]` is BANNED in production pages. No mock arrays, no fake data objects.
- `const dummyXxx`, `const fakeXxx`, `const sampleXxx`, `const stubXxx` are all BANNED.
- If an API endpoint isn't ready, use loading/error states — NEVER hardcode dummy data.
- Every API endpoint in `06-api-contracts.md` MUST have a corresponding frontend service call.

### Stub / Placeholder Ban
- `// FILL` comments are BANNED in page render functions.
- `// TODO` comments are BANNED in page render functions (use a separate TODO tracker).
- `// PLACEHOLDER` and `// STUB` are BANNED anywhere in production code.
- `throw new Error("Not implemented")` is BANNED in production code.
- Empty function bodies (`() => {}`) for event handlers are BANNED — implement or throw.

### Component Implementation
- Every Figma component (from `02-component-inventory.md`) MUST have a React implementation.
- Components MUST accept typed props (TypeScript interface).
- Components MUST use design tokens, not hardcoded colors/spacing.
- Components MUST be exported via barrel files (index.ts).

### Theme & Design System
- ThemeProvider (or equivalent) MUST wrap the entire app tree in the entry point.
- All design tokens from `03-design-system.md` MUST be present as CSS custom properties.
- No hardcoded hex colors in component files — use `var(--color-*)` or Tailwind theme tokens.

## SQL Server / Database

### Naming
- Stored procedures: `usp_Entity_Action` (e.g., `usp_Patient_GetById`)
- Tables: PascalCase singular (e.g., `Patient`, `AppointmentSlot`)
- Indexes: `IX_Table_Column` for non-clustered, `PK_Table` for primary keys
- Foreign keys: `FK_ChildTable_ParentTable`

### Stored Procedures for ALL Data Access
- No inline SQL in application code, no ORM queries
- Repository pattern: Controller -> Service -> Repository -> Stored Procedure

### Idempotency (MANDATORY)
- Every CREATE TABLE: guard with `IF OBJECT_ID('dbo.TableName', 'U') IS NULL`
- Every CREATE PROCEDURE: use `CREATE OR ALTER PROCEDURE`
- Every CREATE VIEW: use `CREATE OR ALTER VIEW`
- Every CREATE FUNCTION: use `CREATE OR ALTER FUNCTION`
- Every ALTER TABLE ADD column: guard with `IF COL_LENGTH('TableName', 'ColumnName') IS NULL`
- Every ALTER TABLE DROP column: guard with `IF COL_LENGTH('TableName', 'ColumnName') IS NOT NULL`
- Every migration: check `__MigrationHistory` before executing
- Every seed INSERT: use MERGE or `IF NOT EXISTS` pattern

### SET Options (MANDATORY)
- Every file creating/altering procs, views, functions MUST start with:
  ```sql
  SET ANSI_NULLS ON;
  SET QUOTED_IDENTIFIER ON;
  ```
- Every stored procedure body MUST start with `SET NOCOUNT ON;`

### Reserved Words (MANDATORY)
- ALWAYS bracket reserved words used as identifiers: `[Plan]`, `[User]`, `[Key]`, `[Order]`, `[Group]`, `[Role]`, `[Type]`, `[Status]`, `[Level]`, `[Action]`, `[State]`, `[Value]`, `[Name]`, `[Date]`, `[Time]`, `[Count]`, `[File]`, `[Size]`, `[Index]`, `[Description]`, `[Source]`, `[Target]`, `[Table]`, `[Column]`, `[Schema]`, `[Database]`, `[Identity]`, `[Default]`, `[Check]`, `[Primary]`, `[Foreign]`, `[Reference]`, `[Transaction]`
- This applies to column names, table aliases, parameters, and variable names

### No Hardcoded Database Names
- NEVER use `USE [DatabaseName]` — scripts must work against whatever DB they're connected to
- NEVER hardcode database names in `EXEC` or dynamic SQL
- If cross-database reference is truly needed, use synonyms or configuration

### Schema Compatibility
- Before referencing a column in ALTER/UPDATE/WHERE, verify it exists with `COL_LENGTH`
- Foreign keys: only create if referenced table exists (`IF OBJECT_ID` guard)
- Type-safe: verify column types before INSERT/UPDATE (don't assume UNIQUEIDENTIFIER vs INT)
- For schema-variant-safe operations, use dynamic SQL with `COL_LENGTH` checks
- `NEWSEQUENTIALID()` is ONLY valid as a DEFAULT constraint — use `NEWID()` for variables/inserts

### Error Handling (MANDATORY)
- All stored procedures: `BEGIN TRY...END TRY` / `BEGIN CATCH...END CATCH` with `THROW`
- All migration scripts: wrap in transactions (`BEGIN TRAN...COMMIT`/`ROLLBACK`)
- `SET NOCOUNT ON` in every procedure
- Never swallow errors — always re-throw or log

### Migration Best Practices
- Number migrations sequentially (`001_`, `002_`, ...)
- Each migration is self-contained and idempotent
- Include rollback logic or document manual rollback steps
- Test against empty DB AND populated DB
- Master deploy script must handle execution order
- Always check `__MigrationHistory` or equivalent before running

### Seed Data
- Use MERGE for upsert semantics
- Guard type-sensitive inserts (check column types before inserting)
- Don't assume specific ID types — use the table's actual column type
- Add `SET IDENTITY_INSERT` only when needed and turn it OFF after
- Never use blind `INSERT INTO` — always guard with `IF NOT EXISTS` or `MERGE`

### Foreign Key Constraints
- Constraints on all relationships
- Indexes on all foreign key columns and common query filters
- Guard FK creation with `IF OBJECT_ID` check on referenced table
- Avoid circular foreign key chains — use logical enforcement if needed

### Test Framework Dependencies
- Never include test framework dependencies (e.g., `tSQLt`) in production migration scripts
- Separate test setup scripts from deployment scripts
- Test schemas should be isolated from production schemas

## Defensive Data Access (MANDATORY)

### Stored Procedure Null Safety
- ALL `GetById` stored procedures MUST return an empty result set for non-existent/deleted IDs — NEVER throw or raise an error.
- Pattern: `SELECT ... FROM Table WHERE Id = @Id` (naturally returns empty if not found). Do NOT use `IF NOT EXISTS ... THROW`.
- For lookup joins (e.g., getting an exam for a result), use LEFT JOIN so the parent query succeeds even if the child record was deleted.
- All `GetById` procs should follow this pattern:
  ```sql
  CREATE OR ALTER PROCEDURE usp_Entity_GetById @Id UNIQUEIDENTIFIER
  AS
  BEGIN
      SET NOCOUNT ON;
      BEGIN TRY
          SELECT * FROM [Entity] WHERE [Id] = @Id;
          -- Returns empty result set if not found (no error thrown)
      END TRY
      BEGIN CATCH
          THROW;
      END CATCH
  END
  ```

### Frontend Graceful Degradation
- When fetching related/referenced records (e.g., exam details for a result), treat missing references as BEST-EFFORT.
- NEVER let a missing child record crash the parent view (e.g., deleted exam should not break the results dashboard).
- Pattern: wrap lookups in try/catch, build a fallback object from available data if the referenced record is gone.
- Use `?.` optional chaining and nullish coalescing `??` for all nested data access from API responses.
- API error responses for "not found" references should be handled silently (no red toast/error banner) — log to console only.

### Connection String & Configuration Wiring
- `appsettings.json` MUST have a valid `ConnectionStrings` section with at least a `DefaultConnection` entry.
- Connection strings MUST use parameterized format: `Server=;Database=;Trusted_Connection=true;` or `Server=;Database=;User Id=;Password=;` — NEVER leave empty.
- `Program.cs` MUST register ALL repository and service interfaces with `builder.Services.AddScoped<IXxxRepository, XxxRepository>()`.
- Every `IXxxRepository` interface MUST have a matching `AddScoped` (or `AddTransient`/`AddSingleton`) registration — unregistered interfaces cause runtime DI exceptions.
- Frontend API base URL MUST be configurable via environment variable or config file — NEVER hardcode `localhost:5000`.

## File Output Format
When generating code, output files with clear markers:

```
--- FILE: path/to/file.ts ---
// file content here

--- FILE: path/to/another-file.cs ---
// file content here
```

Each file must be complete and self-contained. Include all imports/usings.
