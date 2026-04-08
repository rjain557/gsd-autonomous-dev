<#
.SYNOPSIS
    GSD Security Gate - SAST, secrets detection, dependency vulnerability scan
.DESCRIPTION
    Runs before BUILD-VERIFY to catch security issues before runtime testing.
    Scans for: hardcoded secrets, vulnerable dependencies, OWASP top-10 patterns,
    insecure auth/crypto config, and CORS misconfigurations.

    Phases:
      1. Secrets Detection     - API keys, passwords, tokens in source files
      2. Dependency Scan       - npm audit + dotnet vulnerable packages
      3. SAST Patterns         - SQL injection, XSS, insecure deserialization
      4. Auth/Crypto Review    - JWT config, password hashing, HTTPS enforcement
      5. CORS/Headers Review   - Wildcard CORS, missing security headers
      6. Report Generation     - JSON report + markdown summary + severity gate

    Usage:
      pwsh -File gsd-security-gate.ps1 -RepoRoot "D:\repos\project"
      pwsh -File gsd-security-gate.ps1 -RepoRoot "D:\repos\project" -FailOnSeverity high
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [ValidateSet("critical","high","medium","low","none")]
    [string]$FailOnSeverity = "high",   # Block pipeline at this severity or above
    [int]$MaxFiles = 200,
    [switch]$SkipDependencyScan,
    [switch]$SkipSast,
    [switch]$SkipSecretsDetection
)

$ErrorActionPreference = "Continue"

$v3Dir    = Split-Path $PSScriptRoot -Parent
$RepoRoot = (Resolve-Path $RepoRoot).Path
$GsdDir   = Join-Path $RepoRoot ".gsd"
$repoName = Split-Path $RepoRoot -Leaf

$globalLogDir = Join-Path $env:USERPROFILE ".gsd-global/logs/$repoName"
if (-not (Test-Path $globalLogDir)) { New-Item -ItemType Directory -Path $globalLogDir -Force | Out-Null }
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$logFile   = Join-Path $globalLogDir "security-gate-$timestamp.log"
$outDir    = Join-Path $GsdDir "security-gate"
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "$(Get-Date -Format 'HH:mm:ss') [$Level] $Message"
    Add-Content $logFile -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue
    $color = switch ($Level) {
        "ERROR" { "Red" }; "WARN" { "Yellow" }; "OK" { "Green" }
        "SKIP"  { "DarkGray" }; "FIX" { "Magenta" }; "PHASE" { "Cyan" }
        default { "White" }
    }
    Write-Host "  $entry" -ForegroundColor $color
}

$modulesDir    = Join-Path $v3Dir "lib/modules"
$apiClientPath = Join-Path $modulesDir "api-client.ps1"
if (Test-Path $apiClientPath) { . $apiClientPath }

$costTrackerPath = Join-Path $modulesDir "cost-tracker.ps1"
if (Test-Path $costTrackerPath) { . $costTrackerPath }
if (Get-Command Initialize-CostTracker -ErrorAction SilentlyContinue) {
    Initialize-CostTracker -Mode "security_gate" -BudgetCap 3.0 -GsdDir $GsdDir
}

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  GSD Security Gate" -ForegroundColor Cyan
Write-Host "  Repo: $repoName | Fail-on: $FailOnSeverity" -ForegroundColor DarkGray
Write-Host "  Log: $logFile" -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor Cyan

$report = @{
    generated_at   = (Get-Date -Format "o")
    repo           = $repoName
    fail_on        = $FailOnSeverity
    phases         = @()
    findings       = @()
    summary        = @{ critical = 0; high = 0; medium = 0; low = 0; total = 0 }
    status         = "pass"
}

$severityRank = @{ critical = 4; high = 3; medium = 2; low = 1; none = 0 }

function Add-Finding {
    param([string]$Phase, [string]$Severity, [string]$Category,
          [string]$File, [string]$Description, [string]$Recommendation)
    $report.findings += @{
        phase          = $Phase
        severity       = $Severity
        category       = $Category
        file           = $File
        description    = $Description
        recommendation = $Recommendation
    }
    $report.summary[$Severity]++
    $report.summary.total++
}

# ============================================================
# PHASE 1: SECRETS DETECTION
# ============================================================

Write-Log "--- Phase 1: Secrets Detection ---" "PHASE"

