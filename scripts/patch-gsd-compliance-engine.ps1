<#
.SYNOPSIS
    Compliance Engine - Per-iteration compliance audit, DB migration validation, PII tracking.
    Run AFTER patch-gsd-design-token-enforcement.ps1.

.DESCRIPTION
    Consolidates three compliance enhancements:

    1. Per-Iteration Compliance Audit (Rec #15):
       - Structured rule engine mapping SEC-*/COMP-* rule IDs to regex patterns
       - Runs compliance scan EVERY iteration (not just at 100% health)
       - Outputs compliance-scan.json with pass/fail per rule ID

    2. Database Migration Validation (Rec #16):
       - Foreign key consistency across tables
       - Index coverage for query patterns in stored procedures
       - Seed data referential integrity
       - Zero-cost SQL file scan

    3. PII Flow Tracking (Rec #17):
       - Tags fields as PII from data model specs
       - Traces PII through: API parameter -> controller -> SP -> table
       - Verifies: encryption at rest, excluded from logs, masked in UI
       - Mostly regex-based with configurable PII field registry

    All three are zero-cost static scans (no LLM calls).

.INSTALL_ORDER
    1-27. (existing scripts)
    28. patch-gsd-compliance-engine.ps1  <- this file
#>

param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"

$GsdGlobalDir = Join-Path $UserHome ".gsd-global"

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Compliance Engine (Audit + DB Migration + PII)" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Add compliance_engine config ──

$configPath = Join-Path $GsdGlobalDir "config\global-config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    if (-not $config.compliance_engine) {
        $config | Add-Member -NotePropertyName "compliance_engine" -NotePropertyValue ([PSCustomObject]@{
            per_iteration_audit = ([PSCustomObject]@{
                enabled          = $true
                block_on_critical = $true
            })
            db_migration = ([PSCustomObject]@{
                enabled                = $true
                check_foreign_keys     = $true
                check_index_coverage   = $true
                check_seed_integrity   = $true
            })
            pii_tracking = ([PSCustomObject]@{
                enabled       = $true
                pii_fields    = @("email", "ssn", "social_security", "date_of_birth", "dob", "phone", "address", "name", "first_name", "last_name", "credit_card", "card_number", "cvv", "password", "secret", "token")
                check_logging = $true
                check_encryption = $true
                check_ui_masking = $true
            })
        })
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
        Write-Host "  [OK] Added compliance_engine config" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] compliance_engine already exists" -ForegroundColor DarkGray
    }
}

# ── 2. Add compliance functions to resilience.ps1 ──

