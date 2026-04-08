# Build Phase - Codex
# Per-iteration: generate code for the next batch from blueprint
# You have UNLIMITED tokens. Generate COMPLETE, PRODUCTION-READY files.

## Context
- Iteration: {{ITERATION}}
- Health: {{HEALTH}}%
- Project: {{REPO_ROOT}}

## Read These Files
1. {{GSD_DIR}}\blueprint\next-batch.json - YOUR WORK ORDER (the items to build NOW)
2. {{GSD_DIR}}\blueprint\blueprint.json - full blueprint for context and dependencies
3. {{GSD_DIR}}\blueprint\figma-tokens.md - design tokens (if exists)
4. {{GSD_DIR}}\blueprint\partial-fixes.md - fixes needed for partial items (if exists)
5. docs\ - SDLC specification documents (read sections referenced in spec_source)
6. {{FIGMA_PATH}} - Figma designs (check frames referenced in figma_frame)
7. Existing source code - understand current project state

## For Each Item in next-batch.json

### Read its spec_source
Go to the spec document referenced. Read the FULL section. Understand every detail.

### Read its figma_frame (if UI component)
Look at the Figma file referenced. Match the design EXACTLY.

### Generate the File
Create the COMPLETE file at the path specified. Not a snippet - the full file.

### Follow Project Patterns STRICTLY

**SQL Migrations & Stored Procedures:**
- Parameterized queries ONLY (never string concatenation)
- Include IF EXISTS checks for idempotent migrations
- Audit columns: CreatedAt DATETIME2, CreatedBy NVARCHAR(100), ModifiedAt, ModifiedBy
- Proper indexing on foreign keys and lookup columns
- GRANT EXECUTE permissions in stored procedures
- TRY/CATCH with THROW in stored procedures

**.NET 8 Backend:**
- Dapper for ALL data access (never Entity Framework)
- Repository pattern: IUserRepository -> UserRepository calling stored procedures
- Service layer: IUserService -> UserService with business logic
- Controllers: thin, delegate to services, return proper HTTP status codes
- DTOs: separate request/response models, never expose entities
- FluentValidation for input validation
- Serilog structured logging
- Dependency injection registration in Program.cs

**React 18 Frontend:**
- Functional components with hooks ONLY
- Match Figma: exact colors, spacing, typography, responsive breakpoints
- Accessibility: ARIA labels, keyboard nav, focus management
- Error boundaries at route level
- Loading states / skeleton screens
- Use design tokens from figma-tokens.md

**Compliance Patterns:**
- HIPAA: [Authorize] on PHI endpoints, audit log PHI access, encrypt at rest
- SOC 2: Role-based [Authorize(Roles = "...")] on all endpoints
- PCI: never log card numbers, tokenization for payment data
- GDPR: consent tracking, data export endpoint, data deletion endpoint

### Security & Quality Standards (MANDATORY)
Follow ALL rules in: %USERPROFILE%\.gsd-global\prompts\shared\security-standards.md
Follow conventions in: %USERPROFILE%\.gsd-global\prompts\shared\coding-conventions.md
Ensure database completeness per: %USERPROFILE%\.gsd-global\prompts\shared\database-completeness-review.md
Every violation will be caught by the council review and final validation.

### Meet ALL Acceptance Criteria
After generating each file, mentally verify it meets every acceptance criterion
listed in the blueprint item. If it doesn't, fix it before moving on.

### Handle Partial Items
If partial-fixes.md exists, address those specific issues FIRST before new items.
Partial items are items that were generated previously but didn't fully meet criteria.

## After Generating All Items

Append to {{GSD_DIR}}\blueprint\build-log.jsonl:
```json
{
  "iteration": {{ITERATION}},
  "items_built": [1, 2, 3],
  "items_fixed": [4],
  "files_created": ["src/path/file.cs"],
  "files_modified": ["src/path/existing.cs"],
  "timestamp": "..."
}
```

## Boundaries
- DO NOT modify {{GSD_DIR}}\blueprint\blueprint.json (that's the verifier's job)
- DO NOT modify {{GSD_DIR}}\blueprint\health.json
- DO NOT modify {{GSD_DIR}}\blueprint\next-batch.json
- WRITE source code files + build-log.jsonl ONLY

## Partial Repo Handling
ALSO READ: {{GSD_DIR}}\..\..\.gsd-global\blueprint\prompts\codex\partial-repo-guide.md
If blueprint items have status "partial", "refactor", or "extend", you MUST follow
the partial-repo guide. Key rules:
- READ existing files before modifying them
- PRESERVE interfaces and contracts listed in the preserve array
- For refactors: create stored procedures BEFORE rewriting repositories
- NEVER delete files without creating replacements first
- Check import dependencies before changing any exports
