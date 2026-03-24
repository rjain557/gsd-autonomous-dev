<#
.SYNOPSIS
    GSD V3 Build Gate - Compile check + auto-fix loop
.DESCRIPTION
    Runs dotnet build and npm run build, captures errors, and uses an LLM to
    generate fixes. Retries up to MaxAttempts times.

    Usage:
      pwsh -File gsd-build-gate.ps1 -RepoRoot "D:\repos\project"
      pwsh -File gsd-build-gate.ps1 -RepoRoot "D:\repos\project" -FixModel codex -MaxAttempts 5
.PARAMETER RepoRoot
    Repository root path (mandatory)
.PARAMETER FixModel
    Model used for generating fixes: claude or codex (default: "claude")
.PARAMETER MaxAttempts
    Maximum build-fix attempts before stopping (default: 3)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [ValidateSet("claude","codex")]
    [string]$FixModel = "claude",
    [int]$MaxAttempts = 3
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
$globalLogDir = Join-Path $env:USERPROFILE ".gsd-global/logs/${repoName}"
if (-not (Test-Path $globalLogDir)) { New-Item -ItemType Directory -Path $globalLogDir -Force | Out-Null }

$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$logFile = Join-Path $globalLogDir "build-gate-${timestamp}.log"

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
        default { "White" }
    }
    Write-Host "  $entry" -ForegroundColor $color
}

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

# Load config
$configPath = Join-Path $v3Dir "config/global-config.json"
if (Test-Path $configPath) {
    $Config = Get-Content $configPath -Raw | ConvertFrom-Json
}

# Initialize cost tracking
if (Get-Command Initialize-CostTracker -ErrorAction SilentlyContinue) {
    Initialize-CostTracker -Mode "build_gate" -BudgetCap 5.0 -GsdDir $GsdDir
}

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  GSD V3 - Build Gate" -ForegroundColor Cyan
Write-Host "  Repo: $RepoRoot" -ForegroundColor DarkGray
Write-Host "  Fix model: $FixModel | MaxAttempts: $MaxAttempts" -ForegroundColor DarkGray
Write-Host "  Log: $logFile" -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor Cyan

# ============================================================
# DISCOVER BUILD TARGETS
# ============================================================

# Exclude non-production directories (design prototypes, generated refs, test projects are optional)
$excludeDirPattern = '\\(bin|obj|node_modules|design|generated|\.gsd|\.git|wwwroot)\\'

$csprojFiles = @(Get-ChildItem -Path $RepoRoot -Filter "*.csproj" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch $excludeDirPattern } |
    Where-Object { $_.Name -notmatch '\.(Tests|IntegrationTests|UnitTests)\.' })  # Skip test projects - match on filename
$packageJsonFiles = @(Get-ChildItem -Path $RepoRoot -Filter "package.json" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch $excludeDirPattern } |
    Where-Object {
        $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
        $content -and ($content -match '"build"')
    })

Write-Log "Found $($csprojFiles.Count) .csproj file(s) and $($packageJsonFiles.Count) package.json with build script(s)"

if ($csprojFiles.Count -eq 0 -and $packageJsonFiles.Count -eq 0) {
    Write-Log "No build targets found - nothing to gate" -Level WARN
    $result = @{
        status = "skip"
        message = "No build targets found"
        dotnet = @{ found = $false }
        npm = @{ found = $false }
    }
    $outDir = Join-Path $GsdDir "build-gate"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $result | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $outDir "build-gate-report.json") -Encoding UTF8
    exit 0
}

# ============================================================
# BUILD FUNCTIONS
# ============================================================

function Invoke-DotnetBuild {
    param([string]$CsprojPath)
    $projDir = Split-Path $CsprojPath -Parent
    $projName = Split-Path $CsprojPath -Leaf
    Write-Log "Building dotnet: $projName"

    $buildOutput = ""
    try {
        $buildOutput = & dotnet build $CsprojPath --no-restore 2>&1 | Out-String
    } catch {
        $buildOutput = $_.Exception.Message
    }

    $hasErrors = ($buildOutput -match 'Build FAILED') -or ($buildOutput -match ': error ')
    $errorLines = @()
    if ($hasErrors) {
        $errorLines = @($buildOutput -split "`n" | Where-Object { $_ -match ': error ' -or $_ -match ': warning ' } | Select-Object -First 30)
    }
    return @{
        project = $projName
        directory = $projDir
        output = $buildOutput
        success = -not $hasErrors
        errors = $errorLines
    }
}

