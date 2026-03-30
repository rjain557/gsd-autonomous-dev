<#
.SYNOPSIS
    GSD V3 Database Setup - Discover and execute SQL scripts with LLM-assisted error fixing
.DESCRIPTION
    Discovers SQL files in standard directories within the repo, executes them in order
    using sqlcmd, and uses a cheap LLM (DeepSeek by default) to fix SQL errors on retry.

    Execution order:
      1. db/deploy/01_create_database.sql (master schema)
      2. db/migrations/*.sql (sorted by filename)
      3. db/stored-procedures/*.sql or db/sql/procedures/**/*.sql
      4. db/functions/*.sql
      5. db/seeds/*.sql or db/deploy/*seed*.sql
      6. Verify: count tables, SPs, functions

    Outputs to .gsd/database-setup/
.PARAMETER RepoRoot
    Repository root path (mandatory)
.PARAMETER ConnectionString
    Full ADO.NET connection string (mandatory)
.PARAMETER FixModel
    LLM model to use for fixing SQL errors (default: deepseek)
.PARAMETER SkipIfExists
    Skip setup if the database already has tables
.PARAMETER MaxRetries
    Max retries per SQL file after LLM fix (default: 2)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$ConnectionString,
    [ValidateSet("deepseek","claude","codex")][string]$FixModel = "deepseek",
    [switch]$SkipIfExists,
    [int]$MaxRetries = 2
)

$ErrorActionPreference = "Continue"

# ============================================================
# RESOLVE PATHS
# ============================================================

$RepoRoot = (Resolve-Path $RepoRoot).Path
$v3Dir = Split-Path $PSScriptRoot -Parent
$GsdDir = Join-Path $RepoRoot ".gsd"
$OutputDir = Join-Path $GsdDir "database-setup"
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

# ============================================================
# PARSE CONNECTION STRING
# ============================================================

function Parse-ConnectionString {
    param([string]$ConnStr)
    $parts = @{}
    foreach ($segment in $ConnStr.Split(';')) {
        $kv = $segment.Split('=', 2)
        if ($kv.Count -eq 2) {
            $parts[$kv[0].Trim()] = $kv[1].Trim()
        }
    }
    return @{
        Server   = if ($parts['Data Source']) { $parts['Data Source'] } elseif ($parts['Server']) { $parts['Server'] } else { "localhost" }
        Database = if ($parts['Initial Catalog']) { $parts['Initial Catalog'] } elseif ($parts['Database']) { $parts['Database'] } else { "" }
        User     = if ($parts['User ID']) { $parts['User ID'] } elseif ($parts['User']) { $parts['User'] } else { "" }
        Password = if ($parts['Password']) { $parts['Password'] } else { "" }
    }
}

$dbInfo = Parse-ConnectionString $ConnectionString
$Server = $dbInfo.Server
$Database = $dbInfo.Database
$User = $dbInfo.User
$Password = $dbInfo.Password

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  GSD Database Setup" -ForegroundColor Cyan
Write-Host "  Server:   $Server" -ForegroundColor Cyan
Write-Host "  Database: $Database" -ForegroundColor Cyan
Write-Host "  Repo:     $RepoRoot" -ForegroundColor Cyan
Write-Host "  Fix model: $FixModel" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# LOAD API CLIENT (for LLM fixes)
# ============================================================

$apiClientPath = Join-Path $v3Dir "lib\modules\api-client.ps1"
if (Test-Path $apiClientPath) {
    . $apiClientPath
    Write-Host "  [OK] API client loaded" -ForegroundColor Green
} else {
    Write-Host "  [WARN] API client not found - LLM fixes disabled" -ForegroundColor Yellow
}

# ============================================================
# HELPER: RUN SQLCMD
# ============================================================

function Invoke-SqlCmd-File {
    param(
        [string]$SqlFile,
        [string]$TargetDatabase = $Database
    )

    $sqlcmdArgs = @("-S", $Server, "-d", $TargetDatabase, "-i", $SqlFile, "-b")
    if ($User) {
        $sqlcmdArgs += @("-U", $User, "-P", $Password)
    } else {
        $sqlcmdArgs += @("-E")  # Windows auth
    }

    # Run from the SQL file's directory so :r relative includes resolve correctly
    $fileDir = Split-Path $SqlFile -Parent
    Push-Location $fileDir
    try {
        $result = & sqlcmd @sqlcmdArgs 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    return @{
        Success  = ($exitCode -eq 0)
        Output   = ($result | Out-String)
        ExitCode = $exitCode
    }
}

function Invoke-SqlCmd-Query {
    param(
        [string]$Query,
        [string]$TargetDatabase = $Database
    )

    $sqlcmdArgs = @("-S", $Server, "-d", $TargetDatabase, "-Q", $Query, "-b", "-h", "-1", "-W")
    if ($User) {
        $sqlcmdArgs += @("-U", $User, "-P", $Password)
    } else {
        $sqlcmdArgs += @("-E")
    }

    $result = & sqlcmd @sqlcmdArgs 2>&1
    return @{
        Success  = ($LASTEXITCODE -eq 0)
        Output   = ($result | Out-String).Trim()
        ExitCode = $LASTEXITCODE
    }
}

# ============================================================
# HELPER: LLM FIX SQL ERROR
# ============================================================

function Invoke-LlmSqlFix {
    param(
        [string]$SqlContent,
        [string]$ErrorOutput,
        [string]$FileName
    )

    $systemPrompt = @"
You are a SQL Server expert. Fix the SQL script that failed with the error below.
Return ONLY the corrected SQL - no explanations, no markdown fences.
Preserve all business logic. Only fix syntax/compatibility errors.
"@

    $userMessage = @"
File: $FileName
Error: $ErrorOutput

Original SQL:
$SqlContent
"@

    if ($FixModel -eq "claude" -and (Get-Command Invoke-SonnetApi -EA SilentlyContinue)) {
        $response = Invoke-SonnetApi -SystemPrompt $systemPrompt -UserMessage $userMessage -MaxTokens 8192 -Phase "database-setup"
        if ($response.Success) { return $response.Text }
    }
    elseif (Get-Command Invoke-OpenAICompatFallback -EA SilentlyContinue) {
        $dsConfig = $script:ApiConfig.DeepSeek
        $dsKey = $env:DEEPSEEK_API_KEY
        if ($FixModel -eq "deepseek" -and $dsConfig -and $dsKey) {
            $response = Invoke-OpenAICompatFallback -Config $dsConfig -ApiKey $dsKey `
                -SystemPrompt $systemPrompt -UserMessage $userMessage `
                -MaxTokens 8192 -Phase "database-setup" -ModelName "DeepSeek"
            if ($response.Success) { return $response.Text }
        }
    }

    Write-Host "    [WARN] LLM fix unavailable for $FileName" -ForegroundColor Yellow
    return $null
}

# ============================================================
# CHECK IF DATABASE EXISTS AND HAS TABLES
# ============================================================

$dbExists = $false
$tableCount = 0

# Try connecting to master to check if database exists
$checkResult = Invoke-SqlCmd-Query -Query "SELECT COUNT(*) FROM sys.databases WHERE name = '$Database'" -TargetDatabase "master"
if ($checkResult.Success) {
    # sqlcmd may include "(N row(s) affected)" in output even with -h -1; extract first numeric line
    $dbCountLine = ($checkResult.Output -split '\n' | Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -First 1)
    if ($dbCountLine) { $dbExists = ([int]$dbCountLine.Trim() -gt 0) }
}

if ($dbExists) {
    $tableCheck = Invoke-SqlCmd-Query -Query "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE'"
    if ($tableCheck.Success) {
        $tableCountLine = ($tableCheck.Output -split '\n' | Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -First 1)
        if ($tableCountLine) { $tableCount = [int]$tableCountLine.Trim() }
    }
}

if ($SkipIfExists -and $dbExists -and $tableCount -gt 0) {
    Write-Host "  [SKIP] Database '$Database' exists with $tableCount tables - skipping setup" -ForegroundColor Yellow
    $report = @{
        status    = "skipped"
        reason    = "Database exists with $tableCount tables"
        server    = $Server
        database  = $Database
        timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
    $report | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputDir "database-setup-report.json") -Encoding UTF8
    exit 0
}

# ============================================================
# CREATE __MigrationHistory TABLE
# ============================================================

if ($dbExists) {
    $migrationSql = @"
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = '__MigrationHistory')
BEGIN
    CREATE TABLE __MigrationHistory (
        Id INT IDENTITY(1,1) PRIMARY KEY,
        MigrationName NVARCHAR(500) NOT NULL,
        AppliedOn DATETIME2 NOT NULL DEFAULT GETUTCDATE(),
        Status NVARCHAR(50) NOT NULL DEFAULT 'applied',
        ErrorMessage NVARCHAR(MAX) NULL
    )
    PRINT 'Created __MigrationHistory table'
END
"@
    $migFile = Join-Path $OutputDir "_create_migration_history.sql"
    $migrationSql | Set-Content $migFile -Encoding UTF8
    $migResult = Invoke-SqlCmd-File -SqlFile $migFile
    if ($migResult.Success) {
        Write-Host "  [OK] __MigrationHistory table ready" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Could not create __MigrationHistory: $($migResult.Output)" -ForegroundColor Yellow
    }
}

# ============================================================
# DISCOVER SQL FILES
# ============================================================

$sqlCategories = [ordered]@{
    "deploy"     = @()
    "migrations" = @()
    "procedures" = @()
    "functions"  = @()
    "seeds"      = @()
}

# 1. Deploy scripts (master schema)
$deployDir = Join-Path $RepoRoot "db\deploy"
if (Test-Path $deployDir) {
    $sqlCategories["deploy"] = Get-ChildItem -Path $deployDir -Filter "*.sql" -File |
        Where-Object { $_.Name -notmatch 'seed' } |
        Sort-Object Name
}

# 2. Migrations
$migrationsDir = Join-Path $RepoRoot "db\migrations"
if (Test-Path $migrationsDir) {
    $sqlCategories["migrations"] = Get-ChildItem -Path $migrationsDir -Filter "*.sql" -File -Recurse | Sort-Object Name
}

# 3. Stored procedures
$spDirs = @(
    (Join-Path $RepoRoot "db\stored-procedures"),
    (Join-Path $RepoRoot "db\sql\procedures")
)
foreach ($spDir in $spDirs) {
    if (Test-Path $spDir) {
        $sqlCategories["procedures"] += Get-ChildItem -Path $spDir -Filter "*.sql" -File -Recurse | Sort-Object Name
    }
}

# 4. Functions
$funcDir = Join-Path $RepoRoot "db\functions"
if (Test-Path $funcDir) {
    $sqlCategories["functions"] = Get-ChildItem -Path $funcDir -Filter "*.sql" -File -Recurse | Sort-Object Name
}

# 5. Seeds
$seedDir = Join-Path $RepoRoot "db\seeds"
if (Test-Path $seedDir) {
    $sqlCategories["seeds"] = Get-ChildItem -Path $seedDir -Filter "*.sql" -File -Recurse | Sort-Object Name
}
# Also check db/deploy/*seed*.sql
if (Test-Path $deployDir) {
    $seedFiles = Get-ChildItem -Path $deployDir -Filter "*seed*.sql" -File | Sort-Object Name
    if ($seedFiles) { $sqlCategories["seeds"] += $seedFiles }
}

# Count total files
$totalFiles = 0
foreach ($cat in $sqlCategories.Keys) {
    $count = @($sqlCategories[$cat]).Count
    $totalFiles += $count
    if ($count -gt 0) {
        Write-Host "  [FOUND] $cat : $count SQL files" -ForegroundColor Green
    }
}

if ($totalFiles -eq 0) {
    Write-Host "  [WARN] No SQL files found in db/ directories" -ForegroundColor Yellow
    $report = @{
        status    = "no_sql_files"
        server    = $Server
        database  = $Database
        searched  = @("db/deploy/", "db/migrations/", "db/stored-procedures/", "db/sql/procedures/", "db/functions/", "db/seeds/")
        timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
    $report | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputDir "database-setup-report.json") -Encoding UTF8
    exit 0
}

Write-Host ""
Write-Host "  Total SQL files to execute: $totalFiles" -ForegroundColor Cyan

# ============================================================
# EXECUTE SQL FILES IN ORDER
# ============================================================

$results = @{
    succeeded = @()
    failed    = @()
    fixed     = @()
    skipped   = @()
}

$executionLog = @()

foreach ($category in $sqlCategories.Keys) {
    $files = @($sqlCategories[$category])
    if ($files.Count -eq 0) { continue }

    Write-Host ""
    Write-Host "  --- $($category.ToUpper()) ($($files.Count) files) ---" -ForegroundColor Cyan

    foreach ($file in $files) {
        $fileName = $file.Name
        $filePath = $file.FullName
        $relativePath = $filePath.Replace($RepoRoot, "").TrimStart("\", "/")

        Write-Host "    Executing: $relativePath" -ForegroundColor White -NoNewline

        # Check migration history
        if ($dbExists -and $category -eq "migrations") {
            $alreadyRun = Invoke-SqlCmd-Query -Query "SELECT COUNT(*) FROM __MigrationHistory WHERE MigrationName = '$fileName' AND Status = 'applied'"
            $alreadyRunLine = ($alreadyRun.Output -split '\n' | Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -First 1)
            if ($alreadyRun.Success -and $alreadyRunLine -and ([int]$alreadyRunLine.Trim() -gt 0)) {
                Write-Host " [SKIP - already applied]" -ForegroundColor DarkGray
                $results.skipped += $relativePath
                $executionLog += @{ file = $relativePath; category = $category; status = "skipped"; reason = "already applied" }
                continue
            }
        }

        $execResult = Invoke-SqlCmd-File -SqlFile $filePath
        if ($execResult.Success) {
            Write-Host " [OK]" -ForegroundColor Green
            $results.succeeded += $relativePath
            $executionLog += @{ file = $relativePath; category = $category; status = "success" }

            # Record migration
            if ($category -eq "migrations") {
                Invoke-SqlCmd-Query -Query "INSERT INTO __MigrationHistory (MigrationName, Status) VALUES ('$fileName', 'applied')" | Out-Null
            }
        } else {
            Write-Host " [FAIL]" -ForegroundColor Red
            Write-Host "      Error: $($execResult.Output)" -ForegroundColor DarkRed

            # Try LLM fix
            $fixed = $false
            for ($retry = 1; $retry -le $MaxRetries; $retry++) {
                Write-Host "      Attempting LLM fix (retry $retry/$MaxRetries)..." -ForegroundColor Yellow

                $sqlContent = Get-Content $filePath -Raw -Encoding UTF8
                $fixedSql = Invoke-LlmSqlFix -SqlContent $sqlContent -ErrorOutput $execResult.Output -FileName $fileName

                if ($fixedSql) {
                    # Write fixed SQL to temp file
                    $fixedPath = Join-Path $OutputDir "fixed_$fileName"
                    $fixedSql | Set-Content $fixedPath -Encoding UTF8

                    $retryResult = Invoke-SqlCmd-File -SqlFile $fixedPath
                    if ($retryResult.Success) {
                        Write-Host "      [FIXED] LLM fix succeeded on retry $retry" -ForegroundColor Green
                        $results.fixed += $relativePath
                        $executionLog += @{ file = $relativePath; category = $category; status = "fixed"; retry = $retry }
                        $fixed = $true

                        # Record migration
                        if ($category -eq "migrations") {
                            Invoke-SqlCmd-Query -Query "INSERT INTO __MigrationHistory (MigrationName, Status) VALUES ('$fileName', 'applied')" | Out-Null
                        }
                        break
                    } else {
                        Write-Host "      Fix attempt $retry failed: $($retryResult.Output)" -ForegroundColor DarkRed
                    }
                } else {
                    Write-Host "      No LLM fix available" -ForegroundColor DarkYellow
                    break
                }
            }

            if (-not $fixed) {
                $results.failed += $relativePath
                $executionLog += @{ file = $relativePath; category = $category; status = "failed"; error = $execResult.Output }

                # Record failed migration
                if ($category -eq "migrations") {
                    $escapedError = ($execResult.Output -replace "'", "''")
                    if ($escapedError.Length -gt 2000) { $escapedError = $escapedError.Substring(0, 2000) }
                    Invoke-SqlCmd-Query -Query "INSERT INTO __MigrationHistory (MigrationName, Status, ErrorMessage) VALUES ('$fileName', 'failed', '$escapedError')" | Out-Null
                }
            }
        }
    }
}

# ============================================================
# VERIFY: COUNT OBJECTS
# ============================================================

Write-Host ""
Write-Host "  --- VERIFICATION ---" -ForegroundColor Cyan

$verification = @{
    tables     = 0
    procedures = 0
    functions  = 0
    views      = 0
}

$tableResult = Invoke-SqlCmd-Query -Query "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE'"
if ($tableResult.Success) { $verification.tables = [int]$tableResult.Output }

$spResult = Invoke-SqlCmd-Query -Query "SELECT COUNT(*) FROM INFORMATION_SCHEMA.ROUTINES WHERE ROUTINE_TYPE = 'PROCEDURE'"
if ($spResult.Success) { $verification.procedures = [int]$spResult.Output }

$fnResult = Invoke-SqlCmd-Query -Query "SELECT COUNT(*) FROM INFORMATION_SCHEMA.ROUTINES WHERE ROUTINE_TYPE = 'FUNCTION'"
if ($fnResult.Success) { $verification.functions = [int]$fnResult.Output }

$viewResult = Invoke-SqlCmd-Query -Query "SELECT COUNT(*) FROM INFORMATION_SCHEMA.VIEWS"
if ($viewResult.Success) { $verification.views = [int]$viewResult.Output }

Write-Host "    Tables:           $($verification.tables)" -ForegroundColor $(if ($verification.tables -gt 0) { "Green" } else { "Yellow" })
Write-Host "    Stored Procedures: $($verification.procedures)" -ForegroundColor $(if ($verification.procedures -gt 0) { "Green" } else { "Yellow" })
Write-Host "    Functions:        $($verification.functions)" -ForegroundColor $(if ($verification.functions -gt 0) { "Green" } else { "Yellow" })
Write-Host "    Views:            $($verification.views)" -ForegroundColor $(if ($verification.views -gt 0) { "Green" } else { "Yellow" })

# ============================================================
# GENERATE REPORT
# ============================================================

$overallStatus = if ($results.failed.Count -eq 0) { "pass" } elseif ($results.succeeded.Count -gt 0) { "partial" } else { "fail" }

$report = @{
    status       = $overallStatus
    server       = $Server
    database     = $Database
    fix_model    = $FixModel
    timestamp    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    summary      = @{
        total_files = $totalFiles
        succeeded   = $results.succeeded.Count
        fixed       = $results.fixed.Count
        failed      = $results.failed.Count
        skipped     = $results.skipped.Count
    }
    verification = $verification
    files        = @{
        succeeded = $results.succeeded
        fixed     = $results.fixed
        failed    = $results.failed
        skipped   = $results.skipped
    }
    execution_log = $executionLog
}

$reportPath = Join-Path $OutputDir "database-setup-report.json"
$report | ConvertTo-Json -Depth 10 | Set-Content $reportPath -Encoding UTF8

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Database Setup Complete - $overallStatus" -ForegroundColor $(if ($overallStatus -eq "pass") { "Green" } elseif ($overallStatus -eq "partial") { "Yellow" } else { "Red" })
Write-Host "  Succeeded: $($results.succeeded.Count) | Fixed: $($results.fixed.Count) | Failed: $($results.failed.Count) | Skipped: $($results.skipped.Count)" -ForegroundColor Cyan
Write-Host "  Report: $reportPath" -ForegroundColor Gray
Write-Host "================================================================" -ForegroundColor Cyan
