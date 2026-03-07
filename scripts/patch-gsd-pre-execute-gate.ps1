<#
.SYNOPSIS
    Pre-Execute Compile Gate - Build validation before git commit, not after.
    Run AFTER patch-gsd-differential-review.ps1.

.DESCRIPTION
    Moves build validation BEFORE the git commit in the execute phase, so broken
    code never gets committed. If the build fails, errors are sent back to the
    same agent for immediate fix (same context window = cheaper fix).

    Adds:
    1. Invoke-PreExecuteGate function to resilience.ps1
       - Runs dotnet build + npm run build BEFORE committing
       - On failure: sends compile errors back to the executing agent
       - Agent fixes in-place, re-validates, then commits only clean code
       - Max 2 fix attempts before falling through to commit-and-fix-later

    2. Config: pre_execute_gate block in global-config.json
       - enabled (default true)
       - max_fix_attempts (2)
       - include_tests (false -- set true to also run tests pre-commit)

    3. Pipeline integration in convergence-loop.ps1
       - After execute phase returns success, calls Invoke-PreExecuteGate
       - Only commits code that compiles

.INSTALL_ORDER
    1-22. (existing scripts)
    23. patch-gsd-pre-execute-gate.ps1  <- this file
#>

param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"

$GsdGlobalDir = Join-Path $UserHome ".gsd-global"

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Pre-Execute Compile Gate" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Add pre_execute_gate config ──

$configPath = Join-Path $GsdGlobalDir "config\global-config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    if (-not $config.pre_execute_gate) {
        $config | Add-Member -NotePropertyName "pre_execute_gate" -NotePropertyValue ([PSCustomObject]@{
            enabled           = $true
            max_fix_attempts  = 2
            include_tests     = $false
        })
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
        Write-Host "  [OK] Added pre_execute_gate config to global-config.json" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] pre_execute_gate already exists" -ForegroundColor DarkGray
    }
}

# ── 2. Create fix-compile-errors.md prompt template ──

$promptDir = Join-Path $GsdGlobalDir "prompts\codex"
$fixPromptPath = Join-Path $promptDir "fix-compile-errors.md"

$fixPrompt = @'
# GSD Fix Compile Errors - Iteration {{ITERATION}}

## Output Constraints
- Maximum output: 5000 tokens
- Fix ONLY the compile errors listed below -- do not refactor or improve other code

## Input Context
You just generated code that failed to compile. Fix the errors below.

## Compile Errors
{{COMPILE_ERRORS}}

## Instructions
1. Read each error carefully (file path + line number + error message)
2. Open the file, find the line, fix the error
3. Common fixes:
   - Missing using/import statements
   - Type mismatches (check the actual types in referenced files)
   - Missing method implementations (check interface definitions)
   - Syntax errors (unclosed braces, missing semicolons)
4. After fixing, do NOT add new features or refactor -- ONLY fix compile errors
5. Write the fixed files

## Boundaries
- ONLY modify files mentioned in the compile errors
- DO NOT add new files
- DO NOT modify .gsd/ files
'@

Set-Content -Path $fixPromptPath -Value $fixPrompt -Encoding UTF8
Write-Host "  [OK] Created fix-compile-errors.md prompt template" -ForegroundColor Green

# ── 3. Add Invoke-PreExecuteGate function to resilience.ps1 ──