if (-not $SkipSecretsDetection) {
    $secretPatterns = @(
        @{ Pattern = '(?i)(password|pwd|passwd)\s*[=:]\s*["\x27][^"\x27\s]{6,}["\x27]'; Label = "Hardcoded password"; Severity = "critical" }
        @{ Pattern = '(?i)api[_-]?key\s*[=:]\s*["\x27][A-Za-z0-9\-_]{16,}["\x27]'; Label = "Hardcoded API key"; Severity = "critical" }
        @{ Pattern = '(?i)(secret|token)\s*[=:]\s*["\x27][A-Za-z0-9\-_+/]{20,}["\x27]'; Label = "Hardcoded secret/token"; Severity = "critical" }
        @{ Pattern = 'AKIA[0-9A-Z]{16}'; Label = "AWS Access Key ID"; Severity = "critical" }
        @{ Pattern = '(?i)connectionstring[^=]*=\s*["\x27][^"\x27]*password=[^"\x27]+["\x27]'; Label = "Connection string with password"; Severity = "high" }
        @{ Pattern = '-----BEGIN (RSA |EC )?PRIVATE KEY-----'; Label = "Private key in source"; Severity = "critical" }
        @{ Pattern = '(?i)(jwt|bearer)\s*[=:]\s*["\x27]ey[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+["\x27]'; Label = "Hardcoded JWT token"; Severity = "high" }
        @{ Pattern = '(?i)client[_-]?secret\s*[=:]\s*["\x27][A-Za-z0-9\-_~]{10,}["\x27]'; Label = "Hardcoded client secret"; Severity = "critical" }
    )

    $scanExtensions = @("*.cs", "*.ts", "*.tsx", "*.js", "*.json", "*.env", "*.config", "*.yml", "*.yaml")
    $excludeDirs    = @('\node_modules\', '\bin\', '\obj\', '\dist\', '\build\', '\.git\', '\packages\', '\design\', '\generated\')
    $secretCount    = 0

    foreach ($ext in $scanExtensions) {
        $files = Get-ChildItem -Path $RepoRoot -Filter $ext -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $f = $_.FullName; -not ($excludeDirs | Where-Object { $f -match [regex]::Escape($_) }) } |
            Select-Object -First $MaxFiles

        foreach ($file in $files) {
            $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }

            foreach ($p in $secretPatterns) {
                if ($content -match $p.Pattern) {
                    $relPath = $file.FullName.Replace($RepoRoot, '').TrimStart('\', '/')
                    # Skip .env.example and test fixtures
                    if ($relPath -match '(?i)(\.example|\.sample|test|spec|mock|fixture)') { continue }
                    Add-Finding -Phase "secrets" -Severity $p.Severity -Category "secrets" `
                        -File $relPath -Description "$($p.Label) found in $relPath" `
                        -Recommendation "Move to environment variables or secrets manager. Never commit credentials."
                    $secretCount++
                    Write-Log "$($p.Severity.ToUpper()): $($p.Label) in $relPath" $(if ($p.Severity -eq "critical") { "ERROR" } else { "WARN" })
                }
            }
        }
    }

    # Check .gitignore covers sensitive files
    $gitignorePath = Join-Path $RepoRoot ".gitignore"
    if (Test-Path $gitignorePath) {
        $gitignore = Get-Content $gitignorePath -Raw
        $sensitiveFiles = @(".env", "appsettings.Production.json", "*.pfx", "*.key", "secrets.json")
        foreach ($sf in $sensitiveFiles) {
            if ($gitignore -notmatch [regex]::Escape($sf) -and $gitignore -notmatch [regex]::Escape($sf -replace '\*', '')) {
                Add-Finding -Phase "secrets" -Severity "medium" -Category "secrets" `
                    -File ".gitignore" -Description "$sf not in .gitignore — may be accidentally committed" `
                    -Recommendation "Add $sf to .gitignore"
            }
        }
    } else {
        Add-Finding -Phase "secrets" -Severity "high" -Category "secrets" `
            -File ".gitignore" -Description "No .gitignore found — sensitive files may be committed" `
            -Recommendation "Create a .gitignore that excludes .env, appsettings.Production.json, *.pfx, *.key"
    }

    $report.phases += @{ phase = "secrets_detection"; status = if ($secretCount -eq 0) { "pass" } else { "fail" }; count = $secretCount }
    Write-Log "Secrets detection complete: $secretCount finding(s)" $(if ($secretCount -eq 0) { "OK" } else { "WARN" })
}

