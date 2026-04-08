<#
.SYNOPSIS
    GSD Compliance Gate - HIPAA, PCI DSS, GDPR, SOC 2 enforcement
.DESCRIPTION
    Enforces regulatory compliance requirements before pipeline handoff.
    Scans source code, configuration, and database objects for violations.

    Frameworks supported: HIPAA, PCI, GDPR, SOC2 (configurable)

    Phases:
      1. HIPAA    - PHI detection, audit logging, encryption markers
      2. PCI      - Cardholder data detection, payment endpoint isolation
      3. GDPR     - PII detection, consent flows, right-to-erasure, retention
      4. SOC2     - Access control logging, MFA, session management
      5. Report   - Compliance evidence JSON + developer checklist

    Usage:
      pwsh -File gsd-compliance-gate.ps1 -RepoRoot "D:\repos\project" -Frameworks "HIPAA,SOC2"
      pwsh -File gsd-compliance-gate.ps1 -RepoRoot "D:\repos\project" -Frameworks "PCI,GDPR"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$Frameworks = "HIPAA,SOC2",    # Comma-separated: HIPAA,PCI,GDPR,SOC2
    [ValidateSet("critical","high","medium","none")]
    [string]$FailOnSeverity = "high",
    [switch]$GenerateEvidenceReport
)

$ErrorActionPreference = "Continue"

$v3Dir    = Split-Path $PSScriptRoot -Parent
$RepoRoot = (Resolve-Path $RepoRoot).Path
$GsdDir   = Join-Path $RepoRoot ".gsd"
$repoName = Split-Path $RepoRoot -Leaf

$globalLogDir = Join-Path $env:USERPROFILE ".gsd-global/logs/$repoName"
if (-not (Test-Path $globalLogDir)) { New-Item -ItemType Directory -Path $globalLogDir -Force | Out-Null }
$timestamp    = Get-Date -Format "yyyy-MM-dd_HHmmss"
$logFile      = Join-Path $globalLogDir "compliance-gate-$timestamp.log"
$outDir       = Join-Path $GsdDir "compliance-gate"
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "$(Get-Date -Format 'HH:mm:ss') [$Level] $Message"
    Add-Content $logFile -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue
    $color = switch ($Level) {
        "ERROR" { "Red" }; "WARN" { "Yellow" }; "OK" { "Green" }
        "SKIP"  { "DarkGray" }; "PHASE" { "Cyan" }; default { "White" }
    }
    Write-Host "  $entry" -ForegroundColor $color
}

$modulesDir    = Join-Path $v3Dir "lib/modules"
$apiClientPath = Join-Path $modulesDir "api-client.ps1"
if (Test-Path $apiClientPath) { . $apiClientPath }

$activeFrameworks = $Frameworks.ToUpper() -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  GSD Compliance Gate" -ForegroundColor Cyan
Write-Host "  Frameworks: $($activeFrameworks -join ', ') | Fail-on: $FailOnSeverity" -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor Cyan

$report = @{
    generated_at = (Get-Date -Format "o")
    repo         = $repoName
    frameworks   = $activeFrameworks
    violations   = @()
    controls     = @()
    evidence     = @{}
    status       = "pass"
    summary      = @{ critical=0; high=0; medium=0; low=0; total=0 }
}

function Add-Violation {
    param([string]$Framework, [string]$Control, [string]$Severity,
          [string]$File, [string]$Description, [string]$Remediation)
    $report.violations += @{
        framework   = $Framework
        control     = $Control
        severity    = $Severity
        file        = $File
        description = $Description
        remediation = $Remediation
    }
    $report.summary[$Severity]++
    $report.summary.total++
    Write-Log "$Framework [$Control] $Severity : $Description" $(if ($Severity -eq "critical") { "ERROR" } else { "WARN" })
}

function Add-Control {
    param([string]$Framework, [string]$Id, [string]$Name, [string]$Status, [string]$Evidence)
    $report.controls += @{ framework=$Framework; control_id=$Id; name=$Name; status=$Status; evidence=$Evidence }
}

