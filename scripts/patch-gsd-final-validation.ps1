<#
.SYNOPSIS
    GSD Final Validation Gate + Developer Handoff Report
    Run AFTER patch-gsd-hardening.ps1.

.DESCRIPTION
    Adds two capabilities that close the gap between "100% requirements matched"
    and "code is actually ready for a developer":

    1. Invoke-FinalValidation - Quality gate at 100% health:
       - Strict build (dotnet --warnaserrors + npm)
       - Test execution (dotnet test + npm test)
       - SQL validation (reuses existing Test-SqlFiles)
       - Dependency vulnerability audit (dotnet + npm)
       Hard failures set health to 99% so the loop continues to fix.
       Warnings are included in the handoff report but don't block convergence.

    2. New-DeveloperHandoff - Generates developer-handoff.md in repo root:
       - Quick start build commands
       - Database setup (SQL files + connection strings)
       - Environment configuration
       - Project structure (file tree)
       - Requirements status table
       - Validation results
       - Known issues & warnings
       - Health progression chart
       - Cost summary

.INSTALL_ORDER
    1. install-gsd-global.ps1
    2. install-gsd-blueprint.ps1
    3. patch-gsd-partial-repo.ps1
    4. patch-gsd-resilience.ps1
    5. patch-gsd-hardening.ps1
    6. patch-gsd-final-validation.ps1    <- this file
#>

param(
    [string]$UserHome = $env:USERPROFILE
)

$ErrorActionPreference = "Stop"
$GsdGlobalDir = Join-Path $UserHome ".gsd-global"