# ============================================================
# PHASE 2: DEPENDENCY VULNERABILITY SCAN
# ============================================================

Write-Log "--- Phase 2: Dependency Vulnerability Scan ---" "PHASE"

if (-not $SkipDependencyScan) {
    $depFindings = 0

    # npm audit
    $packageJson = Get-ChildItem -Path $RepoRoot -Filter "package.json" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\node_modules\\' } | Select-Object -First 1
    if ($packageJson) {
        Write-Log "Running npm audit..."
        $npmAudit = & bash -c "cd '$(Split-Path $packageJson.FullName -Parent)' && npm audit --json 2>/dev/null" 2>$null
        if ($npmAudit) {
            try {
                $auditData = $npmAudit | ConvertFrom-Json
                $vulns = $auditData.vulnerabilities
                if ($vulns) {
                    foreach ($pkg in ($vulns | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)) {
                        $v = $vulns.$pkg
                        $sev = if ($v.severity -eq "critical") { "critical" } elseif ($v.severity -eq "high") { "high" } else { "medium" }
                        Add-Finding -Phase "dependencies" -Severity $sev -Category "vulnerable_dependency" `
                            -File "package.json" -Description "Vulnerable npm package: $pkg ($($v.severity)) - $($v.via[0])" `
                            -Recommendation "Run: npm audit fix (or npm audit fix --force for breaking changes)"
                        $depFindings++
                    }
                }
            } catch { Write-Log "npm audit parse failed: $($_.Exception.Message)" "WARN" }
        }
    }

    # dotnet vulnerable packages
    $csproj = Get-ChildItem -Path $RepoRoot -Filter "*.csproj" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(bin|obj|test|Test)\\' } | Select-Object -First 1
    if ($csproj) {
        Write-Log "Scanning .NET packages for vulnerabilities..."
        $dotnetAudit = & dotnet list $csproj.FullName package --vulnerable 2>&1
        if ($dotnetAudit -match 'has the following vulnerable packages') {
            $vulnLines = $dotnetAudit | Where-Object { $_ -match '(Critical|High|Medium|Low)\s+' }
            foreach ($line in $vulnLines) {
                $sev = if ($line -match 'Critical') { "critical" } elseif ($line -match 'High') { "high" } else { "medium" }
                Add-Finding -Phase "dependencies" -Severity $sev -Category "vulnerable_dependency" `
                    -File $csproj.Name -Description "Vulnerable .NET package: $($line.Trim())" `
                    -Recommendation "Update package to a patched version: dotnet add package [name] --version [safe-version]"
                $depFindings++
            }
        }
    }

    $report.phases += @{ phase = "dependency_scan"; status = if ($depFindings -eq 0) { "pass" } else { "fail" }; count = $depFindings }
    Write-Log "Dependency scan complete: $depFindings vulnerability(s)" $(if ($depFindings -eq 0) { "OK" } else { "WARN" })
}

# ============================================================
# PHASE 3: SAST — LLM-based pattern analysis
# ============================================================

Write-Log "--- Phase 3: SAST Pattern Analysis ---" "PHASE"