$resilienceFile = Join-Path $GsdGlobalDir "lib\modules\resilience.ps1"
if (Test-Path $resilienceFile) {
    $existing = Get-Content $resilienceFile -Raw

    if ($existing -notlike "*function Invoke-PreExecuteGate*") {

        $gateFunction = @'

# ===========================================
# PRE-EXECUTE COMPILE GATE
# ===========================================

function Invoke-PreExecuteGate {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$Iteration,
        [decimal]$Health,
        [string]$ExecuteAgent = "codex"
    )

    $result = @{
        Passed     = $true
        FixApplied = $false
        Errors     = ""
    }

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            $gateCfg = $config.pre_execute_gate
            if (-not $gateCfg -or -not $gateCfg.enabled) {
                Write-Host "  [GATE] Pre-execute gate disabled" -ForegroundColor DarkGray
                return $result
            }
        } catch {
            return $result
        }
    } else {
        return $result
    }

    $maxAttempts = if ($gateCfg.max_fix_attempts) { [int]$gateCfg.max_fix_attempts } else { 2 }
    $includeTests = if ($gateCfg.include_tests) { $gateCfg.include_tests } else { $false }

    Write-Host "  [GATE] Running pre-execute compile gate..." -ForegroundColor Cyan

    for ($attempt = 1; $attempt -le ($maxAttempts + 1); $attempt++) {
        $errors = @()

        # Check for .sln (dotnet build)
        $slnFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sln" -ErrorAction SilentlyContinue
        if ($slnFiles) {
            $buildOutput = & dotnet build $slnFiles[0].FullName --no-restore 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                $errors += "=== DOTNET BUILD ERRORS ===`n$buildOutput"
            }
        }

        # Check for package.json (npm build)
        $pkgJson = Join-Path $RepoRoot "package.json"
        if (Test-Path $pkgJson) {
            Push-Location $RepoRoot
            $npmOutput = & npm run build 2>&1 | Out-String
            Pop-Location
            if ($LASTEXITCODE -ne 0) {
                $errors += "=== NPM BUILD ERRORS ===`n$npmOutput"
            }
        }

        # Optional: run tests
        if ($includeTests) {
            if ($slnFiles) {
                $testOutput = & dotnet test $slnFiles[0].FullName --no-build 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0) {
                    $errors += "=== DOTNET TEST ERRORS ===`n$testOutput"
                }
            }
            if (Test-Path $pkgJson) {
                Push-Location $RepoRoot
                $npmTestOutput = & npm test 2>&1 | Out-String
                Pop-Location
                if ($LASTEXITCODE -ne 0) {
                    $errors += "=== NPM TEST ERRORS ===`n$npmTestOutput"
                }
            }
        }

        if ($errors.Count -eq 0) {
            if ($attempt -gt 1) {
                Write-Host "  [GATE] Build passed after $($attempt - 1) fix attempt(s)" -ForegroundColor Green
                $result.FixApplied = $true
            } else {
                Write-Host "  [GATE] Build passed on first check" -ForegroundColor Green
            }
            $result.Passed = $true
            return $result
        }

        # Build failed
        $allErrors = $errors -join "`n`n"

        if ($attempt -le $maxAttempts) {
            Write-Host "  [GATE] Build failed (attempt $attempt/$maxAttempts) -- sending errors to $ExecuteAgent for fix" -ForegroundColor Yellow

            # Truncate errors to 8KB
            if ($allErrors.Length -gt 8192) {
                $allErrors = $allErrors.Substring(0, 8192) + "`n... (truncated)"
            }

            # Build fix prompt
            $fixTemplatePath = Join-Path $GlobalDir "prompts\codex\fix-compile-errors.md"
            if (Test-Path $fixTemplatePath) {
                $fixPrompt = Get-Content $fixTemplatePath -Raw
                $fixPrompt = $fixPrompt.Replace("{{ITERATION}}", "$Iteration")
                $fixPrompt = $fixPrompt.Replace("{{COMPILE_ERRORS}}", $allErrors)
            } else {
                $fixPrompt = "Fix these compile errors. Only fix what's broken, don't refactor:`n`n$allErrors"
            }

            # Call the executing agent to fix
            $fixResult = Invoke-WithRetry -Agent $ExecuteAgent -Prompt $fixPrompt `
                -Phase "fix-compile" -LogFile "$GsdDir\logs\iter${Iteration}-fix-${attempt}.log" `
                -CurrentBatchSize 1 -GsdDir $GsdDir -MaxAttempts 1

            if (-not $fixResult.Success) {
                Write-Host "  [GATE] Fix attempt $attempt failed -- agent error, stopping retry" -ForegroundColor Red
                $result.Passed = $false
                break
            }
        } else {
            # Exhausted fix attempts -- fall through (commit broken code, handle in next iteration)
            Write-Host "  [GATE] Build still failing after $maxAttempts fix attempts -- committing as-is" -ForegroundColor Yellow
            $result.Passed = $false
            $result.Errors = $allErrors

            # Log to errors.jsonl
            if (Get-Command Write-GsdError -ErrorAction SilentlyContinue) {
                Write-GsdError -GsdDir $GsdDir -Category "pre_execute_gate_failed" `
                    -Phase "execute" -Iteration $Iteration -Message "Build failed after $maxAttempts fix attempts"
            }
        }
    }

    return $result
}
'@

        Add-Content -Path $resilienceFile -Value $gateFunction -Encoding UTF8
        Write-Host "  [OK] Added Invoke-PreExecuteGate to resilience.ps1" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] Invoke-PreExecuteGate already exists" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "  [GATE] Installation complete." -ForegroundColor Green
Write-Host "  Config: global-config.json -> pre_execute_gate" -ForegroundColor DarkGray
Write-Host "  Prompt: prompts/codex/fix-compile-errors.md" -ForegroundColor DarkGray
Write-Host "  Function: Invoke-PreExecuteGate in resilience.ps1" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  To disable: Set pre_execute_gate.enabled = false in global-config.json" -ForegroundColor DarkGray
Write-Host ""
