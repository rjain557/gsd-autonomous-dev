<#
.SYNOPSIS
    GSD Quality Gates - Database Completeness, Security Standards, Spec Validation
    Run AFTER patch-gsd-resilience-hardening.ps1.

.DESCRIPTION
    Adds three quality gates to the GSD pipeline:

    1. Database Completeness (Test-DatabaseCompleteness):
       Zero-token-cost static analysis verifying the full chain:
       API Endpoint -> Stored Procedure -> Tables -> Seed Data.
       Scans 11-api-to-sp-map.md and source files.

    2. Security Compliance (Test-SecurityCompliance):
       Zero-token-cost regex scan catching OWASP Top 10 violations:
       SQL injection, XSS, eval(), hardcoded secrets, missing [Authorize], etc.

    3. Spec Quality Gate (Invoke-SpecQualityGate):
       Enhanced spec validation combining existing consistency check with
       AI-powered clarity scoring and cross-artifact consistency checking.
       Inspired by GitHub spec-kit methodology.

    Also creates:
    - 5 shared prompt templates (security-standards, coding-conventions,
      database-completeness-review, spec-clarity-check, cross-artifact-consistency)
    - Security checklist appended to council review prompts
    - Security & quality standards reference in execute/build prompts
    - quality_gates config block in global-config.json
    - Pipeline integration in both convergence and blueprint pipelines

.INSTALL_ORDER
    1.  install-gsd-global.ps1
    2.  install-gsd-blueprint.ps1
    3.  patch-gsd-partial-repo.ps1
    4.  patch-gsd-resilience.ps1
    5.  patch-gsd-hardening.ps1
    6.  patch-gsd-final-validation.ps1
    7.  patch-gsd-council.ps1
    8.  patch-gsd-figma-make.ps1
    9.  final-patch-1-spec-check.ps1
    10. final-patch-2-sql-cli.ps1
    11. final-patch-3-interface-detection.ps1
    12. final-patch-4-blueprint-pipeline.ps1
    13. final-patch-5-convergence-pipeline.ps1
    14. final-patch-6-docs.ps1
    15. patch-gsd-supervisor.ps1
    16. patch-gsd-stall-council.ps1
    17. patch-gsd-spec-fix-council.ps1
    18. patch-gsd-parallel-execute.ps1
    19. patch-gsd-resilience-hardening.ps1
    20. patch-gsd-quality-gates.ps1       <- this file
#>

param(
    [string]$UserHome = $env:USERPROFILE
)

$ErrorActionPreference = "Stop"
$GsdGlobalDir = Join-Path $UserHome ".gsd-global"
$LibFile = Join-Path $GsdGlobalDir "lib\modules\resilience.ps1"

