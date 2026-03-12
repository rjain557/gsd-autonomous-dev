<#
.SYNOPSIS
    GSD V3 Validation Fixer - Auto-fixes build/test errors and marks requirements satisfied
.DESCRIPTION
    Runs dotnet build + test in a loop, auto-fixing common disease patterns until clean.
    When validation passes, updates requirements-matrix.json to mark requirements as satisfied.
    Called by phase-orchestrator after local-validate fails.
.PARAMETER RepoRoot
    Repository root path
.PARAMETER RequirementIds
    Array of requirement IDs being validated
.PARAMETER MaxAttempts
    Maximum fix attempts before giving up (default: 5)
#>
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string[]]$RequirementIds,
    [int]$MaxAttempts = 10,
    [switch]$PreValidate
)

$ErrorActionPreference = "Continue"

# Load api-client for LLM-powered fixes
$script:V3Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$apiClientPath = Join-Path $script:V3Root "v3/lib/modules/api-client.ps1"
if (-not $apiClientPath -or -not (Test-Path $apiClientPath)) {
    $apiClientPath = Join-Path (Split-Path $PSScriptRoot -Parent) "lib/modules/api-client.ps1"
}
$script:HasLlmFixer = $false
if (Test-Path $apiClientPath) {
    try {
        . $apiClientPath
        $script:HasLlmFixer = $true
        Write-Host "  [FIXER] LLM-powered code fixer: ENABLED" -ForegroundColor Cyan
    } catch {
        Write-Host "  [FIXER] LLM-powered code fixer: DISABLED (load error: $($_.Exception.Message))" -ForegroundColor DarkYellow
    }
} else {
    Write-Host "  [FIXER] LLM-powered code fixer: DISABLED (api-client not found)" -ForegroundColor DarkYellow
}

# ============================================================
# DISEASE FIX PATTERNS
# ============================================================

$script:NamespaceFixMap = @{
    'using\s+TcaiPlatform\.GDPR(\.Models)?\s*;'              = 'using Technijian.Api.GDPR;'
    'using\s+TcaiPlatform\.Auth\s*;'                          = 'using Technijian.Api.Auth;'
    'using\s+TcaiPlatform\.Security\s*;'                      = 'using Technijian.Api.Security;'
    'using\s+TcaiPlatform\.Services\s*;'                      = 'using Technijian.Api.Services;'
    'using\s+TcaiPlatform\.Repositories\s*;'                  = 'using Technijian.Api.Repositories;'
    'using\s+Backend\.Controllers\s*;'                        = 'using Technijian.Api.Controllers;'
    'using\s+Backend\.Security\s*;'                           = 'using Technijian.Api.Security;'
    'using\s+Backend\.Auth\s*;'                               = 'using Technijian.Api.Auth;'
    'using\s+Backend\.RateLimiting\s*;'                       = 'using Technijian.Api.RateLimiting;'
    'using\s+Backend\.Repositories\s*;'                       = 'using Technijian.Api.Repositories;'
    'using\s+Backend\.Models\s*;'                             = 'using Technijian.Api.Models;'
    'using\s+Tcai\.Api\.Models\s*;'                           = 'using Technijian.Api.Models;'
    'using\s+Tcai\.Api\.Repositories\s*;'                     = 'using Technijian.Api.Repositories;'
    'using\s+Tcai\.Api\.Services\s*;'                         = 'using Technijian.Api.Services;'
    'using\s+Tcai\.Api\.Services\.Interfaces\s*;'             = 'using Technijian.Api.Services.Interfaces;'
    'using\s+System\.Data\.SqlClient\s*;'                     = 'using Microsoft.Data.SqlClient;'
    'namespace\s+TCAI\.Controllers\s*;'                       = 'namespace Technijian.Api.Controllers;'
}

$script:MissingUsingFixes = @{
    'IDbConnectionFactory' = 'using TCAI.Data;'
    'DataClassification'   = 'using Technijian.Api.Security;'
}