function Invoke-NpmBuild {
    param([string]$PackageJsonPath)
    $projDir = Split-Path $PackageJsonPath -Parent
    Write-Log "Building npm: $projDir"

    $buildOutput = ""
    try {
        Push-Location $projDir
        $buildOutput = & npm run build 2>&1 | Out-String
    } catch {
        $buildOutput = $_.Exception.Message
    } finally {
        Pop-Location
    }

    $hasErrors = ($LASTEXITCODE -ne 0) -or ($buildOutput -match 'ERROR in') -or ($buildOutput -match 'error TS')
    $errorLines = @()
    if ($hasErrors) {
        $errorLines = @($buildOutput -split "`n" |
            Where-Object { $_ -match 'ERROR|error TS|Cannot find|Module not found|Failed to compile' } |
            Select-Object -First 30)
    }
    return @{
        project = $projDir
        directory = $projDir
        output = $buildOutput
        success = -not $hasErrors
        errors = $errorLines
    }
}

# ============================================================
# FIX GENERATION
# ============================================================

function Invoke-BuildFix {
    param(
        [string]$ErrorText,
        [string]$ProjectDir
    )

    # Gather context files referenced in error messages
    $referencedFiles = @()
    $errorFileMatches = [regex]::Matches($ErrorText, '([A-Za-z]:\\[^\s:]+\.\w+)|([^\s:]+\.(cs|tsx?|jsx?))')
    foreach ($m in $errorFileMatches) {
        $filePath = $m.Value
        if (-not [System.IO.Path]::IsPathRooted($filePath)) {
            $filePath = Join-Path $ProjectDir $filePath
        }
        if ((Test-Path $filePath) -and $filePath -notin $referencedFiles) {
            $referencedFiles += $filePath
        }
    }

    # Read up to 5 referenced files (truncated)
    $fileContext = ""
    $filesRead = 0
    foreach ($fp in ($referencedFiles | Select-Object -First 5)) {
        $content = Get-Content $fp -Raw -ErrorAction SilentlyContinue
        if ($content) {
            $truncated = if ($content.Length -gt 3000) { $content.Substring(0, 3000) + "`n... (truncated)" } else { $content }
            $fileContext += "`n--- FILE: $fp ---`n$truncated`n"
            $filesRead++
        }
    }

    $systemPrompt = "You are a build error fixer. Given build errors and source files, output ONLY a JSON array of fixes. Each fix: {""file_path"": ""absolute path"", ""old_text"": ""exact text to replace"", ""new_text"": ""replacement text""}. No markdown, no explanation - just the JSON array."

    $userMessage = "BUILD ERRORS:`n$ErrorText`n`nSOURCE FILES ($filesRead files):`n$fileContext`n`nGenerate fixes as a JSON array."

    Write-Log "Requesting fix from $FixModel ($filesRead source files)" -Level FIX

    $fixJson = $null
    if ($FixModel -eq "claude") {
        $result = Invoke-SonnetApi -SystemPrompt $systemPrompt -UserMessage $userMessage -MaxTokens 8192 -Phase "build-gate-fix"
        if ($result -and $result.Success) { $fixJson = $result.Text }
    } else {
        $result = Invoke-CodexMiniApi -SystemPrompt $systemPrompt -UserMessage $userMessage -MaxTokens 8192 -Phase "build-gate-fix"
        if ($result -and $result.Success) { $fixJson = $result.Text }
    }

    if (-not $fixJson) {
        Write-Log "Fix model returned no response" -Level WARN
        return @()
    }

    # Parse JSON — strip markdown fences and any text before/after the JSON array
    $fixJson = $fixJson.Trim()
    # Remove markdown code fences
    $fixJson = $fixJson -replace '(?s)^```(?:json)?\s*\n', '' -replace '\n```\s*$', ''
    # Extract JSON array from response (Claude often adds text before/after)
    if ($fixJson -match '(?s)(\[[\s\S]*\])') {
        $fixJson = $matches[1]
    }
    try {
        $fixes = $fixJson | ConvertFrom-Json
        return @($fixes)
    } catch {
        Write-Log "Failed to parse fix JSON: $($_.Exception.Message)" -Level WARN
        Write-Log "Raw response (first 200 chars): $($fixJson.Substring(0, [Math]::Min(200, $fixJson.Length)))" -Level WARN
        return @()
    }
}

