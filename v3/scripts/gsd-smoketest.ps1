<#
.SYNOPSIS
    GSD V3 Integration Smoke Test - Post-Code-Review Real-World Validation
.DESCRIPTION
    Runs AFTER code review completes to catch real-world integration issues that
    static code review misses. Uses Claude (Sonnet) to analyze code, configs, and
    database objects across 9 validation phases with auto-fix capability.

    Phases:
      1. Build Validation        - dotnet build + npm run build
      2. Database Validation     - Tables, SPs, columns, FKs, migrations
      3. API Smoke Test          - Health endpoint, status codes, CORS
      4. Frontend Route Validation - Route/component mapping, lazy loads
      5. Auth Flow Validation    - Middleware, guards, token refresh
      6. Module Completeness     - API+frontend+DB wiring per module
      7. Mock Data Detection     - Hardcoded data, TODOs, console.log
      8. RBAC Matrix             - Route -> role -> guard mapping
      9. Integration Gap Report  - Aggregated gap analysis

    Usage:
      pwsh -File gsd-smoketest.ps1 -RepoRoot "C:\repos\project"
      pwsh -File gsd-smoketest.ps1 -RepoRoot "C:\repos\project" -ConnectionString "Server=.;Database=MyDb;Trusted_Connection=true;"
      pwsh -File gsd-smoketest.ps1 -RepoRoot "C:\repos\project" -MaxCycles 5 -SkipBuild -SkipDbValidation
.PARAMETER RepoRoot
    Repository root path (mandatory)
.PARAMETER ConnectionString
    SQL Server connection string for live database validation (optional)
.PARAMETER MaxCycles
    Maximum smoke-test-fix cycles before stopping (default: 3)
.PARAMETER FixModel
    Model used for generating fixes: claude or codex (default: "claude")
.PARAMETER TestUsers
    JSON array of test user credentials for auth validation (optional)
    Example: '[{"username":"admin@test.com","password":"Test123!","roles":["Admin"]}]'
.PARAMETER AzureAdConfig
    JSON object with Azure AD configuration for auth flow validation (optional)
    Example: '{"tenantId":"...","clientId":"...","audience":"api://..."}'
.PARAMETER SkipBuild
    Skip the build validation phase
.PARAMETER SkipDbValidation
    Skip the database validation phase
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$ConnectionString = "",
    [int]$MaxCycles = 3,
    [ValidateSet("claude","codex")]
    [string]$FixModel = "claude",
    [string]$TestUsers = "",
    [string]$AzureAdConfig = "",
    [switch]$SkipBuild,
    [switch]$SkipDbValidation,
    [bool]$CostOptimize = $true
)

$ErrorActionPreference = "Continue"

# ============================================================
# SETUP: Resolve paths, load modules, load config
# ============================================================

$v3Dir = Split-Path $PSScriptRoot -Parent
$RepoRoot = (Resolve-Path $RepoRoot).Path
$GsdDir = Join-Path $RepoRoot ".gsd"

# Centralized logging
$repoName = Split-Path $RepoRoot -Leaf
$globalLogDir = Join-Path $env:USERPROFILE ".gsd-global/logs/$repoName"
if (-not (Test-Path $globalLogDir)) { New-Item -ItemType Directory -Path $globalLogDir -Force | Out-Null }

$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$logFile = Join-Path $globalLogDir "smoketest-$timestamp.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "$(Get-Date -Format 'HH:mm:ss') [$Level] $Message"
    Add-Content $logFile -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "OK"    { "Green" }
        "SKIP"  { "DarkGray" }
        "FIX"   { "Magenta" }
        "PHASE" { "Cyan" }
        default { "White" }
    }
    Write-Host "  $entry" -ForegroundColor $color
}

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  GSD V3 - Integration Smoke Test" -ForegroundColor Cyan
Write-Host "  Repo: $RepoRoot" -ForegroundColor DarkGray
Write-Host "  Fix model: $FixModel | MaxCycles: $MaxCycles" -ForegroundColor DarkGray
if ($ConnectionString) { Write-Host "  DB: Connected" -ForegroundColor DarkGray }
if ($SkipBuild) { Write-Host "  Build: SKIPPED" -ForegroundColor DarkGray }
if ($SkipDbValidation) { Write-Host "  DB Validation: SKIPPED" -ForegroundColor DarkGray }
Write-Host "  Cost Optimize: $(if ($CostOptimize) { 'ON (tiered models)' } else { 'OFF (all premium)' })" -ForegroundColor DarkGray
Write-Host "  Log: $logFile" -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor Cyan

# Load modules
$modulesDir = Join-Path $v3Dir "lib/modules"
$apiClientPath = Join-Path $modulesDir "api-client.ps1"
if (-not (Test-Path $apiClientPath)) {
    Write-Host "  [FATAL] api-client.ps1 not found at $apiClientPath" -ForegroundColor Red
    exit 1
}
. $apiClientPath

$costTrackerPath = Join-Path $modulesDir "cost-tracker.ps1"
if (Test-Path $costTrackerPath) { . $costTrackerPath }

$traceabilityUpdaterPath = Join-Path $modulesDir "traceability-updater.ps1"
if (Test-Path $traceabilityUpdaterPath) { . $traceabilityUpdaterPath }

$mockDataDetectorPath = Join-Path $modulesDir "mock-data-detector.ps1"
if (Test-Path $mockDataDetectorPath) { . $mockDataDetectorPath }

$routeRoleMatrixPath = Join-Path $modulesDir "route-role-matrix.ps1"
if (Test-Path $routeRoleMatrixPath) { . $routeRoleMatrixPath }

# Load config
$configPath = Join-Path $v3Dir "config/global-config.json"
if (Test-Path $configPath) {
    $Config = Get-Content $configPath -Raw | ConvertFrom-Json
}

# Initialize cost tracking
if (Get-Command Initialize-CostTracker -ErrorAction SilentlyContinue) {
    Initialize-CostTracker -Mode "smoke_test" -BudgetCap 10.0 -GsdDir $GsdDir
}

# Load model tiers config
$modelTiersPath = Join-Path $v3Dir "config/model-tiers.json"
$ModelTiers = $null
if (Test-Path $modelTiersPath) {
    $ModelTiers = Get-Content $modelTiersPath -Raw | ConvertFrom-Json
}

# Cost tracking by tier
$script:costByTier = @{ local = 0.0; cheap = 0.0; mid = 0.0; premium = 0.0 }
$script:tasksByTier = @{ local = 0; cheap = 0; mid = 0; premium = 0 }

# ============================================================
# TIERED MODEL SELECTION (cost optimization)
# ============================================================

function Select-ModelForTask {
    param(
        [ValidateSet("local","cheap","mid","premium")]
        [string]$Tier
    )
    switch ($Tier) {
        "local"   { return $null }  # No LLM needed
        "cheap"   {
            # Try DeepSeek first (cheapest), fallback to Kimi, then MiniMax
            $cheapModels = @("deepseek", "kimi", "minimax")
            foreach ($m in $cheapModels) {
                $keyVar = switch ($m) {
                    "deepseek" { "DEEPSEEK_API_KEY" }
                    "kimi"     { "KIMI_API_KEY" }
                    "minimax"  { "MINIMAX_API_KEY" }
                }
                if ([Environment]::GetEnvironmentVariable($keyVar)) { return $m }
            }
            return "codex"  # fallback to mid-tier if no cheap keys
        }
        "mid"     { return "codex" }
        "premium" { return "claude" }
    }
}

function Invoke-CheapModel {
    param(
        [string]$Model,      # "deepseek", "kimi", "minimax"
        [string]$System,
        [string]$UserMessage,
        [int]$MaxTokens = 4096
    )

    $endpoint = switch ($Model) {
        "deepseek" { "https://api.deepseek.com/v1/chat/completions" }
        "kimi"     { "https://api.moonshot.ai/v1/chat/completions" }
        "minimax"  { "https://api.minimax.io/v1/chat/completions" }
    }
    $modelId = switch ($Model) {
        "deepseek" { "deepseek-chat" }
        "kimi"     { "moonshot-v1-8k" }
        "minimax"  { "MiniMax-Text-01" }
    }
    $apiKey = switch ($Model) {
        "deepseek" { $env:DEEPSEEK_API_KEY }
        "kimi"     { $env:KIMI_API_KEY }
        "minimax"  { $env:MINIMAX_API_KEY }
    }

    if (-not $apiKey) { return $null }

    # Standard OpenAI-compatible format
    $body = @{
        model = $modelId
        messages = @(
            @{ role = "system"; content = $System }
            @{ role = "user"; content = $UserMessage }
        )
        max_tokens = [Math]::Min($MaxTokens, 8192)  # DeepSeek cap
    } | ConvertTo-Json -Depth 10

    $headers = @{
        "Authorization" = "Bearer $apiKey"
        "Content-Type"  = "application/json"
    }

    try {
        $response = Invoke-RestMethod -Uri $endpoint -Method POST -Headers $headers -Body $body -TimeoutSec 120
        return $response.choices[0].message.content
    } catch {
        Write-Log "Cheap model $Model failed: $_" -Level WARN
        return $null
    }
}

function Estimate-TierCost {
    param(
        [string]$Text,
        [string]$Tier
    )
    # Rough token estimate: 1 token ~ 4 chars
    $tokens = [math]::Max(1, [math]::Ceiling($Text.Length / 4))
    $costPer1M = switch ($Tier) {
        "local"   { 0 }
        "cheap"   { 0.21 }
        "mid"     { 1.50 }
        "premium" { 9.00 }
        default   { 0 }
    }
    return [math]::Round(($tokens / 1000000) * $costPer1M, 4)
}