if (-not (Test-Path $LibFile)) {
    Write-Host "[XX] Resilience module not found. Run install chain first." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Quality Gates - DB Completeness, Security, Specs" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ==================== SECTION 1: Prompt Templates ====================

Write-Host "[1/5] Creating prompt templates..." -ForegroundColor Yellow

$sharedDir = Join-Path $GsdGlobalDir "prompts\shared"
if (-not (Test-Path $sharedDir)) { New-Item -Path $sharedDir -ItemType Directory -Force | Out-Null }

# --- security-standards.md ---
$securityStandards = @'
# Security & Compliance Standards Reference
# Source: OWASP Cheat Sheets, Microsoft .NET Conventions, HIPAA/SOC2/PCI/GDPR

All generated code MUST comply with these rules. Violations are caught by
council review and final validation scans.

---

## .NET 8 Backend Security

### Authentication & Authorization
| ID | Rule |
|----|------|
| SEC-NET-01 | `[Authorize]` attribute on ALL controller classes |
| SEC-NET-02 | `[ValidateAntiForgeryToken]` on POST/PUT/DELETE actions |
| SEC-NET-03 | HttpOnly + Secure + SameSite=Strict on all cookies |
| SEC-NET-04 | Session timeout max 60 minutes, no sliding expiration |
| SEC-NET-05 | JWT: 15-min access token, 7-day refresh token, signed with RS256 |
| SEC-NET-06 | Login throttling: rate limit on auth endpoints |
| SEC-NET-07 | Identical error messages for bad username vs bad password |
| SEC-NET-08 | ASP.NET Core Identity for auth -- never custom implementations |
| SEC-NET-09 | Verify user access to the specific resource, not just existence |

### Input Validation
| ID | Rule |
|----|------|
| SEC-NET-10 | Whitelist validation: accept known-good, reject everything else |
| SEC-NET-11 | `SqlParameter` or Dapper `@params` for ALL database queries |
| SEC-NET-12 | `IPAddress.TryParse()` and `Uri.CheckHostName()` for IP/URL input |
| SEC-NET-13 | Never use `[AllowHtml]` without proven safe content |
| SEC-NET-14 | FluentValidation or DataAnnotations on all request DTOs |

### Data Protection & Cryptography
| ID | Rule |
|----|------|
| SEC-NET-15 | AES-256 for PII/PHI encryption at rest (Data Protection API) |
| SEC-NET-16 | TLS 1.2+ enforced in Program.cs -- never SSL |
| SEC-NET-17 | PBKDF2 or bcrypt for password hashing with unique salt |
| SEC-NET-18 | SHA-512 for non-password hashing |
| SEC-NET-19 | Never implement custom cryptography |
| SEC-NET-20 | Keys in Azure Key Vault or DPAPI -- never in code or config files |
| SEC-NET-21 | Unique nonce for every encryption operation |
| SEC-NET-22 | Connection strings in environment variables or secret manager |

### Security Headers
| ID | Rule |
|----|------|
| SEC-NET-23 | `X-Content-Type-Options: nosniff` |
| SEC-NET-24 | `X-Frame-Options: DENY` |
| SEC-NET-25 | `Content-Security-Policy: default-src 'self'` (strict, no inline scripts) |
| SEC-NET-26 | `Strict-Transport-Security: max-age=15768000` (HSTS, 6 months) |
| SEC-NET-27 | Remove server version headers |

### Error Handling & Logging
| ID | Rule |
|----|------|
| SEC-NET-28 | Catch specific exception types -- never bare `catch (Exception)` |
| SEC-NET-29 | `ILogger<T>` with structured logging (Serilog pattern) |
| SEC-NET-30 | Never log passwords, tokens, API keys, SSN, card numbers, PHI |
| SEC-NET-31 | Log context: userId, requestId, timestamp, operation |
| SEC-NET-32 | Production: no debug flags, no stack traces in responses |
| SEC-NET-33 | `async/await` for all I/O; `.ConfigureAwait(false)` in library code |

### Deserialization & SSRF
| ID | Rule |
|----|------|
| SEC-NET-34 | Never use `BinaryFormatter` (CVE risk) |
| SEC-NET-35 | Use `System.Text.Json` or `DataContractSerializer` |
| SEC-NET-36 | Validate integrity before deserializing untrusted data |
| SEC-NET-37 | Validate/whitelist URLs before server-side HTTP requests |
| SEC-NET-38 | Never auto-follow redirects to prevent internal resource access |

---

## SQL Server Security

### Access Control
| ID | Rule |
|----|------|
| SEC-SQL-01 | Stored procedures ONLY -- no inline SQL from application layer |
| SEC-SQL-02 | All parameters use `SqlDbType` with explicit size |
| SEC-SQL-03 | No dynamic SQL (`sp_executesql`) with unvalidated input |
| SEC-SQL-04 | Row-level security via WHERE clause on TenantId/OrgId |
| SEC-SQL-05 | Least privilege: app account has EXECUTE only, never db_owner |
| SEC-SQL-06 | Windows Integrated Auth when possible |

### Structure & Patterns
| ID | Rule |
|----|------|
| SEC-SQL-07 | `BEGIN TRY / END TRY / BEGIN CATCH / THROW / END CATCH` in all SPs |
| SEC-SQL-08 | Audit columns on every table: CreatedAt, CreatedBy, ModifiedAt, ModifiedBy |
| SEC-SQL-09 | Audit log INSERT on all INSERT/UPDATE/DELETE of sensitive data |
| SEC-SQL-10 | Explicit column lists in SELECT -- never `SELECT *` |
| SEC-SQL-11 | Strong typing for all parameters |
| SEC-SQL-12 | IF EXISTS checks for idempotent migrations |
| SEC-SQL-13 | GRANT EXECUTE permissions explicitly in each SP |
| SEC-SQL-14 | Proper indexing on foreign keys and lookup columns |
| SEC-SQL-15 | `SET NOCOUNT ON` at top of every SP |

### Encryption & Backup
| ID | Rule |
|----|------|
| SEC-SQL-16 | TDE for PHI/PII databases |
| SEC-SQL-17 | TLS 1.2+ for all database connections |
| SEC-SQL-18 | Encrypted backups stored separately with restricted access |

---

## React 18 Frontend Security

### XSS Prevention
| ID | Rule |
|----|------|
| SEC-FE-01 | No `dangerouslySetInnerHTML` without DOMPurify sanitization |
| SEC-FE-02 | No `eval()` or `new Function()` anywhere |
| SEC-FE-03 | JSX auto-escaping for all text content |
| SEC-FE-04 | DOMPurify for any user-generated HTML rendering |

### Data & Token Handling
| ID | Rule |
|----|------|
| SEC-FE-05 | HTTPS only for all API calls |
| SEC-FE-06 | Never store tokens, PII, passwords in `localStorage` |
| SEC-FE-07 | Use httpOnly + Secure + SameSite=Strict cookies for auth tokens |
| SEC-FE-08 | `Authorization: Bearer <token>` header -- never in URL parameters |
| SEC-FE-09 | Token refresh/rotation mechanism |

### Error Handling
| ID | Rule |
|----|------|
| SEC-FE-10 | Error boundaries at route level -- never expose stack traces |
| SEC-FE-11 | User-friendly error messages, no technical details |
| SEC-FE-12 | Remove `console.log` debug statements before production |
| SEC-FE-13 | Never log sensitive data to console |

### Dependencies
| ID | Rule |
|----|------|
| SEC-FE-14 | `npm audit` in CI/CD -- fix high/critical vulnerabilities |
| SEC-FE-15 | Exact version pinning in package.json |
| SEC-FE-16 | Subresource Integrity (SRI) hashes for CDN-hosted libraries |

---

## Compliance Patterns

### HIPAA
| ID | Rule |
|----|------|
| COMP-HIPAA-01 | PHI encrypted at rest (AES-256 / TDE) and in transit (TLS 1.2+) |
| COMP-HIPAA-02 | Audit trail for all PHI access: who, what, when, from where |
| COMP-HIPAA-03 | Role-based access control for PHI endpoints |
| COMP-HIPAA-04 | Minimum necessary: grant only permissions needed for role |
| COMP-HIPAA-05 | Data isolation by organization/practice |
| COMP-HIPAA-06 | 6+ year log retention |
| COMP-HIPAA-07 | Incident reporting within 24 hours |

### SOC 2
| ID | Rule |
|----|------|
| COMP-SOC2-01 | Change control: log all production changes with approval |
| COMP-SOC2-02 | Security monitoring: failed logins, privilege escalation |
| COMP-SOC2-03 | Incident response playbook documented |
| COMP-SOC2-04 | Backup tested regularly, RTO/RPO targets defined |
| COMP-SOC2-05 | Code review mandatory for all production changes |
| COMP-SOC2-06 | Vulnerability scan + patch within SLA (critical: 24-48 hrs) |

### PCI DSS
| ID | Rule |
|----|------|
| COMP-PCI-01 | Never store raw card numbers -- use payment processor tokens |
| COMP-PCI-02 | Card data encrypted in transit (TLS 1.2+) and at rest (AES-256) |
| COMP-PCI-03 | Isolate payment systems via firewall/VLAN |
| COMP-PCI-04 | Multi-factor auth for admin access |
| COMP-PCI-05 | Never log card numbers |
| COMP-PCI-06 | Quarterly external penetration testing |

### GDPR
| ID | Rule |
|----|------|
| COMP-GDPR-01 | APIs for data export, deletion, portability |
| COMP-GDPR-02 | Explicit consent tracking for data processing |
| COMP-GDPR-03 | Data minimization: collect only necessary data |
| COMP-GDPR-04 | Privacy by design: encrypt PII by default |
| COMP-GDPR-05 | Breach notification within 72 hours |
| COMP-GDPR-06 | Data retention/deletion schedules enforced |
'@
Set-Content -Path "$sharedDir\security-standards.md" -Value $securityStandards -Encoding UTF8
Write-Host "   [OK] prompts\shared\security-standards.md" -ForegroundColor DarkGreen

# --- coding-conventions.md ---
$codingConventions = @'
# Coding Conventions Reference
# Source: Microsoft C# Conventions, React Best Practices, SQL Server Standards

## .NET 8 / C# Conventions

### Naming
| Element | Convention | Example |
|---------|-----------|---------|
| Classes, structs, enums | PascalCase | `UserService`, `OrderStatus` |
| Interfaces | I + PascalCase | `IUserRepository`, `IAuthService` |
| Methods, properties | PascalCase | `GetUserById()`, `IsActive` |
| Parameters, locals | camelCase | `userId`, `orderTotal` |
| Private fields | _camelCase | `_userRepository`, `_logger` |
| DTOs | PascalCase + Dto | `UserResponseDto`, `CreateOrderRequestDto` |

### Architecture
- Repository pattern: `IUserRepository` -> `UserRepository` (Dapper + SPs)
- Service layer: `IUserService` -> `UserService` (business logic)
- Controllers: thin, delegate to services, return `IActionResult`
- DTOs: separate request/response models, never expose entities
- Dependency injection (constructor injection), one class per file
- Allman braces, 4-space indentation, 120-char max line length

### SOLID Principles
- Single Responsibility: One class = one reason to change
- Open/Closed: Extend via interfaces, not modification
- Liskov Substitution: Derived types substitutable for base
- Interface Segregation: Small, focused interfaces
- Dependency Inversion: Depend on abstractions, not concrete types

## React 18 Conventions
- Functional components with hooks ONLY, one per file, named export
- Props interface defined above component, hooks at top of body
- PascalCase components/files, camelCase variables, UPPER_SNAKE_CASE constants
- Error boundaries at route level, loading/skeleton states for async ops

## SQL Server Conventions
- Tables: PascalCase singular (`User`, `OrderItem`)
- SPs: `usp_Entity_Action` (`usp_User_GetById`, `usp_Order_Create`)
- Views: `vw_Description`, Functions: `fn_Description`
- Indexes: `IX_Table_Column`, PKs: `PK_Table`, FKs: `FK_Child_Parent`
- `SET NOCOUNT ON`, `BEGIN TRY/END TRY/BEGIN CATCH/THROW/END CATCH`
- Audit columns on every table, explicit column lists, IF EXISTS for migrations

### Seed Data
- `MERGE` or `IF NOT EXISTS` for idempotency
- FK references must be consistent, realistic timestamps
- Group INSERTs by entity, match Figma mock data exactly
'@
Set-Content -Path "$sharedDir\coding-conventions.md" -Value $codingConventions -Encoding UTF8
Write-Host "   [OK] prompts\shared\coding-conventions.md" -ForegroundColor DarkGreen

# --- database-completeness-review.md ---
$dbCompleteness = @'
# Database Completeness Standards

## Required Chain
```
API Endpoint -> Controller Method -> Repository/Service -> Stored Procedure
    -> Functions/Views (if complex) -> Tables -> Seed Data
```

## Enhanced Blueprint Tier Structure
| Tier | Name | Contents |
|------|------|----------|
| 1 | Database Foundation | Tables, migrations, indexes, constraints |
| 1.5 | Database Functions & Views | Views for complex reads, scalar/table-valued functions |
| 2 | Stored Procedures | All CRUD + business logic SPs |
| 2.5 | Seed Data | INSERT scripts per table group, FK-consistent, matching Figma mock data |
| 3 | API Layer | .NET 8 controllers, services, repositories, DTOs, validators |
| 4 | Frontend Components | React 18 components matching Figma exactly |
| 5 | Integration & Config | Routing, auth flows, middleware, DI, config files |
| 6 | Compliance & Polish | Audit logging, encryption, RBAC, error boundaries, accessibility |

## Verification Rules
1. Every endpoint in `_analysis/06-api-contracts.md` MUST have a stored procedure
2. Every row in `_analysis/11-api-to-sp-map.md` must be complete (no empty cells)
3. Every SP MUST reference tables that exist in migrations
4. Complex queries (3+ table JOINs) SHOULD use a view
5. Every table MUST have seed data matching Figma mock data exactly
6. Seed data FK references MUST point to existing parent records
7. No orphaned SPs or tables

## Cross-Reference Sources
- `_analysis/06-api-contracts.md` -- API endpoints
- `_analysis/11-api-to-sp-map.md` -- End-to-end chain map
- `_analysis/08-mock-data-catalog.md` -- Mock data values for seed scripts
- `_stubs/database/01-tables.sql`, `02-stored-procedures.sql`, `03-seed-data.sql`
'@
Set-Content -Path "$sharedDir\database-completeness-review.md" -Value $dbCompleteness -Encoding UTF8
Write-Host "   [OK] prompts\shared\database-completeness-review.md" -ForegroundColor DarkGreen

# --- spec-clarity-check.md ---
$specClarity = @'
# Spec Clarity & Completeness Check
# Run BEFORE blueprint or planning. Token budget: ~2000 output tokens.

You are a SPEC AUDITOR. Validate specs are complete enough for code generation.

## Context
- Project: {{REPO_ROOT}}
- Specs: docs\ (Phase A through E)
- Figma: {{FIGMA_PATH}}
- Analysis: {{INTERFACE_ANALYSIS}} (if exists)
- Output: {{GSD_DIR}}\assessment\

## Check For
1. **Ambiguous language**: "should", "might", "possibly", "as needed", "appropriate"
2. **Missing acceptance criteria**: Requirements without testable assertions
3. **Incomplete data models**: Endpoints missing request/response types
4. **Missing database chain**: Features without SP or table references
5. **Orphaned references**: Figma frames or SPs referenced but not defined
6. **Missing error specs**: Endpoints without error response definitions

## Output
Write: {{GSD_DIR}}\assessment\spec-quality.json
```json
{
  "clarity_score": 0-100,
  "total_requirements": N,
  "fully_specified": N,
  "underspecified": N,
  "issues": [{ "id": "SPEC-001", "severity": "block|warn|info", "source": "...", "issue": "...", "suggestion": "..." }],
  "ambiguous_language": [{ "source": "...", "text": "...", "suggestion": "..." }],
  "missing_chain_links": [{ "feature": "...", "missing": "...", "suggestion": "..." }]
}
```

## Scoring
- 90-100: PASS
- 70-89: WARN (proceed with caution)
- 0-69: BLOCK (specs need work)

Rules: Under 2000 tokens. Be specific. Be actionable.
'@
Set-Content -Path "$GsdGlobalDir\prompts\claude\spec-clarity-check.md" -Value $specClarity -Encoding UTF8
Write-Host "   [OK] prompts\claude\spec-clarity-check.md" -ForegroundColor DarkGreen

# --- cross-artifact-consistency.md ---
$crossArtifact = @'
# Cross-Artifact Consistency Check
# Run AFTER Figma Make analysis, BEFORE code generation. Token budget: ~2000.

You are a CONSISTENCY AUDITOR. Verify cross-references across all deliverables.

## Context
- Project: {{REPO_ROOT}}
- Interface: {{INTERFACE_NAME}}
- Analysis: {{INTERFACE_ANALYSIS}}

## Read ALL of These
1. `_analysis/05-data-types.md` -- TypeScript interfaces
2. `_analysis/06-api-contracts.md` -- API endpoints
3. `_analysis/08-mock-data-catalog.md` -- Mock data records
4. `_analysis/11-api-to-sp-map.md` -- End-to-end chain map
5. `_stubs/database/01-tables.sql` -- Table definitions
6. `_stubs/database/02-stored-procedures.sql` -- SP signatures
7. `_stubs/database/03-seed-data.sql` -- Seed data INSERTs
8. `_stubs/backend/Controllers/*.cs` -- Controller stubs
9. `_stubs/backend/Models/*.cs` -- DTO stubs

## Verify
A. Entity names IDENTICAL across all files (case-sensitive)
B. Field names match: TypeScript = C# DTO = SQL column
C. Every API endpoint in 06 has a SP in 11-api-to-sp-map
D. Every SP has a table, every table has seed data
E. Mock data IDs match seed data IDs, FK refs consistent

## Output
Write: {{GSD_DIR}}\assessment\cross-artifact-consistency.json
```json
{
  "consistent": true|false,
  "entity_mismatches": [...],
  "field_mismatches": [...],
  "missing_chain_links": [...],
  "seed_data_gaps": [...],
  "fk_violations": [...]
}
```

Rules: Under 2000 tokens. Tables and JSON only.
'@
Set-Content -Path "$GsdGlobalDir\prompts\claude\cross-artifact-consistency.md" -Value $crossArtifact -Encoding UTF8
Write-Host "   [OK] prompts\claude\cross-artifact-consistency.md" -ForegroundColor DarkGreen

Write-Host ""

# ==================== SECTION 2: PowerShell Functions ====================

Write-Host "[2/5] Appending quality gate functions to resilience.ps1..." -ForegroundColor Yellow

$existing = Get-Content $LibFile -Raw

# Check if already applied
if ($existing -match "function Test-DatabaseCompleteness") {
    Write-Host "   [>>]  Quality gate functions already present -- skipping append" -ForegroundColor DarkGray
} else {
    $qualityFunctions = @'

# ===============================================================
# QUALITY GATES -- Database Completeness, Security Compliance, Spec Validation
# Added by patch-gsd-quality-gates.ps1 (Script 20)
# ===============================================================

function Test-DatabaseCompleteness {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [switch]$Detailed
    )

    Write-Host "    [DB] Checking database completeness..." -ForegroundColor DarkGray

    $configPath = Join-Path $env:USERPROFILE ".gsd-global\config\global-config.json"
    $qgEnabled = $true; $requireSeed = $true; $minCoverage = 90
    if (Test-Path $configPath) {
        try {
            $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
            if ($cfg.quality_gates -and $cfg.quality_gates.database_completeness) {
                $qg = $cfg.quality_gates.database_completeness
                if ($null -ne $qg.enabled) { $qgEnabled = $qg.enabled }
                if ($null -ne $qg.require_seed_data) { $requireSeed = $qg.require_seed_data }
                if ($null -ne $qg.min_coverage_pct) { $minCoverage = $qg.min_coverage_pct }
            }
        } catch { }
    }

    if (-not $qgEnabled) {
        Write-Host "    [>>]  Database completeness check disabled" -ForegroundColor DarkGray
        return @{ Passed = $true; Coverage = @{}; Issues = @(); Skipped = $true }
    }

    $issues = @()
    $apiEndpoints = @()

    # Discover from 11-api-to-sp-map.md
    $spMapFiles = Get-ChildItem -Path $RepoRoot -Recurse -Filter "11-api-to-sp-map.md" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($spMapFiles) {
        $mapContent = Get-Content $spMapFiles.FullName -Raw -ErrorAction SilentlyContinue
        $tableRows = [regex]::Matches($mapContent, '\|\s*\S+.*?\|\s*(GET|POST|PUT|DELETE|PATCH)\s*\|\s*(/\S+)\s*\|\s*(\S+)\s*\|\s*(usp_\S+|MISSING|-)\s*\|\s*(\S.*?)\s*\|\s*(\S.*?)\s*\|')
        foreach ($row in $tableRows) {
            $apiEndpoints += @{ Method = $row.Groups[1].Value; Route = $row.Groups[2].Value; StoredProc = $row.Groups[4].Value.Trim() }
        }
    }

    # Fallback: scan .cs files
    if ($apiEndpoints.Count -eq 0) {
        $csFiles = Get-ChildItem -Path $RepoRoot -Recurse -Include "*.cs" -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch "(bin|obj|node_modules|\.git)" }
        foreach ($cs in $csFiles) {
            $content = Get-Content $cs.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }
            $httpMatches = [regex]::Matches($content, '\[(Http(Get|Post|Put|Delete|Patch))\s*\("([^"]*?)"\)\]')
            foreach ($m in $httpMatches) {
                $apiEndpoints += @{ Method = $m.Groups[2].Value.ToUpper(); Route = $m.Groups[3].Value; StoredProc = "" }
            }
        }
    }

    # Discover SPs, tables, seed data from .sql files
    $spDefined = @(); $tablesDefined = @(); $tablesWithSeed = @()
    $sqlFiles = Get-ChildItem -Path $RepoRoot -Recurse -Include "*.sql" -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch "(bin|obj|node_modules|\.git)" }
    foreach ($sql in $sqlFiles) {
        $content = Get-Content $sql.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        foreach ($m in [regex]::Matches($content, 'CREATE\s+(OR\s+ALTER\s+)?PROC(?:EDURE)?\s+\[?dbo\]?\.\[?(usp_\w+|sp_\w+|\w+)\]?', 'IgnoreCase')) { $spDefined += $m.Groups[2].Value }
        foreach ($m in [regex]::Matches($content, 'CREATE\s+TABLE\s+\[?dbo\]?\.\[?(\w+)\]?', 'IgnoreCase')) { $tablesDefined += $m.Groups[1].Value }
        foreach ($m in [regex]::Matches($content, 'INSERT\s+INTO\s+\[?dbo\]?\.\[?(\w+)\]?', 'IgnoreCase')) { if ($m.Groups[1].Value -notin $tablesWithSeed) { $tablesWithSeed += $m.Groups[1].Value } }
        foreach ($m in [regex]::Matches($content, 'MERGE\s+\[?dbo\]?\.\[?(\w+)\]?', 'IgnoreCase')) { if ($m.Groups[1].Value -notin $tablesWithSeed) { $tablesWithSeed += $m.Groups[1].Value } }
    }

    # Cross-reference
    $apiToSpCovered = 0; $missingStoredProcs = @()
    foreach ($ep in $apiEndpoints) {
        $sp = $ep.StoredProc
        if ($sp -and $sp -ne "-" -and $sp -ne "MISSING") {
            if ($sp -in $spDefined -or $spDefined.Count -eq 0) { $apiToSpCovered++ } else { $missingStoredProcs += "$($ep.Method) $($ep.Route) -> $sp (not found)" }
        } elseif ($sp -eq "MISSING" -or -not $sp) { $missingStoredProcs += "$($ep.Method) $($ep.Route) -> NO SP mapped" }
        else { $apiToSpCovered++ }
    }

    $tablesWithSeedCount = 0; $missingSeedData = @()
    foreach ($tbl in $tablesDefined) { if ($tbl -in $tablesWithSeed) { $tablesWithSeedCount++ } else { $missingSeedData += $tbl } }

    $coverage = @{
        api_to_sp = @{ total = $apiEndpoints.Count; covered = $apiToSpCovered; missing = $missingStoredProcs; pct = if ($apiEndpoints.Count -gt 0) { [math]::Round(($apiToSpCovered / $apiEndpoints.Count) * 100, 1) } else { 100 } }
        tables_defined = $tablesDefined.Count; sps_defined = $spDefined.Count
        tables_to_seed = @{ total = $tablesDefined.Count; covered = $tablesWithSeedCount; missing = $missingSeedData; pct = if ($tablesDefined.Count -gt 0) { [math]::Round(($tablesWithSeedCount / $tablesDefined.Count) * 100, 1) } else { 100 } }
    }

    if ($missingStoredProcs.Count -gt 0) { $issues += "$($missingStoredProcs.Count) API endpoint(s) missing stored procedures" }
    if ($requireSeed -and $missingSeedData.Count -gt 0) { $issues += "$($missingSeedData.Count) table(s) missing seed data: $($missingSeedData -join ', ')" }

    $overallPct = 100
    $vals = @()
    if ($apiEndpoints.Count -gt 0) { $vals += $coverage.api_to_sp.pct }
    if ($tablesDefined.Count -gt 0) { $vals += $coverage.tables_to_seed.pct }
    if ($vals.Count -gt 0) { $overallPct = [math]::Round(($vals | Measure-Object -Average).Average, 1) }

    $passed = $issues.Count -eq 0 -or $overallPct -ge $minCoverage
    $assessDir = Join-Path $GsdDir "assessment"
    if (-not (Test-Path $assessDir)) { New-Item -Path $assessDir -ItemType Directory -Force | Out-Null }
    @{ timestamp = (Get-Date).ToString("o"); coverage = $coverage; overall_pct = $overallPct; passed = $passed; issues = $issues } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $assessDir "db-completeness.json") -Encoding UTF8

    if ($passed) { Write-Host "    [OK] Database completeness: ${overallPct}% ($($spDefined.Count) SPs, $($tablesDefined.Count) tables, $tablesWithSeedCount seeded)" -ForegroundColor DarkGreen }
    else { Write-Host "    [!!]  Database completeness: ${overallPct}% - $($issues.Count) issue(s)" -ForegroundColor DarkYellow; $issues | ForEach-Object { Write-Host "      - $_" -ForegroundColor DarkYellow } }

    return @{ Passed = $passed; Coverage = $coverage; OverallPct = $overallPct; Issues = $issues; MissingStoredProcs = $missingStoredProcs; MissingSeedData = $missingSeedData }
}