function Apply-Fixes {
    param([array]$Fixes)
    $applied = 0
    foreach ($fix in $Fixes) {
        $filePath = $fix.file_path
        if (-not $filePath -or -not (Test-Path $filePath)) {
            Write-Log "Fix target not found: $filePath" -Level WARN
            continue
        }
        $content = Get-Content $filePath -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        $oldText = $fix.old_text
        $newText = $fix.new_text
        if (-not $oldText -or -not $content.Contains($oldText)) {
            Write-Log "old_text not found in $filePath - skipping" -Level WARN
            continue
        }

        $content = $content.Replace($oldText, $newText)
        Set-Content $filePath -Value $content -Encoding UTF8 -NoNewline
        Write-Log "Applied fix to $filePath" -Level FIX
        $applied++
    }
    return $applied
}

# ============================================================
# MAIN BUILD-FIX LOOP
# ============================================================

$overallPass = $true
$dotnetResults = @()
$npmResults = @()

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    Write-Log "--- Build attempt $attempt of $MaxAttempts ---"
    $allErrors = @()

    # Dotnet builds
    foreach ($csproj in $csprojFiles) {
        $result = Invoke-DotnetBuild -CsprojPath $csproj.FullName
        if (-not $result.success) {
            Write-Log "FAIL: $($result.project) - $($result.errors.Count) error(s)" -Level ERROR
            $allErrors += @{ type = "dotnet"; project = $result.project; dir = $result.directory; errors = $result.errors }
        } else {
            Write-Log "PASS: $($result.project)" -Level OK
        }
        $dotnetResults = @($result)
    }

    # NPM builds
    foreach ($pkg in $packageJsonFiles) {
        $result = Invoke-NpmBuild -PackageJsonPath $pkg.FullName
        if (-not $result.success) {
            Write-Log "FAIL: npm build in $($result.directory) - $($result.errors.Count) error(s)" -Level ERROR
            $allErrors += @{ type = "npm"; project = $result.project; dir = $result.directory; errors = $result.errors }
        } else {
            Write-Log "PASS: npm build in $($result.directory)" -Level OK
        }
        $npmResults = @($result)
    }

    if ($allErrors.Count -eq 0) {
        Write-Log "All builds passed on attempt $attempt" -Level OK
        $overallPass = $true
        break
    }

    $overallPass = $false

    if ($attempt -lt $MaxAttempts) {
        Write-Log "Build failures found, requesting fixes..." -Level FIX
        foreach ($err in $allErrors) {
            $errorText = $err.errors -join "`n"
            $fixes = Invoke-BuildFix -ErrorText $errorText -ProjectDir $err.dir
            if ($fixes.Count -gt 0) {
                $applied = Apply-Fixes -Fixes $fixes
                Write-Log "Applied $applied fix(es) for $($err.project)" -Level FIX
            } else {
                Write-Log "No fixes generated for $($err.project)" -Level WARN
            }
        }
    }
}

# ============================================================
# OUTPUT REPORT
# ============================================================

$outDir = Join-Path $GsdDir "build-gate"
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$report = @{
    status = if ($overallPass) { "pass" } else { "fail" }
    attempts = $attempt
    max_attempts = $MaxAttempts
    timestamp = (Get-Date -Format "o")
    dotnet = @{
        found = ($csprojFiles.Count -gt 0)
        projects = $csprojFiles.Count
        results = @($dotnetResults | ForEach-Object {
            @{ project = $_.project; success = $_.success; error_count = $_.errors.Count }
        })
    }
    npm = @{
        found = ($packageJsonFiles.Count -gt 0)
        projects = $packageJsonFiles.Count
        results = @($npmResults | ForEach-Object {
            @{ project = $_.project; success = $_.success; error_count = $_.errors.Count }
        })
    }
    fix_model = $FixModel
    log_file = $logFile
}

$report | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $outDir "build-gate-report.json") -Encoding UTF8

$statusColor = if ($overallPass) { "Green" } else { "Red" }
$statusLabel = if ($overallPass) { "PASS" } else { "FAIL" }
Write-Host "`n============================================" -ForegroundColor $statusColor
Write-Host "  Build Gate: $statusLabel (attempt $attempt of $MaxAttempts)" -ForegroundColor $statusColor
Write-Host "  Report: $(Join-Path $outDir 'build-gate-report.json')" -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor $statusColor