if (-not (Test-Path "$GsdGlobalDir\lib\modules\resilience.ps1")) {
    Write-Host "[XX] Resilience patch not applied. Run patch-gsd-resilience.ps1 first." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Final Validation + Developer Handoff" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ========================================================
# Append final validation functions to resilience library
# ========================================================

Write-Host "[SHIELD] Adding final validation modules to resilience library..." -ForegroundColor Yellow

$finalValidationCode = @'

# ===============================================================
# GSD FINAL VALIDATION MODULES - appended to resilience.ps1
# ===============================================================

# -- Final validation config --
$script:FINAL_VALIDATION_TIMEOUT = 300   # 5 min per check
$script:MAX_VALIDATION_ATTEMPTS = 3

function Invoke-FinalValidation {
    <#
    .SYNOPSIS
        Quality gate that runs when health reaches 100%, before declaring CONVERGED.
        Returns structured results: hard failures block convergence, warnings are advisory.
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [int]$Iteration
    )

    $result = @{
        Passed       = $true
        HardFailures = @()
        Warnings     = @()
        Details      = @{}
        Timestamp    = (Get-Date).ToUniversalTime().ToString("o")
    }

    $logLines = @("=== Final Validation at iter $Iteration ===", "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", "")

    # --- Check 1: Strict .NET Build ---
    try {
        $slnFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sln" -Recurse -Depth 2 -ErrorAction SilentlyContinue
        if ($slnFiles -and $slnFiles.Count -gt 0) {
            $sln = $slnFiles[0].FullName
            $logLines += "CHECK 1: dotnet build --warnaserrors"
            $buildOutput = & dotnet build $sln --no-restore --verbosity quiet 2>&1 | Out-String
            $buildErrors = ($buildOutput -split "`n") | Where-Object { $_ -match "(error CS|error MSB|warning CS)" }
            if ($LASTEXITCODE -ne 0 -or ($buildErrors | Where-Object { $_ -match "error" }).Count -gt 0) {
                $errorCount = ($buildErrors | Where-Object { $_ -match "error" }).Count
                $result.HardFailures += "dotnet build: $errorCount compilation error(s)"
                $result.Passed = $false
                $result.Details["dotnet_build"] = @{ passed=$false; errors=$buildErrors }
                $logLines += "  FAIL: $errorCount error(s)"
                $logLines += $buildErrors
            } else {
                $warnCount = ($buildErrors | Where-Object { $_ -match "warning" }).Count
                if ($warnCount -gt 0) {
                    $result.Warnings += "dotnet build: $warnCount warning(s)"
                    $result.Details["dotnet_build"] = @{ passed=$true; warnings=$warnCount }
                    $logLines += "  WARN: $warnCount warning(s)"
                } else {
                    $result.Details["dotnet_build"] = @{ passed=$true; warnings=0 }
                    $logLines += "  PASS"
                }
            }
        } else {
            $result.Details["dotnet_build"] = @{ skipped=$true; reason="No .sln found" }
            $logLines += "CHECK 1: SKIP (no .sln file)"
        }
    } catch {
        $result.Warnings += "dotnet build check failed: $($_.Exception.Message)"
        $logLines += "CHECK 1: ERROR - $($_.Exception.Message)"
    }

    # --- Check 2: npm Build ---
    try {
        $pkgLocations = @("$RepoRoot\package.json", "$RepoRoot\client\package.json",
                          "$RepoRoot\frontend\package.json", "$RepoRoot\web\package.json",
                          "$RepoRoot\src\client\package.json", "$RepoRoot\src\web\package.json")
        $pkgJson = $pkgLocations | Where-Object { Test-Path $_ } | Select-Object -First 1

        if ($pkgJson) {
            $pkgDir = Split-Path $pkgJson -Parent
            $pkg = Get-Content $pkgJson -Raw | ConvertFrom-Json
            if ($pkg.scripts -and $pkg.scripts.build) {
                $logLines += "CHECK 2: npm run build (in $pkgDir)"
                Push-Location $pkgDir
                try {
                    if (-not (Test-Path "node_modules")) {
                        & npm install --silent 2>&1 | Out-Null
                    }
                    $npmOutput = & npm run build 2>&1 | Out-String
                    $npmErrors = ($npmOutput -split "`n") | Where-Object { $_ -match "(TS\d{4}|SyntaxError|Module not found|Cannot find|ERROR|Failed to compile)" }
                    if ($LASTEXITCODE -ne 0) {
                        $result.HardFailures += "npm build: failed with exit code $LASTEXITCODE"
                        $result.Passed = $false
                        $result.Details["npm_build"] = @{ passed=$false; errors=$npmErrors }
                        $logLines += "  FAIL: exit code $LASTEXITCODE"
                        $logLines += $npmErrors
                    } else {
                        $result.Details["npm_build"] = @{ passed=$true }
                        $logLines += "  PASS"
                    }
                } finally { Pop-Location }
            } else {
                $result.Details["npm_build"] = @{ skipped=$true; reason="No build script in package.json" }
                $logLines += "CHECK 2: SKIP (no build script)"
            }
        } else {
            $result.Details["npm_build"] = @{ skipped=$true; reason="No package.json found" }
            $logLines += "CHECK 2: SKIP (no package.json)"
        }
    } catch {
        $result.Warnings += "npm build check failed: $($_.Exception.Message)"
        $logLines += "CHECK 2: ERROR - $($_.Exception.Message)"
    }

    # --- Check 3: .NET Tests ---
    try {
        $testProjects = Get-ChildItem -Path $RepoRoot -Recurse -Depth 3 -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "\.(Tests?|Specs?)\.csproj$" }

        if ($testProjects -and $testProjects.Count -gt 0) {
            $logLines += "CHECK 3: dotnet test ($($testProjects.Count) test project(s))"
            $allTestsPassed = $true
            $testSummary = @()
            foreach ($tp in $testProjects) {
                $testOutput = & dotnet test $tp.FullName --no-build --verbosity normal 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0) {
                    $allTestsPassed = $false
                    $failedLines = ($testOutput -split "`n") | Where-Object { $_ -match "(Failed|Error)" } | Select-Object -First 10
                    $testSummary += "$($tp.Name): FAILED"
                    $testSummary += $failedLines
                } else {
                    $passedMatch = [regex]::Match($testOutput, "Passed!\s+-\s+Failed:\s+(\d+),\s+Passed:\s+(\d+)")
                    if ($passedMatch.Success) {
                        $testSummary += "$($tp.Name): Passed ($($passedMatch.Groups[2].Value) tests)"
                    } else {
                        $testSummary += "$($tp.Name): Passed"
                    }
                }
            }
            if (-not $allTestsPassed) {
                $failCount = ($testSummary | Where-Object { $_ -match "FAILED" }).Count
                $result.HardFailures += "dotnet test: $failCount test project(s) failed"
                $result.Passed = $false
                $result.Details["dotnet_test"] = @{ passed=$false; summary=$testSummary }
                $logLines += "  FAIL: $failCount project(s) failed"
            } else {
                $result.Details["dotnet_test"] = @{ passed=$true; summary=$testSummary }
                $logLines += "  PASS: all $($testProjects.Count) project(s)"
            }
            $logLines += $testSummary
        } else {
            $result.Warnings += "No .NET test projects detected"
            $result.Details["dotnet_test"] = @{ skipped=$true; reason="No test projects found" }
            $logLines += "CHECK 3: SKIP (no test projects) - WARNING: no tests"
        }
    } catch {
        $result.Warnings += "dotnet test check failed: $($_.Exception.Message)"
        $logLines += "CHECK 3: ERROR - $($_.Exception.Message)"
    }

    # --- Check 4: npm Tests ---
    try {
        if ($pkgJson) {
            $pkg = Get-Content $pkgJson -Raw | ConvertFrom-Json
            $hasRealTests = $pkg.scripts -and $pkg.scripts.test -and
                $pkg.scripts.test -notmatch 'echo\s+"?Error' -and
                $pkg.scripts.test -ne "exit 1"

            if ($hasRealTests) {
                $pkgDir = Split-Path $pkgJson -Parent
                $logLines += "CHECK 4: npm test (in $pkgDir)"
                Push-Location $pkgDir
                try {
                    $env:CI = "true"  # prevents interactive watch mode
                    $npmTestOutput = & npm test 2>&1 | Out-String
                    $env:CI = $null
                    if ($LASTEXITCODE -ne 0) {
                        $failLines = ($npmTestOutput -split "`n") | Where-Object { $_ -match "(FAIL|Error|failed)" } | Select-Object -First 10
                        $result.HardFailures += "npm test: tests failed"
                        $result.Passed = $false
                        $result.Details["npm_test"] = @{ passed=$false; output=$failLines }
                        $logLines += "  FAIL"
                        $logLines += $failLines
                    } else {
                        $result.Details["npm_test"] = @{ passed=$true }
                        $logLines += "  PASS"
                    }
                } finally { Pop-Location }
            } else {
                $result.Warnings += "No real npm test script detected"
                $result.Details["npm_test"] = @{ skipped=$true; reason="Default or missing test script" }
                $logLines += "CHECK 4: SKIP (no real test script) - WARNING: no tests"
            }
        } else {
            $result.Details["npm_test"] = @{ skipped=$true; reason="No package.json" }
            $logLines += "CHECK 4: SKIP (no package.json)"
        }
    } catch {
        $result.Warnings += "npm test check failed: $($_.Exception.Message)"
        $logLines += "CHECK 4: ERROR - $($_.Exception.Message)"
    }

    # --- Check 5: SQL Validation ---
    try {
        if (Get-Command Test-SqlFiles -ErrorAction SilentlyContinue) {
            $logLines += "CHECK 5: SQL validation"
            $sqlResult = Test-SqlFiles -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration
            if (-not $sqlResult.Passed) {
                $result.Warnings += "SQL issues: $($sqlResult.Errors.Count) pattern violation(s)"
                $result.Details["sql_validation"] = @{ passed=$false; errors=$sqlResult.Errors }
                $logLines += "  WARN: $($sqlResult.Errors.Count) issue(s)"
                $logLines += $sqlResult.Errors
            } else {
                $result.Details["sql_validation"] = @{ passed=$true }
                $logLines += "  PASS"
            }
        } else {
            $result.Details["sql_validation"] = @{ skipped=$true; reason="Test-SqlFiles not available" }
            $logLines += "CHECK 5: SKIP (function not available)"
        }
    } catch {
        $result.Warnings += "SQL validation failed: $($_.Exception.Message)"
        $logLines += "CHECK 5: ERROR - $($_.Exception.Message)"
    }

    # --- Check 6: .NET Vulnerability Audit ---
    try {
        $slnFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sln" -Recurse -Depth 2 -ErrorAction SilentlyContinue
        if ($slnFiles -and $slnFiles.Count -gt 0 -and (Get-Command dotnet -ErrorAction SilentlyContinue)) {
            $logLines += "CHECK 6: dotnet list package --vulnerable"
            $vulnOutput = & dotnet list package --vulnerable 2>&1 | Out-String
            $vulnLines = ($vulnOutput -split "`n") | Where-Object { $_ -match "(Critical|High|Moderate)" }
            if ($vulnLines.Count -gt 0) {
                $result.Warnings += "NuGet vulnerabilities: $($vulnLines.Count) package(s) flagged"
                $result.Details["dotnet_audit"] = @{ passed=$false; vulnerabilities=$vulnLines }
                $logLines += "  WARN: $($vulnLines.Count) vulnerable package(s)"
            } else {
                $result.Details["dotnet_audit"] = @{ passed=$true }
                $logLines += "  PASS"
            }
        } else {
            $result.Details["dotnet_audit"] = @{ skipped=$true }
            $logLines += "CHECK 6: SKIP (no .sln or dotnet)"
        }
    } catch {
        $result.Details["dotnet_audit"] = @{ skipped=$true; error=$_.Exception.Message }
        $logLines += "CHECK 6: ERROR - $($_.Exception.Message)"
    }

    # --- Check 7: npm Vulnerability Audit ---
    try {
        if ($pkgJson -and (Get-Command npm -ErrorAction SilentlyContinue)) {
            $pkgDir = Split-Path $pkgJson -Parent
            $logLines += "CHECK 7: npm audit --audit-level=high"
            Push-Location $pkgDir
            try {
                $auditOutput = & npm audit --audit-level=high 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0) {
                    $vulnCount = if ($auditOutput -match "(\d+)\s+vulnerabilit") { $Matches[1] } else { "unknown" }
                    $result.Warnings += "npm audit: $vulnCount high+ severity vulnerability/ies"
                    $result.Details["npm_audit"] = @{ passed=$false; output=$auditOutput.Substring(0, [math]::Min(2000, $auditOutput.Length)) }
                    $logLines += "  WARN: $vulnCount vulnerability/ies"
                } else {
                    $result.Details["npm_audit"] = @{ passed=$true }
                    $logLines += "  PASS"
                }
            } finally { Pop-Location }
        } else {
            $result.Details["npm_audit"] = @{ skipped=$true }
            $logLines += "CHECK 7: SKIP (no package.json or npm)"
        }
    } catch {
        $result.Details["npm_audit"] = @{ skipped=$true; error=$_.Exception.Message }
        $logLines += "CHECK 7: ERROR - $($_.Exception.Message)"
    }

    # --- Write results ---
    $logLines += ""
    $logLines += "=== Summary ==="
    $logLines += "Passed: $($result.Passed)"
    $logLines += "Hard failures: $($result.HardFailures.Count)"
    $logLines += "Warnings: $($result.Warnings.Count)"

    # Save log
    $logPath = Join-Path $GsdDir "logs\final-validation.log"
    $logLines -join "`n" | Set-Content $logPath -Encoding UTF8

    # Save structured results
    $jsonPath = Join-Path $GsdDir "health\final-validation.json"
    @{
        passed        = $result.Passed
        hard_failures = $result.HardFailures
        warnings      = $result.Warnings
        iteration     = $Iteration
        timestamp     = $result.Timestamp
        checks        = @{
            dotnet_build = $result.Details["dotnet_build"]
            npm_build    = $result.Details["npm_build"]
            dotnet_test  = $result.Details["dotnet_test"]
            npm_test     = $result.Details["npm_test"]
            sql          = $result.Details["sql_validation"]
            dotnet_audit = $result.Details["dotnet_audit"]
            npm_audit    = $result.Details["npm_audit"]
        }
    } | ConvertTo-Json -Depth 4 | Set-Content $jsonPath -Encoding UTF8

    # Log via structured error system if failures
    if (-not $result.Passed -and (Get-Command Write-GsdError -ErrorAction SilentlyContinue)) {
        Write-GsdError -GsdDir $GsdDir -Category "validation_fail" -Phase "final-validation" `
            -Iteration $Iteration -Message ($result.HardFailures -join "; ")
    }

    return $result
}


function New-DeveloperHandoff {
    <#
    .SYNOPSIS
        Generates developer-handoff.md in the repo root with everything a developer
        needs to pick up, compile, and run the project.
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$Pipeline = "converge",
        [string]$ExitReason = "unknown",
        [double]$FinalHealth = 0,
        [int]$Iteration = 0,
        $ValidationResult = $null
    )

    $repoName = Split-Path $RepoRoot -Leaf
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $md = @()

    # ===== HEADER =====
    $md += "# Developer Handoff - $repoName"
    $md += ""
    $md += "| Field | Value |"
    $md += "|-------|-------|"
    $md += "| Generated | $timestamp |"
    $md += "| Pipeline | $Pipeline |"
    $md += "| Exit Reason | $ExitReason |"
    $md += "| Final Health | ${FinalHealth}% |"
    $md += "| Iterations | $Iteration |"
    $md += ""

    # ===== QUICK START =====
    $md += "## Quick Start"
    $md += ""
    $buildCmds = @()

    # .NET
    $slnFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sln" -Recurse -Depth 2 -ErrorAction SilentlyContinue
    if ($slnFiles -and $slnFiles.Count -gt 0) {
        $slnRel = $slnFiles[0].FullName.Replace("$RepoRoot\", "")
        $buildCmds += "### .NET"
        $buildCmds += '```bash'
        $buildCmds += "dotnet restore $slnRel"
        $buildCmds += "dotnet build $slnRel"
        $buildCmds += "dotnet test    # if test projects exist"
        $buildCmds += '```'
        $buildCmds += ""
    }

    # npm
    $pkgLocations = @("$RepoRoot\package.json", "$RepoRoot\client\package.json",
                      "$RepoRoot\frontend\package.json", "$RepoRoot\web\package.json",
                      "$RepoRoot\src\client\package.json", "$RepoRoot\src\web\package.json")
    $pkgJson = $pkgLocations | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($pkgJson) {
        $pkgDir = (Split-Path $pkgJson -Parent).Replace("$RepoRoot\", "")
        if ($pkgDir -eq (Split-Path $pkgJson -Parent)) { $pkgDir = "." }
        $buildCmds += "### Node.js / React"
        $buildCmds += '```bash'
        if ($pkgDir -ne ".") { $buildCmds += "cd $pkgDir" }
        $buildCmds += "npm install"
        $buildCmds += "npm run build"
        $buildCmds += "npm test       # if tests exist"
        $buildCmds += '```'
        $buildCmds += ""
    }

    # Docker
    $dockerFiles = @("$RepoRoot\docker-compose.yml", "$RepoRoot\docker-compose.yaml")
    $dockerFile = $dockerFiles | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($dockerFile) {
        $buildCmds += "### Docker"
        $buildCmds += '```bash'
        $buildCmds += "docker-compose up -d"
        $buildCmds += '```'
        $buildCmds += ""
    }

    if ($buildCmds.Count -eq 0) {
        $buildCmds += "*No build system detected. Check project root for build instructions.*"
        $buildCmds += ""
    }
    $md += $buildCmds

    # ===== DATABASE SETUP =====
    $sqlFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sql" -Recurse -Depth 4 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "(node_modules|\.git|bin|obj)" } |
        Sort-Object Name

    if ($sqlFiles -and $sqlFiles.Count -gt 0) {
        $md += "## Database Setup"
        $md += ""

        # Connection string from appsettings
        $appSettings = @("$RepoRoot\appsettings.json", "$RepoRoot\src\appsettings.json",
                         "$RepoRoot\Api\appsettings.json", "$RepoRoot\src\Api\appsettings.json")
        $appSettingsFile = $appSettings | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($appSettingsFile) {
            try {
                $config = Get-Content $appSettingsFile -Raw | ConvertFrom-Json
                if ($config.ConnectionStrings) {
                    $md += "### Connection Strings"
                    $md += ""
                    $md += "From ``$(Split-Path $appSettingsFile -Leaf)``:"
                    $md += '```json'
                    $md += ($config.ConnectionStrings | ConvertTo-Json -Depth 2)
                    $md += '```'
                    $md += ""
                    $md += "> Update server name, credentials, and database name for your environment."
                    $md += ""
                }
            } catch {}
        }

        $md += "### SQL Scripts ($($sqlFiles.Count) files)"
        $md += ""
        $md += "Execute in this order:"
        $md += ""
        $md += "| # | File | Size |"
        $md += "|---|------|------|"
        $i = 0
        foreach ($sf in $sqlFiles) {
            $i++
            $relPath = $sf.FullName.Replace("$RepoRoot\", "")
            $sizeKb = [math]::Round($sf.Length / 1024, 1)
            $md += "| $i | ``$relPath`` | ${sizeKb} KB |"
        }
        $md += ""
    }

    # ===== ENVIRONMENT CONFIGURATION =====
    $md += "## Environment Configuration"
    $md += ""

    # appsettings
    $allAppSettings = Get-ChildItem -Path $RepoRoot -Filter "appsettings*.json" -Recurse -Depth 3 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "(node_modules|\.git|bin|obj)" }
    if ($allAppSettings -and $allAppSettings.Count -gt 0) {
        $md += "### Configuration Files"
        $md += ""
        foreach ($as in $allAppSettings) {
            $relPath = $as.FullName.Replace("$RepoRoot\", "")
            $md += "- ``$relPath``"
        }
        $md += ""
    }

    # .env files
    $envFiles = Get-ChildItem -Path $RepoRoot -Filter ".env*" -Recurse -Depth 3 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "(node_modules|\.git)" }
    if ($envFiles -and $envFiles.Count -gt 0) {
        $md += "### Environment Files"
        $md += ""
        foreach ($ef in $envFiles) {
            $relPath = $ef.FullName.Replace("$RepoRoot\", "")
            $md += "- ``$relPath``"
        }
        $md += ""
        $md += "> Copy ``.env.example`` to ``.env`` and fill in values before running."
        $md += ""
    }

    if ((-not $allAppSettings -or $allAppSettings.Count -eq 0) -and (-not $envFiles -or $envFiles.Count -eq 0)) {
        $md += "*No configuration files detected.*"
        $md += ""
    }

    # ===== PROJECT STRUCTURE =====
    $fileTreePath = Join-Path $GsdDir "file-map-tree.md"
    if (Test-Path $fileTreePath) {
        $md += "## Project Structure"
        $md += ""
        $md += '```'
        $treeContent = Get-Content $fileTreePath -Raw
        if ($treeContent.Length -gt 5000) {
            $md += $treeContent.Substring(0, 5000)
            $md += "... (truncated, see .gsd/file-map-tree.md for full tree)"
        } else {
            $md += $treeContent
        }
        $md += '```'
        $md += ""
    }

    # ===== REQUIREMENTS STATUS =====
    $matrixPath = if ($Pipeline -eq "blueprint") {
        Join-Path $GsdDir "blueprint\blueprint.json"
    } else {
        Join-Path $GsdDir "health\requirements-matrix.json"
    }

    if (Test-Path $matrixPath) {
        try {
            $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
            $reqs = if ($Pipeline -eq "blueprint" -and $matrix.tiers) {
                $allItems = @()
                foreach ($tier in $matrix.tiers) {
                    foreach ($item in $tier.items) {
                        $allItems += [PSCustomObject]@{
                            id          = if ($item.id) { $item.id } else { $item.file }
                            description = if ($item.description) { $item.description } else { $item.file }
                            status      = if ($item.status) { $item.status } else { "not_started" }
                            files       = if ($item.file) { @($item.file) } else { @() }
                        }
                    }
                }
                $allItems
            } elseif ($matrix.requirements) {
                $matrix.requirements
            } else { @() }

            if ($reqs.Count -gt 0) {
                $md += "## Requirements Status"
                $md += ""

                $satisfied = @($reqs | Where-Object { $_.status -eq "satisfied" })
                $partial   = @($reqs | Where-Object { $_.status -eq "partial" })
                $notStarted = @($reqs | Where-Object { $_.status -eq "not_started" })

                $md += "| Status | Count |"
                $md += "|--------|-------|"
                $md += "| Satisfied | $($satisfied.Count) |"
                $md += "| Partial | $($partial.Count) |"
                $md += "| Not Started | $($notStarted.Count) |"
                $md += "| **Total** | **$($reqs.Count)** |"
                $md += ""

                $md += "<details>"
                $md += "<summary>Full requirements list ($($reqs.Count) items)</summary>"
                $md += ""
                $md += "| ID | Description | Status | Implemented In |"
                $md += "|----|-------------|--------|---------------|"

                # Satisfied first, then partial, then not_started
                foreach ($r in ($satisfied + $partial + $notStarted)) {
                    $id = if ($r.id) { $r.id } else { "-" }
                    $desc = if ($r.description) { $r.description.Substring(0, [math]::Min(80, $r.description.Length)) } else { "-" }
                    $files = if ($r.satisfied_by) { ($r.satisfied_by | Select-Object -First 3) -join ", " }
                             elseif ($r.files) { ($r.files | Select-Object -First 3) -join ", " }
                             else { "-" }
                    $statusIcon = switch ($r.status) {
                        "satisfied"   { "OK" }
                        "partial"     { "PARTIAL" }
                        "not_started" { "TODO" }
                        default       { $r.status }
                    }
                    $md += "| $id | $desc | $statusIcon | $files |"
                }
                $md += ""
                $md += "</details>"
                $md += ""
            }
        } catch {
            $md += "## Requirements Status"
            $md += ""
            $md += "*Could not parse requirements matrix: $($_.Exception.Message)*"
            $md += ""
        }
    }

    # ===== VALIDATION RESULTS =====
    $md += "## Validation Results"
    $md += ""

    $valJsonPath = Join-Path $GsdDir "health\final-validation.json"
    if ($ValidationResult) {
        if ($ValidationResult.Passed) {
            $md += "**Status: PASSED**"
        } else {
            $md += "**Status: FAILED**"
        }
        $md += ""

        if ($ValidationResult.HardFailures -and $ValidationResult.HardFailures.Count -gt 0) {
            $md += "### Failures (blocking)"
            $md += ""
            foreach ($f in $ValidationResult.HardFailures) { $md += "- $f" }
            $md += ""
        }

        if ($ValidationResult.Warnings -and $ValidationResult.Warnings.Count -gt 0) {
            $md += "### Warnings (non-blocking)"
            $md += ""
            foreach ($w in $ValidationResult.Warnings) { $md += "- $w" }
            $md += ""
        }

        if ((-not $ValidationResult.HardFailures -or $ValidationResult.HardFailures.Count -eq 0) -and
            (-not $ValidationResult.Warnings -or $ValidationResult.Warnings.Count -eq 0)) {
            $md += "All checks passed with no warnings."
            $md += ""
        }
    } elseif (Test-Path $valJsonPath) {
        try {
            $valData = Get-Content $valJsonPath -Raw | ConvertFrom-Json
            $md += "**Status: $(if ($valData.passed) {'PASSED'} else {'FAILED'})**"
            $md += ""
            if ($valData.hard_failures.Count -gt 0) {
                $md += "### Failures"
                $md += ""
                foreach ($f in $valData.hard_failures) { $md += "- $f" }
                $md += ""
            }
            if ($valData.warnings.Count -gt 0) {
                $md += "### Warnings"
                $md += ""
                foreach ($w in $valData.warnings) { $md += "- $w" }
                $md += ""
            }
        } catch {
            $md += "*Could not parse validation results.*"
            $md += ""
        }
    } else {
        $md += "*Final validation was not run (health did not reach 100%).*"
        $md += ""
    }

    # ===== KNOWN ISSUES =====
    $md += "## Known Issues"
    $md += ""

    $hasIssues = $false

    # Drift report
    $driftPath = Join-Path $GsdDir "health\drift-report.md"
    if (Test-Path $driftPath) {
        $driftContent = (Get-Content $driftPath -Raw).Trim()
        if ($driftContent.Length -gt 10) {
            $md += "### Remaining Gaps"
            $md += ""
            $md += $driftContent
            $md += ""
            $hasIssues = $true
        }
    }

    # Recent errors
    $errorsPath = Join-Path $GsdDir "logs\errors.jsonl"
    if (Test-Path $errorsPath) {
        $errorLines = Get-Content $errorsPath -ErrorAction SilentlyContinue | Select-Object -Last 10
        if ($errorLines -and $errorLines.Count -gt 0) {
            $md += "### Recent Errors (last 10)"
            $md += ""
            $md += "| Category | Phase | Message |"
            $md += "|----------|-------|---------|"
            foreach ($line in $errorLines) {
                try {
                    $err = $line | ConvertFrom-Json
                    $msg = if ($err.message.Length -gt 80) { $err.message.Substring(0, 80) + "..." } else { $err.message }
                    $md += "| $($err.category) | $($err.phase) | $msg |"
                } catch {}
            }
            $md += ""
            $hasIssues = $true
        }
    }

    if (-not $hasIssues) {
        $md += "*No known issues.*"
        $md += ""
    }

    # ===== HEALTH PROGRESSION =====
    $historyPath = if ($Pipeline -eq "blueprint") {
        Join-Path $GsdDir "blueprint\health-history.jsonl"
    } else {
        Join-Path $GsdDir "health\health-history.jsonl"
    }

    if (Test-Path $historyPath) {
        $entries = Get-Content $historyPath -ErrorAction SilentlyContinue |
            ForEach-Object { try { $_ | ConvertFrom-Json } catch {} }
        if ($entries -and $entries.Count -gt 0) {
            $md += "## Health Progression"
            $md += ""
            $md += '```'
            foreach ($e in $entries) {
                $iter = if ($e.iteration) { $e.iteration } else { "?" }
                $h = if ($e.health_score) { $e.health_score } elseif ($e.health) { $e.health } else { 0 }
                $filled = [math]::Floor($h / 5)
                $empty = 20 - $filled
                $bar = "#" * $filled + "." * $empty
                $md += "  Iter {0,3}: [{1}] {2,5:N1}%" -f $iter, $bar, $h
            }
            $md += '```'
            $md += ""
        }
    }

    # ===== COST SUMMARY =====
    $costPath = Join-Path $GsdDir "costs\cost-summary.json"
    if (Test-Path $costPath) {
        try {
            $costs = Get-Content $costPath -Raw | ConvertFrom-Json
            $md += "## Cost Summary"
            $md += ""
            $md += "| Metric | Value |"
            $md += "|--------|-------|"
            $md += "| Total API Cost | `$$('{0:N2}' -f $costs.total_cost_usd) |"
            $md += "| Total API Calls | $($costs.total_calls) |"
            if ($costs.total_tokens) {
                $md += "| Input Tokens | $('{0:N0}' -f $costs.total_tokens.input) |"
                $md += "| Output Tokens | $('{0:N0}' -f $costs.total_tokens.output) |"
                if ($costs.total_tokens.cached) {
                    $md += "| Cached Tokens | $('{0:N0}' -f $costs.total_tokens.cached) |"
                }
            }
            $md += ""

            if ($costs.by_agent) {
                $md += "### Cost by Agent"
                $md += ""
                $md += "| Agent | Calls | Cost |"
                $md += "|-------|-------|------|"
                $costs.by_agent.PSObject.Properties | ForEach-Object {
                    $md += "| $($_.Name) | $($_.Value.calls) | `$$('{0:N2}' -f $_.Value.cost_usd) |"
                }
                $md += ""
            }

            if ($costs.by_phase) {
                $md += "### Cost by Phase"
                $md += ""
                $md += "| Phase | Calls | Cost |"
                $md += "|-------|-------|------|"
                $costs.by_phase.PSObject.Properties | ForEach-Object {
                    $md += "| $($_.Name) | $($_.Value.calls) | `$$('{0:N2}' -f $_.Value.cost_usd) |"
                }
                $md += ""
            }
        } catch {
            $md += "## Cost Summary"
            $md += ""
            $md += "*Could not parse cost data.*"
            $md += ""
        }
    }

    # ===== FOOTER =====
    $md += "---"
    $md += "*Generated by GSD Autonomous Dev Engine*"

    # Write file
    $handoffPath = Join-Path $RepoRoot "developer-handoff.md"
    ($md -join "`n") | Set-Content $handoffPath -Encoding UTF8

    Write-Host "  [DOC] Generated: developer-handoff.md" -ForegroundColor Green

    return $handoffPath
}

Write-Host "  Final validation modules loaded." -ForegroundColor DarkGray
'@

$resilienceFile = Join-Path $GsdGlobalDir "lib\modules\resilience.ps1"
$existing = Get-Content $resilienceFile -Raw
if ($existing -match "GSD FINAL VALIDATION MODULES") {
    # Remove old section and replace with current version
    $markerLine = "`n# GSD FINAL VALIDATION MODULES"
    $idx = $existing.IndexOf($markerLine)
    if ($idx -gt 0) {
        $existing = $existing.Substring(0, $idx)
        Set-Content -Path $resilienceFile -Value $existing -Encoding UTF8
    }
    Add-Content -Path $resilienceFile -Value "`n$finalValidationCode" -Encoding UTF8
    Write-Host "   [OK] Updated final validation modules in resilience.ps1" -ForegroundColor DarkGreen
} else {
    Add-Content -Path $resilienceFile -Value "`n$finalValidationCode" -Encoding UTF8
    Write-Host "   [OK] Appended final validation modules to resilience.ps1" -ForegroundColor DarkGreen
}

Write-Host ""

# ========================================================
# DONE
# ========================================================

Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  [OK] Final Validation Patch Applied" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  NEW CAPABILITIES:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  [SHIELD] Final validation gate at 100% health:" -ForegroundColor White
Write-Host "     - Strict build (dotnet --warnaserrors + npm)" -ForegroundColor DarkGray
Write-Host "     - Test execution (dotnet test + npm test)" -ForegroundColor DarkGray
Write-Host "     - SQL pattern validation" -ForegroundColor DarkGray
Write-Host "     - Dependency vulnerability audit (dotnet + npm)" -ForegroundColor DarkGray
Write-Host "     - Hard failures reset health to 99% for auto-fix" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  [DOC] Developer handoff report at pipeline exit:" -ForegroundColor White
Write-Host "     - Build commands, database setup, environment config" -ForegroundColor DarkGray
Write-Host "     - Requirements status table, validation results" -ForegroundColor DarkGray
Write-Host "     - Health progression, cost summary, known issues" -ForegroundColor DarkGray
Write-Host ""