function Test-SecurityCompliance {
    param([string]$RepoRoot, [string]$GsdDir, [switch]$Detailed)

    Write-Host "    [LOCK] Checking security compliance..." -ForegroundColor DarkGray

    $configPath = Join-Path $env:USERPROFILE ".gsd-global\config\global-config.json"
    $qgEnabled = $true; $blockOnCritical = $true
    if (Test-Path $configPath) {
        try {
            $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
            if ($cfg.quality_gates -and $cfg.quality_gates.security_compliance) {
                $qg = $cfg.quality_gates.security_compliance
                if ($null -ne $qg.enabled) { $qgEnabled = $qg.enabled }
                if ($null -ne $qg.block_on_critical) { $blockOnCritical = $qg.block_on_critical }
            }
        } catch { }
    }
    if (-not $qgEnabled) { Write-Host "    [>>]  Security compliance check disabled" -ForegroundColor DarkGray; return @{ Passed = $true; Violations = @(); ViolationCount = 0; Skipped = $true } }

    $violations = @()
    $patterns = @(
        @{ Regex = 'string\.Format\s*\(.*?(SELECT|INSERT|UPDATE|DELETE)|"\s*\+\s*.*?(SELECT|INSERT|UPDATE|DELETE)|\$".*?(SELECT|INSERT|UPDATE|DELETE)'; Severity = "Critical"; Desc = "SQL injection via string concatenation"; Filter = ".cs" }
        @{ Regex = 'dangerouslySetInnerHTML'; Severity = "Critical"; Desc = "XSS: dangerouslySetInnerHTML"; Filter = ".tsx,.jsx" }
        @{ Regex = '\beval\s*\('; Severity = "Critical"; Desc = "Code injection: eval()"; Filter = ".ts,.tsx,.js,.jsx" }
        @{ Regex = 'new\s+Function\s*\('; Severity = "Critical"; Desc = "Code injection: new Function()"; Filter = ".ts,.tsx,.js,.jsx" }
        @{ Regex = 'localStorage\.(setItem|getItem).*?(token|password|secret|jwt|ssn)'; Severity = "Critical"; Desc = "Secrets in localStorage"; Filter = ".ts,.tsx,.js,.jsx" }
        @{ Regex = 'BinaryFormatter'; Severity = "Critical"; Desc = "Deserialization CVE: BinaryFormatter"; Filter = ".cs" }
        @{ Regex = '(password|secret|apikey|connectionstring)\s*=\s*"[^{][^"]{4,}"'; Severity = "Critical"; Desc = "Hardcoded secret"; Filter = ".cs,.json" }
        @{ Regex = 'console\.(log|error|warn).*?(password|token|ssn|creditcard|secret)'; Severity = "High"; Desc = "Sensitive data in console log"; Filter = ".ts,.tsx,.js,.jsx" }
        @{ Regex = 'sp_executesql.*\+'; Severity = "Critical"; Desc = "Dynamic SQL with concatenation"; Filter = ".sql" }
    )

    $allFiles = Get-ChildItem -Path $RepoRoot -Recurse -Include "*.cs","*.ts","*.tsx","*.js","*.jsx","*.sql","*.json" -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch "(bin|obj|node_modules|\.git|\.gsd|dist|build|package-lock)" }
    foreach ($pattern in $patterns) {
        $filterExts = $pattern.Filter -split ","
        foreach ($file in ($allFiles | Where-Object { $_.Extension -in $filterExts })) {
            $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }
            foreach ($m in [regex]::Matches($content, $pattern.Regex, 'IgnoreCase')) {
                if ($pattern.Desc -match "dangerouslySetInnerHTML" -and $content -match "DOMPurify") { continue }
                if ($pattern.Desc -match "Hardcoded secret" -and $file.Name -match "appsettings\.Development") { continue }
                $relPath = $file.FullName.Replace($RepoRoot, "").TrimStart("\", "/")
                $lineNum = ($content.Substring(0, $m.Index) -split "`n").Count
                $violations += @{ Severity = $pattern.Severity; Description = $pattern.Desc; File = $relPath; Line = $lineNum; Match = $m.Value.Substring(0, [Math]::Min($m.Value.Length, 80)) }
            }
        }
    }

    # Check missing [Authorize] on controllers
    foreach ($ctrl in ($allFiles | Where-Object { $_.Name -match "Controller\.cs$" })) {
        $content = Get-Content $ctrl.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -and $content -match "\[ApiController\]" -and $content -notmatch "\[Authorize") {
            $violations += @{ Severity = "High"; Description = "Controller missing [Authorize]"; File = $ctrl.FullName.Replace($RepoRoot, "").TrimStart("\", "/"); Line = 1; Match = $ctrl.Name }
        }
    }

    # Check CREATE TABLE missing audit columns
    foreach ($sql in ($allFiles | Where-Object { $_.Extension -eq ".sql" })) {
        $content = Get-Content $sql.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -and $content -match "CREATE\s+TABLE" -and $content -notmatch "CreatedAt") {
            $violations += @{ Severity = "Medium"; Description = "Missing audit columns in CREATE TABLE"; File = $sql.FullName.Replace($RepoRoot, "").TrimStart("\", "/"); Line = 1; Match = "CREATE TABLE without CreatedAt" }
        }
    }

    $assessDir = Join-Path $GsdDir "assessment"
    if (-not (Test-Path $assessDir)) { New-Item -Path $assessDir -ItemType Directory -Force | Out-Null }
    $criticals = @($violations | Where-Object { $_.Severity -eq "Critical" })
    $highs = @($violations | Where-Object { $_.Severity -eq "High" })
    $mediums = @($violations | Where-Object { $_.Severity -eq "Medium" })
    $passed = -not ($blockOnCritical -and $criticals.Count -gt 0)
    @{ timestamp = (Get-Date).ToString("o"); passed = $passed; violation_count = $violations.Count; by_severity = @{ critical = $criticals.Count; high = $highs.Count; medium = $mediums.Count }; violations = $violations } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $assessDir "security-compliance.json") -Encoding UTF8

    if ($violations.Count -eq 0) { Write-Host "    [OK] Security compliance: 0 violations" -ForegroundColor DarkGreen }
    else {
        $color = if ($criticals.Count -gt 0) { "Red" } elseif ($highs.Count -gt 0) { "DarkYellow" } else { "DarkGray" }
        Write-Host "    [!!]  Security: $($criticals.Count) critical, $($highs.Count) high, $($mediums.Count) medium" -ForegroundColor $color
        if ($Detailed) { $violations | Select-Object -First 10 | ForEach-Object { Write-Host "      [$($_.Severity)] $($_.File):$($_.Line) - $($_.Description)" -ForegroundColor $color } }
    }
    return @{ Passed = $passed; Violations = $violations; ViolationCount = $violations.Count; Criticals = $criticals.Count; Highs = $highs.Count; Mediums = $mediums.Count }
}