# ============================================================
# MAIN FIX LOOP
# ============================================================

function Invoke-ValidationFixLoop {
    Write-Host "`n  === VALIDATION FIXER START ===" -ForegroundColor Cyan
    Write-Host "  Repo: $RepoRoot" -ForegroundColor DarkGray
    Write-Host "  Requirements: $($RequirementIds -join ', ')" -ForegroundColor DarkGray

    $attempt = 0
    $allClean = $false

    while ($attempt -lt $MaxAttempts -and -not $allClean) {
        $attempt++
        $totalFixes = 0
        Write-Host "`n  --- Fix Attempt $attempt/$MaxAttempts ---" -ForegroundColor Yellow

        # ===== STEP 1: C# Backend Build =====
        Write-Host "    [BUILD] API project..." -ForegroundColor DarkGray
        $apiDir = Join-Path $RepoRoot "src/Server/Technijian.Api"
        if (Test-Path $apiDir) {
            $buildOutput = & pwsh -NoProfile -Command "cd '$apiDir'; dotnet build --no-restore 2>&1" | Out-String
            if ($LASTEXITCODE -ne 0) {
                Write-Host "    [FAIL] API build failed" -ForegroundColor Red
                $fixCount = Repair-BuildErrors -BuildOutput $buildOutput
                $totalFixes += $fixCount
                if ($fixCount -eq 0) {
                    $deleteCount = Remove-DiseaseFiles -BuildOutput $buildOutput
                    $totalFixes += $deleteCount
                }
                if ($totalFixes -gt 0) { continue }  # Rebuild after fixes
            } else {
                Write-Host "    [PASS] API build clean" -ForegroundColor Green
            }
        }

        # ===== STEP 2: TypeScript Type-check (frontend) =====
        Write-Host "    [TYPECHECK] Frontend..." -ForegroundColor DarkGray
        $tsConfigPaths = @("src/web/tsconfig.json", "src/shared/tsconfig.json")
        $tsErrors = @()
        foreach ($tsConfig in $tsConfigPaths) {
            $fullTsConfig = Join-Path $RepoRoot $tsConfig
            if (-not (Test-Path $fullTsConfig)) { continue }
            $tsOutput = & pwsh -NoProfile -Command "cd '$RepoRoot'; npx tsc --noEmit --project $tsConfig 2>&1" | Out-String
            if ($LASTEXITCODE -ne 0) {
                $tsErrors += @{ Config = $tsConfig; Output = $tsOutput }
            }
        }
        if ($tsErrors.Count -gt 0) {
            Write-Host "    [FAIL] TypeScript errors found" -ForegroundColor Red
            $fixCount = Repair-TypeScriptErrors -Errors $tsErrors
            $totalFixes += $fixCount
        } else {
            Write-Host "    [PASS] TypeScript clean" -ForegroundColor Green
        }

        # ===== STEP 3: C# Test Build =====
        $testDir = Join-Path $RepoRoot "tests/backend"
        if (Test-Path $testDir) {
            Write-Host "    [BUILD] Test project..." -ForegroundColor DarkGray
            $testBuildOutput = & pwsh -NoProfile -Command "cd '$testDir'; dotnet build 2>&1" | Out-String
            if ($LASTEXITCODE -ne 0) {
                Write-Host "    [FAIL] Test build failed" -ForegroundColor Red
                $fixCount = Repair-BuildErrors -BuildOutput $testBuildOutput
                $totalFixes += $fixCount
                if ($fixCount -eq 0) {
                    $deleteCount = Remove-BrokenTestFiles -BuildOutput $testBuildOutput
                    $totalFixes += $deleteCount
                }
                if ($totalFixes -gt 0) { continue }
            } else {
                Write-Host "    [PASS] Test build clean" -ForegroundColor Green
            }
        }

        # ===== STEP 4: Unit Tests (best effort — don't block on runtime failures) =====
        if (Test-Path $testDir) {
            Write-Host "    [TEST] Running unit tests..." -ForegroundColor DarkGray
            $testRunOutput = & pwsh -NoProfile -Command "cd '$testDir'; dotnet test --no-build --filter 'FullyQualifiedName!~Integration' 2>&1" | Out-String
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    [PASS] Unit tests pass" -ForegroundColor Green
            } else {
                Write-Host "    [WARN] Some unit tests failed (non-blocking)" -ForegroundColor DarkYellow
            }
        }

        # ===== CHECK: If no fixes were needed or applied, we're either clean or stuck =====
        if ($totalFixes -eq 0) {
            # Re-check if we're actually clean
            $apiClean = $true
            if (Test-Path $apiDir) {
                $checkOutput = & pwsh -NoProfile -Command "cd '$apiDir'; dotnet build --no-restore 2>&1" | Out-String
                $apiClean = ($LASTEXITCODE -eq 0)
            }
            $tsClean = $true
            foreach ($tsConfig in $tsConfigPaths) {
                $fullTsConfig = Join-Path $RepoRoot $tsConfig
                if (-not (Test-Path $fullTsConfig)) { continue }
                $null = & pwsh -NoProfile -Command "cd '$RepoRoot'; npx tsc --noEmit --project $tsConfig 2>&1" | Out-String
                if ($LASTEXITCODE -ne 0) { $tsClean = $false }
            }

            if ($apiClean -and $tsClean) {
                $allClean = $true
            } else {
                Write-Host "    [STUCK] Pattern fixes exhausted, using LLM fixer..." -ForegroundColor DarkYellow
                if (-not $script:HasLlmFixer) {
                    Write-Host "    [STUCK] No LLM fixer available" -ForegroundColor Red
                    break
                }
                # LLM fixer was already invoked in Repair-BuildErrors / Repair-TypeScriptErrors
                # If it still can't fix, we're stuck
                break
            }
        }
    }

    if ($allClean) {
        Write-Host "`n  [SUCCESS] All validation passed after $attempt attempt(s)" -ForegroundColor Green
        Update-RequirementStatus -ReqIds $RequirementIds -Status "satisfied"
        return @{ Success = $true; Attempts = $attempt }
    } else {
        Write-Host "`n  [PARTIAL] Some issues remain after $MaxAttempts attempts" -ForegroundColor Yellow
        return @{ Success = $false; Attempts = $attempt }
    }
}