function Invoke-TieredSmokePhase {
    <#
    .SYNOPSIS
        Routes a smoke test phase to the appropriate model tier.
        If CostOptimize is off, always uses premium (Claude).
    #>
    param(
        [string]$PhaseName,
        [string]$Tier,       # "local", "cheap", "mid", "premium"
        [string]$System,
        [string]$UserMessage,
        [int]$MaxTokens = 8192
    )

    # If cost optimization is off, force premium for all LLM tasks
    if (-not $CostOptimize -and $Tier -ne "local") {
        $Tier = "premium"
    }

    $model = Select-ModelForTask -Tier $Tier
    $script:tasksByTier[$Tier]++

    if ($null -eq $model) {
        # Local processing -- caller handles directly
        Write-Log "$PhaseName : local processing (no LLM)" "INFO"
        return $null
    }

    Write-Log "$PhaseName : using $Tier tier ($model)" "INFO"

    $result = $null
    switch ($Tier) {
        "cheap" {
            $raw = Invoke-CheapModel -Model $model -System $System -UserMessage $UserMessage -MaxTokens $MaxTokens
            if (-not $raw) {
                # Fallback: try codex (mid-tier)
                Write-Log "$PhaseName : cheap model failed, falling back to codex" "WARN"
                $raw = $null
                try {
                    $codexResult = Invoke-CodexMiniApi -SystemPrompt $System -UserMessage $UserMessage -MaxTokens $MaxTokens -Phase "smoke-test-$PhaseName"
                    if ($codexResult -and $codexResult.Success) { $raw = $codexResult.Text }
                } catch { }
                if (-not $raw) {
                    # Final fallback: premium
                    Write-Log "$PhaseName : codex fallback also failed, using Claude" "WARN"
                    return Invoke-SmokePhase -PhaseName $PhaseName -UserPrompt $UserMessage -MaxTokens $MaxTokens
                }
                $script:costByTier["mid"] += (Estimate-TierCost -Text "$System$UserMessage$raw" -Tier "mid")
            } else {
                $script:costByTier["cheap"] += (Estimate-TierCost -Text "$System$UserMessage$raw" -Tier "cheap")
            }
            # Parse JSON from raw text
            $raw = $raw.Trim() -replace '(?s)^```(?:json)?\s*\n', '' -replace '\n```\s*$', ''
            try { $result = $raw | ConvertFrom-Json } catch {
                Write-Log "$PhaseName : cheap model JSON parse failed - $($_.Exception.Message)" "WARN"
                return $null
            }
        }
        "mid" {
            # Use Codex Mini (Responses API)
            $phase = "smoke-test-$PhaseName"
            try {
                $codexResult = Invoke-CodexMiniApi -SystemPrompt $System -UserMessage $UserMessage -MaxTokens $MaxTokens -Phase $phase
                if ($codexResult -and $codexResult.Success -and $codexResult.Text) {
                    if ($codexResult.Usage -and (Get-Command Add-ApiCallCost -ErrorAction SilentlyContinue)) {
                        Add-ApiCallCost -Model "gpt-5.1-codex-mini" -Usage $codexResult.Usage -Phase $phase
                    }
                    $raw = $codexResult.Text.Trim() -replace '(?s)^```(?:json)?\s*\n', '' -replace '\n```\s*$', ''
                    try { $result = $raw | ConvertFrom-Json } catch {
                        Write-Log "$PhaseName : codex JSON parse failed - $($_.Exception.Message)" "WARN"
                    }
                    $script:costByTier["mid"] += (Estimate-TierCost -Text "$System$UserMessage$raw" -Tier "mid")
                }
            } catch {
                Write-Log "$PhaseName : codex exception - $($_.Exception.Message)" "ERROR"
            }
        }
        "premium" {
            # Use Claude Sonnet via existing Invoke-SmokePhase
            $result = Invoke-SmokePhase -PhaseName $PhaseName -UserPrompt $UserMessage -MaxTokens $MaxTokens
            $script:costByTier["premium"] += (Estimate-TierCost -Text "$System$UserMessage" -Tier "premium")
        }
    }

    return $result
}

# Output directory
$smokeDir = Join-Path $GsdDir "smoke-test"
if (-not (Test-Path $smokeDir)) { New-Item -ItemType Directory -Path $smokeDir -Force | Out-Null }

# Load smoke test prompt template
$smokePromptPath = Join-Path $v3Dir "prompts/sonnet/08-smoke-test.md"
$smokePromptTemplate = ""
if (Test-Path $smokePromptPath) {
    $smokePromptTemplate = Get-Content $smokePromptPath -Raw -Encoding UTF8
}

# ============================================================
# SYSTEM PROMPTS
# ============================================================

$smokeSystemPrompt = @"
You are an integration smoke tester for a generated codebase. Code review has already passed. You are looking for REAL-WORLD integration issues that static review misses. Return ONLY a JSON object. No markdown, no explanation, no preamble. Just the JSON object starting with { and ending with }.
"@

$fixSystemPrompt = @"
You are a code fixer. You receive a source file and a list of issues found by smoke testing. Your job is to fix ALL the issues and return the COMPLETE corrected file.

Rules:
1. Return ONLY the corrected file content. No markdown fences. No explanation. No preamble.
2. Fix every issue listed. Do not skip any.
3. Preserve the file's overall structure, imports, and exports.
4. Do not add unnecessary changes beyond what's needed to fix the issues.
5. If an issue mentions missing functionality, add a minimal correct implementation.
6. The output must be valid, compilable code in the same language as the input.
"@

# ============================================================
# HELPER: Invoke Claude for a smoke test phase
# ============================================================