$resilienceFile = Join-Path $GsdGlobalDir "lib\modules\resilience.ps1"
if (Test-Path $resilienceFile) {
    $existing = Get-Content $resilienceFile -Raw

    if ($existing -notlike "*function Invoke-PerIterationCompliance*") {

        $complianceFunctions = @'

# ===========================================
# COMPLIANCE ENGINE
# ===========================================

# ── Per-Iteration Compliance Audit ──

function Invoke-PerIterationCompliance {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$Iteration
    )

    $result = @{
        Passed   = $true
        Critical = @()
        High     = @()
        Medium   = @()
        RuleResults = @()
    }

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if (-not $config.compliance_engine -or -not $config.compliance_engine.per_iteration_audit -or
                -not $config.compliance_engine.per_iteration_audit.enabled) {
                return $result
            }
        } catch { return $result }
    } else { return $result }

    Write-Host "  [COMPLIANCE] Running per-iteration compliance audit..." -ForegroundColor Cyan

    # Structured rule engine: ID -> regex -> severity -> file glob
    $rules = @(
        # Network Security (SEC-NET-*)
        @{ Id="SEC-NET-01"; Name="SQL Injection"; Severity="critical"; Glob="*.cs"; Pattern='string\.Format\s*\(\s*".*SELECT|".*\+.*sql|SqlCommand\(\s*\$"|\.ExecuteSqlRaw\(\s*\$"' }
        @{ Id="SEC-NET-02"; Name="XSS via innerHTML"; Severity="critical"; Glob="*.tsx,*.jsx"; Pattern='dangerouslySetInnerHTML|\.innerHTML\s*=' }
        @{ Id="SEC-NET-03"; Name="Eval usage"; Severity="critical"; Glob="*.ts,*.tsx,*.js,*.jsx"; Pattern='\beval\s*\(|new\s+Function\s*\(' }
        @{ Id="SEC-NET-04"; Name="Hardcoded secrets"; Severity="critical"; Glob="*.cs,*.ts,*.json"; Pattern='(?i)(password|secret|api_key|apikey|connection_string)\s*[:=]\s*"[^"]{8,}"' }
        @{ Id="SEC-NET-05"; Name="Missing Authorize"; Severity="high"; Glob="*Controller*.cs"; Pattern='(?s)\[ApiController\](?!.*\[Authorize)' }
        @{ Id="SEC-NET-06"; Name="HTTP instead of HTTPS"; Severity="high"; Glob="*.cs,*.ts"; Pattern='http://(?!localhost|127\.0\.0\.1|0\.0\.0\.0)' }
        @{ Id="SEC-NET-07"; Name="Console.log sensitive data"; Severity="medium"; Glob="*.ts,*.tsx,*.js"; Pattern='console\.\w+\(.*(?i)(password|token|secret|ssn|credit)' }
        @{ Id="SEC-NET-08"; Name="localStorage for tokens"; Severity="high"; Glob="*.ts,*.tsx,*.js"; Pattern='localStorage\.\w+\(.*(?i)(token|jwt|auth|session)' }

        # SQL Security (SEC-SQL-*)
        @{ Id="SEC-SQL-01"; Name="String concatenation in SQL"; Severity="critical"; Glob="*.sql"; Pattern='\+\s*@|\+\s*CAST|''.*\+' }
        @{ Id="SEC-SQL-02"; Name="Missing parameterized query"; Severity="high"; Glob="*.cs"; Pattern='new SqlCommand\(\s*\$"|SqlCommand\(\s*".*\+' }
        @{ Id="SEC-SQL-03"; Name="Dynamic SQL without sp_executesql"; Severity="high"; Glob="*.sql"; Pattern='EXEC\s*\(\s*@(?!.*sp_executesql)' }

        # Frontend Security (SEC-FE-*)
        @{ Id="SEC-FE-01"; Name="Missing CSRF token"; Severity="high"; Glob="*.cs"; Pattern='\[HttpPost\](?!.*\[ValidateAntiForgeryToken\])' }
        @{ Id="SEC-FE-02"; Name="Unvalidated redirect"; Severity="medium"; Glob="*.cs"; Pattern='Redirect\(\s*\w+\)(?!.*IsLocalUrl)' }

        # HIPAA (COMP-HIPAA-*)
        @{ Id="COMP-HIPAA-01"; Name="PII in log output"; Severity="critical"; Glob="*.cs"; Pattern='(?i)_logger\.\w+\(.*(?:ssn|social.*security|date.*birth|medical)' }
        @{ Id="COMP-HIPAA-02"; Name="Unencrypted PII storage"; Severity="critical"; Glob="*.cs"; Pattern='(?i)(?:ssn|social_security)\s*=\s*(?!.*Encrypt|.*Hash)' }

        # SOC 2 (COMP-SOC2-*)
        @{ Id="COMP-SOC2-01"; Name="Missing audit log"; Severity="high"; Glob="*.cs"; Pattern='(?s)(?:INSERT|UPDATE|DELETE)(?!.*AuditLog|.*_logger|.*LogAudit)' }

        # PCI (COMP-PCI-*)
        @{ Id="COMP-PCI-01"; Name="Credit card in logs"; Severity="critical"; Glob="*.cs,*.ts"; Pattern='(?i)_logger\.\w+\(.*(?:card.*number|credit.*card|cvv|ccv)' }
        @{ Id="COMP-PCI-02"; Name="Unmasked card display"; Severity="high"; Glob="*.tsx,*.jsx"; Pattern='(?i)card.*number.*\{(?!.*mask|.*\*\*\*|.*slice\(-4\))' }

        # GDPR (COMP-GDPR-*)
        @{ Id="COMP-GDPR-01"; Name="Missing data deletion endpoint"; Severity="medium"; Glob="*Controller*.cs"; Pattern='(?!)' }  # placeholder -- checked separately
    )

    # Scan source files
    $sourceFiles = Get-ChildItem -Path $RepoRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notlike "*\node_modules\*" -and
            $_.FullName -notlike "*\bin\*" -and
            $_.FullName -notlike "*\obj\*" -and
            $_.FullName -notlike "*\.gsd\*" -and
            $_.FullName -notlike "*\.git\*" -and
            $_.Extension -in ".cs", ".ts", ".tsx", ".jsx", ".js", ".sql", ".json"
        }

    $fileContents = @{}
    foreach ($f in $sourceFiles) {
        try {
            $fileContents[$f.FullName] = @{
                Content  = Get-Content $f.FullName -Raw
                Relative = $f.FullName.Substring($RepoRoot.Length + 1)
                Extension = $f.Extension
            }
        } catch {}
    }

    foreach ($rule in $rules) {
        if ($rule.Pattern -eq '(?!)') { continue }  # skip placeholder rules

        $ruleGlobs = $rule.Glob -split ','
        $violations = @()

        foreach ($kvp in $fileContents.GetEnumerator()) {
            $info = $kvp.Value
            $matchesGlob = $false
            foreach ($g in $ruleGlobs) {
                if ($info.Relative -like $g.Trim()) { $matchesGlob = $true; break }
            }
            if (-not $matchesGlob) { continue }

            try {
                $regexMatches = [regex]::Matches($info.Content, $rule.Pattern)
                foreach ($m in $regexMatches) {
                    $lineNum = ($info.Content.Substring(0, $m.Index) -split "`n").Count
                    $violations += @{
                        file = $info.Relative
                        line = $lineNum
                        match = $m.Value.Substring(0, [math]::Min(80, $m.Value.Length))
                    }
                }
            } catch {}
        }

        $status = if ($violations.Count -eq 0) { "passed" } else { "failed" }
        $result.RuleResults += @{
            id         = $rule.Id
            name       = $rule.Name
            severity   = $rule.Severity
            status     = $status
            violations = $violations.Count
            details    = $violations | Select-Object -First 5
        }

        if ($violations.Count -gt 0) {
            switch ($rule.Severity) {
                "critical" { $result.Critical += "$($rule.Id): $($rule.Name) ($($violations.Count) violations)" }
                "high"     { $result.High += "$($rule.Id): $($rule.Name) ($($violations.Count) violations)" }
                "medium"   { $result.Medium += "$($rule.Id): $($rule.Name) ($($violations.Count) violations)" }
            }
        }
    }

    # Determine pass/fail
    $blockOnCritical = $config.compliance_engine.per_iteration_audit.block_on_critical
    if ($blockOnCritical -and $result.Critical.Count -gt 0) {
        $result.Passed = $false
    }

    $total = $result.RuleResults.Count
    $passed = ($result.RuleResults | Where-Object { $_.status -eq "passed" }).Count
    $result.Summary = "Rules: $passed/$total passed. Critical: $($result.Critical.Count), High: $($result.High.Count), Medium: $($result.Medium.Count)"

    Write-Host "  [COMPLIANCE] $($result.Summary)" -ForegroundColor $(if ($result.Critical.Count -eq 0) { "Green" } else { "Red" })

    if ($result.Critical.Count -gt 0) {
        foreach ($c in $result.Critical) { Write-Host "    [CRITICAL] $c" -ForegroundColor Red }
    }

    # Save results
    $valDir = Join-Path $GsdDir "validation"
    if (-not (Test-Path $valDir)) { New-Item -Path $valDir -ItemType Directory -Force | Out-Null }
    @{
        iteration = $Iteration
        timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        passed    = $result.Passed
        summary   = $result.Summary
        critical  = $result.Critical
        high      = $result.High
        medium    = $result.Medium
        rules     = $result.RuleResults
    } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $valDir "compliance-scan.json") -Encoding UTF8

    return $result
}

