# Phase 8: Integration Smoke Test

You are performing integration smoke testing on a generated codebase. Code review has already passed. You are looking for REAL-WORLD integration issues that static review misses.

## Project Context
{{PROJECT_CONTEXT}}

## Database Connection Info
{{DATABASE_CONNECTION_INFO}}

## Azure AD Configuration
{{AZURE_AD_CONFIG}}

## Test User Credentials
{{TEST_USER_CREDENTIALS}}

---

## Phase-Specific Instructions

### Phase: build_validation
Run build commands and analyze output for compilation errors, missing dependencies, type mismatches.

**Checklist:**
- dotnet build succeeds with zero errors
- npm run build / vite build succeeds with zero errors
- No TypeScript strict mode violations
- No missing package references
- No circular dependency warnings

### Phase: database_validation
Validate database schema completeness and stored procedure coverage.

**Checklist:**
- Every stored procedure referenced in C# code (usp_*) has a matching SQL definition file
- Every table referenced in SQL has a CREATE TABLE statement
- Foreign key references point to existing tables
- All columns referenced in SELECT/INSERT/UPDATE exist in their tables
- Migration ordering is correct (no forward references to tables not yet created)
- Seed data references valid tables, columns, and data types
- SET ANSI_NULLS ON / SET QUOTED_IDENTIFIER ON present on all procs
- SET NOCOUNT ON in every procedure body
- Error handling (BEGIN TRY/CATCH) in every procedure
- Idempotency guards on all DDL statements (IF OBJECT_ID, IF COL_LENGTH)

### Phase: api_smoke_test
Validate API endpoint configuration, middleware ordering, and controller setup.

**Checklist:**
- /health or /api/health endpoint exists and is mapped
- All controller routes are valid (no duplicate verb+path combinations)
- CORS policy is configured in Program.cs/Startup.cs
- Swagger/OpenAPI configured for Development environment
- Middleware pipeline order: UseRouting -> UseAuthentication -> UseAuthorization -> MapControllers
- UseCors() before UseAuthentication()
- All controllers have [ApiController] and [Route] attributes
- Every action has explicit HTTP method attribute ([HttpGet], [HttpPost], etc.)
- DTOs used in API responses (not raw domain models)
- Input validation configured (FluentValidation or DataAnnotations)
- Error handling middleware present (UseExceptionHandler or custom)
- All injected services have matching DI registrations

### Phase: frontend_route_validation
Validate React router configuration against actual page components.

**Checklist:**
- Every Route element has a matching imported component
- Every lazy() import path resolves to an existing file
- No duplicate route paths
- Nested routes have Outlet in parent components
- All imports in App.tsx/router.tsx resolve to existing files
- Protected routes wrapped with auth guards
- 404/NotFound catch-all route exists
- No broken lazy load imports
- Route hierarchy is logical and consistent

### Phase: auth_flow_validation
Validate authentication and authorization wiring end-to-end.

**Checklist:**
- Authentication middleware registered in correct pipeline order
- JWT Bearer or Azure AD auth configured with all required settings (issuer, audience, etc.)
- [Authorize] on all controllers/actions that need protection
- Frontend AuthProvider wraps the app tree
- Protected routes redirect to login when unauthenticated
- Token refresh logic exists (not just initial token acquisition)
- Role-based authorization where needed ([Authorize(Roles = "...")])
- Auth token attached to API calls (Authorization: Bearer header)
- Logout clears tokens and redirects appropriately
- CORS allows frontend origin for auth-related endpoints

### Phase: module_completeness
Verify all 3 layers exist for each documented module: API, frontend, database.

**Checklist:**
- Each module in docs has a matching backend controller
- Each module in docs has a matching frontend page
- Each module in docs has matching stored procedures/tables
- Each controller has a matching frontend page that calls its endpoints
- CRUD completeness: Create, Read, Update, Delete all present where expected
- List endpoints have pagination parameters
- Detail endpoints accept ID parameters
- No orphaned controllers (no matching frontend consumer)
- No orphaned pages (no matching API endpoints)

### Phase: mock_data_detection
Scan for development artifacts that should not be in production code.

**Checklist:**
- const mockXxx = [...] or const fakeXxx = [...] in non-test files
- // TODO, // FIXME, // HACK, // PLACEHOLDER, // FILL comments
- console.log, console.warn, console.error statements (should use structured logging)
- Empty function bodies: () => {}
- throw new Error("Not implemented")
- Hardcoded data arrays that should come from API calls
- Static return values in service functions that should call real APIs
- Commented-out code blocks (dead code)
- Hardcoded localhost URLs or port numbers
- Hardcoded API keys or secrets

### Phase: e2e_smoke_test
Validate that all screens render and CRUD operations work end-to-end using Playwright E2E tests.

**Checklist:**
- All screen components render without "Application Error" (React ErrorBoundary not triggered)
- Navigation links work for each role (technijian_admin, client_admin, client_user)
- CRUD flows: Create form opens, required fields fill, submit completes without validation error
- Real API data appears in lists (not static mock data)
- Role-based guards: forbidden screens show 403, not crash
- No hardcoded user IDs in screen components (grep: `const currentUserId = '`)
- No module-scope state references in router functions (grep: `appState` inside module-level function)
- Playwright test: `npx playwright test` → all pass, 0 failures

**Key patterns that break E2E but pass code review:**
1. `Array.isArray(apiData) ? apiData : staticFallback` — paginated wrapper returns object, static always used
2. `const currentUserId = 'hardcoded-value'` — real API items filtered out silently
3. `appState.user?.id` referenced inside module-scope router function — ReferenceError at runtime
4. `useNavigate()` inside state-machine app — throws because no BrowserRouter context

### Phase: rbac_matrix
Build and validate the role-based access control matrix.

**Checklist:**
- Matrix mapping: Route/Endpoint -> Required Roles -> Actual Guard Implementation
- Every sensitive backend endpoint has [Authorize] or [Authorize(Roles = "...")]
- Every protected frontend route has an auth guard component
- Backend role names match frontend role checks (case-sensitive comparison)
- Public endpoints (login, register, health) do NOT have [Authorize]
- Admin-only endpoints have explicit role restrictions
- Frontend conditionally shows/hides nav items based on user roles
- API returns proper status codes: 401 unauthenticated, 403 unauthorized

---

## Output Format

For each phase, return a JSON object:

```json
{
  "phase": "phase_name",
  "status": "pass | fail | warn",
  "issues": [
    {
      "severity": "critical | high | medium | low",
      "category": "build_error | db_gap | api_gap | frontend_gap | auth_gap | module_gap | mock_data | rbac_gap",
      "file": "relative/path/to/file",
      "description": "Clear description of the issue",
      "fix_suggestion": "Specific suggestion for how to fix"
    }
  ],
  "summary": "1-2 sentence summary of findings"
}
```

### Severity Definitions
- **critical**: Blocks application from running (build errors, missing tables, broken routes)
- **high**: Security vulnerability or data integrity risk (missing auth, unprotected endpoints)
- **medium**: Functional gap that affects user experience (mock data, missing CRUD operations)
- **low**: Code quality issue (console.log, TODO comments, style inconsistencies)

Respond with ONLY the JSON object. No markdown fences, no explanation.