function Invoke-SmokePhase {
    param(
        [string]$PhaseName,
        [string]$UserPrompt,
        [int]$MaxTokens = 8192
    )

    $phase = "smoke-test-$PhaseName"
    Write-Log "Invoking Claude for phase: $PhaseName" "PHASE"

    try {
        $result = Invoke-SonnetApi -SystemPrompt $smokeSystemPrompt -UserMessage $UserPrompt -MaxTokens $MaxTokens -JsonMode -Phase $phase

        if ($result -and $result.Success -and $result.Text) {
            if ($result.Usage -and (Get-Command Add-ApiCallCost -ErrorAction SilentlyContinue)) {
                Add-ApiCallCost -Model "claude-sonnet-4-6" -Usage $result.Usage -Phase $phase
            }

            $responseText = $result.Text.Trim()
            $responseText = $responseText -replace '(?s)^```(?:json)?\s*\n', '' -replace '\n```\s*$', ''

            try {
                $parsed = $responseText | ConvertFrom-Json
                return $parsed
            }
            catch {
                Write-Log "$PhaseName : JSON parse failed - $($_.Exception.Message)" "WARN"
                return $null
            }
        }
        else {
            $errMsg = if ($result.Error) { $result.Error } elseif ($result.Message) { $result.Message } else { "Unknown" }
            Write-Log "$PhaseName : API error - $errMsg" "ERROR"
            return $null
        }
    }
    catch {
        Write-Log "$PhaseName : Exception - $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# ============================================================
# HELPER: Fix a file using the fix model
# ============================================================

function Invoke-SmokeFix {
    param(
        [string]$FilePath,
        [string]$RelPath,
        [array]$Issues,
        [string]$Model
    )

    if (-not (Test-Path $FilePath)) {
        Write-Log "Fix skipped - file not found: $RelPath" "WARN"
        return $false
    }

    $fileContent = Get-Content $FilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $fileContent) {
        Write-Log "Fix skipped - file empty or unreadable: $RelPath" "WARN"
        return $false
    }

    $issueList = ""
    $idx = 1
    foreach ($issue in $Issues) {
        $issueList += "$idx. [$($issue.severity)] $($issue.description)"
        if ($issue.fix_suggestion) { $issueList += " -- Suggestion: $($issue.fix_suggestion)" }
        $issueList += "`n"
        $idx++
    }

    $fixPrompt = @"
## File to Fix
Path: $RelPath

## Current Code
$fileContent

## Issues to Fix
$issueList

## Task
Fix ALL issues listed above. Return the COMPLETE corrected file. No markdown fences. No explanation.
"@

    try {
        $result = $null
        $phase = "smoke-fix-$Model"

        switch ($Model) {
            "codex" {
                $result = Invoke-CodexMiniApi -SystemPrompt $fixSystemPrompt -UserMessage $fixPrompt -MaxTokens 16384 -Phase $phase
            }
            "claude" {
                $result = Invoke-SonnetApi -SystemPrompt $fixSystemPrompt -UserMessage $fixPrompt -MaxTokens 16384 -Phase $phase
            }
        }

        if ($result -and $result.Success -and $result.Text) {
            if ($result.Usage -and (Get-Command Add-ApiCallCost -ErrorAction SilentlyContinue)) {
                $modelId = switch ($Model) {
                    "codex"  { "gpt-5.1-codex-mini" }
                    "claude" { "claude-sonnet-4-6" }
                }
                Add-ApiCallCost -Model $modelId -Usage $result.Usage -Phase $phase
            }

            $fixedCode = $result.Text.Trim()
            $fixedCode = $fixedCode -replace '(?s)^```[a-z]*\s*\n', '' -replace '\n```\s*$', ''

            # Sanity: fixed code should be at least 50% the length of original
            if ($fixedCode.Length -lt ($fileContent.Length * 0.5)) {
                Write-Log "Fix rejected - output too short ($($fixedCode.Length) vs $($fileContent.Length) chars): $RelPath" "WARN"
                return $false
            }

            if ($fixedCode -eq $fileContent) {
                Write-Log "Fix skipped - no changes produced for: $RelPath" "SKIP"
                return $false
            }

            $fixedCode | Set-Content $FilePath -Encoding UTF8 -NoNewline
            Write-Log "Fixed $($Issues.Count) issue(s) in: $RelPath" "FIX"
            return $true
        }
        else {
            $errMsg = if ($result.Error) { $result.Error } elseif ($result.Message) { $result.Message } else { "Unknown" }
            Write-Log "Fix API error for $RelPath : $errMsg" "ERROR"
            return $false
        }
    }
    catch {
        Write-Log "Fix exception for $RelPath : $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# ============================================================
# HELPER: Gather project context for prompts
# ============================================================

function Get-ProjectContext {
    param([string]$Root)

    $context = @()

    # Detect project structure
    $hasDotnet = Test-Path (Join-Path $Root "*.sln") -ErrorAction SilentlyContinue
    if (-not $hasDotnet) {
        $hasDotnet = (Get-ChildItem -Path $Root -Filter "*.csproj" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1) -ne $null
    }
    $hasNode = Test-Path (Join-Path $Root "package.json")
    $hasSql = (Get-ChildItem -Path $Root -Filter "*.sql" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1) -ne $null

    $context += "## Project Structure"
    $context += "- .NET Backend: $(if ($hasDotnet) { 'Yes' } else { 'No' })"
    $context += "- Node/React Frontend: $(if ($hasNode) { 'Yes' } else { 'No' })"
    $context += "- SQL Database: $(if ($hasSql) { 'Yes' } else { 'No' })"

    # Docs summary
    $docsDir = Join-Path $Root "docs"
    if (Test-Path $docsDir) {
        $docFiles = Get-ChildItem -Path $docsDir -Filter "*.md" -ErrorAction SilentlyContinue
        if ($docFiles.Count -gt 0) {
            $context += ""
            $context += "## Documentation Files"
            foreach ($doc in $docFiles | Select-Object -First 20) {
                $context += "- $($doc.Name)"
            }
        }
    }

    return ($context -join "`n")
}

# ============================================================
# HELPER: Read files matching pattern (up to N files, maxSize each)
# ============================================================

function Read-ProjectFiles {
    param(
        [string]$Root,
        [string[]]$Patterns,
        [int]$MaxFiles = 10,
        [int]$MaxSizePerFile = 16000,
        [string[]]$ExcludePatterns = @('bin', 'obj', 'node_modules', 'dist', '.gsd')
    )

    $content = ""
    $filesRead = 0

    foreach ($pattern in $Patterns) {
        $files = Get-ChildItem -Path $Root -Filter $pattern -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $path = $_.FullName
                $excluded = $false
                foreach ($ep in $ExcludePatterns) {
                    if ($path -match [regex]::Escape($ep)) { $excluded = $true; break }
                }
                -not $excluded
            } |
            Select-Object -First ($MaxFiles - $filesRead)

        foreach ($file in $files) {
            if ($filesRead -ge $MaxFiles) { break }
            try {
                $raw = Get-Content -Path $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                if ($raw.Length -gt $MaxSizePerFile) {
                    $raw = $raw.Substring(0, $MaxSizePerFile) + "`n[... truncated at ${MaxSizePerFile} chars ...]"
                }
                $relPath = $file.FullName.Replace($Root, '').TrimStart('\', '/')
                $content += "`n### File: $relPath`n$raw`n"
                $filesRead++
            }
            catch { }
        }
    }

    return $content
}

# ============================================================
# PHASE 1: BUILD VALIDATION
# ============================================================

function Invoke-BuildValidation {
    param([string]$Root)

    Write-Host "`n--- Phase 1: Build Validation ---" -ForegroundColor Yellow
    Write-Log "=== Phase 1: Build Validation ===" "PHASE"

    # Tier: LOCAL -- just run dotnet build / npm run build
    $script:tasksByTier["local"]++

    $result = @{
        phase = "build_validation"
        status = "pass"
        issues = @()
        summary = ""
    }

    if ($SkipBuild) {
        $result.status = "skip"
        $result.summary = "Build validation skipped by user"
        Write-Log "Build validation skipped" "SKIP"
        return $result
    }

    # Backend build
    $slnFiles = Get-ChildItem -Path $Root -Filter "*.sln" -ErrorAction SilentlyContinue
    $csprojFiles = Get-ChildItem -Path $Root -Filter "*.csproj" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '(bin|obj|node_modules)[/\\]' }

    if ($slnFiles -or $csprojFiles) {
        Write-Log "Running dotnet build..." "INFO"
        $buildTarget = if ($slnFiles) { $slnFiles[0].FullName } else { $csprojFiles[0].FullName }

        try {
            $buildOutput = & dotnet build $buildTarget --no-restore 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                $result.status = "fail"
                # Extract error lines
                $errorLines = ($buildOutput -split "`n") | Where-Object { $_ -match '(error CS|error FS|error MSB|FAILED)' } | Select-Object -First 20
                foreach ($err in $errorLines) {
                    $result.issues += @{
                        severity = "critical"
                        category = "build_error"
                        file = ""
                        description = $err.Trim()
                        fix_suggestion = "Fix compilation error"
                    }
                }
                Write-Log "dotnet build FAILED with $($errorLines.Count) error(s)" "ERROR"
            }
            else {
                Write-Log "dotnet build succeeded" "OK"
            }
        }
        catch {
            $result.issues += @{
                severity = "high"
                category = "build_error"
                file = ""
                description = "dotnet build threw exception: $($_.Exception.Message)"
                fix_suggestion = "Check .NET SDK installation and project file"
            }
            $result.status = "warn"
            Write-Log "dotnet build exception: $($_.Exception.Message)" "ERROR"
        }
    }

    # Frontend build
    $packageJson = Join-Path $Root "package.json"
    if (Test-Path $packageJson) {
        Write-Log "Running npm run build..." "INFO"
        try {
            Push-Location $Root
            $npmOutput = & npm run build 2>&1 | Out-String
            Pop-Location

            if ($LASTEXITCODE -ne 0) {
                if ($result.status -ne "fail") { $result.status = "fail" }
                $errorLines = ($npmOutput -split "`n") | Where-Object { $_ -match '(ERROR|Error|error|TS\d{4}|Cannot find)' } | Select-Object -First 20
                foreach ($err in $errorLines) {
                    $result.issues += @{
                        severity = "critical"
                        category = "build_error"
                        file = ""
                        description = "Frontend: $($err.Trim())"
                        fix_suggestion = "Fix TypeScript/build error"
                    }
                }
                Write-Log "npm run build FAILED with $($errorLines.Count) error(s)" "ERROR"
            }
            else {
                Write-Log "npm run build succeeded" "OK"
            }
        }
        catch {
            $result.issues += @{
                severity = "high"
                category = "build_error"
                file = ""
                description = "npm build threw exception: $($_.Exception.Message)"
                fix_suggestion = "Check Node.js/npm installation"
            }
            if ($result.status -ne "fail") { $result.status = "warn" }
            Write-Log "npm build exception: $($_.Exception.Message)" "ERROR"
        }
    }

    $result.summary = "Build: $(if ($result.status -eq 'pass') { 'All builds passed' } elseif ($result.status -eq 'fail') { "$($result.issues.Count) build error(s) found" } else { 'Partial build results' })"
    return $result
}

# ============================================================
# PHASE 2: DATABASE VALIDATION
# ============================================================

function Invoke-DatabaseValidation {
    param([string]$Root, [string]$ConnStr)

    Write-Host "`n--- Phase 2: Database Validation ---" -ForegroundColor Yellow
    Write-Log "=== Phase 2: Database Validation ===" "PHASE"

    $result = @{
        phase = "database_validation"
        status = "pass"
        issues = @()
        summary = ""
    }

    if ($SkipDbValidation) {
        $result.status = "skip"
        $result.summary = "Database validation skipped by user"
        Write-Log "Database validation skipped" "SKIP"
        return $result
    }

    # Gather SQL files and C# repository files for analysis
    $sqlContent = Read-ProjectFiles -Root $Root -Patterns @("*.sql") -MaxFiles 20 -MaxSizePerFile 8000
    $repoContent = Read-ProjectFiles -Root $Root -Patterns @("*Repository.cs", "*Controller.cs") -MaxFiles 10 -MaxSizePerFile 8000
    $migrationContent = Read-ProjectFiles -Root $Root -Patterns @("*migration*.sql", "*Migration*.cs") -MaxFiles 5 -MaxSizePerFile 4000

    if ([string]::IsNullOrWhiteSpace($sqlContent) -and [string]::IsNullOrWhiteSpace($repoContent)) {
        $result.status = "skip"
        $result.summary = "No SQL or repository files found"
        Write-Log "No database files to validate" "SKIP"
        return $result
    }

    $dbContext = ""
    if ($ConnStr) {
        $dbContext = "`n## Database Connection: Available (connection string provided)`n"
    }

    $prompt = @"
# Smoke Test Phase: Database Validation

## Context
You are validating the database layer of a .NET + SQL Server application.
Code review has already passed. Look for INTEGRATION issues.
$dbContext

## SQL Files
$sqlContent

## Repository / Controller Files
$repoContent

## Migration Files
$migrationContent

## What To Check
1. Every stored procedure referenced in C# code (usp_*) has a matching SQL definition
2. Every table referenced in SQL has CREATE TABLE or exists in migrations
3. Foreign key references point to existing tables
4. All required columns referenced in SELECT/INSERT/UPDATE exist in CREATE TABLE
5. Migration ordering is correct (no forward references)
6. Seed data references valid tables and columns
7. SET ANSI_NULLS ON / SET QUOTED_IDENTIFIER ON present on all procs
8. SET NOCOUNT ON in every procedure body
9. Error handling (BEGIN TRY/CATCH) in every procedure
10. Idempotency guards on all DDL statements

## Output Format
Return a JSON object:
{"phase":"database_validation","status":"pass|fail|warn","issues":[{"severity":"critical|high|medium|low","category":"db_gap","file":"path","description":"description","fix_suggestion":"suggestion"}],"summary":"1-2 sentence summary"}
"@

    # Tier: cheap (structured schema comparison) -- falls back to mid/premium
    $parsed = Invoke-TieredSmokePhase -PhaseName "db-validation" -Tier "cheap" -System $smokeSystemPrompt -UserMessage $prompt

    if ($parsed) {
        $result.status = if ($parsed.status) { $parsed.status } else { "warn" }
        $result.issues = if ($parsed.issues) { @($parsed.issues) } else { @() }
        $result.summary = if ($parsed.summary) { $parsed.summary } else { "$($result.issues.Count) database issue(s) found" }
    }
    else {
        $result.status = "warn"
        $result.summary = "Database validation API call failed"
    }

    Write-Log "Database validation: $($result.status) - $($result.issues.Count) issue(s)" $(if ($result.status -eq "pass") { "OK" } else { "WARN" })
    return $result
}

# ============================================================
# PHASE 3: API SMOKE TEST
# ============================================================

function Invoke-ApiSmokeTest {
    param([string]$Root)

    Write-Host "`n--- Phase 3: API Smoke Test ---" -ForegroundColor Yellow
    Write-Log "=== Phase 3: API Smoke Test ===" "PHASE"

    $result = @{
        phase = "api_smoke_test"
        status = "pass"
        issues = @()
        summary = ""
    }

    $controllerContent = Read-ProjectFiles -Root $Root -Patterns @("*Controller.cs") -MaxFiles 15 -MaxSizePerFile 8000
    $programContent = Read-ProjectFiles -Root $Root -Patterns @("Program.cs", "Startup.cs") -MaxFiles 3 -MaxSizePerFile 8000
    $configContent = Read-ProjectFiles -Root $Root -Patterns @("appsettings.json", "appsettings.Development.json") -MaxFiles 2 -MaxSizePerFile 4000

    if ([string]::IsNullOrWhiteSpace($controllerContent)) {
        $result.status = "skip"
        $result.summary = "No API controllers found"
        Write-Log "No controllers to smoke test" "SKIP"
        return $result
    }

    $prompt = @"
# Smoke Test Phase: API Smoke Test

## Context
Validate the API layer of a .NET backend. Check that endpoints are properly configured, middleware is correct, and configuration is complete.

## Controller Files
$controllerContent

## Program.cs / Startup.cs
$programContent

## Configuration
$configContent

## What To Check
1. /health or /api/health endpoint exists and is configured
2. All controller routes are valid (no duplicates, no conflicts)
3. CORS is configured in Program.cs/Startup.cs
4. Swagger/OpenAPI is configured (at least for Development)
5. Authentication middleware is in correct order (UseRouting -> UseAuthentication -> UseAuthorization -> MapControllers)
6. All controllers have [ApiController] and [Route] attributes
7. Every controller action has an explicit HTTP method attribute ([HttpGet], [HttpPost], etc.)
8. DTOs are used (not raw domain models) in API responses
9. Input validation exists (FluentValidation or DataAnnotations)
10. Error handling middleware is configured
11. Every injected service/repository in controllers is registered in DI

## Output Format
Return a JSON object:
{"phase":"api_smoke_test","status":"pass|fail|warn","issues":[{"severity":"critical|high|medium|low","category":"api_gap","file":"path","description":"description","fix_suggestion":"suggestion"}],"summary":"1-2 sentence summary"}
"@

    # Tier: mid (needs code understanding for API wiring)
    $parsed = Invoke-TieredSmokePhase -PhaseName "api-smoke" -Tier "mid" -System $smokeSystemPrompt -UserMessage $prompt

    if ($parsed) {
        $result.status = if ($parsed.status) { $parsed.status } else { "warn" }
        $result.issues = if ($parsed.issues) { @($parsed.issues) } else { @() }
        $result.summary = if ($parsed.summary) { $parsed.summary } else { "$($result.issues.Count) API issue(s) found" }
    }
    else {
        $result.status = "warn"
        $result.summary = "API smoke test API call failed"
    }

    Write-Log "API smoke test: $($result.status) - $($result.issues.Count) issue(s)" $(if ($result.status -eq "pass") { "OK" } else { "WARN" })
    return $result
}

# ============================================================
# PHASE 4: FRONTEND ROUTE VALIDATION
# ============================================================

function Invoke-FrontendRouteValidation {
    param([string]$Root)

    Write-Host "`n--- Phase 4: Frontend Route Validation ---" -ForegroundColor Yellow
    Write-Log "=== Phase 4: Frontend Route Validation ===" "PHASE"

    $result = @{
        phase = "frontend_route_validation"
        status = "pass"
        issues = @()
        summary = ""
    }

    # Find router/app files
    $routerContent = Read-ProjectFiles -Root $Root -Patterns @("App.tsx", "router.tsx", "routes.tsx", "Router.tsx", "AppRoutes.tsx") -MaxFiles 5 -MaxSizePerFile 12000

    if ([string]::IsNullOrWhiteSpace($routerContent)) {
        $result.status = "skip"
        $result.summary = "No router/App files found"
        Write-Log "No frontend router files found" "SKIP"
        return $result
    }

    # Also get page/screen component files (just filenames for existence check)
    $pageFiles = @()
    foreach ($srcDir in @("src", "client", "frontend", "app")) {
        $dir = Join-Path $Root $srcDir
        if (Test-Path $dir) {
            $pages = Get-ChildItem -Path $dir -Filter "*.tsx" -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match '(pages|screens|views)[/\\]' -and $_.FullName -notmatch '(node_modules|dist)[/\\]' }
            foreach ($p in $pages) {
                $pageFiles += $p.FullName.Replace($Root, '').TrimStart('\', '/')
            }
        }
    }

    $pageListStr = if ($pageFiles.Count -gt 0) { ($pageFiles | ForEach-Object { "- $_" }) -join "`n" } else { "(no page files found)" }
    $lazyContent = Read-ProjectFiles -Root $Root -Patterns @("index.ts", "index.tsx") -MaxFiles 10 -MaxSizePerFile 4000 -ExcludePatterns @('bin', 'obj', 'node_modules', 'dist', '.gsd', 'components')

    # Tier: LOCAL — parse router file with regex using route-role-matrix module
    $script:tasksByTier["local"]++
    Write-Log "Frontend routes: using local tier (regex parsing)" "INFO"

    # Use the local route-role-matrix module if available
    if (Get-Command Build-RouteRoleMatrix -ErrorAction SilentlyContinue) {
        try {
            $matrix = Build-RouteRoleMatrix -RepoRoot $Root
            if ($matrix -and $matrix.Gaps) {
                foreach ($gap in $matrix.Gaps) {
                    $result.issues += @{
                        severity = $gap.Severity
                        category = "frontend_gap"
                        file = if ($gap.Route) { $gap.Route } else { "" }
                        description = $gap.Description
                        fix_suggestion = switch ($gap.Type) {
                            'unguarded_route' { 'Wrap route with ProtectedRoute/AuthGuard component' }
                            'orphan_nav'      { 'Add a matching <Route> for this navigation item' }
                            'hidden_route'    { 'Add navigation entry so users can reach this route' }
                            'missing_file'    { 'Create the missing file in the expected location' }
                            'empty_role'      { 'Assign routes to this role or remove it' }
                            default           { 'Review and fix the route configuration' }
                        }
                    }
                }
                $result.status = if ($result.issues.Count -eq 0) { "pass" } elseif (@($result.issues | Where-Object { $_.severity -eq "critical" }).Count -gt 0) { "fail" } else { "warn" }
                $result.summary = "Local scan: $($matrix.Summary.TotalRoutes) routes, $($matrix.Summary.GuardedRoutes) guarded, $($matrix.Summary.TotalGaps) gap(s)"
                Write-Log "Frontend routes (local): $($result.status) - $($result.issues.Count) issue(s)" $(if ($result.status -eq "pass") { "OK" } else { "WARN" })
                return $result
            }
        } catch {
            Write-Log "Local route parsing failed, falling back to LLM: $($_.Exception.Message)" "WARN"
        }
    }

    # Fallback: also do local regex-based route/component existence check
    $localIssues = @()
    foreach ($srcDir in @("src", "client", "frontend", "app")) {
        $dir = Join-Path $Root $srcDir
        if (-not (Test-Path $dir)) { continue }

        # Find router files and extract Route paths + components
        $routerFiles = Get-ChildItem -Path $dir -Include "App.tsx", "router.tsx", "routes.tsx", "Router.tsx", "AppRoutes.tsx" -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '(node_modules|dist)[/\\]' }

        foreach ($rf in $routerFiles) {
            try {
                $content = [System.IO.File]::ReadAllText($rf.FullName)
                # Extract Route elements
                $routeMatches = [regex]::Matches($content, '<Route[^>]*path\s*=\s*"([^"]+)"[^>]*(element\s*=\s*\{\s*<(\w+)|component\s*=\s*\{?\s*(\w+))')
                foreach ($m in $routeMatches) {
                    $path = $m.Groups[1].Value
                    $component = if ($m.Groups[3].Value) { $m.Groups[3].Value } else { $m.Groups[4].Value }

                    # Check if component file exists in page list
                    $componentExists = $pageFiles | Where-Object { $_ -match "(?i)$component" }
                    if (-not $componentExists -and $component -notin @('Navigate', 'Outlet', 'NotFound', 'Loading')) {
                        $localIssues += @{
                            severity = "high"
                            category = "frontend_gap"
                            file = $rf.FullName.Replace($Root, '').TrimStart('\', '/')
                            description = "Route '$path' references component '$component' but no matching page file found"
                            fix_suggestion = "Create the $component page component"
                        }
                    }
                }

                # Check for duplicate paths
                $allPaths = [regex]::Matches($content, '<Route[^>]*path\s*=\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
                $dupes = $allPaths | Group-Object | Where-Object { $_.Count -gt 1 }
                foreach ($d in $dupes) {
                    $localIssues += @{
                        severity = "high"
                        category = "frontend_gap"
                        file = $rf.FullName.Replace($Root, '').TrimStart('\', '/')
                        description = "Duplicate route path: '$($d.Name)' appears $($d.Count) times"
                        fix_suggestion = "Remove duplicate route definition"
                    }
                }

                # Check for 404 catch-all
                if ($content -notmatch '<Route[^>]*path\s*=\s*"\*"') {
                    $localIssues += @{
                        severity = "medium"
                        category = "frontend_gap"
                        file = $rf.FullName.Replace($Root, '').TrimStart('\', '/')
                        description = "No catch-all 404 route (path='*') found"
                        fix_suggestion = "Add <Route path='*' element={<NotFound />} /> as the last route"
                    }
                }
            } catch { }
        }
    }

    if ($localIssues.Count -gt 0) {
        $result.issues = $localIssues
        $result.status = if (@($localIssues | Where-Object { $_.severity -eq "critical" }).Count -gt 0) { "fail" } else { "warn" }
    }
    $result.summary = "Local scan: $($localIssues.Count) frontend route issue(s) found"
    Write-Log "Frontend routes (local): $($result.status) - $($result.issues.Count) issue(s)" $(if ($result.status -eq "pass") { "OK" } else { "WARN" })
    return $result
}

# ============================================================
# PHASE 5: AUTH FLOW VALIDATION
# ============================================================

function Invoke-AuthFlowValidation {
    param([string]$Root, [string]$AzureAd, [string]$Users)

    Write-Host "`n--- Phase 5: Auth Flow Validation ---" -ForegroundColor Yellow
    Write-Log "=== Phase 5: Auth Flow Validation ===" "PHASE"

    $result = @{
        phase = "auth_flow_validation"
        status = "pass"
        issues = @()
        summary = ""
    }

    $authContent = Read-ProjectFiles -Root $Root -Patterns @("*Auth*.cs", "*Auth*.ts", "*Auth*.tsx", "*auth*.ts", "*auth*.tsx", "*middleware*.cs") -MaxFiles 10 -MaxSizePerFile 8000
    $programContent = Read-ProjectFiles -Root $Root -Patterns @("Program.cs", "Startup.cs") -MaxFiles 2 -MaxSizePerFile 8000
    $routerContent = Read-ProjectFiles -Root $Root -Patterns @("App.tsx", "router.tsx", "routes.tsx") -MaxFiles 3 -MaxSizePerFile 8000

    if ([string]::IsNullOrWhiteSpace($authContent) -and [string]::IsNullOrWhiteSpace($programContent)) {
        $result.status = "skip"
        $result.summary = "No auth files found"
        Write-Log "No auth files to validate" "SKIP"
        return $result
    }

    $azureAdContext = if ($AzureAd) { "`n## Azure AD Configuration`n$AzureAd`n" } else { "" }
    $testUserContext = if ($Users) { "`n## Test User Credentials`n$Users`n" } else { "" }

    $prompt = @"
# Smoke Test Phase: Auth Flow Validation

## Context
Validate authentication and authorization flow end-to-end.
$azureAdContext
$testUserContext

## Auth Files
$authContent

## Program.cs / Startup.cs
$programContent

## Router Files
$routerContent

## What To Check
1. Authentication middleware is registered and in correct order in Program.cs
2. JWT Bearer or Azure AD authentication is configured with required settings
3. [Authorize] attribute is on controllers/actions that need protection
4. Frontend has auth context/provider wrapping the app
5. Protected routes redirect to login when unauthenticated
6. Token refresh logic exists (not just initial auth)
7. Role-based checks exist where needed ([Authorize(Roles = "...")])
8. Auth token is attached to API calls (Authorization header)
9. Logout clears tokens and redirects
10. CORS allows the frontend origin for auth endpoints

## Output Format
Return a JSON object:
{"phase":"auth_flow_validation","status":"pass|fail|warn","issues":[{"severity":"critical|high|medium|low","category":"auth_gap","file":"path","description":"description","fix_suggestion":"suggestion"}],"summary":"1-2 sentence summary"}
"@

    # Tier: mid (needs code understanding for auth flow analysis)
    $parsed = Invoke-TieredSmokePhase -PhaseName "auth-flow" -Tier "mid" -System $smokeSystemPrompt -UserMessage $prompt

    if ($parsed) {
        $result.status = if ($parsed.status) { $parsed.status } else { "warn" }
        $result.issues = if ($parsed.issues) { @($parsed.issues) } else { @() }
        $result.summary = if ($parsed.summary) { $parsed.summary } else { "$($result.issues.Count) auth flow issue(s) found" }
    }
    else {
        $result.status = "warn"
        $result.summary = "Auth flow validation API call failed"
    }

    Write-Log "Auth flow: $($result.status) - $($result.issues.Count) issue(s)" $(if ($result.status -eq "pass") { "OK" } else { "WARN" })
    return $result
}

# ============================================================
# PHASE 6: MODULE COMPLETENESS CHECK
# ============================================================

function Invoke-ModuleCompletenessCheck {
    param([string]$Root)

    Write-Host "`n--- Phase 6: Module Completeness Check ---" -ForegroundColor Yellow
    Write-Log "=== Phase 6: Module Completeness Check ===" "PHASE"

    $result = @{
        phase = "module_completeness"
        status = "pass"
        issues = @()
        summary = ""
    }

    # Gather docs for module definitions
    $docsContent = Read-ProjectFiles -Root $Root -Patterns @("*.md") -MaxFiles 5 -MaxSizePerFile 6000 -ExcludePatterns @('bin', 'obj', 'node_modules', 'dist', '.gsd', 'README')

    # Controller listing
    $controllers = Get-ChildItem -Path $Root -Filter "*Controller.cs" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '(bin|obj|node_modules)[/\\]' }
    $controllerList = if ($controllers) { ($controllers | ForEach-Object { $_.FullName.Replace($Root, '').TrimStart('\', '/') }) -join "`n" } else { "(none)" }

    # Frontend page listing
    $pageList = @()
    foreach ($srcDir in @("src", "client", "frontend", "app")) {
        $dir = Join-Path $Root $srcDir
        if (Test-Path $dir) {
            $pages = Get-ChildItem -Path $dir -Filter "*.tsx" -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match '(pages|screens|views)[/\\]' -and $_.FullName -notmatch '(node_modules|dist)[/\\]' }
            foreach ($p in $pages) { $pageList += $p.FullName.Replace($Root, '').TrimStart('\', '/') }
        }
    }
    $pageListStr = if ($pageList.Count -gt 0) { ($pageList -join "`n") } else { "(none)" }

    # SQL file listing
    $sqlFiles = Get-ChildItem -Path $Root -Filter "*.sql" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '(bin|obj|node_modules)[/\\]' }
    $sqlListStr = if ($sqlFiles) { ($sqlFiles | ForEach-Object { $_.FullName.Replace($Root, '').TrimStart('\', '/') }) -join "`n" } else { "(none)" }

    $prompt = @"
# Smoke Test Phase: Module Completeness Check

## Context
For each documented module/feature, verify all 3 layers exist: API endpoint, frontend page, database objects.

## Documentation
$docsContent

## Backend Controllers
$controllerList

## Frontend Pages
$pageListStr

## SQL Files
$sqlListStr

## What To Check
1. For each module mentioned in docs: does a matching controller exist?
2. For each module mentioned in docs: does a matching frontend page exist?
3. For each module mentioned in docs: do matching stored procedures/tables exist?
4. For each controller: does a matching frontend page call its endpoints?
5. CRUD completeness: if a module should have Create/Read/Update/Delete, are all present?
6. List operations: do list endpoints have pagination parameters?
7. Detail operations: do detail endpoints accept an ID parameter?

## Output Format
Return a JSON object:
{"phase":"module_completeness","status":"pass|fail|warn","issues":[{"severity":"critical|high|medium|low","category":"module_gap","file":"path","description":"description","fix_suggestion":"suggestion"}],"summary":"1-2 sentence summary"}
"@

    # Tier: cheap (structured checklist verification)
    $parsed = Invoke-TieredSmokePhase -PhaseName "module-completeness" -Tier "cheap" -System $smokeSystemPrompt -UserMessage $prompt

    if ($parsed) {
        $result.status = if ($parsed.status) { $parsed.status } else { "warn" }
        $result.issues = if ($parsed.issues) { @($parsed.issues) } else { @() }
        $result.summary = if ($parsed.summary) { $parsed.summary } else { "$($result.issues.Count) module completeness issue(s) found" }
    }
    else {
        $result.status = "warn"
        $result.summary = "Module completeness check API call failed"
    }

    Write-Log "Module completeness: $($result.status) - $($result.issues.Count) issue(s)" $(if ($result.status -eq "pass") { "OK" } else { "WARN" })
    return $result
}

# ============================================================
# PHASE 7: MOCK DATA DETECTION
# ============================================================

function Invoke-MockDataDetection {
    param([string]$Root)

    Write-Host "`n--- Phase 7: Mock Data Detection ---" -ForegroundColor Yellow
    Write-Log "=== Phase 7: Mock Data Detection ===" "PHASE"

    $result = @{
        phase = "mock_data_detection"
        status = "pass"
        issues = @()
        summary = ""
    }

    # Scan for mock data patterns locally first (fast pre-filter)
    $mockPatterns = @(
        'const\s+mock\w*\s*=',
        'const\s+fake\w*\s*=',
        'const\s+dummy\w*\s*=',
        'const\s+sample\w*\s*=',
        'const\s+stub\w*\s*=',
        '//\s*(TODO|FIXME|HACK|PLACEHOLDER|FILL)',
        'console\.\s*(log|warn|error|debug)\s*\(',
        'throw\s+new\s+Error\s*\(\s*[''"]Not\s+implemented',
        '\(\)\s*=>\s*\{\s*\}'
    )

    $suspiciousFiles = @()

    foreach ($srcDir in @("src", "client", "frontend", "app", "backend")) {
        $dir = Join-Path $Root $srcDir
        if (-not (Test-Path $dir)) { continue }

        $codeFiles = Get-ChildItem -Path $dir -Include "*.ts", "*.tsx", "*.cs" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '(bin|obj|node_modules|dist|test|spec|__test__)[/\\]' }

        foreach ($file in $codeFiles) {
            try {
                $content = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
                foreach ($pattern in $mockPatterns) {
                    if ($content -match $pattern) {
                        $suspiciousFiles += $file.FullName
                        break
                    }
                }
            }
            catch { }
        }
    }

    # Tier: LOCAL — use mock-data-detector module (pure regex, no LLM)
    $script:tasksByTier["local"]++
    Write-Log "Mock data: using local tier (regex scanning)" "INFO"

    # Use the local mock-data-detector module if available
    if (Get-Command Find-MockDataPatterns -ErrorAction SilentlyContinue) {
        try {
            $mockPatternResults = Find-MockDataPatterns -RepoRoot $Root
            $stubResults = Find-StubImplementations -RepoRoot $Root
            $placeholderResults = Find-PlaceholderConfigs -RepoRoot $Root

            # Convert mock patterns to smoke test issue format
            foreach ($mp in $mockPatternResults) {
                $sev = if (Get-Command Get-MockDataSeverity -ErrorAction SilentlyContinue) {
                    Get-MockDataSeverity -Finding $mp
                } else { $mp.Severity }
                $result.issues += @{
                    severity = $sev
                    category = "mock_data"
                    file = $mp.File
                    description = "$($mp.Pattern): $($mp.Match)"
                    fix_suggestion = $mp.Suggestion
                }
            }
            # Convert stubs
            foreach ($s in $stubResults) {
                $sev = if (Get-Command Get-MockDataSeverity -ErrorAction SilentlyContinue) {
                    Get-MockDataSeverity -Finding $s
                } else { "high" }
                $result.issues += @{
                    severity = $sev
                    category = "mock_data"
                    file = $s.File
                    description = "$($s.Type): $($s.Description)"
                    fix_suggestion = $s.Suggestion
                }
            }
            # Convert placeholder configs
            foreach ($pc in $placeholderResults) {
                $sev = if (Get-Command Get-MockDataSeverity -ErrorAction SilentlyContinue) {
                    Get-MockDataSeverity -Finding $pc
                } else { "critical" }
                $result.issues += @{
                    severity = $sev
                    category = "mock_data"
                    file = $pc.File
                    description = "Placeholder $($pc.ConfigKey): $($pc.PlaceholderValue)"
                    fix_suggestion = $pc.Suggestion
                }
            }

            $critCount = @($result.issues | Where-Object { $_.severity -eq "critical" }).Count
            $highCount = @($result.issues | Where-Object { $_.severity -eq "high" }).Count
            $result.status = if ($result.issues.Count -eq 0) { "pass" } elseif ($critCount -gt 0) { "fail" } else { "warn" }
            $result.summary = "Local scan: $($mockPatternResults.Count) patterns, $($stubResults.Count) stubs, $($placeholderResults.Count) placeholder configs"
            Write-Log "Mock data (local): $($result.status) - $($result.issues.Count) issue(s)" $(if ($result.status -eq "pass") { "OK" } else { "WARN" })
            return $result
        } catch {
            Write-Log "Local mock data scan failed: $($_.Exception.Message)" "WARN"
        }
    }

    # Fallback: use the regex pre-filter results directly (still local, no LLM)
    if ($suspiciousFiles.Count -eq 0) {
        $result.summary = "No mock data or placeholder patterns detected"
        Write-Log "No mock data found" "OK"
        return $result
    }

    # Convert suspicious file matches to issues
    foreach ($filePath in ($suspiciousFiles | Select-Object -Unique -First 30)) {
        try {
            $content = Get-Content -Path $filePath -Raw -ErrorAction Stop
            $relPath = $filePath.Replace($Root, '').TrimStart('\', '/')
            $lines = $content -split "`n"
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                foreach ($pattern in $mockPatterns) {
                    if ($line -match $pattern) {
                        $sev = if ($line -match '(?i)(password|secret|apikey|credential)') { "critical" }
                               elseif ($line -match '(?i)(mock|fake|dummy|stub)') { "high" }
                               elseif ($line -match '(?i)(TODO|FIXME|HACK|console\.)') { "medium" }
                               else { "low" }
                        $result.issues += @{
                            severity = $sev
                            category = "mock_data"
                            file = $relPath
                            description = "Line $($i+1): Pattern match '$pattern'"
                            fix_suggestion = "Replace with real implementation"
                        }
                        break  # One issue per line
                    }
                }
            }
        } catch { }
    }

    $critCount = @($result.issues | Where-Object { $_.severity -eq "critical" }).Count
    $result.status = if ($result.issues.Count -eq 0) { "pass" } elseif ($critCount -gt 0) { "fail" } else { "warn" }
    $result.summary = "Local regex scan: $($result.issues.Count) mock data issue(s) in $($suspiciousFiles.Count) file(s)"
    Write-Log "Mock data (local fallback): $($result.status) - $($result.issues.Count) issue(s)" $(if ($result.status -eq "pass") { "OK" } else { "WARN" })
    return $result
}

# ============================================================
# PHASE 8: RBAC MATRIX
# ============================================================

function Invoke-RbacMatrixValidation {
    param([string]$Root)

    Write-Host "`n--- Phase 8: RBAC Matrix Validation ---" -ForegroundColor Yellow
    Write-Log "=== Phase 8: RBAC Matrix Validation ===" "PHASE"

    $result = @{
        phase = "rbac_matrix"
        status = "pass"
        issues = @()
        summary = ""
    }

    # Tier: LOCAL — use route-role-matrix module (regex parsing + set operations)
    $script:tasksByTier["local"]++
    Write-Log "RBAC matrix: using local tier (regex parsing)" "INFO"

    # Use the local route-role-matrix module if available
    if (Get-Command Build-RouteRoleMatrix -ErrorAction SilentlyContinue) {
        try {
            $matrix = Build-RouteRoleMatrix -RepoRoot $Root
            if ($matrix) {
                # Convert matrix gaps to smoke test issue format
                foreach ($gap in $matrix.Gaps) {
                    $result.issues += @{
                        severity = $gap.Severity
                        category = "rbac_gap"
                        file = if ($gap.Route) { $gap.Route } else { "" }
                        description = $gap.Description
                        fix_suggestion = switch ($gap.Type) {
                            'unguarded_route' { 'Add [Authorize] attribute or wrap with auth guard' }
                            'orphan_nav'      { 'Add a matching route or remove the navigation entry' }
                            'hidden_route'    { 'Add navigation entry with proper role visibility' }
                            'empty_role'      { 'Assign accessible routes to this role or remove it' }
                            'missing_file'    { 'Create the missing router/RBAC config file' }
                            default           { 'Review RBAC configuration' }
                        }
                    }
                }

                # Also do local C# [Authorize] analysis
                $csControllers = Get-ChildItem -Path $Root -Filter "*Controller.cs" -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -notmatch '(bin|obj|node_modules)[/\\]' }

                foreach ($ctrl in $csControllers) {
                    try {
                        $content = [System.IO.File]::ReadAllText($ctrl.FullName)
                        $relPath = $ctrl.FullName.Replace($Root, '').TrimStart('\', '/')

                        # Check if controller has [Authorize] at class level
                        $hasClassAuthorize = $content -match '(?m)^\s*\[Authorize'
                        # Check for action methods
                        $actionMatches = [regex]::Matches($content, '\[(Http(Get|Post|Put|Delete|Patch))\]')

                        if ($actionMatches.Count -gt 0 -and -not $hasClassAuthorize) {
                            # Check if individual actions have [Authorize]
                            $lines = $content -split "`n"
                            for ($i = 0; $i -lt $lines.Count; $i++) {
                                if ($lines[$i] -match '\[(Http(Get|Post|Put|Delete|Patch))') {
                                    # Look up to 3 lines before for [Authorize]
                                    $hasActionAuth = $false
                                    for ($j = [Math]::Max(0, $i - 3); $j -lt $i; $j++) {
                                        if ($lines[$j] -match '\[Authorize') { $hasActionAuth = $true; break }
                                    }
                                    if (-not $hasActionAuth -and $relPath -notmatch '(?i)(health|status|ping|auth|login|register)') {
                                        $result.issues += @{
                                            severity = "high"
                                            category = "rbac_gap"
                                            file = $relPath
                                            description = "Line $($i+1): Action has no [Authorize] attribute"
                                            fix_suggestion = "Add [Authorize] to this action or the controller class"
                                        }
                                    }
                                }
                            }
                        }
                    } catch { }
                }

                $critCount = @($result.issues | Where-Object { $_.severity -eq "critical" }).Count
                $result.status = if ($result.issues.Count -eq 0) { "pass" } elseif ($critCount -gt 0) { "fail" } else { "warn" }
                $result.summary = "Local scan: $($matrix.Summary.TotalRoutes) routes, $($matrix.Summary.TotalRoles) roles, $($result.issues.Count) gap(s)"
                Write-Log "RBAC matrix (local): $($result.status) - $($result.issues.Count) issue(s)" $(if ($result.status -eq "pass") { "OK" } else { "WARN" })
                return $result
            }
        } catch {
            Write-Log "Local RBAC parsing failed: $($_.Exception.Message)" "WARN"
        }
    }

    # Fallback: use LLM (mid tier) if local parsing fails
    $controllerContent = Read-ProjectFiles -Root $Root -Patterns @("*Controller.cs") -MaxFiles 15 -MaxSizePerFile 6000
    $routerContent = Read-ProjectFiles -Root $Root -Patterns @("App.tsx", "router.tsx", "routes.tsx", "ProtectedRoute.tsx", "AuthGuard.tsx", "RequireAuth.tsx") -MaxFiles 5 -MaxSizePerFile 8000
    $roleContent = Read-ProjectFiles -Root $Root -Patterns @("*Role*.cs", "*Role*.ts", "*Permission*.cs", "*Permission*.ts", "*policy*.cs") -MaxFiles 5 -MaxSizePerFile 4000

    if ([string]::IsNullOrWhiteSpace($controllerContent) -and [string]::IsNullOrWhiteSpace($routerContent)) {
        $result.status = "skip"
        $result.summary = "No RBAC-related files found"
        Write-Log "No RBAC files to validate" "SKIP"
        return $result
    }

    $prompt = @"
# Smoke Test Phase: RBAC Matrix Validation

## Context
Build a role-based access control matrix and identify gaps between backend authorization and frontend route guards.

## Backend Controllers (with [Authorize] attributes)
$controllerContent

## Frontend Router (with auth guards)
$routerContent

## Role/Permission Definitions
$roleContent

## What To Check
1. Build matrix: Route/Endpoint -> Required Roles -> Actual Guard Implementation
2. Backend: every sensitive endpoint has [Authorize] or [Authorize(Roles = "...")]
3. Frontend: every protected route has an auth guard component
4. Backend role names match frontend role checks (no mismatches like "Admin" vs "admin")
5. Public endpoints (login, register, health) do NOT have [Authorize]
6. Admin-only endpoints have role restrictions (not just authentication)
7. Frontend shows/hides navigation items based on roles
8. API returns 401 for unauthenticated and 403 for unauthorized (not 500)

## Output Format
Return a JSON object:
{"phase":"rbac_matrix","status":"pass|fail|warn","issues":[{"severity":"critical|high|medium|low","category":"rbac_gap","file":"path","description":"description","fix_suggestion":"suggestion"}],"summary":"1-2 sentence summary"}
"@

    # Fallback to mid-tier LLM
    $parsed = Invoke-TieredSmokePhase -PhaseName "rbac-matrix" -Tier "mid" -System $smokeSystemPrompt -UserMessage $prompt

    if ($parsed) {
        $result.status = if ($parsed.status) { $parsed.status } else { "warn" }
        $result.issues = if ($parsed.issues) { @($parsed.issues) } else { @() }
        $result.summary = if ($parsed.summary) { $parsed.summary } else { "$($result.issues.Count) RBAC issue(s) found" }
    }
    else {
        $result.status = "warn"
        $result.summary = "RBAC matrix validation API call failed"
    }

    Write-Log "RBAC matrix: $($result.status) - $($result.issues.Count) issue(s)" $(if ($result.status -eq "pass") { "OK" } else { "WARN" })
    return $result
}

# ============================================================
# PHASE 9: INTEGRATION GAP REPORT (uses all prior results)
# ============================================================

function Invoke-IntegrationGapReport {
    param([string]$Root, [array]$PhaseResults)

    Write-Host "`n--- Phase 9: Integration Gap Report ---" -ForegroundColor Yellow
    Write-Log "=== Phase 9: Integration Gap Report ===" "PHASE"

    # Tier: LOCAL -- pure aggregation, no LLM
    $script:tasksByTier["local"]++

    # Aggregate all issues
    $allIssues = @()
    foreach ($pr in $PhaseResults) {
        if ($pr.issues) {
            foreach ($issue in $pr.issues) {
                $allIssues += @{
                    phase = $pr.phase
                    severity = if ($issue.severity) { $issue.severity } else { "medium" }
                    category = if ($issue.category) { $issue.category } else { $pr.phase }
                    file = if ($issue.file) { $issue.file } else { "" }
                    description = if ($issue.description) { $issue.description } else { "Unspecified issue" }
                    fix_suggestion = if ($issue.fix_suggestion) { $issue.fix_suggestion } else { "" }
                }
            }
        }
    }

    $result = @{
        phase = "integration_gap_report"
        status = if ($allIssues.Count -eq 0) { "pass" } else { "fail" }
        issues = $allIssues
        summary = ""
    }

    # Categorize
    $bySeverity = @{
        critical = @($allIssues | Where-Object { $_.severity -eq "critical" }).Count
        high     = @($allIssues | Where-Object { $_.severity -eq "high" }).Count
        medium   = @($allIssues | Where-Object { $_.severity -eq "medium" }).Count
        low      = @($allIssues | Where-Object { $_.severity -eq "low" }).Count
    }

    $byCategory = @{}
    foreach ($issue in $allIssues) {
        $cat = $issue.category
        if (-not $byCategory.ContainsKey($cat)) { $byCategory[$cat] = 0 }
        $byCategory[$cat]++
    }

    $result.summary = "Total: $($allIssues.Count) issues (C:$($bySeverity.critical) H:$($bySeverity.high) M:$($bySeverity.medium) L:$($bySeverity.low))"

    Write-Log "Integration gap report: $($result.summary)" $(if ($allIssues.Count -eq 0) { "OK" } else { "WARN" })
    return $result
}

# ============================================================
# MAIN LOOP: Run all phases -> Fix -> Re-run
# ============================================================

$script:totalErrors = 0
$overallStartTime = Get-Date
$projectContext = Get-ProjectContext -Root $RepoRoot
$cycleHistory = @()

for ($cycle = 1; $cycle -le $MaxCycles; $cycle++) {
    $cycleStart = Get-Date

    Write-Host "`n" -NoNewline
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  SMOKE TEST CYCLE $cycle / $MaxCycles" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan

    Write-Log "=== Starting smoke test cycle $cycle ===" "PHASE"

    # ---- RUN ALL PHASES ----
    $phaseResults = @()

    # Phase 1: Build
    $buildResult = Invoke-BuildValidation -Root $RepoRoot
    $phaseResults += $buildResult

    # Phase 2: Database
    $dbResult = Invoke-DatabaseValidation -Root $RepoRoot -ConnStr $ConnectionString
    $phaseResults += $dbResult

    # Phase 3: API
    $apiResult = Invoke-ApiSmokeTest -Root $RepoRoot
    $phaseResults += $apiResult

    # Phase 4: Frontend Routes
    $feResult = Invoke-FrontendRouteValidation -Root $RepoRoot
    $phaseResults += $feResult

    # Phase 5: Auth Flow
    $authResult = Invoke-AuthFlowValidation -Root $RepoRoot -AzureAd $AzureAdConfig -Users $TestUsers
    $phaseResults += $authResult

    # Phase 6: Module Completeness
    $moduleResult = Invoke-ModuleCompletenessCheck -Root $RepoRoot
    $phaseResults += $moduleResult

    # Phase 7: Mock Data
    $mockResult = Invoke-MockDataDetection -Root $RepoRoot
    $phaseResults += $mockResult

    # Phase 8: RBAC
    $rbacResult = Invoke-RbacMatrixValidation -Root $RepoRoot
    $phaseResults += $rbacResult

    # Phase 9: Integration Gap Report (aggregates all above)
    $gapResult = Invoke-IntegrationGapReport -Root $RepoRoot -PhaseResults $phaseResults
    $phaseResults += $gapResult

    # ---- AGGREGATE ----
    $allIssues = @($gapResult.issues)
    $fixableIssues = @($allIssues | Where-Object { $_.severity -in @("critical", "high", "medium") })

    $bySeverity = @{
        critical = @($allIssues | Where-Object { $_.severity -eq "critical" }).Count
        high     = @($allIssues | Where-Object { $_.severity -eq "high" }).Count
        medium   = @($allIssues | Where-Object { $_.severity -eq "medium" }).Count
        low      = @($allIssues | Where-Object { $_.severity -eq "low" }).Count
    }

    $cycleHistory += @{
        cycle = $cycle
        total_issues = $allIssues.Count
        critical = $bySeverity.critical
        high = $bySeverity.high
        medium = $bySeverity.medium
        low = $bySeverity.low
        fixable = $fixableIssues.Count
    }

    Write-Host "`n  Cycle $cycle results: $($allIssues.Count) issues (C:$($bySeverity.critical) H:$($bySeverity.high) M:$($bySeverity.medium) L:$($bySeverity.low))" -ForegroundColor $(if ($allIssues.Count -eq 0) { "Green" } else { "Yellow" })

    # ---- CHECK EXIT CONDITIONS ----

    # Clean: no fixable issues
    if ($fixableIssues.Count -eq 0) {
        Write-Host "`n  ** ALL CLEAR - No fixable issues remaining! **" -ForegroundColor Green
        Write-Log "Cycle ${cycle}: Clean - no fixable issues" "OK"
        break
    }

    # Last cycle: just report
    if ($cycle -eq $MaxCycles) {
        Write-Host "  Max cycles ($MaxCycles) reached. Remaining issues reported below." -ForegroundColor Yellow
        Write-Log "Max cycles reached with $($fixableIssues.Count) fixable issues remaining" "WARN"
        break
    }

    # Early-stop check: if cycle 2+ and issues didn't drop by 10%
    $earlyStop = $false
    if ($cycle -ge 2 -and $cycleHistory.Count -ge 2) {
        $prevIssues = $cycleHistory[-2].total_issues
        $currIssues = $allIssues.Count
        if ($prevIssues -gt 0) {
            $improvementPct = [math]::Round((($prevIssues - $currIssues) / $prevIssues) * 100, 1)
            Write-Host "  Convergence: $prevIssues -> $currIssues issues ($improvementPct% improvement)" -ForegroundColor $(if ($improvementPct -ge 10) { "Green" } else { "Yellow" })
            if ($improvementPct -lt 10) {
                Write-Host "  ** Will stop after applying fixes (diminishing returns). **" -ForegroundColor Yellow
                $earlyStop = $true
            }
        }
    }

    # ---- FIX PHASE ----
    Write-Host "`n--- Fixing $($fixableIssues.Count) issue(s) with $FixModel ---" -ForegroundColor Magenta

    # Group fixable issues by file
    $issuesByFile = @{}
    foreach ($issue in $fixableIssues) {
        $key = $issue.file
        if (-not $key -or $key -eq "") { continue }
        # Resolve to full path
        $fullPath = if ([System.IO.Path]::IsPathRooted($key)) { $key } else { Join-Path $RepoRoot $key }
        if (-not (Test-Path $fullPath)) { continue }
        if (-not $issuesByFile.ContainsKey($fullPath)) { $issuesByFile[$fullPath] = @() }
        $issuesByFile[$fullPath] += $issue
    }

    $fixedCount = 0
    $fixFailCount = 0
    foreach ($filePath in $issuesByFile.Keys) {
        $fileIssues = $issuesByFile[$filePath]
        $relPath = $filePath.Replace($RepoRoot, '').TrimStart('\', '/')

        # Deduplicate issues
        $uniqueIssues = @()
        $seenTexts = @{}
        foreach ($fi in $fileIssues) {
            $key = "$($fi.description)::$($fi.fix_suggestion)"
            if (-not $seenTexts.ContainsKey($key)) {
                $seenTexts[$key] = $true
                $uniqueIssues += $fi
            }
        }

        Write-Host "  Fixing $($uniqueIssues.Count) issue(s) in: $relPath" -ForegroundColor Magenta

        $fixed = Invoke-SmokeFix -FilePath $filePath -RelPath $relPath -Issues $uniqueIssues -Model $FixModel
        if ($fixed) { $fixedCount++ } else { $fixFailCount++ }
    }

    Write-Log "Cycle ${cycle} fix results: ${fixedCount} files fixed, ${fixFailCount} failed" $(if ($fixedCount -gt 0) { "FIX" } else { "WARN" })

    if ($fixedCount -eq 0) {
        Write-Host "  No files were fixed - stopping to prevent infinite loop." -ForegroundColor Yellow
        Write-Log "No fixes applied in cycle $cycle - stopping" "WARN"
        break
    }

    if ($earlyStop) {
        Write-Host "  ** EARLY STOP after fixes applied -- diminishing returns. **" -ForegroundColor Yellow
        Write-Log "Early stop after applying fixes in cycle $cycle" "WARN"
        break
    }

    Write-Host "  Proceeding to re-run smoke tests..." -ForegroundColor Cyan
    Start-Sleep -Seconds 2
}

# ============================================================
# BUILD FINAL REPORTS
# ============================================================

Write-Host "`n--- Building Final Reports ---" -ForegroundColor Yellow

$overallDuration = ((Get-Date) - $overallStartTime).TotalMinutes

# Structured report
$report = @{
    generated_at     = (Get-Date -Format "o")
    repo             = $RepoRoot
    duration_minutes = [math]::Round($overallDuration, 1)
    cycles_completed = $cycle
    max_cycles       = $MaxCycles
    fix_model        = $FixModel
    cost_optimize    = $CostOptimize
    total_issues     = $allIssues.Count
    by_severity      = $bySeverity
    cycle_history    = $cycleHistory
    phase_results    = @()
    issues           = $allIssues
}

foreach ($pr in $phaseResults) {
    $report.phase_results += @{
        phase   = $pr.phase
        status  = $pr.status
        summary = $pr.summary
        issue_count = if ($pr.issues) { $pr.issues.Count } else { 0 }
    }
}

$reportPath = Join-Path $smokeDir "smoke-test-report.json"
$report | ConvertTo-Json -Depth 10 | Set-Content $reportPath -Encoding UTF8
Write-Log "Report saved: $reportPath" "OK"

# Markdown summary
$summaryLines = @()
$summaryLines += "# Smoke Test Report"
$summaryLines += ""
$summaryLines += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$summaryLines += "Repo: ``$repoName``"
$summaryLines += "Duration: $([math]::Round($overallDuration, 1)) min | Cycles: $cycle / $MaxCycles | Fix model: $FixModel"
$summaryLines += ""
$summaryLines += "## Phase Results"
$summaryLines += ""
$summaryLines += "| # | Phase | Status | Issues | Summary |"
$summaryLines += "|---|-------|--------|--------|---------|"
$phaseNum = 1
foreach ($pr in $phaseResults) {
    $statusEmoji = switch ($pr.status) { "pass" { "PASS" } "fail" { "FAIL" } "warn" { "WARN" } "skip" { "SKIP" } default { "?" } }
    $issueCount = if ($pr.issues) { $pr.issues.Count } else { 0 }
    $shortSummary = if ($pr.summary -and $pr.summary.Length -gt 60) { $pr.summary.Substring(0, 57) + "..." } else { $pr.summary }
    $summaryLines += "| $phaseNum | $($pr.phase) | $statusEmoji | $issueCount | $shortSummary |"
    $phaseNum++
}

$summaryLines += ""
$summaryLines += "## Cycle History"
$summaryLines += ""
$summaryLines += "| Cycle | Total | Critical | High | Medium | Low | Fixable |"
$summaryLines += "|-------|-------|----------|------|--------|-----|---------|"
foreach ($ch in $cycleHistory) {
    $summaryLines += "| $($ch.cycle) | $($ch.total_issues) | $($ch.critical) | $($ch.high) | $($ch.medium) | $($ch.low) | $($ch.fixable) |"
}

$summaryLines += ""
$summaryLines += "## Issue Summary"
$summaryLines += ""
$summaryLines += "| Severity | Count |"
$summaryLines += "|----------|-------|"
$summaryLines += "| Critical | $($bySeverity.critical) |"
$summaryLines += "| High | $($bySeverity.high) |"
$summaryLines += "| Medium | $($bySeverity.medium) |"
$summaryLines += "| Low | $($bySeverity.low) |"

# Critical/High detail
$criticalHigh = @($allIssues | Where-Object { $_.severity -in @("critical","high") })
if ($criticalHigh.Count -gt 0) {
    $summaryLines += ""
    $summaryLines += "## Critical & High Issues"
    $summaryLines += ""
    foreach ($issue in $criticalHigh) {
        $summaryLines += "### [$($issue.severity)] $($issue.category)"
        if ($issue.file) { $summaryLines += "- **File**: ``$($issue.file)``" }
        $summaryLines += "- **Phase**: $($issue.phase)"
        $summaryLines += "- **Issue**: $($issue.description)"
        if ($issue.fix_suggestion) { $summaryLines += "- **Fix**: $($issue.fix_suggestion)" }
        $summaryLines += ""
    }
}

$summaryPath = Join-Path $smokeDir "smoke-test-summary.md"
$summaryLines -join "`n" | Set-Content $summaryPath -Encoding UTF8
Write-Log "Summary saved: $summaryPath" "OK"

# Gap report (categorized by type)
$gapLines = @()
$gapLines += "# Integration Gap Report"
$gapLines += ""
$gapLines += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$gapLines += "Repo: ``$repoName``"
$gapLines += ""

$categories = @("build_error", "db_gap", "api_gap", "frontend_gap", "auth_gap", "module_gap", "mock_data", "rbac_gap")
foreach ($cat in $categories) {
    $catIssues = @($allIssues | Where-Object { $_.category -eq $cat })
    if ($catIssues.Count -eq 0) { continue }

    $gapLines += "## $($cat -replace '_', ' ' -replace '(?<=\b)\w', { $_.Value.ToUpper() })"
    $gapLines += ""
    $gapLines += "| Severity | File | Description | Fix Suggestion |"
    $gapLines += "|----------|------|-------------|----------------|"
    foreach ($issue in $catIssues) {
        $shortDesc = if ($issue.description.Length -gt 60) { $issue.description.Substring(0, 57) + "..." } else { $issue.description }
        $shortFix = if ($issue.fix_suggestion -and $issue.fix_suggestion.Length -gt 60) { $issue.fix_suggestion.Substring(0, 57) + "..." } else { $issue.fix_suggestion }
        $file = if ($issue.file) { Split-Path $issue.file -Leaf } else { "-" }
        $gapLines += "| $($issue.severity) | $file | $shortDesc | $shortFix |"
    }
    $gapLines += ""
}

# Uncategorized issues
$uncategorized = @($allIssues | Where-Object { $_.category -notin $categories })
if ($uncategorized.Count -gt 0) {
    $gapLines += "## Other Issues"
    $gapLines += ""
    $gapLines += "| Severity | Category | File | Description |"
    $gapLines += "|----------|----------|------|-------------|"
    foreach ($issue in $uncategorized) {
        $shortDesc = if ($issue.description.Length -gt 60) { $issue.description.Substring(0, 57) + "..." } else { $issue.description }
        $file = if ($issue.file) { Split-Path $issue.file -Leaf } else { "-" }
        $gapLines += "| $($issue.severity) | $($issue.category) | $file | $shortDesc |"
    }
    $gapLines += ""
}

$gapPath = Join-Path $smokeDir "gap-report.md"
$gapLines -join "`n" | Set-Content $gapPath -Encoding UTF8
Write-Log "Gap report saved: $gapPath" "OK"

# ============================================================
# PRINT FINAL STATS
# ============================================================

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  SMOKE TEST COMPLETE" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Cycles:   $cycle / $MaxCycles" -ForegroundColor White
Write-Host "  Duration: $([math]::Round($overallDuration, 1)) min" -ForegroundColor White
Write-Host "" -NoNewline

$finalTotal = $allIssues.Count
Write-Host "  Final issues: $finalTotal" -ForegroundColor $(if ($finalTotal -eq 0) { "Green" } else { "Yellow" })

$critColor = if ($bySeverity.critical -gt 0) { "Red" } else { "Green" }
$highColor = if ($bySeverity.high -gt 0) { "Yellow" } else { "Green" }
Write-Host "    Critical: $($bySeverity.critical)" -ForegroundColor $critColor
Write-Host "    High:     $($bySeverity.high)" -ForegroundColor $highColor
Write-Host "    Medium:   $($bySeverity.medium)" -ForegroundColor White
Write-Host "    Low:      $($bySeverity.low)" -ForegroundColor DarkGray

Write-Host "" -NoNewline
Write-Host "  Phase breakdown:" -ForegroundColor White
foreach ($pr in $phaseResults) {
    $statusColor = switch ($pr.status) { "pass" { "Green" } "fail" { "Red" } "warn" { "Yellow" } "skip" { "DarkGray" } default { "White" } }
    $issueCount = if ($pr.issues) { $pr.issues.Count } else { 0 }
    Write-Host "    $($pr.phase): $($pr.status.ToUpper()) ($issueCount issues)" -ForegroundColor $statusColor
}

Write-Host "" -NoNewline
Write-Host "  Report:     $reportPath" -ForegroundColor DarkGray
Write-Host "  Summary:    $summaryPath" -ForegroundColor DarkGray
Write-Host "  Gap Report: $gapPath" -ForegroundColor DarkGray

if (Get-Command Get-TotalCost -ErrorAction SilentlyContinue) {
    Write-Host "  Cost:       `$$(Get-TotalCost)" -ForegroundColor DarkGray
}

# Cost optimization summary
if ($CostOptimize) {
    Write-Host "" -NoNewline
    Write-Host "  === Cost Optimization Summary ===" -ForegroundColor Cyan
    $localTasks  = $script:tasksByTier["local"]
    $cheapTasks  = $script:tasksByTier["cheap"]
    $midTasks    = $script:tasksByTier["mid"]
    $premiumTasks = $script:tasksByTier["premium"]
    $cheapCost   = [math]::Round($script:costByTier["cheap"], 4)
    $midCost     = [math]::Round($script:costByTier["mid"], 4)
    $premiumCost = [math]::Round($script:costByTier["premium"], 4)
    $totalTieredCost = [math]::Round($cheapCost + $midCost + $premiumCost, 4)
    # Estimate what it would cost if everything used premium
    $allPremiumEstimate = [math]::Round(($script:costByTier["cheap"] / [math]::Max(0.01, 0.21) * 9.0) + ($script:costByTier["mid"] / [math]::Max(0.01, 1.50) * 9.0) + $premiumCost, 4)
    $saved = [math]::Round([math]::Max(0, $allPremiumEstimate - $totalTieredCost), 4)

    Write-Host "  Local (free):     $localTasks task(s), `$0.00" -ForegroundColor Green
    Write-Host "  Cheap (DeepSeek): $cheapTasks task(s), `$$cheapCost" -ForegroundColor Green
    Write-Host "  Mid (Codex):      $midTasks task(s), `$$midCost" -ForegroundColor Yellow
    Write-Host "  Premium (Claude): $premiumTasks task(s), `$$premiumCost" -ForegroundColor Red
    Write-Host "  Total:            `$$totalTieredCost (saved ~`$$saved vs all-premium)" -ForegroundColor Cyan

    Write-Log "Cost summary: Local=$localTasks Cheap=$cheapTasks/$cheapCost Mid=$midTasks/$midCost Premium=$premiumTasks/$premiumCost Total=$totalTieredCost Saved=$saved" "OK"

    # Also save to report
    $costSummary = @{
        tiers = @{
            local   = @{ tasks = $localTasks; cost = 0 }
            cheap   = @{ tasks = $cheapTasks; cost = $cheapCost }
            mid     = @{ tasks = $midTasks; cost = $midCost }
            premium = @{ tasks = $premiumTasks; cost = $premiumCost }
        }
        total_cost = $totalTieredCost
        estimated_savings = $saved
    }
    $costSummaryPath = Join-Path $smokeDir "cost-summary.json"
    $costSummary | ConvertTo-Json -Depth 5 | Set-Content $costSummaryPath -Encoding UTF8
}

Write-Host "============================================`n" -ForegroundColor Cyan

# Return exit code: 0 if no critical/high issues remain, 1 otherwise
exit $(if (($bySeverity.critical + $bySeverity.high) -gt 0) { 1 } else { 0 })
