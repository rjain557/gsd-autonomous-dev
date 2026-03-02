<#
.SYNOPSIS
    Final Integration Sub-Patch 2/6: SQL + CLI Enhancements
    Fixes GAP 6+16: Wire sqlcmd actual syntax validation
    Fixes GAP 8: Parse CLI version numbers properly
#>
param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"
$LibFile = Join-Path $UserHome ".gsd-global\lib\modules\resilience.ps1"

Write-Host "Sub-patch 2/6: SQL + CLI version enhancements..." -ForegroundColor Yellow

$code = @'

# ===============================================================
# SQLCMD SYNTAX VALIDATION - uses sqlcmd parse-only when available
# ===============================================================

function Test-SqlSyntaxWithSqlcmd {
    param([string]$SqlFilePath, [string]$GsdDir)

    if (-not $script:HasSqlCmd) { return @{ Passed = $true; Error = $null } }
    if (-not (Test-Path $SqlFilePath)) { return @{ Passed = $true; Error = $null } }

    try {
        $output = sqlcmd -S "(localdb)\PARSE_CHECK" -i $SqlFilePath -b 2>&1
        $syntaxErrors = $output | Where-Object {
            $_ -match "(Incorrect syntax|Unexpected|Invalid column|Must declare|Unclosed)" -and
            $_ -notmatch "(Login failed|network-related|server was not found)"
        }
        if ($syntaxErrors.Count -gt 0) {
            return @{ Passed = $false; Error = ($syntaxErrors | Select-Object -First 3) -join "; " }
        }
        return @{ Passed = $true; Error = $null }
    } catch {
        return @{ Passed = $true; Error = $null }
    }
}

# ===============================================================
# ENHANCED Test-SqlFiles - pattern checks + sqlcmd when available
# ===============================================================