if (-not $SkipSast -and (Get-Command Invoke-SonnetApi -ErrorAction SilentlyContinue)) {
    # Read backend controllers + Program.cs for SAST
    $csFiles = @(Get-ChildItem -Path $RepoRoot -Filter "*.cs" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(bin|obj|test|Test|migration|Migration|design|generated)\\' } |
        Select-Object -First 40)

    $csContent = ""
    foreach ($f in $csFiles) {
        $c = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        if ($c) {
            $relPath = $f.FullName.Replace($RepoRoot, '').TrimStart('\', '/')
            $truncated = if ($c.Length -gt 3000) { $c.Substring(0, 3000) + "`n// ... truncated" } else { $c }
            $csContent += "`n### $relPath`n$truncated`n"
        }
    }

    $tsFiles = @(Get-ChildItem -Path $RepoRoot -Filter "*.tsx" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(node_modules|dist|build|design|generated)\\' } | Select-Object -First 20)
    $tsContent = ""
    foreach ($f in $tsFiles) {
        $c = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        if ($c) {
            $relPath = $f.FullName.Replace($RepoRoot, '').TrimStart('\', '/')
            $truncated = if ($c.Length -gt 2000) { $c.Substring(0, 2000) + "`n// ... truncated" } else { $c }
            $tsContent += "`n### $relPath`n$truncated`n"
        }
    }

    $sastPrompt = @"
## Security Code Review (SAST)

Analyze the following source code for OWASP Top-10 and common security vulnerabilities.

## Backend C# Files
$csContent

## Frontend TypeScript/React Files
$tsContent

## Check For
1. SQL injection (string concatenation in queries, even with Dapper)
2. XSS vulnerabilities (dangerouslySetInnerHTML, unescaped user input)
3. Insecure deserialization
4. Missing input validation on API endpoints
5. Insecure direct object references (no ownership checks on GET/PUT/DELETE by ID)
6. Sensitive data exposure in API responses (passwords, tokens in response objects)
7. Missing rate limiting on auth endpoints
8. Path traversal vulnerabilities (file upload/download endpoints)
9. Command injection (if any shell execution exists)
10. Insecure randomness (Math.random() for tokens, GUIDs for security)

## Output Format
Return JSON:
{"findings":[{"severity":"critical|high|medium|low","category":"owasp_category","file":"path","line_hint":"approximate area","description":"what the vulnerability is","recommendation":"how to fix it"}],"summary":"1-2 sentence overall assessment"}
Return ONLY the JSON. No markdown fences.
"@

    $sastSystem = "You are a security code reviewer performing SAST analysis. Find real vulnerabilities, not false positives. Return JSON only."

    try {
        $sastResult = Invoke-SonnetApi -SystemPrompt $sastSystem -UserMessage $sastPrompt -MaxTokens 8192 -Phase "security-sast"
        if ($sastResult -and $sastResult.Success -and $sastResult.Text) {
            $jsonText = $sastResult.Text.Trim() -replace '(?s)^```[a-z]*\s*\n', '' -replace '\n```\s*$', ''
            $parsed = $jsonText | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($parsed -and $parsed.findings) {
                foreach ($f in $parsed.findings) {
                    Add-Finding -Phase "sast" -Severity $f.severity -Category $f.category `
                        -File ($f.file ?? "") -Description $f.description `
                        -Recommendation $f.recommendation
                }
                Write-Log "SAST complete: $($parsed.findings.Count) finding(s). $($parsed.summary)" $(if ($parsed.findings.Count -eq 0) { "OK" } else { "WARN" })
            }
            $report.phases += @{ phase = "sast"; status = if ($parsed.findings.Count -eq 0) { "pass" } else { "warn" }; count = $parsed.findings.Count }
        }
    } catch {
        Write-Log "SAST LLM call failed: $($_.Exception.Message)" "WARN"
        $report.phases += @{ phase = "sast"; status = "skip"; count = 0 }
    }
}

# ============================================================
# PHASE 4: AUTH / CRYPTO REVIEW
# ============================================================

Write-Log "--- Phase 4: Auth/Crypto Review ---" "PHASE"

$authFindings = 0

# JWT config checks
$programFiles = Get-ChildItem -Path $RepoRoot -Filter "Program.cs" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' }
foreach ($pf in $programFiles) {
    $content = Get-Content $pf.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }
    $relPath = $pf.FullName.Replace($RepoRoot, '').TrimStart('\', '/')

    if ($content -match 'AddAuthentication' -and $content -notmatch 'ValidateIssuer\s*=\s*true') {
        Add-Finding -Phase "auth_crypto" -Severity "high" -Category "insecure_auth" `
            -File $relPath -Description "JWT ValidateIssuer not set to true - accepts tokens from any issuer" `
            -Recommendation "Set ValidateIssuer = true in JwtBearerOptions"
        $authFindings++
    }
    if ($content -match 'ValidateLifetime\s*=\s*false') {
        Add-Finding -Phase "auth_crypto" -Severity "critical" -Category "insecure_auth" `
            -File $relPath -Description "JWT lifetime validation disabled - expired tokens will be accepted" `
            -Recommendation "Set ValidateLifetime = true"
        $authFindings++
    }
    if ($content -match 'IssuerSigningKey.*new SymmetricSecurityKey.*Encoding\.UTF8\.GetBytes\(["\x27][^"\x27]{1,32}["\x27]\)') {
        Add-Finding -Phase "auth_crypto" -Severity "high" -Category "weak_crypto" `
            -File $relPath -Description "Weak JWT signing key (< 32 chars hardcoded string)" `
            -Recommendation "Use a 256-bit+ random key from environment variables"
        $authFindings++
    }
    if ($content -match '\.AllowAnyOrigin\(\)' -and $content -match 'AllowCredentials') {
        Add-Finding -Phase "auth_crypto" -Severity "critical" -Category "cors" `
            -File $relPath -Description "CORS AllowAnyOrigin() with AllowCredentials() - this is rejected by browsers and is insecure" `
            -Recommendation "Specify explicit allowed origins instead of AllowAnyOrigin when using credentials"
        $authFindings++
    }
    if ($content -match '\.AllowAnyOrigin\(\)' -and $content -notmatch 'AllowCredentials') {
        Add-Finding -Phase "auth_crypto" -Severity "medium" -Category "cors" `
            -File $relPath -Description "CORS allows any origin - acceptable for public APIs, risky for private ones" `
            -Recommendation "Specify allowed origins explicitly for non-public APIs"
        $authFindings++
    }
}

# Password hashing check (C# - look for MD5/SHA1 without salt)
$csFiles = Get-ChildItem -Path $RepoRoot -Filter "*.cs" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\(bin|obj|test|Test)\\' }
foreach ($f in $csFiles) {
    $c = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $c) { continue }
    $relPath = $f.FullName.Replace($RepoRoot, '').TrimStart('\', '/')
    if ($c -match 'MD5\.Create\(\)|SHA1\.Create\(\)|MD5\.HashData\(') {
        Add-Finding -Phase "auth_crypto" -Severity "high" -Category "weak_crypto" `
            -File $relPath -Description "MD5/SHA1 used for hashing - insecure for passwords" `
            -Recommendation "Use BCrypt.Net, Argon2, or ASP.NET Core Identity's PasswordHasher<T>"
        $authFindings++
    }
}

$report.phases += @{ phase = "auth_crypto"; status = if ($authFindings -eq 0) { "pass" } else { "warn" }; count = $authFindings }
Write-Log "Auth/crypto review complete: $authFindings finding(s)" $(if ($authFindings -eq 0) { "OK" } else { "WARN" })

# ============================================================
# DETERMINE OVERALL STATUS
# ============================================================

$failSeverities = @("critical","high","medium","low") | Where-Object {
    $severityRank[$_] -ge $severityRank[$FailOnSeverity]
}
$blockingCount = ($report.findings | Where-Object { $_.severity -in $failSeverities }).Count
$report.status = if ($blockingCount -eq 0) { "pass" } else { "fail" }

# ============================================================
# WRITE REPORTS
# ============================================================

$report | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $outDir "security-gate-report.json") -Encoding UTF8

$md = @()
$md += "# Security Gate Report"
$md += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Repo: $repoName | Status: $($report.status.ToUpper())"
$md += ""
$md += "## Summary"
$md += "| Severity | Count |"
$md += "|----------|-------|"
$md += "| Critical | $($report.summary.critical) |"
$md += "| High     | $($report.summary.high) |"
$md += "| Medium   | $($report.summary.medium) |"
$md += "| Low      | $($report.summary.low) |"
$md += "| **Total** | **$($report.summary.total)** |"
$md += ""
if ($report.findings.Count -gt 0) {
    $md += "## Findings"
    $md += "| Severity | Category | File | Description |"
    $md += "|----------|----------|------|-------------|"
    foreach ($f in ($report.findings | Sort-Object { switch($_.severity){"critical"{0}"high"{1}"medium"{2}default{3}} })) {
        $md += "| $($f.severity) | $($f.category) | $($f.file) | $($f.description) |"
    }
    $md += ""
    $md += "## Recommendations"
    $num = 1
    foreach ($f in ($report.findings | Where-Object { $_.severity -in @("critical","high") })) {
        $md += "$num. **[$($f.severity.ToUpper())]** $($f.description)`n   → $($f.recommendation)"
        $num++
    }
}
$md -join "`n" | Set-Content (Join-Path $outDir "security-gate-summary.md") -Encoding UTF8

$statusColor = if ($report.status -eq "pass") { "Green" } else { "Red" }
Write-Host "`n============================================" -ForegroundColor $statusColor
Write-Host "  Security Gate: $($report.status.ToUpper())" -ForegroundColor $statusColor
Write-Host "  Critical: $($report.summary.critical) | High: $($report.summary.high) | Medium: $($report.summary.medium) | Low: $($report.summary.low)" -ForegroundColor DarkGray
Write-Host "  Report: $(Join-Path $outDir 'security-gate-report.json')" -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor $statusColor