function Invoke-SpecQualityGate {
    param([string]$RepoRoot, [string]$GsdDir, [array]$Interfaces = @(), [switch]$DryRun, [int]$MinClarityScore = 70)

    Write-Host "    [SEARCH] Running spec quality gate..." -ForegroundColor DarkGray

    $configPath = Join-Path $env:USERPROFILE ".gsd-global\config\global-config.json"
    $qgEnabled = $true; $checkCrossArtifact = $true
    if (Test-Path $configPath) {
        try {
            $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
            if ($cfg.quality_gates -and $cfg.quality_gates.spec_quality) {
                $qg = $cfg.quality_gates.spec_quality
                if ($null -ne $qg.enabled) { $qgEnabled = $qg.enabled }
                if ($null -ne $qg.min_clarity_score) { $MinClarityScore = $qg.min_clarity_score }
                if ($null -ne $qg.check_cross_artifact) { $checkCrossArtifact = $qg.check_cross_artifact }
            }
        } catch { }
    }
    if (-not $qgEnabled) { Write-Host "    [>>]  Spec quality gate disabled" -ForegroundColor DarkGray; return @{ Passed = $true; ClarityScore = 100; ConsistencyPassed = $true; Issues = @(); Skipped = $true } }

    $issues = @(); $clarityScore = 100; $consistencyPassed = $true

    # Step 1: Existing consistency check
    if (Get-Command Invoke-SpecConsistencyCheck -ErrorAction SilentlyContinue) {
        try {
            $specResult = Invoke-SpecConsistencyCheck -RepoRoot $RepoRoot -GsdDir $GsdDir -Interfaces $Interfaces
            if (-not $specResult.Passed) { $issues += "Spec consistency check found conflicts"; $consistencyPassed = $false }
        } catch { Write-Host "    [!!]  Spec consistency check error: $_" -ForegroundColor DarkYellow }
    }

    # Step 2: Clarity check via Claude
    if (-not $DryRun) {
        $clarityPrompt = Join-Path $env:USERPROFILE ".gsd-global\prompts\claude\spec-clarity-check.md"
        if (Test-Path $clarityPrompt) {
            try {
                $promptContent = (Get-Content $clarityPrompt -Raw).Replace("{{REPO_ROOT}}", $RepoRoot).Replace("{{GSD_DIR}}", $GsdDir)
                $figmaPath = ""; $amPath = Join-Path $env:USERPROFILE ".gsd-global\config\agent-map.json"
                if (Test-Path $amPath) { try { $figmaPath = (Get-Content $amPath -Raw | ConvertFrom-Json).figma_path } catch { } }
                $promptContent = $promptContent.Replace("{{FIGMA_PATH}}", $figmaPath)
                $ifaceCtx = ""; foreach ($iface in $Interfaces) { $aDir = Join-Path $RepoRoot "$($iface.name)\_analysis"; if (Test-Path $aDir) { $ifaceCtx += "- $($iface.name): has _analysis/ dir`n" } }
                $promptContent = $promptContent.Replace("{{INTERFACE_ANALYSIS}}", $ifaceCtx)
                Write-Host "    [SEARCH] Running spec clarity check via Claude..." -ForegroundColor DarkGray
                $clarityResult = Invoke-WithRetry -Agent "claude" -Prompt $promptContent -Phase "spec-clarity-check" -RepoRoot $RepoRoot -GsdDir $GsdDir -MaxOutputTokens 4000
                if ($clarityResult.Success) {
                    $scoreMatch = [regex]::Match($clarityResult.Response, '"clarity_score"\s*:\s*(\d+)')
                    if ($scoreMatch.Success) { $clarityScore = [int]$scoreMatch.Groups[1].Value }
                    Write-Host "    [OK] Spec clarity score: $clarityScore" -ForegroundColor $(if ($clarityScore -ge 85) { "DarkGreen" } elseif ($clarityScore -ge 70) { "DarkYellow" } else { "Red" })
                }
            } catch { Write-Host "    [!!]  Spec clarity check error: $_" -ForegroundColor DarkYellow }
        }
    }

    # Step 3: Cross-artifact consistency
    if ($checkCrossArtifact -and -not $DryRun) {
        $hasAnalysis = $false
        foreach ($iface in $Interfaces) { if (Test-Path (Join-Path $RepoRoot "$($iface.name)\_analysis")) { $hasAnalysis = $true; break } }
        if (Test-Path (Join-Path $RepoRoot "_analysis")) { $hasAnalysis = $true }
        if ($hasAnalysis) {
            $cPrompt = Join-Path $env:USERPROFILE ".gsd-global\prompts\claude\cross-artifact-consistency.md"
            if (Test-Path $cPrompt) {
                try {
                    $promptContent = (Get-Content $cPrompt -Raw).Replace("{{REPO_ROOT}}", $RepoRoot).Replace("{{GSD_DIR}}", $GsdDir)
                    $ifaceName = if ($Interfaces.Count -gt 0) { $Interfaces[0].name } else { "" }
                    $ifaceAnalysis = if ($ifaceName) { Join-Path $RepoRoot "$ifaceName\_analysis" } else { Join-Path $RepoRoot "_analysis" }
                    $promptContent = $promptContent.Replace("{{INTERFACE_NAME}}", $ifaceName).Replace("{{INTERFACE_ANALYSIS}}", $ifaceAnalysis)
                    Write-Host "    [SEARCH] Running cross-artifact consistency check..." -ForegroundColor DarkGray
                    $crossResult = Invoke-WithRetry -Agent "claude" -Prompt $promptContent -Phase "cross-artifact-check" -RepoRoot $RepoRoot -GsdDir $GsdDir -MaxOutputTokens 4000
                    if ($crossResult.Success) {
                        $cm = [regex]::Match($crossResult.Response, '"consistent"\s*:\s*(true|false)')
                        if ($cm.Success -and $cm.Groups[1].Value -eq "false") { $consistencyPassed = $false; $issues += "Cross-artifact consistency check found mismatches" }
                    }
                } catch { Write-Host "    [!!]  Cross-artifact check error: $_" -ForegroundColor DarkYellow }
            }
        }
    }

    $passed = $clarityScore -ge $MinClarityScore -and $consistencyPassed
    $assessDir = Join-Path $GsdDir "assessment"
    if (-not (Test-Path $assessDir)) { New-Item -Path $assessDir -ItemType Directory -Force | Out-Null }
    $verdict = if ($clarityScore -ge 90) { "PASS" } elseif ($clarityScore -ge 70) { "WARN" } else { "BLOCK" }
    @{ timestamp = (Get-Date).ToString("o"); passed = $passed; clarity_score = $clarityScore; min_clarity_score = $MinClarityScore; consistency_passed = $consistencyPassed; issues = $issues; verdict = $verdict } | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $assessDir "spec-quality-gate.json") -Encoding UTF8

    if ($passed) { Write-Host "    [OK] Spec quality gate: $verdict (clarity=$clarityScore, consistency=$consistencyPassed)" -ForegroundColor DarkGreen }
    else { Write-Host "    [!!]  Spec quality gate: $verdict (clarity=$clarityScore, consistency=$consistencyPassed)" -ForegroundColor $(if ($clarityScore -lt 70) { "Red" } else { "DarkYellow" }); $issues | ForEach-Object { Write-Host "      - $_" -ForegroundColor DarkYellow } }

    return @{ Passed = $passed; ClarityScore = $clarityScore; ConsistencyPassed = $consistencyPassed; Issues = $issues; Verdict = $verdict }
}
'@
    Add-Content -Path $LibFile -Value $qualityFunctions -Encoding UTF8
    Write-Host "   [OK] 3 functions appended to resilience.ps1" -ForegroundColor DarkGreen
}