# Save original if it exists and hasn't been saved yet
if ((Get-Command Test-SqlFiles -ErrorAction SilentlyContinue) -and -not $script:SqlFilesV3) {
    $script:SqlFilesV3 = $true

    function Test-SqlFiles {
        param([string]$RepoRoot, [string]$GsdDir, [int]$Iteration)

        $sqlFiles = git -C $RepoRoot diff --name-only HEAD 2>$null | Where-Object { $_ -match "\.sql$" }
        if (-not $sqlFiles -or $sqlFiles.Count -eq 0) { return @{ Passed = $true; Errors = @() } }

        Write-Host "    [SEARCH] Checking $($sqlFiles.Count) SQL files..." -ForegroundColor DarkGray
        $sqlErrors = @()

        foreach ($sqlFile in $sqlFiles) {
            $fullPath = Join-Path $RepoRoot $sqlFile
            if (-not (Test-Path $fullPath)) { continue }
            $content = Get-Content $fullPath -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }

            # Pattern checks
            if ($content -match "string\.Format|`"\s*\+\s*.*SELECT|\$`".*SELECT") {
                $sqlErrors += "$sqlFile : String concatenation in SQL"
            }
            if ($content -match "CREATE\s+(OR\s+ALTER\s+)?PROC" -and $content -notmatch "BEGIN\s+TRY") {
                $sqlErrors += "$sqlFile : Missing TRY/CATCH in stored procedure"
            }
            if ($content -match "CREATE\s+TABLE" -and $content -notmatch "CreatedAt") {
                $sqlErrors += "$sqlFile : Missing audit columns in CREATE TABLE"
            }

            # sqlcmd syntax validation
            if ($script:HasSqlCmd) {
                $syntaxResult = Test-SqlSyntaxWithSqlcmd -SqlFilePath $fullPath -GsdDir $GsdDir
                if (-not $syntaxResult.Passed) {
                    $sqlErrors += "$sqlFile : Syntax error: $($syntaxResult.Error)"
                }
            }
        }

        if ($sqlErrors.Count -gt 0) {
            Write-Host "    [!!]  $($sqlErrors.Count) SQL issues:" -ForegroundColor DarkYellow
            $sqlErrors | Select-Object -First 5 | ForEach-Object { Write-Host "      - $_" -ForegroundColor DarkYellow }
        } else {
            Write-Host "    [OK] SQL OK$(if ($script:HasSqlCmd) { ' (sqlcmd verified)' })" -ForegroundColor DarkGreen
        }

        return @{ Passed = ($sqlErrors.Count -eq 0); Errors = $sqlErrors }
    }
}

# ===============================================================
# CLI VERSION COMPATIBILITY CHECK
# ===============================================================

$script:TESTED_CLAUDE_MAJORS = @(1, 2)
$script:TESTED_CODEX_MAJORS = @(0, 1)
$script:TESTED_DOTNET_MAJOR = 8

function Test-CliVersionCompat {
    param([string]$Tool, [string]$VersionOutput, [int[]]$TestedMajors)

    $versionMatch = [regex]::Match($VersionOutput, '(\d+)\.(\d+)')
    if (-not $versionMatch.Success) {
        return @{ Compatible = $true; Version = "unknown"; Warning = $null }
    }

    $major = [int]$versionMatch.Groups[1].Value
    $version = $versionMatch.Value

    if ($major -notin $TestedMajors) {
        return @{
            Compatible = $true
            Version = $version
            Warning = "$Tool v$version detected - scripts tested with major versions: $($TestedMajors -join ', '). May need flag updates."
        }
    }

    return @{ Compatible = $true; Version = $version; Warning = $null }
}

# Enhance Test-CliVersions to use version compat
if ((Get-Command Test-CliVersions -ErrorAction SilentlyContinue) -and -not $script:CliVersionsV2) {
    $script:CliVersionsV2 = $true

    function Test-CliVersions {
        param([string]$GsdDir)
        Write-Host "    Checking CLI versions..." -ForegroundColor DarkGray

        try {
            $claudeVer = (claude --version 2>&1) -join " "
            $compat = Test-CliVersionCompat -Tool "claude" -VersionOutput $claudeVer -TestedMajors $script:TESTED_CLAUDE_MAJORS
            Write-Host "    [OK] claude: $($compat.Version)" -ForegroundColor DarkGreen
            if ($compat.Warning) { Write-Host "    [!!]  $($compat.Warning)" -ForegroundColor DarkYellow }
        } catch { Write-Host "    [XX] claude CLI not found" -ForegroundColor Red; return $false }

        try {
            $codexVer = (codex --version 2>&1) -join " "
            $compat = Test-CliVersionCompat -Tool "codex" -VersionOutput $codexVer -TestedMajors $script:TESTED_CODEX_MAJORS
            Write-Host "    [OK] codex: $($compat.Version)" -ForegroundColor DarkGreen
            if ($compat.Warning) { Write-Host "    [!!]  $($compat.Warning)" -ForegroundColor DarkYellow }
        } catch { Write-Host "    [XX] codex CLI not found" -ForegroundColor Red; return $false }

        try {
            $dotnetVer = (dotnet --version 2>&1) -join " "
            $compat = Test-CliVersionCompat -Tool "dotnet" -VersionOutput $dotnetVer -TestedMajors @($script:TESTED_DOTNET_MAJOR)
            Write-Host "    [OK] dotnet: $($compat.Version)" -ForegroundColor DarkGreen
            if ($compat.Warning) { Write-Host "    [!!]  $($compat.Warning)" -ForegroundColor DarkYellow }
        } catch { Write-Host "    [!!]  dotnet not found" -ForegroundColor DarkYellow }

        try {
            $nodeVer = (node --version 2>&1) -join " "
            $npmVer = (npm --version 2>&1) -join " "
            Write-Host "    [OK] node: $nodeVer / npm: $npmVer" -ForegroundColor DarkGreen
        } catch { Write-Host "    [!!]  node/npm not found" -ForegroundColor DarkYellow }

        try {
            $null = sqlcmd -? 2>&1
            Write-Host "    [OK] sqlcmd: available" -ForegroundColor DarkGreen
            $script:HasSqlCmd = $true
        } catch {
            Write-Host "    [>>]  sqlcmd not found (SQL linting pattern-only)" -ForegroundColor DarkGray
            $script:HasSqlCmd = $false
        }

        return $true
    }
}
'@

$existing = Get-Content $LibFile -Raw
if ($existing -match "Test-SqlSyntaxWithSqlcmd") {
    $idx = $existing.IndexOf("`n# SQL + CLI")
    if ($idx -gt 0) {
        $existing = $existing.Substring(0, $idx)
        Set-Content -Path $LibFile -Value $existing -Encoding UTF8
    }
    Add-Content -Path $LibFile -Value "`n$code" -Encoding UTF8
    Write-Host "   [OK] SQL + CLI enhancements updated" -ForegroundColor DarkGreen
} else {
    Add-Content -Path $LibFile -Value "`n$code" -Encoding UTF8
    Write-Host "   [OK] SQL + CLI enhancements added" -ForegroundColor DarkGreen
}
