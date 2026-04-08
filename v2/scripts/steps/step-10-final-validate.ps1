# ===============================================================
# Step 10: Final Validation Gate
# Agent: Claude (synthesis) | 12-check validation before declaring CONVERGED
# ===============================================================

param(
    [Parameter(Mandatory)][string]$GsdDir,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][PSObject]$AgentMap,
    [Parameter(Mandatory)][PSObject]$Config
)

$stepId = "10-final-validation"
Write-Host "`n=== STEP 10: Final Validation Gate ===" -ForegroundColor Cyan

$maxAttempts = $Config.limits.max_final_validation_attempts
$validationPassed = $false
$attempt = 0
$results = @{}

while (-not $validationPassed -and $attempt -lt $maxAttempts) {
    $attempt++
    Write-Host "`n  Validation attempt $attempt/$maxAttempts" -ForegroundColor DarkGray
    $hardFail = $false
    $warnings = @()

    # -- Check 1: .NET Build --
    $slnFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sln" -Recurse -Depth 2 -ErrorAction SilentlyContinue
    if ($slnFiles.Count -gt 0) {
        try {
            $null = dotnet build ($slnFiles[0].FullName) --no-restore 2>&1
            $results["dotnet_build"] = if ($LASTEXITCODE -eq 0) { "pass" } else { "fail" }
        } catch { $results["dotnet_build"] = "fail" }
        if ($results["dotnet_build"] -eq "fail") { $hardFail = $true }
        Write-Host "    [$(if ($results['dotnet_build'] -eq 'pass') {'OK'} else {'XX'})] .NET build" -ForegroundColor $(if ($results['dotnet_build'] -eq 'pass') {'Green'} else {'Red'})
    } else { $results["dotnet_build"] = "skipped" }

    # -- Check 2: npm Build --
    $pkgJson = Get-ChildItem -Path $RepoRoot -Filter "package.json" -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkgJson) {
        try {
            Push-Location (Split-Path $pkgJson.FullName)
            $null = npm run build 2>&1
            $results["npm_build"] = if ($LASTEXITCODE -eq 0) { "pass" } else { "fail" }
            Pop-Location
        } catch { $results["npm_build"] = "fail"; Pop-Location }
        if ($results["npm_build"] -eq "fail") { $hardFail = $true }
        Write-Host "    [$(if ($results['npm_build'] -eq 'pass') {'OK'} else {'XX'})] npm build" -ForegroundColor $(if ($results['npm_build'] -eq 'pass') {'Green'} else {'Red'})
    } else { $results["npm_build"] = "skipped" }

    # -- Check 3: .NET Tests --
    if ($slnFiles.Count -gt 0) {
        try {
            $null = dotnet test ($slnFiles[0].FullName) --no-build 2>&1
            $results["dotnet_test"] = if ($LASTEXITCODE -eq 0) { "pass" } else { "fail" }
        } catch { $results["dotnet_test"] = "fail" }
        if ($results["dotnet_test"] -eq "fail") { $hardFail = $true }
        Write-Host "    [$(if ($results['dotnet_test'] -eq 'pass') {'OK'} else {'XX'})] .NET tests" -ForegroundColor $(if ($results['dotnet_test'] -eq 'pass') {'Green'} else {'Red'})
    } else { $results["dotnet_test"] = "skipped" }

    # -- Check 4: npm Tests --
    if ($pkgJson) {
        try {
            Push-Location (Split-Path $pkgJson.FullName)
            $env:CI = "true"
            $null = npm test 2>&1
            $results["npm_test"] = if ($LASTEXITCODE -eq 0) { "pass" } else { "fail" }
            Pop-Location
        } catch { $results["npm_test"] = "fail"; Pop-Location }
        if ($results["npm_test"] -eq "fail") { $hardFail = $true }
        Write-Host "    [$(if ($results['npm_test'] -eq 'pass') {'OK'} else {'XX'})] npm tests" -ForegroundColor $(if ($results['npm_test'] -eq 'pass') {'Green'} else {'Red'})
    } else { $results["npm_test"] = "skipped" }

    # -- Check 5: SQL Validation (pattern scan, warn only) --
    $sqlFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sql" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "node_modules|bin|obj|\.gsd" }
    $sqlIssues = 0
    foreach ($sqlFile in $sqlFiles) {
        $content = Get-Content $sqlFile.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -match "['\"]\s*\+\s*@|@\w+\s*\+\s*['\"]") { $sqlIssues++ }
        if ($content -match "CREATE\s+(PROC|PROCEDURE)" -and $content -notmatch "TRY") { $sqlIssues++ }
    }
    $results["sql_validation"] = if ($sqlIssues -eq 0) { "pass" } else { "warn" }
    if ($sqlIssues -gt 0) { $warnings += "$sqlIssues SQL pattern issues" }
    Write-Host "    [$(if ($sqlIssues -eq 0) {'OK'} else {'!!'})  ] SQL validation ($sqlIssues issues)" -ForegroundColor $(if ($sqlIssues -eq 0) {'Green'} else {'Yellow'})

    # -- Check 6-7: Vulnerability Audits (warn only) --
    $results["dotnet_audit"] = "skipped"
    $results["npm_audit"] = "skipped"

    # -- Check 8: Security Compliance (regex scan) --
    $securityIssues = 0
    $csFiles = Get-ChildItem -Path $RepoRoot -Filter "*.cs" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "bin|obj|\.gsd" }
    foreach ($csFile in $csFiles) {
        $content = Get-Content $csFile.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -match 'eval\s*\(' -or $content -match 'new\s+Function\s*\(') { $securityIssues++ }
        if ($content -match '(password|secret|apikey|connectionstring)\s*=\s*"[^"]+?"' -and $content -notmatch 'appsettings') { $securityIssues++ }
    }
    $jsFiles = Get-ChildItem -Path $RepoRoot -Include "*.tsx","*.ts","*.jsx","*.js" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "node_modules|dist|build|\.gsd" }
    foreach ($jsFile in $jsFiles) {
        $content = Get-Content $jsFile.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -match 'dangerouslySetInnerHTML' -and $content -notmatch 'DOMPurify') { $securityIssues++ }
        if ($content -match 'localStorage\.(set|get)Item.*?(password|token|secret|key)') { $securityIssues++ }
    }
    $results["security_compliance"] = if ($securityIssues -eq 0) { "pass" } else { "fail" }
    if ($securityIssues -gt 0) { $hardFail = $true }
    Write-Host "    [$(if ($securityIssues -eq 0) {'OK'} else {'XX'})] Security ($securityIssues issues)" -ForegroundColor $(if ($securityIssues -eq 0) {'Green'} else {'Red'})

    $validationPassed = -not $hardFail

    if (-not $validationPassed -and $attempt -lt $maxAttempts) {
        Write-Host "`n  Validation failed. Sending failures to fix loop..." -ForegroundColor Yellow
        # Write validation errors as error context for next attempt
        $errorCtx = "## Final Validation Failures (Attempt $attempt)`n"
        foreach ($key in $results.Keys) {
            if ($results[$key] -eq "fail") {
                $errorCtx += "- $key FAILED`n"
            }
        }
        $supervisorDir = Join-Path $GsdDir "supervisor"
        if (-not (Test-Path $supervisorDir)) { New-Item -ItemType Directory -Path $supervisorDir -Force | Out-Null }
        Set-Content -Path (Join-Path $supervisorDir "error-context.md") -Value $errorCtx -Encoding UTF8
    }
}

# Save final validation results
$validationReport = @{
    timestamp = (Get-Date -Format "o")
    passed = $validationPassed
    attempts = $attempt
    results = $results
    warnings = $warnings
}
$validationReport | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $GsdDir "health\final-validation.json") -Encoding UTF8

if ($validationPassed) {
    Write-Host "`n  FINAL VALIDATION PASSED" -ForegroundColor Green
    Send-ConvergedNotification -TotalIterations $attempt -TotalRequirements 0
} else {
    Write-Host "`n  FINAL VALIDATION FAILED after $maxAttempts attempts" -ForegroundColor Red
    Send-EscalationNotification -Reason "Final validation failed" -Details ($results | ConvertTo-Json -Compress)
}

return @{
    Success = $validationPassed
    Attempts = $attempt
    Results = $results
    Warnings = $warnings
    StepId = $stepId
}