# ── Database Migration Validation ──

function Test-DatabaseMigrationIntegrity {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir
    )

    $result = @{
        Passed   = $true
        Issues   = @()
        Summary  = ""
    }

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if (-not $config.compliance_engine -or -not $config.compliance_engine.db_migration -or
                -not $config.compliance_engine.db_migration.enabled) {
                return $result
            }
        } catch { return $result }
    } else { return $result }

    Write-Host "  [DB] Running database migration integrity scan..." -ForegroundColor Cyan

    # Find SQL files
    $sqlFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sql" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike "*\node_modules\*" -and $_.FullName -notlike "*\.gsd\*" }

    if ($sqlFiles.Count -eq 0) {
        Write-Host "  [DB] No SQL files found -- skipping" -ForegroundColor DarkGray
        return $result
    }

    $allSqlContent = ""
    foreach ($sf in $sqlFiles) {
        $allSqlContent += (Get-Content $sf.FullName -Raw) + "`n"
    }

    # ── 1. Foreign Key Consistency ──
    if ($config.compliance_engine.db_migration.check_foreign_keys) {
        # Find REFERENCES clauses and verify target tables exist
        $fkRegex = '(?i)REFERENCES\s+\[?(\w+)\]?\s*\(\s*\[?(\w+)\]?\s*\)'
        $fkMatches = [regex]::Matches($allSqlContent, $fkRegex)

        $createTableRegex = '(?i)CREATE\s+TABLE\s+\[?(?:dbo\.)?\]?\[?(\w+)\]?'
        $tables = @([regex]::Matches($allSqlContent, $createTableRegex) | ForEach-Object { $_.Groups[1].Value.ToLower() })

        foreach ($fk in $fkMatches) {
            $refTable = $fk.Groups[1].Value.ToLower()
            if ($refTable -notin $tables) {
                $result.Issues += @{
                    type    = "foreign_key"
                    severity = "high"
                    message = "FK references table '$($fk.Groups[1].Value)' which is not defined in any CREATE TABLE"
                }
            }
        }
    }

    # ── 2. Index Coverage ──
    if ($config.compliance_engine.db_migration.check_index_coverage) {
        # Find WHERE clauses in SPs and check for indexes
        $whereRegex = '(?i)WHERE\s+\[?(\w+)\]?\s*='
        $whereMatches = [regex]::Matches($allSqlContent, $whereRegex)
        $queriedColumns = @($whereMatches | ForEach-Object { $_.Groups[1].Value.ToLower() } | Select-Object -Unique)

        $indexRegex = '(?i)CREATE\s+(?:UNIQUE\s+)?(?:NONCLUSTERED\s+)?INDEX\s+\w+\s+ON\s+\[?\w+\]?\s*\(\s*\[?(\w+)\]?'
        $pkRegex = '(?i)PRIMARY\s+KEY\s*\(\s*\[?(\w+)\]?'
        $indexedColumns = @()
        $indexedColumns += [regex]::Matches($allSqlContent, $indexRegex) | ForEach-Object { $_.Groups[1].Value.ToLower() }
        $indexedColumns += [regex]::Matches($allSqlContent, $pkRegex) | ForEach-Object { $_.Groups[1].Value.ToLower() }
        $indexedColumns = $indexedColumns | Select-Object -Unique

        foreach ($col in $queriedColumns) {
            if ($col -notin $indexedColumns -and $col -ne "id") {
                $result.Issues += @{
                    type    = "index_coverage"
                    severity = "medium"
                    message = "Column '$col' used in WHERE clause but no index found"
                }
            }
        }
    }

    # ── 3. Seed Data Integrity ──
    if ($config.compliance_engine.db_migration.check_seed_integrity) {
        # Find INSERT statements and verify referenced tables exist
        $insertRegex = '(?i)INSERT\s+INTO\s+\[?(?:dbo\.)?\]?\[?(\w+)\]?'
        $insertMatches = [regex]::Matches($allSqlContent, $insertRegex)
        $seededTables = @($insertMatches | ForEach-Object { $_.Groups[1].Value.ToLower() } | Select-Object -Unique)

        $createTableRegex2 = '(?i)CREATE\s+TABLE\s+\[?(?:dbo\.)?\]?\[?(\w+)\]?'
        $tables2 = @([regex]::Matches($allSqlContent, $createTableRegex2) | ForEach-Object { $_.Groups[1].Value.ToLower() })

        foreach ($st in $seededTables) {
            if ($st -notin $tables2) {
                $result.Issues += @{
                    type    = "seed_integrity"
                    severity = "high"
                    message = "INSERT INTO '$st' but table not defined in CREATE TABLE"
                }
            }
        }
    }

    # Summary
    $highCount = ($result.Issues | Where-Object { $_.severity -eq "high" }).Count
    $medCount = ($result.Issues | Where-Object { $_.severity -eq "medium" }).Count
    $result.Summary = "DB integrity: $($result.Issues.Count) issues (high: $highCount, medium: $medCount)"
    if ($highCount -gt 0) { $result.Passed = $false }

    Write-Host "  [DB] $($result.Summary)" -ForegroundColor $(if ($result.Passed) { "Green" } else { "Yellow" })

    # Save results
    $valDir = Join-Path $GsdDir "validation"
    if (-not (Test-Path $valDir)) { New-Item -Path $valDir -ItemType Directory -Force | Out-Null }
    @{
        timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        passed    = $result.Passed
        issues    = $result.Issues
        summary   = $result.Summary
    } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $valDir "db-migration-results.json") -Encoding UTF8

    return $result
}