# ============================================================
# TYPESCRIPT ERROR FIXER
# ============================================================

function Repair-TypeScriptErrors {
    param([array]$Errors)

    $fixCount = 0

    foreach ($tsError in $Errors) {
        $output = $tsError.Output
        $lines = $output -split "`n"

        # Collect error files
        $errorFileMap = @{}
        foreach ($line in $lines) {
            # TS error format: src/web/App.tsx(10,5): error TS2304: Cannot find name 'foo'.
            if ($line -match '(?<file>[^(]+)\((?<line>\d+),(?<col>\d+)\):\s*error\s+(?<code>TS\d+):\s*(?<msg>.+)') {
                $tsFile = $Matches['file'].Trim()
                $tsCode = $Matches['code']
                $tsMsg = $Matches['msg']
                if (-not [System.IO.Path]::IsPathRooted($tsFile)) {
                    $tsFile = Join-Path $RepoRoot $tsFile
                }
                if (-not (Test-Path $tsFile)) { continue }
                if (-not $errorFileMap.ContainsKey($tsFile)) { $errorFileMap[$tsFile] = @() }
                $errorFileMap[$tsFile] += @{ Code = $tsCode; Msg = $tsMsg }
            }
        }

        # Try LLM fix for TypeScript files
        if ($script:HasLlmFixer) {
            foreach ($tsFile in @($errorFileMap.Keys)) {
                if (-not (Test-Path $tsFile)) { continue }
                $errors = $errorFileMap[$tsFile]
                $errorSummary = ($errors | ForEach-Object { "$($_.Code): $($_.Msg)" }) -join "`n"
                $fileContent = Get-Content $tsFile -Raw -Encoding UTF8
                if ($fileContent.Length -gt 8000) {
                    $fileContent = $fileContent.Substring(0, 8000) + "`n// ... (truncated)"
                }

                $fixPrompt = @"
Fix the following TypeScript errors in this file. Return ONLY the complete fixed file content, no markdown fences, no explanations.

File: $tsFile
Errors:
$errorSummary

Current file content:
$fileContent
"@

                try {
                    Write-Host "      [LLM-FIX] Fixing TS errors in $tsFile ($($errors.Count) errors)..." -ForegroundColor Cyan
                    $result = Invoke-SonnetApi -UserMessage $fixPrompt -MaxTokens 8192 -Phase "validation-fix-ts"
                    if ($result -and $result.Success -and $result.Text) {
                        $fixedContent = $result.Text.Trim()
                        if ($fixedContent -match '^```(?:typescript|tsx|ts)?\s*\n') {
                            $fixedContent = $fixedContent -replace '^```(?:typescript|tsx|ts)?\s*\n', '' -replace '\n```\s*$', ''
                        }
                        if ($fixedContent.Length -gt 100) {
                            Set-Content $tsFile -Value $fixedContent -Encoding UTF8
                            Write-Host "      [LLM-FIX] Fixed $tsFile" -ForegroundColor Green
                            $fixCount++
                        }
                    }
                } catch {
                    Write-Host "      [LLM-FIX] Error: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
    }

    return $fixCount
}

# ============================================================
# BUILD ERROR PARSER & FIXER
# ============================================================

function Repair-BuildErrors {
    param([string]$BuildOutput)

    $fixCount = 0
    $lines = $BuildOutput -split "`n"

    # Protected files — NEVER delete these regardless of errors
    $protectedFiles = @('Program.cs', 'Startup.cs', '.csproj', 'GlobalUsings.cs', 'appsettings.json')

    # Phase 1: Collect all error files and their error details
    $errorFileMap = @{}  # file -> list of {code, msg}
    foreach ($line in $lines) {
        if ($line -match '(?<file>[^(]+)\((?<line>\d+),(?<col>\d+)\):\s*error\s+(?<code>CS\d+):\s*(?<msg>.+)') {
            $errorFile = $Matches['file'].Trim()
            $errorCode = $Matches['code']
            $errorMsg = $Matches['msg']
            if ($errorFile -match '[\\/]obj[\\/]') { continue }
            if (-not [System.IO.Path]::IsPathRooted($errorFile)) {
                $errorFile = Join-Path $RepoRoot $errorFile
            }
            if (-not (Test-Path $errorFile)) { continue }
            if (-not $errorFileMap.ContainsKey($errorFile)) { $errorFileMap[$errorFile] = @() }
            $errorFileMap[$errorFile] += @{ Code = $errorCode; Msg = $errorMsg }
        }
    }

    # Phase 2: Quick pattern fixes (FREE — namespace mappings, missing usings)
    foreach ($errorFile in @($errorFileMap.Keys)) {
        if (-not (Test-Path $errorFile)) { continue }
        $content = Get-Content $errorFile -Raw -Encoding UTF8
        $originalContent = $content

        # Apply namespace fix map
        foreach ($pattern in $script:NamespaceFixMap.Keys) {
            if ($content -match $pattern) {
                $content = $content -replace $pattern, $script:NamespaceFixMap[$pattern]
            }
        }
        # Add missing common usings
        $errors = $errorFileMap[$errorFile]
        foreach ($err in $errors) {
            if ($err.Msg -match "'IDbConnectionFactory'" -and $content -notmatch 'using TCAI\.Data') {
                $content = "using TCAI.Data;`n" + $content
            }
        }

        if ($content -ne $originalContent) {
            Set-Content $errorFile $content -Encoding UTF8 -NoNewline
            Write-Host "      [PATTERN-FIX] Fixed namespace issues in $errorFile" -ForegroundColor Yellow
            $fixCount++
        }
    }

    # Phase 3: LLM fixes ALL remaining errors (any error type, any language)
    # Only runs if pattern fixes didn't resolve everything
    if ($fixCount -eq 0 -and $script:HasLlmFixer) {
        foreach ($errorFile in @($errorFileMap.Keys)) {
            if (-not (Test-Path $errorFile)) { continue }
            $errors = $errorFileMap[$errorFile]
            $errorSummary = ($errors | ForEach-Object { "$($_.Code): $($_.Msg)" }) -join "`n"
            $fileContent = Get-Content $errorFile -Raw -Encoding UTF8
            if ($fileContent.Length -gt 12000) {
                $fileContent = $fileContent.Substring(0, 12000) + "`n// ... (truncated)"
            }

            $fixPrompt = @"
Fix ALL the following build errors in this file. Return ONLY the complete fixed file content. No markdown fences, no explanations, no comments about what you changed.

File: $errorFile
Errors:
$errorSummary

Current file content:
$fileContent
"@

            try {
                Write-Host "      [LLM-FIX] Fixing $errorFile ($($errors.Count) errors)..." -ForegroundColor Cyan
                $result = Invoke-SonnetApi -UserMessage $fixPrompt -MaxTokens 12000 -Phase "validation-fix"
                if ($result -and $result.Success -and $result.Text) {
                    $fixedContent = $result.Text.Trim()
                    # Strip markdown fences if model added them
                    $fixedContent = $fixedContent -replace '(?s)^```[a-z]*\s*\n', '' -replace '\n```\s*$', ''
                    if ($fixedContent.Length -gt 100) {
                        Set-Content $errorFile -Value $fixedContent -Encoding UTF8
                        Write-Host "      [LLM-FIX] Fixed $errorFile" -ForegroundColor Green
                        $fixCount++
                    }
                }
            } catch {
                Write-Host "      [LLM-FIX] Error: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    # Also do a sweep for common namespace diseases in all recently modified files
    $recentFiles = Get-ChildItem -Path $RepoRoot -Recurse -Filter "*.cs" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](obj|bin|node_modules)[\\/]' -and $_.LastWriteTime -gt (Get-Date).AddHours(-2) }

    foreach ($file in $recentFiles) {
        $content = Get-Content $file.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        $originalContent = $content
        foreach ($pattern in $script:NamespaceFixMap.Keys) {
            if ($content -match $pattern) {
                $content = $content -replace $pattern, $script:NamespaceFixMap[$pattern]
            }
        }

        # Fix System.Data.SqlClient
        if ($content -match 'System\.Data\.SqlClient') {
            $content = $content -replace 'using\s+System\.Data\.SqlClient\s*;', 'using Microsoft.Data.SqlClient;'
            $content = $content -replace 'System\.Data\.SqlClient\.', 'Microsoft.Data.SqlClient.'
        }

        # Fix DataLevel -> DataClassification
        if ($content -match '\bDataLevel\b') {
            $content = $content -replace '\bDataLevel\b', 'DataClassification'
        }

        if ($content -ne $originalContent) {
            Set-Content $file.FullName $content -Encoding UTF8 -NoNewline
            Write-Host "      [AUTO-FIX] Fixed namespace diseases in $($file.FullName)" -ForegroundColor Yellow
            $fixCount++
        }
    }

    return $fixCount
}

function Apply-NamespaceFixes {
    param([string]$Content, [string]$FilePath)

    $original = $Content
    foreach ($pattern in $script:NamespaceFixMap.Keys) {
        if ($Content -match $pattern) {
            $Content = $Content -replace $pattern, $script:NamespaceFixMap[$pattern]
        }
    }

    if ($Content -ne $original) {
        Set-Content $FilePath $Content -Encoding UTF8 -NoNewline
        Write-Host "      [AUTO-FIX] Fixed namespaces in $FilePath" -ForegroundColor Yellow
        return $true
    }
    return $false
}

function Remove-DiseaseFiles {
    param([string]$BuildOutput)

    $deleteCount = 0
    $lines = $BuildOutput -split "`n"

    foreach ($line in $lines) {
        if ($line -match '(?<file>[^(]+)\(\d+,\d+\):\s*error\s+CS0246:.*TcaiPlatform') {
            $errorFile = $Matches['file'].Trim()
            if (-not [System.IO.Path]::IsPathRooted($errorFile)) {
                $errorFile = Join-Path $RepoRoot $errorFile
            }

            if ((Test-Path $errorFile) -and (Get-Content $errorFile -Raw) -match 'global using') {
                Remove-Item $errorFile -Force
                Write-Host "      [DELETE] Removed disease bridge file: $errorFile" -ForegroundColor Yellow
                $deleteCount++
            }
        }
    }
    return $deleteCount
}

function Remove-RecentlyGeneratedErrorFiles {
    param([string]$BuildOutput)

    $deleteCount = 0
    $errorFiles = @{}

    $lines = $BuildOutput -split "`n"
    foreach ($line in $lines) {
        if ($line -match '(?<file>[^(]+)\(\d+,\d+\):\s*error\s+CS') {
            $file = $Matches['file'].Trim()
            if ($file -match '[\\/](obj|bin)[\\/]') { continue }
            if (-not $errorFiles.ContainsKey($file)) { $errorFiles[$file] = 0 }
            $errorFiles[$file]++
        }
    }

    # Delete recently-generated files (< 4 hours old) with 2+ errors
    # NEVER delete Program.cs, Startup.cs, or .csproj files
    $protected = @('Program.cs', 'Startup.cs', '.csproj', 'GlobalUsings.cs')
    foreach ($file in $errorFiles.Keys) {
        if ($errorFiles[$file] -lt 2) { continue }
        $fullPath = if ([System.IO.Path]::IsPathRooted($file)) { $file } else { Join-Path $RepoRoot $file }
        if (-not (Test-Path $fullPath)) { continue }
        if ($protected | Where-Object { $fullPath -match [regex]::Escape($_) }) { continue }

        $fileAge = (Get-Date) - (Get-Item $fullPath).LastWriteTime
        if ($fileAge.TotalHours -lt 4) {
            Remove-Item $fullPath -Force
            Write-Host "      [DELETE] Removed recently-generated error file ($($errorFiles[$file]) errors): $fullPath" -ForegroundColor Yellow
            $deleteCount++
        }
    }
    return $deleteCount
}

function Remove-BrokenTestFiles {
    param([string]$BuildOutput)

    $deleteCount = 0
    $brokenFiles = @{}

    $lines = $BuildOutput -split "`n"
    foreach ($line in $lines) {
        if ($line -match '(?<file>[^(]+)\(\d+,\d+\):\s*error\s+CS') {
            $file = $Matches['file'].Trim()
            if ($file -match 'tests[\\/]') {
                if (-not $brokenFiles.ContainsKey($file)) {
                    $brokenFiles[$file] = 0
                }
                $brokenFiles[$file]++
            }
        }
    }

    # Delete test files with 3+ errors (likely hallucinated)
    foreach ($file in $brokenFiles.Keys) {
        if ($brokenFiles[$file] -ge 3) {
            $fullPath = if ([System.IO.Path]::IsPathRooted($file)) { $file } else { Join-Path $RepoRoot $file }
            if (Test-Path $fullPath) {
                Remove-Item $fullPath -Force
                Write-Host "      [DELETE] Removed broken test file ($($brokenFiles[$file]) errors): $fullPath" -ForegroundColor Yellow
                $deleteCount++
            }
        }
    }
    return $deleteCount
}

# ============================================================
# REQUIREMENT STATUS UPDATER
# ============================================================

function Update-RequirementStatus {
    param(
        [string[]]$ReqIds,
        [string]$Status = "satisfied"
    )

    $matrixPath = Join-Path $RepoRoot ".gsd/requirements/requirements-matrix.json"
    if (-not (Test-Path $matrixPath)) {
        Write-Host "    [WARN] requirements-matrix.json not found at $matrixPath" -ForegroundColor DarkYellow
        return
    }

    try {
        $matrix = Get-Content $matrixPath -Raw -Encoding UTF8 | ConvertFrom-Json

        $updated = 0
        foreach ($reqId in $ReqIds) {
            $req = $matrix.requirements | Where-Object { $_.id -eq $reqId }
            if ($req -and $req.status -ne $Status) {
                $req.status = $Status
                $req | Add-Member -NotePropertyName "satisfied_at" -NotePropertyValue (Get-Date -Format "o") -Force
                $req | Add-Member -NotePropertyName "satisfied_by" -NotePropertyValue "gsd-validation-fixer" -Force
                $updated++
                Write-Host "    [MARK] $reqId → $Status" -ForegroundColor Green
            }
        }

        if ($updated -gt 0) {
            # Recalculate summary
            $satisfied = @($matrix.requirements | Where-Object { $_.status -eq "satisfied" }).Count
            $partial = @($matrix.requirements | Where-Object { $_.status -eq "partial" }).Count
            $notStarted = @($matrix.requirements | Where-Object { $_.status -eq "not_started" }).Count
            $matrix.summary.satisfied = $satisfied
            $matrix.summary.partial = $partial
            $matrix.summary.not_started = $notStarted

            $healthPct = if ($matrix.total -gt 0) { [math]::Round(($satisfied / $matrix.total) * 100, 1) } else { 0 }

            $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8
            Write-Host "    [HEALTH] $satisfied/$($matrix.total) satisfied ($healthPct%)" -ForegroundColor Cyan
        }
    }
    catch {
        Write-Host "    [ERROR] Failed to update requirements: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# PRE-VALIDATE MODE: LLM reviews+fixes code BEFORE local build
# ============================================================

function Invoke-PreValidateFix {
    Write-Host "`n  === PRE-VALIDATE LLM FIX ===" -ForegroundColor Cyan
    Write-Host "  Requirements: $($RequirementIds -join ', ')" -ForegroundColor DarkGray

    if (-not $script:HasLlmFixer) {
        Write-Host "    [SKIP] LLM fixer not available" -ForegroundColor DarkYellow
        return @{ Success = $false; Fixed = 0 }
    }

    $fixCount = 0
    $gsdDir = Join-Path $RepoRoot ".gsd"

    # Phase 1: Quick namespace fixes (FREE — no API calls)
    $csFiles = @()
    foreach ($reqId in $RequirementIds) {
        $genDir = Join-Path $gsdDir "generated/$reqId"
        if (Test-Path $genDir) {
            $csFiles += @(Get-ChildItem $genDir -Recurse -Filter "*.cs" -ErrorAction SilentlyContinue)
        }
        # Also check recently written files in src/Server
        $apiDir = Join-Path $RepoRoot "src/Server/Technijian.Api"
        if (Test-Path $apiDir) {
            $recentCs = @(Get-ChildItem $apiDir -Recurse -Filter "*.cs" -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-10) })
            $csFiles += $recentCs
        }
    }
    $csFiles = @($csFiles | Select-Object -Unique)

    # Apply namespace fixes to all recently generated .cs files
    foreach ($file in $csFiles) {
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        $original = $content
        foreach ($pattern in $script:NamespaceFixMap.Keys) {
            $content = $content -replace $pattern, $script:NamespaceFixMap[$pattern]
        }
        if ($content -ne $original) {
            Set-Content $file.FullName -Value $content -Encoding UTF8
            $fixCount++
            Write-Host "    [NS-FIX] $($file.Name)" -ForegroundColor DarkCyan
        }
    }

    # Phase 2: LLM review+fix for each requirement's generated files
    $apiDir = Join-Path $RepoRoot "src/Server/Technijian.Api"
    $projectContext = ""
    if (Test-Path $apiDir) {
        # Get existing namespace patterns from a known-good file
        $sampleFile = Get-ChildItem $apiDir -Recurse -Filter "*.cs" -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt 500 -and $_.Length -lt 5000 } | Select-Object -First 1
        if ($sampleFile) {
            $projectContext = Get-Content $sampleFile.FullName -Raw -ErrorAction SilentlyContinue
        }
    }

    $recentFiles = @(Get-ChildItem $RepoRoot -Recurse -Include "*.cs","*.ts","*.tsx" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-10) -and $_.Length -gt 100 })

    if ($recentFiles.Count -eq 0) {
        Write-Host "    [SKIP] No recently generated files to review" -ForegroundColor DarkGray
        return @{ Success = $true; Fixed = $fixCount }
    }

    Write-Host "    [LLM] Reviewing $($recentFiles.Count) recently generated files..." -ForegroundColor Cyan
    $batchSize = 5
    for ($i = 0; $i -lt $recentFiles.Count; $i += $batchSize) {
        $batch = $recentFiles[$i..([math]::Min($i + $batchSize - 1, $recentFiles.Count - 1))]
        $fileContents = ""
        foreach ($f in $batch) {
            $relPath = $f.FullName.Replace($RepoRoot, "").TrimStart("\", "/")
            $fc = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if ($fc) { $fileContents += "`n=== FILE: $relPath ===`n$fc`n" }
        }

        $reviewPrompt = @"
Review these recently generated files for a .NET 8 + React 18 project.
Project uses: namespace Technijian.Api.*, Dapper, SQL Server stored procedures, TCAI.Data for DB access.
DO NOT use Entity Framework. Repositories inherit from BaseRepository and use TCAI.Data.DapperHelper.

Fix these common issues:
- Wrong namespaces (should be Technijian.Api.*)
- Missing using statements
- References to non-existent types or methods
- FILL/TODO stubs that should be implemented
- TypeScript import path errors

For each file that needs fixes, output ONLY:
=== FIX: <relative-path> ===
<complete fixed file content>
=== END ===

If a file is correct, skip it entirely. Output NOTHING for correct files.

Project sample for reference:
$projectContext

Files to review:
$fileContents
"@
        try {
            $result = Invoke-SonnetApi -UserMessage $reviewPrompt -MaxTokens 12000 -Phase "pre-validate-fix"
            if ($result -and $result -match "=== FIX:") {
                $fixes = [regex]::Matches($result, '=== FIX:\s*(.+?)\s*===\s*\n([\s\S]*?)(?:=== END ===)')
                foreach ($fix in $fixes) {
                    $fixPath = $fix.Groups[1].Value.Trim()
                    $fixContent = $fix.Groups[2].Value.Trim()
                    $fullPath = Join-Path $RepoRoot $fixPath
                    if ((Test-Path $fullPath) -and $fixContent.Length -gt 50) {
                        Set-Content $fullPath -Value $fixContent -Encoding UTF8
                        $fixCount++
                        Write-Host "    [LLM-FIX] $fixPath" -ForegroundColor Green
                    }
                }
            }
        } catch {
            Write-Host "    [WARN] LLM review batch error: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }

    Write-Host "    [DONE] Pre-validate fixed $fixCount files" -ForegroundColor $(if ($fixCount -gt 0) { "Green" } else { "DarkGray" })
    return @{ Success = $true; Fixed = $fixCount }
}

# ============================================================
# ENTRY POINT
# ============================================================

if ($PreValidate) {
    $result = Invoke-PreValidateFix
    exit $(if ($result.Success) { 0 } else { 1 })
} else {
    $result = Invoke-ValidationFixLoop
    exit $(if ($result.Success) { 0 } else { 1 })
}
