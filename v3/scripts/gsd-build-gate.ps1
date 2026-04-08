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

function Get-PreferredBackendProject {
    $preferredPaths = @(
        (Join-Path $RepoRoot "src\\Server\\Technijian.Api\\Technijian.Api.csproj"),
        (Join-Path $RepoRoot "src\\backend\\Technijian.Api\\Technijian.Api.csproj")
    )

    foreach ($candidate in $preferredPaths) {
        if (Test-Path $candidate) {
            return @(Get-Item $candidate)
        }
    }

    return @(Get-ChildItem -Path $RepoRoot -Filter "*.csproj" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(bin|obj|node_modules|design|generated|\.gsd|\.git|wwwroot)\\' } |
        Where-Object { $_.Name -notmatch '\.(Tests|IntegrationTests|UnitTests)\.' } |
        Sort-Object FullName |
        Select-Object -First 1)
}

function Get-PreferredPackageJsonFiles {
    $preferredPaths = @(
        (Join-Path $RepoRoot "package.json"),
        (Join-Path $RepoRoot "src\\web\\package.json"),
        (Join-Path $RepoRoot "src\\Client\\technijian-spa\\package.json")
    )

    $resolved = @()
    foreach ($candidate in $preferredPaths) {
        if (Test-Path $candidate) {
            $resolved += Get-Item $candidate
        }
    }

    if ($resolved.Count -gt 0) {
        return @($resolved | Sort-Object FullName -Unique)
    }

    return @(Get-ChildItem -Path $RepoRoot -Filter "package.json" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(bin|obj|node_modules|design|generated|\.gsd|\.git|wwwroot)\\' } |
        Sort-Object FullName |
        Select-Object -First 1)
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

$csprojFiles = @(Get-PreferredBackendProject | Where-Object { $_ })
$packageJsonFiles = @(Get-PreferredPackageJsonFiles | Where-Object {
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
        $buildOutput = & dotnet build $CsprojPath -c Release 2>&1 | Out-String
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
        $previousCi = $env:CI
        $previousBrowser = $env:BROWSER
        $env:CI = "1"
        $env:BROWSER = "none"
        $buildOutput = & npm run build 2>&1 | Out-String
        $npmExitCode = $LASTEXITCODE
    } catch {
        $buildOutput = $_.Exception.Message
    } finally {
        $env:CI = $previousCi
        $env:BROWSER = $previousBrowser
        Pop-Location
    }

    $hasErrors = ($npmExitCode -ne 0) -or ($buildOutput -match 'error TS') -or ($buildOutput -match 'error during build:') -or ($buildOutput -match 'Build failed') -or ($buildOutput -match 'Failed to compile')
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
        $result = Invoke-SonnetApi -SystemPrompt $systemPrompt -UserMessage $userMessage -MaxTokens 16384 -Phase "build-gate-fix"
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
# STARTUP VALIDATION (DI CHECK)
# ============================================================

# After build passes, try to start the app briefly to catch DI registration failures
if ($overallPass -and $csprojFiles.Count -gt 0) {
    Write-Log "--- Startup Validation (DI Check) ---"

    # Find the main API project (prefer *.Api.csproj with Program.cs)
    $mainCsproj = $csprojFiles | Where-Object {
        $_.Name -match '\.Api\.csproj$' -and (Test-Path (Join-Path (Split-Path $_.FullName -Parent) "Program.cs"))
    } | Select-Object -First 1
    if (-not $mainCsproj) {
        $mainCsproj = $csprojFiles | Where-Object {
            Test-Path (Join-Path (Split-Path $_.FullName -Parent) "Program.cs")
        } | Select-Object -First 1
    }
    if (-not $mainCsproj) { $mainCsproj = $csprojFiles[0] }

    Write-Log "Running startup validation against $($mainCsproj.Name)..."

    $startupJob = Start-Job -ScriptBlock {
        param($CsprojPath)
        $env:ASPNETCORE_ENVIRONMENT = "Development"
        $env:ASPNETCORE_URLS = "http://localhost:0"  # random port to avoid conflicts
        $output = & dotnet run --project $CsprojPath --no-build 2>&1
        return $output -join "`n"
    } -ArgumentList $mainCsproj.FullName

    $completed = Wait-Job $startupJob -Timeout 15
    if ($completed) {
        $startupOutput = Receive-Job $startupJob
        Remove-Job $startupJob -Force

        # Check for DI resolution failures
        $diFailure = $false
        if ($startupOutput -match "Unable to resolve service|No service for type|InvalidOperationException.*registered|AggregateException.*resolution") {
            $diFailure = $true
            $missingServices = [regex]::Matches($startupOutput, "Unable to resolve service for type '([^']+)'") |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
            $noServiceTypes = [regex]::Matches($startupOutput, "No service for type '([^']+)'") |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
            $allMissing = @($missingServices) + @($noServiceTypes) | Sort-Object -Unique

            Write-Log "STARTUP FAILED: $($allMissing.Count) missing DI registration(s)" -Level ERROR
            foreach ($svc in $allMissing) {
                Write-Log "  Missing: $svc" -Level ERROR
            }

            # Save DI errors for downstream fix
            $diErrorFile = Join-Path $GsdDir "build-gate/di-errors.json"
            $diErrorDir = Split-Path $diErrorFile -Parent
            if (-not (Test-Path $diErrorDir)) { New-Item -ItemType Directory -Path $diErrorDir -Force | Out-Null }
            @{
                timestamp = (Get-Date -Format "o")
                missing_services = $allMissing
                raw_output = ($startupOutput | Select-Object -First 100) -join "`n"
                project = $mainCsproj.Name
            } | ConvertTo-Json -Depth 5 | Set-Content $diErrorFile -Encoding UTF8

            # Attempt auto-fix: ask LLM to generate DI registrations
            if ($attempt -le $MaxAttempts) {
                $programCsPath = Join-Path (Split-Path $mainCsproj.FullName -Parent) "Program.cs"
                $startupCsPath = Join-Path (Split-Path $mainCsproj.FullName -Parent) "Startup.cs"
                $diContext = ""
                if (Test-Path $programCsPath) {
                    $diContext += "`n--- FILE: $programCsPath ---`n$(Get-Content $programCsPath -Raw)`n"
                }
                if (Test-Path $startupCsPath) {
                    $diContext += "`n--- FILE: $startupCsPath ---`n$(Get-Content $startupCsPath -Raw)`n"
                }

                $diSystemPrompt = "You are a DI registration fixer for .NET 8. Given missing service types and the Program.cs/Startup.cs file, output ONLY a JSON array of fixes. Each fix: {""file_path"": ""absolute path"", ""old_text"": ""exact text to replace"", ""new_text"": ""replacement text""}. Add the missing AddScoped/AddTransient/AddSingleton registrations. Common fixes: IDbConnection -> SqlConnection, IConnectionMultiplexer -> ConnectionMultiplexer.Connect, BlobServiceClient -> new BlobServiceClient(connStr). No markdown, no explanation - just the JSON array."
                $diUserMessage = "MISSING DI SERVICES:`n$($allMissing -join "`n")`n`nSTARTUP ERROR OUTPUT:`n$($startupOutput | Select-Object -First 50)`n`nSOURCE FILES:`n$diContext`n`nGenerate fixes as a JSON array."

                Write-Log "Requesting DI fix from $FixModel..." -Level FIX
                $fixJson = $null
                if ($FixModel -eq "claude") {
                    $result = Invoke-SonnetApi -SystemPrompt $diSystemPrompt -UserMessage $diUserMessage -MaxTokens 16384 -Phase "build-gate-di-fix"
                    if ($result -and $result.Success) { $fixJson = $result.Text }
                } else {
                    $result = Invoke-CodexMiniApi -SystemPrompt $diSystemPrompt -UserMessage $diUserMessage -MaxTokens 8192 -Phase "build-gate-di-fix"
                    if ($result -and $result.Success) { $fixJson = $result.Text }
                }

                if ($fixJson) {
                    $fixJson = $fixJson.Trim()
                    $fixJson = $fixJson -replace '(?s)^```(?:json)?\s*\n', '' -replace '\n```\s*$', ''
                    if ($fixJson -match '(?s)(\[[\s\S]*\])') { $fixJson = $matches[1] }
                    try {
                        $diFixes = $fixJson | ConvertFrom-Json
                        $applied = Apply-Fixes -Fixes @($diFixes)
                        Write-Log "Applied $applied DI fix(es)" -Level FIX

                        if ($applied -gt 0) {
                            # Re-build after DI fixes
                            Write-Log "Re-building after DI fixes..."
                            $rebuildResult = Invoke-DotnetBuild -CsprojPath $mainCsproj.FullName
                            if ($rebuildResult.success) {
                                Write-Log "Rebuild after DI fix: PASS" -Level OK
                            } else {
                                Write-Log "Rebuild after DI fix: FAIL - $($rebuildResult.errors.Count) error(s)" -Level ERROR
                                $overallPass = $false
                            }
                        }
                    } catch {
                        Write-Log "Failed to parse DI fix JSON: $($_.Exception.Message)" -Level WARN
                    }
                } else {
                    Write-Log "DI fix model returned no response" -Level WARN
                }
            }

            $overallPass = $false
        } elseif ($startupOutput -match "Unhandled exception|Application startup exception|Host terminated unexpectedly") {
            Write-Log "STARTUP FAILED: Application threw exception during startup" -Level ERROR
            # Log first 10 lines of error
            $errorLines = ($startupOutput -split "`n" | Where-Object { $_ -match 'Exception|Error|Unhandled|terminated' } | Select-Object -First 10)
            foreach ($line in $errorLines) {
                Write-Log "  $line" -Level ERROR
            }
            $overallPass = $false
        } else {
            # Process exited but no DI error — could be other startup failure
            Write-Log "Startup process exited (checking output)..." -Level WARN
        }
    } else {
        # App is still running after 15s — means it started successfully (no crash)
        Stop-Job $startupJob
        Remove-Job $startupJob -Force
        Write-Log "Startup validation: PASS (no DI errors detected)" -Level OK
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
    di_check = @{
        ran = ($overallPass -or $diFailure)
        passed = (-not $diFailure)
        missing_services = if ($allMissing) { @($allMissing) } else { @() }
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
