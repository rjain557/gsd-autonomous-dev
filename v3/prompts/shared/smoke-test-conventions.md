# Smoke Test Conventions

## Purpose
Integration smoke testing runs AFTER code review to catch real-world issues that static code review cannot detect. These include cross-layer wiring gaps, missing DI registrations, broken route-component mappings, leftover mock data, and RBAC mismatches.

## When To Run
- After code review completes (manually or via `-RunSmokeTest` flag on gsd-codereview.ps1)
- After major refactoring or module additions
- Before developer handoff as a final quality gate
- After convergence when health reaches 100%

## Project Configuration Template

Each project should provide these context values for accurate smoke testing:

### Database Connection
```
ConnectionString: "Server=.;Database=ProjectDb;Trusted_Connection=true;TrustServerCertificate=true;"
```
- Required for live DB validation (table/SP existence checks)
- If not provided, falls back to static file analysis (checking .sql files)

### Azure AD / Auth Configuration
```json
{
  "tenantId": "your-tenant-id",
  "clientId": "your-client-id",
  "audience": "api://your-api-id",
  "instance": "https://login.microsoftonline.com/",
  "scopes": ["api://your-api-id/.default"]
}
```
- Required for auth flow validation
- If not provided, auth checks are limited to code pattern analysis

### Test User Credentials
```json
[
  {"username": "admin@test.com", "password": "Test123!", "roles": ["Admin", "User"]},
  {"username": "user@test.com", "password": "Test123!", "roles": ["User"]},
  {"username": "readonly@test.com", "password": "Test123!", "roles": ["ReadOnly"]}
]
```
- Used for role-based access matrix validation
- Define at least one user per role level

### Functional Expectations
Each project should document which modules/features are expected:
- List of CRUD modules (e.g., Users, Products, Orders)
- List of read-only/dashboard modules
- List of admin-only features
- Expected API endpoint count range
- Expected page/screen count

## Testing Requirements

### Build Validation
- Backend: `dotnet build` must complete with zero errors
- Frontend: `npm run build` or `vite build` must complete with zero errors
- Both builds must succeed in CI-clean environment (no local-only dependencies)

### Database Completeness
- Every `usp_*` reference in C# code must have a matching SQL file
- Every table in SQL must have a CREATE TABLE definition
- All foreign keys must reference existing tables
- Seed data must be type-safe and reference valid columns
- Migration scripts must be idempotent

### API Layer
- Health endpoint required at `/api/health` or `/health`
- CORS must be configured for frontend origin
- Middleware pipeline must follow correct order
- Every controller action needs explicit route + HTTP method attribute
- DI registrations must cover all injected interfaces

### Frontend Layer
- Every route must map to an existing page component
- No broken lazy imports
- Auth guards on protected routes
- 404 catch-all route present
- No mock/fake/dummy/sample data in production pages

### Auth Layer
- Authentication middleware properly ordered
- Token refresh implemented (not just initial auth)
- Role-based authorization on sensitive endpoints
- Frontend and backend role names must match

### Mock Data Ban
The following patterns are BANNED in production code (non-test files):
- `const mockXxx = [...]`
- `const fakeXxx = [...]`
- `const dummyXxx = [...]`
- `const sampleXxx = [...]`
- `const stubXxx = [...]`
- `// TODO`, `// FIXME`, `// HACK`, `// PLACEHOLDER`, `// FILL`
- `console.log(...)`, `console.warn(...)`, `console.error(...)`
- `throw new Error("Not implemented")`
- `() => {}` (empty event handlers)

## Gap Report Template

The integration gap report categorizes all findings by type:

### Categories
| Category | Description |
|----------|-------------|
| build_error | Compilation failures in backend or frontend |
| db_gap | Missing tables, stored procedures, columns, or FK violations |
| api_gap | Missing endpoints, incorrect middleware, DI registration issues |
| frontend_gap | Broken routes, missing components, import errors |
| auth_gap | Missing auth middleware, unprotected endpoints, missing guards |
| module_gap | Missing full-stack wiring for documented modules |
| mock_data | Leftover mock data, TODOs, console.log in production code |
| rbac_gap | Role-route mismatches, missing authorization attributes |

### Severity Scale
| Severity | Description | Fix Priority |
|----------|-------------|--------------|
| critical | App cannot start or has security vulnerability | Immediate |
| high | Feature broken or data integrity at risk | Before release |
| medium | Degraded UX or incomplete feature | Should fix |
| low | Code quality or style issue | Nice to fix |

## Known Patterns To Check For

Based on real-world experience with generated codebases, these integration gaps are the most common:

### 1. DI Registration Gaps
Every `IXxxRepository` and `IXxxService` interface MUST have a matching `AddScoped<>` (or equivalent) registration in `Program.cs`. Missing registrations cause runtime crashes, not build errors.

### 2. Connection String Placeholders
Generated `appsettings.json` files often contain `Server=.;Database=YourDb` or empty connection strings. These pass build validation but fail at runtime.

### 3. Frontend Pages Without API Calls
Page components that render static/mock data instead of calling real API endpoints via useQuery/useMutation. Especially common in dashboard and list views.

### 4. Route-Component Mismatches
`App.tsx` imports a component from path A, but the component actually lives at path B. Works in development with hot reload but fails in production builds.

### 5. Blocked File Accumulation
When the pipeline cannot write to key files (App.tsx, Program.cs, shared types), route and DI registrations accumulate as "intended but never written". The smoke test catches these because the wiring simply does not exist.

### 6. Orphaned Stored Procedures
C# repository code references `usp_Entity_Action` but no matching `.sql` file exists, or the SQL file has a typo in the procedure name. Passes code review but fails at runtime.

### 7. Auth Middleware Ordering
`UseAuthentication()` and `UseAuthorization()` placed before `UseRouting()` causes all routes to silently skip auth. Extremely common and hard to catch in code review.

### 8. Role Name Case Mismatches
Backend uses `[Authorize(Roles = "Admin")]` but frontend checks `user.roles.includes("admin")` (lowercase). Auth appears to work but role-specific features break.

### 9. Missing Error Boundaries
Frontend pages lack error boundaries, so a single failed API call crashes the entire app instead of showing a graceful error state.

### 10. Hardcoded Localhost URLs
Frontend API client configured with `http://localhost:5000` instead of reading from environment config. Works in dev, breaks in every other environment.

## Output Files

Smoke test produces three files in `.gsd/smoke-test/`:

| File | Format | Purpose |
|------|--------|---------|
| `smoke-test-report.json` | JSON | Structured results for automation |
| `smoke-test-summary.md` | Markdown | Human-readable summary with tables |
| `gap-report.md` | Markdown | Categorized gap analysis for developer handoff |