Write-Host ""

# ==================== SECTION 3: Prompt Modifications ====================

Write-Host "[3/5] Updating agent prompts with security & quality references..." -ForegroundColor Yellow

$securityRef = @"

### Security & Quality Standards (MANDATORY)
Follow ALL rules in: %USERPROFILE%\.gsd-global\prompts\shared\security-standards.md
Follow conventions in: %USERPROFILE%\.gsd-global\prompts\shared\coding-conventions.md
Ensure database completeness per: %USERPROFILE%\.gsd-global\prompts\shared\database-completeness-review.md
Every violation will be caught by the council review and final validation.
"@

$securityChecklist = @"

## Security Review (MANDATORY)
1. **SQL injection**: Any string concatenation in query building?
2. **Auth**: Every controller class has [Authorize] attribute?
3. **Secrets**: Hardcoded connection strings, API keys, or passwords?
4. **PII**: PHI/PII encrypted at rest? Excluded from logs?
5. **XSS**: Any dangerouslySetInnerHTML without DOMPurify?
6. **Tokens**: Sensitive data stored in localStorage?
7. **Audit**: INSERT/UPDATE/DELETE operations logged to audit table?
8. **Compliance**: HIPAA/SOC2/PCI/GDPR patterns per security-standards.md?

## Database Completeness Review
1. Every API endpoint has a corresponding stored procedure?
2. Every stored procedure references existing tables?
3. Seed data exists for all tables?
4. The _analysis/11-api-to-sp-map.md chain is complete (no empty cells)?
"@

