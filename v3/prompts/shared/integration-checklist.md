# Module Integration Checklist

Every module MUST pass ALL checks in its applicable layers before marking "satisfied".
File-exists is NOT sufficient. The module must be wired end-to-end.

## Per-Module Verification

### Layer 1: Database
- [ ] Table exists with correct schema (columns, types, constraints)
- [ ] Stored procedures exist and match API parameter expectations (names, types, order)
- [ ] Seed data exists (if applicable — lookup tables, default roles, etc.)
- [ ] Connection string resolves to real database (not placeholder like `Server=YOUR_SERVER`)
- [ ] SP is actually called from backend repository (not just defined in SQL)
- [ ] SP parameter names match the C#/backend parameter names exactly

### Layer 2: Backend API
- [ ] Controller exists with correct route attributes (`[Route("api/[controller]")]`)
- [ ] Controller methods call repository/service (not returning mock/hardcoded data)
- [ ] Repository uses Dapper/EF to call real stored procedures (not in-memory lists)
- [ ] DI registration exists in Program.cs/Startup.cs (`builder.Services.AddScoped<IRepo, Repo>()`)
- [ ] Auth attributes (`[Authorize]`, `[Authorize(Roles="...")]`) applied correctly
- [ ] Error handling returns proper HTTP status codes (400, 401, 403, 404, 500)
- [ ] No hardcoded/mock data in responses (no `return Ok(new List<User> { ... })`)
- [ ] Model/DTO classes have correct property names matching frontend expectations
- [ ] Swagger/OpenAPI annotations present for API documentation

### Layer 3: Frontend
- [ ] Page component exists and is imported in router (App.tsx / router.tsx)
- [ ] Route is accessible (not hidden by broken guard/role check)
- [ ] Page calls real API endpoint (not mock hook returning static data)
- [ ] CRUD: Create form submits via API POST, receives and handles response
- [ ] CRUD: Read/List calls API GET, renders response data in UI
- [ ] CRUD: Update form submits via API PUT/PATCH, receives and handles response
- [ ] CRUD: Delete action calls API DELETE, removes item from UI on success
- [ ] Loading states shown during API calls (`isLoading`, skeleton, spinner)
- [ ] Error states shown on API failure (toast, alert, error boundary)
- [ ] No `console.log` / `console.error` in production code
- [ ] No `TODO` / `FIXME` / `FILL` / `PLACEHOLDER` markers remaining
- [ ] No `useState` with hardcoded arrays as initial mock data
- [ ] Form validation exists for required fields

### Layer 4: Integration (end-to-end data flow)
- [ ] Frontend to Backend: API calls use correct base URL and auth headers
- [ ] Backend to Database: Connection string is real, not placeholder
- [ ] Auth flow: Login produces token, token sent on protected requests, logout clears token
- [ ] Role-based visibility: Each role sees correct navigation items and routes
- [ ] Data flow: Create in UI, verify in DB, re-fetch in UI shows new data
- [ ] Error propagation: DB error surfaces as meaningful message in UI (not generic 500)
- [ ] Pagination: If list has many items, pagination/infinite scroll works end-to-end

### Layer 5: Cross-Cutting
- [ ] CORS configured for frontend origin (not `*` in production)
- [ ] Auth middleware wired in correct order (`UseAuthentication()` before `UseAuthorization()`)
- [ ] Error boundaries exist for React component crashes
- [ ] API error responses include correlation IDs for debugging
- [ ] No secrets in client-side code or browser console output
- [ ] Environment-specific config (dev/staging/prod) uses correct values
- [ ] Health check endpoint exists and returns 200 when all dependencies are up

## How to Use This Checklist

### During Code Review (Phase 6)
For each requirement under review, check the applicable layers. A page requirement
must pass Layers 3, 4, and 5. An API requirement must pass Layers 2, 4, and 5.
A full-stack feature must pass ALL layers.

### During Verification (Phase 7)
Only promote a requirement to "satisfied" if ALL applicable checklist items pass.
If any item fails, the requirement stays "partial" with the failing items listed
as blocking issues.

### During Wire-Up (Phase 9)
Systematically go through every checklist item for every module. Fix all gaps.
This is the phase that prevents "file exists but nothing works" syndrome.