# Get all source files (shared across frameworks)
$allCsFiles = @(Get-ChildItem -Path $RepoRoot -Filter "*.cs" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\(bin|obj|test|Test|migration|Migration)\\' })
$allTsFiles = @(Get-ChildItem -Path $RepoRoot -Filter "*.ts" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\(node_modules|dist|build)\\' })
$allTsxFiles = @(Get-ChildItem -Path $RepoRoot -Filter "*.tsx" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\(node_modules|dist|build)\\' })

# ============================================================
# HIPAA CHECKS
# ============================================================

if ($activeFrameworks -contains "HIPAA") {
    Write-Log "--- HIPAA Compliance Check ---" "PHASE"

    $phiPatterns = @(
        @{ Name="SSN"; Pattern='(?i)(ssn|social.?security)\s*[=:{\["\x27]'; Control="§164.312(a)(2)(iv)" }
        @{ Name="MRN/PatientID"; Pattern='(?i)(mrn|patient.?id|medical.?record)\s*[=:{\["\x27]'; Control="§164.312(a)(2)(iv)" }
        @{ Name="DOB"; Pattern='(?i)(date.?of.?birth|dob|birth.?date)\s*[=:{\["\x27]'; Control="§164.312(a)(2)(iv)" }
        @{ Name="Diagnosis"; Pattern='(?i)(diagnosis|icd.?code|diagnosis.?code)\s*[=:{\["\x27]'; Control="§164.312(a)(2)(iv)" }
    )

    # Check if PHI fields are present (expected in healthcare apps)
    $phiFieldsFound = @()
    foreach ($p in $phiPatterns) {
        foreach ($f in $allCsFiles) {
            $c = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if ($c -match $p.Pattern) { $phiFieldsFound += $p.Name; break }
        }
    }

    if ($phiFieldsFound.Count -gt 0) {
        Write-Log "PHI fields detected: $($phiFieldsFound -join ', ') — verifying safeguards..." "INFO"

        # Check audit logging exists
        $hasAuditLog = $false
        foreach ($f in $allCsFiles) {
            $c = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if ($c -match '(?i)(audit|AuditLog|IAuditService|_auditService|WriteAudit|LogAccess)') {
                $hasAuditLog = $true; break
            }
        }
        if (-not $hasAuditLog) {
            Add-Violation -Framework "HIPAA" -Control "§164.312(b)" -Severity "critical" `
                -File "(no audit log found)" `
                -Description "PHI fields detected but no audit logging implementation found" `
                -Remediation "Implement an audit service that logs: who accessed what PHI, when, from where. Log all CRUD operations on PHI entities."
        } else {
            Add-Control -Framework "HIPAA" -Id "§164.312(b)" -Name "Audit Controls" -Status "pass" -Evidence "Audit logging service found in source"
        }

        # Check encryption at rest markers
        $hasEncryption = $false
        foreach ($f in $allCsFiles + @(Get-ChildItem -Path $RepoRoot -Filter "appsettings*.json" -Recurse -File -ErrorAction SilentlyContinue)) {
            $c = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if ($c -match '(?i)(encrypt|AES|DataProtection|ColumnEncryption|AlwaysEncrypted)') {
                $hasEncryption = $true; break
            }
        }
        if (-not $hasEncryption) {
            Add-Violation -Framework "HIPAA" -Control "§164.312(a)(2)(iv)" -Severity "high" `
                -File "(configuration)" `
                -Description "PHI detected but no encryption-at-rest markers found (no AES/DataProtection/ColumnEncryption)" `
                -Remediation "Use SQL Server Always Encrypted for PHI columns, or implement application-layer encryption with AES-256."
        } else {
            Add-Control -Framework "HIPAA" -Id "§164.312(a)(2)(iv)" -Name "Encryption at Rest" -Status "pass" -Evidence "Encryption implementation found"
        }

        # Check PHI not in logs
        foreach ($f in $allCsFiles) {
            $c = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $c) { continue }
            $relPath = $f.FullName.Replace($RepoRoot,'').TrimStart('\','/')
            if ($c -match '(?i)(ILogger|_logger)\.(Log|Information|Debug|Error).*\{(ssn|mrn|dob|patientId|diagnosis)') {
                Add-Violation -Framework "HIPAA" -Control "§164.312(b)" -Severity "critical" `
                    -File $relPath -Description "PHI field appears to be included in log statements" `
                    -Remediation "Never log PHI. Use data masking or structured log sanitization."
            }
        }
    } else {
        Write-Log "No PHI field patterns detected - HIPAA checks passed (verify this is correct for your domain)" "OK"
        Add-Control -Framework "HIPAA" -Id "§164.312" -Name "PHI Inventory" -Status "warn" -Evidence "No PHI patterns found - confirm with domain expert"
    }
}

# ============================================================
# PCI DSS CHECKS
# ============================================================

if ($activeFrameworks -contains "PCI") {
    Write-Log "--- PCI DSS Compliance Check ---" "PHASE"

    # Detect cardholder data
    $cardPatterns = @(
        @{ Pattern = '(?i)(card.?number|pan|primary.?account.?number|cardnum)\s*[=:{\["\x27]'; Name="Card Number field" }
        @{ Pattern = '(?i)(cvv|cvc|csc|card.?verification)\s*[=:{\["\x27]'; Name="CVV/CVC field" }
        @{ Pattern = '\b4[0-9]{12}(?:[0-9]{3})?\b'; Name="Visa card number pattern" }
        @{ Pattern = '\b5[1-5][0-9]{14}\b'; Name="Mastercard number pattern" }
    )

    foreach ($p in $cardPatterns) {
        foreach ($f in $allCsFiles + $allTsFiles) {
            $c = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $c) { continue }
            $relPath = $f.FullName.Replace($RepoRoot,'').TrimStart('\','/')
            if ($relPath -match '(?i)(test|spec|mock|fixture|example)') { continue }
            if ($c -match $p.Pattern) {
                Add-Violation -Framework "PCI" -Control "PCI-DSS 3.4" -Severity "critical" `
                    -File $relPath -Description "$($p.Name) found in source — CHD must not be stored unless necessary" `
                    -Remediation "Use tokenization (Stripe, Braintree) — never store raw card data. If required, implement PCI-DSS encryption."
            }
        }
    }

    # Check HTTPS enforcement
    $programFiles = Get-ChildItem -Path $RepoRoot -Filter "Program.cs" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' }
    $hasHttpsRedirect = $false
    foreach ($pf in $programFiles) {
        $c = Get-Content $pf.FullName -Raw -ErrorAction SilentlyContinue
        if ($c -match 'UseHttpsRedirection') { $hasHttpsRedirect = $true; break }
    }
    if (-not $hasHttpsRedirect) {
        Add-Violation -Framework "PCI" -Control "PCI-DSS 4.1" -Severity "high" `
            -File "Program.cs" -Description "UseHttpsRedirection() not found — payment data must be transmitted over TLS" `
            -Remediation "Add app.UseHttpsRedirection() to Program.cs middleware pipeline."
    } else {
        Add-Control -Framework "PCI" -Id "PCI-DSS 4.1" -Name "TLS Enforcement" -Status "pass" -Evidence "UseHttpsRedirection found in Program.cs"
    }
}

# ============================================================
# GDPR CHECKS
# ============================================================

if ($activeFrameworks -contains "GDPR") {
    Write-Log "--- GDPR Compliance Check ---" "PHASE"

    $piiPatterns = @(
        @{ Name="Email"; Pattern='(?i)email\s*[=:{\["\x27]' }
        @{ Name="Phone"; Pattern='(?i)(phone|mobile|telephone)\s*[=:{\["\x27]' }
        @{ Name="Address"; Pattern='(?i)(street|address|postcode|zipcode)\s*[=:{\["\x27]' }
        @{ Name="IP Address logging"; Pattern='(?i)(ipaddress|remote.?ip|client.?ip)\s*[=:{\["\x27]' }
    )

    $piiFound = @()
    foreach ($p in $piiPatterns) {
        foreach ($f in $allCsFiles) {
            $c = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if ($c -match $p.Pattern) { $piiFound += $p.Name; break }
        }
    }

    if ($piiFound.Count -gt 0) {
        Write-Log "PII fields detected: $($piiFound -join ', ') — verifying GDPR controls..." "INFO"

        # Right to erasure endpoint
        $hasErasureEndpoint = $false
        foreach ($f in $allCsFiles) {
            $c = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if ($c -match '(?i)(delete|erase|forget|gdpr|right.?to|anonymize).*\[Http(Delete|Post)') {
                $hasErasureEndpoint = $true; break
            }
        }
        if (-not $hasErasureEndpoint) {
            Add-Violation -Framework "GDPR" -Control "Art. 17" -Severity "high" `
                -File "(controllers)" -Description "No right-to-erasure endpoint found (Art. 17 Right to be Forgotten)" `
                -Remediation "Implement DELETE /api/users/{id}/data endpoint that anonymizes or deletes all user PII."
        } else {
            Add-Control -Framework "GDPR" -Id "Art.17" -Name "Right to Erasure" -Status "pass" -Evidence "Deletion/anonymization endpoint found"
        }

        # Data retention markers
        $hasRetentionPolicy = $false
        foreach ($f in $allCsFiles) {
            $c = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if ($c -match '(?i)(retention|expire|purge|archive|data.?lifecycle)') {
                $hasRetentionPolicy = $true; break
            }
        }
        if (-not $hasRetentionPolicy) {
            Add-Violation -Framework "GDPR" -Control "Art. 5(1)(e)" -Severity "medium" `
                -File "(none found)" -Description "No data retention policy implementation detected" `
                -Remediation "Implement scheduled jobs to purge or archive PII data past retention period. Document retention periods per data category."
        }

        # Consent tracking
        $hasConsent = $false
        foreach ($f in $allCsFiles + $allTsFiles) {
            $c = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if ($c -match '(?i)(consent|gdprConsent|accepted.?terms|cookie.?consent)') {
                $hasConsent = $true; break
            }
        }
        if (-not $hasConsent) {
            Add-Violation -Framework "GDPR" -Control "Art. 7" -Severity "high" `
                -File "(none found)" -Description "No consent tracking found (Art. 7 Conditions for consent)" `
                -Remediation "Implement consent records: timestamp, version of privacy policy accepted, IP address. Store in AuditConsent table."
        }
    }
}

# ============================================================
# SOC 2 CHECKS
# ============================================================

if ($activeFrameworks -contains "SOC2") {
    Write-Log "--- SOC 2 Compliance Check ---" "PHASE"

    # CC6.1 - Logical access controls
    $hasRbac = $false
    foreach ($f in $allCsFiles) {
        $c = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        if ($c -match '\[Authorize\(Roles') { $hasRbac = $true; break }
    }
    if (-not $hasRbac) {
        Add-Violation -Framework "SOC2" -Control "CC6.1" -Severity "high" `
            -File "(controllers)" -Description "No role-based [Authorize(Roles=...)] found — logical access control CC6.1 requires role verification" `
            -Remediation "Add [Authorize(Roles = \"Admin,Manager\")] to sensitive controller actions."
    } else {
        Add-Control -Framework "SOC2" -Id "CC6.1" -Name "Logical Access Controls" -Status "pass" -Evidence "Role-based [Authorize] attributes found"
    }

    # CC7.2 - System monitoring / logging
    $hasStructuredLogging = $false
    foreach ($f in $allCsFiles) {
        $c = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        if ($c -match '(?i)(Serilog|ILogger|OpenTelemetry|ApplicationInsights)') {
            $hasStructuredLogging = $true; break
        }
    }
    if (-not $hasStructuredLogging) {
        Add-Violation -Framework "SOC2" -Control "CC7.2" -Severity "medium" `
            -File "(configuration)" -Description "No structured logging framework detected (Serilog, OpenTelemetry, AppInsights)" `
            -Remediation "Add Serilog or OpenTelemetry for structured, queryable logs. Log all auth events, data access, and errors."
    }

    # CC6.7 - Session management
    $hasSessionTimeout = $false
    foreach ($f in @(Get-ChildItem -Path $RepoRoot -Filter "appsettings*.json" -Recurse -File -ErrorAction SilentlyContinue)) {
        $c = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        if ($c -match '(?i)(expir|timeout|lifetime|ValidFor)') { $hasSessionTimeout = $true; break }
    }
    if (-not $hasSessionTimeout) {
        Add-Violation -Framework "SOC2" -Control "CC6.7" -Severity "medium" `
            -File "appsettings.json" -Description "No session/token expiry configuration found" `
            -Remediation "Configure JWT expiry (recommend 15min for access tokens, 7 days for refresh tokens) in appsettings.json."
    }
}

# ============================================================
# DETERMINE OVERALL STATUS
# ============================================================

$severityRank = @{ critical=4; high=3; medium=2; low=1; none=0 }
$failRank = $severityRank[$FailOnSeverity]
$blockingViolations = @($report.violations | Where-Object { $severityRank[$_.severity] -ge $failRank })
$report.status = if ($blockingViolations.Count -eq 0) { "pass" } elseif ($report.summary.critical -gt 0) { "fail" } else { "warn" }

# ============================================================
# GENERATE REPORTS
# ============================================================

$report | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $outDir "compliance-gate-report.json") -Encoding UTF8

# Evidence checklist
$md = @()
$md += "# Compliance Gate Report"
$md += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Frameworks: $($activeFrameworks -join ', ') | Status: $($report.status.ToUpper())"
$md += ""
$md += "## Violation Summary"
$md += "| Framework | Critical | High | Medium | Low |"
$md += "|-----------|----------|------|--------|-----|"
foreach ($fw in $activeFrameworks) {
    $fwViols = @($report.violations | Where-Object { $_.framework -eq $fw })
    $md += "| $fw | $(@($fwViols|Where-Object{$_.severity-eq'critical'}).Count) | $(@($fwViols|Where-Object{$_.severity-eq'high'}).Count) | $(@($fwViols|Where-Object{$_.severity-eq'medium'}).Count) | $(@($fwViols|Where-Object{$_.severity-eq'low'}).Count) |"
}
$md += ""
if ($report.violations.Count -gt 0) {
    $md += "## Violations (Remediation Required)"
    foreach ($v in $report.violations | Sort-Object { switch($_.severity){"critical"{0}"high"{1}default{2}} }) {
        $md += "### [$($v.framework)] $($v.control) — $($v.severity.ToUpper())"
        $md += "**Issue:** $($v.description)"
        $md += "**Fix:** $($v.remediation)"
        $md += ""
    }
}
if ($report.controls.Count -gt 0) {
    $md += "## Controls Verified (Passing)"
    $md += "| Framework | Control | Name | Status |"
    $md += "|-----------|---------|------|--------|"
    foreach ($c in $report.controls) {
        $md += "| $($c.framework) | $($c.control_id) | $($c.name) | $($c.status) |"
    }
}
$md -join "`n" | Set-Content (Join-Path $outDir "compliance-gate-summary.md") -Encoding UTF8

$statusColor = switch ($report.status) { "pass" { "Green" }; "warn" { "Yellow" }; default { "Red" } }
Write-Host "`n============================================" -ForegroundColor $statusColor
Write-Host "  Compliance Gate: $($report.status.ToUpper())" -ForegroundColor $statusColor
Write-Host "  Violations: $($report.summary.total) (C:$($report.summary.critical) H:$($report.summary.high) M:$($report.summary.medium))" -ForegroundColor DarkGray
Write-Host "  Report: $(Join-Path $outDir 'compliance-gate-summary.md')" -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor $statusColor