# Append to codex/execute.md
$executePath = Join-Path $GsdGlobalDir "prompts\codex\execute.md"
if (Test-Path $executePath) {
    $content = Get-Content $executePath -Raw
    if ($content -notmatch "Security & Quality Standards") {
        $content = $content.Replace("## Execute", "$securityRef`n`n## Execute")
        Set-Content -Path $executePath -Value $content -Encoding UTF8
        Write-Host "   [OK] codex\execute.md updated" -ForegroundColor DarkGreen
    } else {
        Write-Host "   [>>]  codex\execute.md already has security ref" -ForegroundColor DarkGray
    }
}

# Append security checklist to council review prompts
foreach ($reviewFile in @("council\codex-review.md", "council\gemini-review.md")) {
    $reviewPath = Join-Path $GsdGlobalDir "prompts\$reviewFile"
    if (Test-Path $reviewPath) {
        $content = Get-Content $reviewPath -Raw
        if ($content -notmatch "Security Review \(MANDATORY\)") {
            $content += $securityChecklist
            Set-Content -Path $reviewPath -Value $content -Encoding UTF8
            Write-Host "   [OK] $reviewFile updated" -ForegroundColor DarkGreen
        } else {
            Write-Host "   [>>]  $reviewFile already has security checklist" -ForegroundColor DarkGray
        }
    }
}