# ── PII Flow Tracking ──

function Invoke-PiiFlowAnalysis {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir
    )

    $result = @{
        Passed    = $true
        Risks     = @()
        PiiFields = @()
        Summary   = ""
    }

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if (-not $config.compliance_engine -or -not $config.compliance_engine.pii_tracking -or
                -not $config.compliance_engine.pii_tracking.enabled) {
                return $result
            }
        } catch { return $result }
    } else { return $result }

    $piiFieldNames = @($config.compliance_engine.pii_tracking.pii_fields)

    Write-Host "  [PII] Running PII flow analysis..." -ForegroundColor Cyan

    # Find source files
    $sourceFiles = Get-ChildItem -Path $RepoRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Extension -in ".cs", ".ts", ".tsx", ".sql" -and
            $_.FullName -notlike "*\node_modules\*" -and
            $_.FullName -notlike "*\bin\*" -and
            $_.FullName -notlike "*\obj\*" -and
            $_.FullName -notlike "*\.gsd\*"
        }

    foreach ($field in $piiFieldNames) {
        $fieldPattern = "(?i)$([regex]::Escape($field))"
        $foundIn = @()

        foreach ($f in $sourceFiles) {
            $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }

            if ($content -match $fieldPattern) {
                $relativePath = $f.FullName.Substring($RepoRoot.Length + 1)
                $foundIn += $relativePath

                # Check for logging risks (PII in log output)
                if ($config.compliance_engine.pii_tracking.check_logging) {
                    if ($content -match "(?i)(_logger|Console|console)\.\w+\(.*$field") {
                        $result.Risks += @{
                            type    = "pii_in_logs"
                            field   = $field
                            file    = $relativePath
                            severity = "critical"
                            message = "PII field '$field' appears in log output"
                        }
                    }
                }

                # Check for encryption (PII stored without encryption)
                if ($config.compliance_engine.pii_tracking.check_encryption -and $f.Extension -eq ".cs") {
                    if ($content -match "(?i)$field\s*=" -and $content -notmatch "(?i)(Encrypt|Hash|Protect|DataProtect).*$field|$field.*(Encrypt|Hash)") {
                        # Only flag if it looks like storage (not just reading)
                        if ($content -match "(?i)(INSERT|UPDATE|SaveChanges|Repository)") {
                            $result.Risks += @{
                                type    = "pii_unencrypted"
                                field   = $field
                                file    = $relativePath
                                severity = "high"
                                message = "PII field '$field' may be stored without encryption"
                            }
                        }
                    }
                }

                # Check UI masking (PII displayed without masking)
                if ($config.compliance_engine.pii_tracking.check_ui_masking -and $f.Extension -in ".tsx", ".jsx") {
                    if ($content -match "(?i)\{.*$field.*\}" -and $content -notmatch "(?i)(mask|hide|\*\*\*|slice\(-4\)|substring).*$field|$field.*(mask|hide)") {
                        $result.Risks += @{
                            type    = "pii_unmasked_ui"
                            field   = $field
                            file    = $relativePath
                            severity = "high"
                            message = "PII field '$field' displayed in UI without masking"
                        }
                    }
                }
            }
        }

        if ($foundIn.Count -gt 0) {
            $result.PiiFields += @{
                field    = $field
                found_in = $foundIn
                count    = $foundIn.Count
            }
        }
    }

    # Summary
    $criticalCount = ($result.Risks | Where-Object { $_.severity -eq "critical" }).Count
    $highCount = ($result.Risks | Where-Object { $_.severity -eq "high" }).Count
    $result.Summary = "PII fields: $($result.PiiFields.Count) tracked, Risks: $($result.Risks.Count) (critical: $criticalCount, high: $highCount)"

    if ($criticalCount -gt 0) { $result.Passed = $false }

    Write-Host "  [PII] $($result.Summary)" -ForegroundColor $(if ($criticalCount -eq 0) { "Green" } else { "Red" })

    if ($criticalCount -gt 0) {
        foreach ($r in ($result.Risks | Where-Object { $_.severity -eq "critical" })) {
            Write-Host "    [CRITICAL] $($r.message) ($($r.file))" -ForegroundColor Red
        }
    }

    # Save results
    $valDir = Join-Path $GsdDir "validation"
    if (-not (Test-Path $valDir)) { New-Item -Path $valDir -ItemType Directory -Force | Out-Null }
    @{
        timestamp  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        passed     = $result.Passed
        pii_fields = $result.PiiFields
        risks      = $result.Risks
        summary    = $result.Summary
    } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $valDir "pii-flow-results.json") -Encoding UTF8

    return $result
}
'@

        Add-Content -Path $resilienceFile -Value $complianceFunctions -Encoding UTF8
        Write-Host "  [OK] Added compliance engine functions to resilience.ps1" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] Compliance engine functions already exist" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "  [COMPLIANCE] Installation complete." -ForegroundColor Green
Write-Host "  Config: global-config.json -> compliance_engine" -ForegroundColor DarkGray
Write-Host "  Functions: Invoke-PerIterationCompliance, Test-DatabaseMigrationIntegrity, Invoke-PiiFlowAnalysis" -ForegroundColor DarkGray
Write-Host "  Output: .gsd/validation/compliance-scan.json, db-migration-results.json, pii-flow-results.json" -ForegroundColor DarkGray
Write-Host ""