Write-Host ""

# ==================== SECTION 4: Configuration ====================

Write-Host "[4/5] Updating global-config.json..." -ForegroundColor Yellow

$configPath = Join-Path $GsdGlobalDir "config\global-config.json"
if (Test-Path $configPath) {
    $configContent = Get-Content $configPath -Raw
    if ($configContent -notmatch "quality_gates") {
        $configContent = $configContent.Replace('"patterns"', @"
"quality_gates": {
        "database_completeness": { "enabled": true, "require_seed_data": true, "min_coverage_pct": 90 },
        "security_compliance": { "enabled": true, "block_on_critical": true, "warn_on_high": true },
        "spec_quality": { "enabled": true, "min_clarity_score": 70, "check_cross_artifact": true }
    },
    "patterns"
"@)
        Set-Content -Path $configPath -Value $configContent -Encoding UTF8
        Write-Host "   [OK] quality_gates added to global-config.json" -ForegroundColor DarkGreen
    } else {
        Write-Host "   [>>]  quality_gates already in global-config.json" -ForegroundColor DarkGray
    }
}

Write-Host ""

# ==================== SECTION 5: Pipeline Integration ====================

Write-Host "[5/5] Integrating quality gates into pipelines..." -ForegroundColor Yellow

# Convergence pipeline: upgrade spec check to quality gate
$convPath = Join-Path $GsdGlobalDir "scripts\convergence-loop.ps1"
if (Test-Path $convPath) {
    $content = Get-Content $convPath -Raw
    if ($content -notmatch "Invoke-SpecQualityGate") {
        # Replace the existing spec consistency check block with the enhanced quality gate
        $oldBlock = 'if (Get-Command Invoke-SpecConsistencyCheck -ErrorAction SilentlyContinue) {'
        $newBlock = @'
if (Get-Command Invoke-SpecQualityGate -ErrorAction SilentlyContinue) {
        Write-Host "  [SEARCH] Spec quality gate (consistency + clarity + cross-artifact)..." -ForegroundColor Cyan
        $specResult = Invoke-SpecQualityGate -RepoRoot $RepoRoot -GsdDir $GsdDir -Interfaces $Interfaces -DryRun:$DryRun
        if (-not $specResult.Passed -and $specResult.Verdict -eq "BLOCK") {
            Write-Host "  [BLOCK] Spec quality gate BLOCKED. See .gsd\assessment\spec-quality-gate.json" -ForegroundColor Red
            Remove-GsdLock -GsdDir $GsdDir; exit 1
        } elseif (-not $specResult.Passed) {
            Write-Host "  [!!]  Spec quality gate WARN: $($specResult.Issues -join '; ')" -ForegroundColor DarkYellow
        }
    } elseif (Get-Command Invoke-SpecConsistencyCheck -ErrorAction SilentlyContinue) {
'@
        if ($content -match [regex]::Escape($oldBlock)) {
            $content = $content.Replace($oldBlock, $newBlock)
            Set-Content -Path $convPath -Value $content -Encoding UTF8
            Write-Host "   [OK] convergence-loop.ps1 spec gate upgraded" -ForegroundColor DarkGreen
        }
    } else {
        Write-Host "   [>>]  convergence-loop.ps1 already has quality gate" -ForegroundColor DarkGray
    }

    # Add DB completeness + security checks before final validation
    $content = Get-Content $convPath -Raw
    if ($content -notmatch "Test-DatabaseCompleteness") {
        $insertBefore = "# Final validation gate - runs when health reaches 100%"
        $qualityChecks = @'
    # Quality gate checks before final validation
    if ($FinalHealth -ge $TargetHealth -and -not $DryRun) {
        if (Get-Command Test-DatabaseCompleteness -ErrorAction SilentlyContinue) {
            $dbResult = Test-DatabaseCompleteness -RepoRoot $RepoRoot -GsdDir $GsdDir
            if (-not $dbResult.Passed -and -not $dbResult.Skipped) {
                $ctxPath = Join-Path $GsdDir "supervisor\error-context.md"
                $existingCtx = ""; if (Test-Path $ctxPath) { $existingCtx = Get-Content $ctxPath -Raw }
                "$existingCtx`n## Database Completeness Issues`n$(($dbResult.Issues | ForEach-Object { "- $_" }) -join "`n")" | Set-Content $ctxPath -Encoding UTF8
            }
        }
        if (Get-Command Test-SecurityCompliance -ErrorAction SilentlyContinue) {
            $secResult = Test-SecurityCompliance -RepoRoot $RepoRoot -GsdDir $GsdDir -Detailed
            if (-not $secResult.Passed -and -not $secResult.Skipped) {
                $ctxPath = Join-Path $GsdDir "supervisor\error-context.md"
                $existingCtx = ""; if (Test-Path $ctxPath) { $existingCtx = Get-Content $ctxPath -Raw }
                "$existingCtx`n## Security Compliance Issues`n- $($secResult.Criticals) critical, $($secResult.Highs) high violations" | Set-Content $ctxPath -Encoding UTF8
            }
        }
    }

'@
        if ($content -match [regex]::Escape($insertBefore)) {
            $content = $content.Replace($insertBefore, "$qualityChecks    $insertBefore")
            Set-Content -Path $convPath -Value $content -Encoding UTF8
            Write-Host "   [OK] convergence-loop.ps1 quality checks added" -ForegroundColor DarkGreen
        }
    } else {
        Write-Host "   [>>]  convergence-loop.ps1 already has quality checks" -ForegroundColor DarkGray
    }
}

# Blueprint pipeline: same upgrades
$bpPath = Join-Path $GsdGlobalDir "blueprint\scripts\blueprint-pipeline.ps1"
if (Test-Path $bpPath) {
    $content = Get-Content $bpPath -Raw
    if ($content -notmatch "Invoke-SpecQualityGate") {
        $oldBlock = 'if (Get-Command Invoke-SpecConsistencyCheck -ErrorAction SilentlyContinue) {'
        $newBlock = @'
if (Get-Command Invoke-SpecQualityGate -ErrorAction SilentlyContinue) {
        Write-Host "  [SEARCH] Spec quality gate (consistency + clarity + cross-artifact)..." -ForegroundColor Cyan
        $specResult = Invoke-SpecQualityGate -RepoRoot $RepoRoot -GsdDir $GsdDir -Interfaces $Interfaces -DryRun:$DryRun
        if (-not $specResult.Passed -and $specResult.Verdict -eq "BLOCK") {
            Write-Host "  [BLOCK] Spec quality gate BLOCKED. See .gsd\assessment\spec-quality-gate.json" -ForegroundColor Red
            Remove-GsdLock -GsdDir $GsdDir; exit 1
        } elseif (-not $specResult.Passed) {
            Write-Host "  [!!]  Spec quality gate WARN: $($specResult.Issues -join '; ')" -ForegroundColor DarkYellow
        }
    } elseif (Get-Command Invoke-SpecConsistencyCheck -ErrorAction SilentlyContinue) {
'@
        if ($content -match [regex]::Escape($oldBlock)) {
            $content = $content.Replace($oldBlock, $newBlock)
            Set-Content -Path $bpPath -Value $content -Encoding UTF8
            Write-Host "   [OK] blueprint-pipeline.ps1 spec gate upgraded" -ForegroundColor DarkGreen
        }
    } else {
        Write-Host "   [>>]  blueprint-pipeline.ps1 already has quality gate" -ForegroundColor DarkGray
    }

    # Add quality checks before final validation
    $content = Get-Content $bpPath -Raw
    if ($content -notmatch "Test-DatabaseCompleteness") {
        $insertBefore = "# Final validation gate - runs when health reaches 100%"
        $qualityChecks = @'
    # Quality gate checks before final validation
    if ($FinalHealth -ge $TargetHealth -and -not $DryRun) {
        if (Get-Command Test-DatabaseCompleteness -ErrorAction SilentlyContinue) {
            $dbResult = Test-DatabaseCompleteness -RepoRoot $RepoRoot -GsdDir $GsdDir
            if (-not $dbResult.Passed -and -not $dbResult.Skipped) {
                $ctxPath = Join-Path $GsdDir "supervisor\error-context.md"
                $existingCtx = ""; if (Test-Path $ctxPath) { $existingCtx = Get-Content $ctxPath -Raw }
                "$existingCtx`n## Database Completeness Issues`n$(($dbResult.Issues | ForEach-Object { "- $_" }) -join "`n")" | Set-Content $ctxPath -Encoding UTF8
            }
        }
        if (Get-Command Test-SecurityCompliance -ErrorAction SilentlyContinue) {
            $secResult = Test-SecurityCompliance -RepoRoot $RepoRoot -GsdDir $GsdDir -Detailed
            if (-not $secResult.Passed -and -not $secResult.Skipped) {
                $ctxPath = Join-Path $GsdDir "supervisor\error-context.md"
                $existingCtx = ""; if (Test-Path $ctxPath) { $existingCtx = Get-Content $ctxPath -Raw }
                "$existingCtx`n## Security Compliance Issues`n- $($secResult.Criticals) critical, $($secResult.Highs) high violations" | Set-Content $ctxPath -Encoding UTF8
            }
        }
    }

'@
        if ($content -match [regex]::Escape($insertBefore)) {
            $content = $content.Replace($insertBefore, "$qualityChecks    $insertBefore")
            Set-Content -Path $bpPath -Value $content -Encoding UTF8
            Write-Host "   [OK] blueprint-pipeline.ps1 quality checks added" -ForegroundColor DarkGreen
        }
    } else {
        Write-Host "   [>>]  blueprint-pipeline.ps1 already has quality checks" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  Quality Gates installed successfully" -ForegroundColor Green
Write-Host "  - 5 prompt templates (shared/ + claude/)" -ForegroundColor DarkGreen
Write-Host "  - 3 functions (Test-DatabaseCompleteness, Test-SecurityCompliance, Invoke-SpecQualityGate)" -ForegroundColor DarkGreen
Write-Host "  - Security checklist in council review prompts" -ForegroundColor DarkGreen
Write-Host "  - quality_gates config in global-config.json" -ForegroundColor DarkGreen
Write-Host "  - Pipeline integration (convergence + blueprint)" -ForegroundColor DarkGreen
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
