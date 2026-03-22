<#
.SYNOPSIS
    GSD V3 Database Validator - FREE static analysis for SQL Server scripts.
.DESCRIPTION
    Scans all .sql files in a repository and checks for common database issues:
    idempotency, hardcoded DB names, missing SET options, reserved word bracketing,
    column existence preflights, FK on missing tables, migration safety, seed data
    safety, error handling, and schema-variant safety.

    This module costs ZERO tokens — pure regex/string-based static analysis.
    Catches the 50+ categories of database issues found in real projects.
#>

# ============================================================
# RESERVED WORDS LIST
# ============================================================

$script:ReservedWords = @(
    'Plan', 'User', 'Key', 'Index', 'Name', 'Type', 'Status', 'Level',
    'Order', 'Group', 'Role', 'Action', 'State', 'Source', 'Target',
    'Value', 'Description', 'Date', 'Time', 'Count', 'File', 'Size',
    'Table', 'Column', 'Schema', 'Database', 'Procedure', 'Function',
    'View', 'Trigger', 'Transaction', 'Constraint', 'Reference',
    'Primary', 'Foreign', 'Identity', 'Default', 'Check', 'Unique',
    'Clustered'
)

# ============================================================
# MAIN VALIDATION FUNCTION
# ============================================================

function Invoke-DatabaseValidation {
    <#
    .SYNOPSIS
        Run static analysis on all .sql files in a repository.
    .PARAMETER RepoRoot
        Repository root path (mandatory).
    .PARAMETER GsdDir
        GSD state directory. Defaults to .gsd under RepoRoot.
    .PARAMETER Config
        Optional config hashtable for tuning thresholds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [string]$GsdDir,

        [hashtable]$Config = @{}
    )

    if (-not $GsdDir) {
        $GsdDir = Join-Path $RepoRoot ".gsd"
    }

    $violations = [System.Collections.ArrayList]::new()
    $warnings   = [System.Collections.ArrayList]::new()
    $stats = @{
        FilesScanned  = 0
        TotalChecks   = 0
        Blocking      = 0
        Warnings      = 0
        Passed        = 0
    }

    # Find all .sql files (exclude node_modules, bin, obj, .git)
    $sqlFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sql" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $rel = $_.FullName.Substring($RepoRoot.Length)
            $rel -notmatch '[\\/](node_modules|bin|obj|\.git|\.gsd)[\\/]'
        }

    if (-not $sqlFiles -or $sqlFiles.Count -eq 0) {
        Write-Host "  [DB-VALIDATOR] No .sql files found in $RepoRoot" -ForegroundColor Yellow
        $result = @{
            passed     = $true
            violations = @()
            warnings   = @()
            stats      = $stats
        }
        Write-DbValidationReport -GsdDir $GsdDir -Result $result
        return $result
    }

    $stats.FilesScanned = $sqlFiles.Count
    Write-Host "  [DB-VALIDATOR] Scanning $($sqlFiles.Count) SQL files..." -ForegroundColor Cyan

    foreach ($sqlFile in $sqlFiles) {
        $relativePath = $sqlFile.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
        $content = Get-Content $sqlFile.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        $lines = $content -split "`n"

        # --- Check 1: Idempotency ---
        Test-Idempotency -Content $content -Lines $lines -File $relativePath -Violations $violations -Stats $stats

        # --- Check 2: Hardcoded DB Names ---
        Test-HardcodedDbNames -Content $content -Lines $lines -File $relativePath -Violations $violations -Stats $stats

        # --- Check 3: SET Options ---
        Test-SetOptions -Content $content -Lines $lines -File $relativePath -Violations $violations -Warnings $warnings -Stats $stats

        # --- Check 4: Reserved Word Brackets ---
        Test-ReservedWordBrackets -Content $content -Lines $lines -File $relativePath -Violations $violations -Warnings $warnings -Stats $stats

        # --- Check 5: Column Existence Preflights ---
        Test-ColumnExistencePreflights -Content $content -Lines $lines -File $relativePath -Violations $violations -Stats $stats

        # --- Check 6: FK on Missing Tables ---
        Test-ForeignKeyGuards -Content $content -Lines $lines -File $relativePath -Violations $violations -Warnings $warnings -Stats $stats

        # --- Check 7: Migration Idempotency ---
        Test-MigrationIdempotency -Content $content -Lines $lines -File $relativePath -SqlFile $sqlFile -Violations $violations -Warnings $warnings -Stats $stats

        # --- Check 8: Seed Data Safety ---
        Test-SeedDataSafety -Content $content -Lines $lines -File $relativePath -SqlFile $sqlFile -Violations $violations -Warnings $warnings -Stats $stats

        # --- Check 9: Error Handling ---
        Test-ErrorHandling -Content $content -Lines $lines -File $relativePath -Violations $violations -Warnings $warnings -Stats $stats

        # --- Check 10: Schema-variant Safety ---
        Test-SchemaVariantSafety -Content $content -Lines $lines -File $relativePath -Violations $violations -Warnings $warnings -Stats $stats
    }

    $stats.Blocking = ($violations | Where-Object { $_.severity -eq 'blocking' }).Count
    $stats.Warnings = $warnings.Count
    $stats.Passed   = $stats.TotalChecks - $stats.Blocking - $stats.Warnings

    $allPassed = ($stats.Blocking -eq 0)

    $result = @{
        passed     = $allPassed
        violations = @($violations)
        warnings   = @($warnings)
        stats      = $stats
    }

    $statusColor = if ($allPassed) { "Green" } else { "Red" }
    $statusText  = if ($allPassed) { "PASS" } else { "FAIL" }
    Write-Host "  [DB-VALIDATOR] [$statusText] $($stats.FilesScanned) files, $($stats.TotalChecks) checks, $($stats.Blocking) blocking, $($stats.Warnings) warnings" -ForegroundColor $statusColor

    Write-DbValidationReport -GsdDir $GsdDir -Result $result
    return $result
}

# ============================================================
# CHECK 1: Idempotency
# ============================================================

function Test-Idempotency {
    param($Content, $Lines, $File, $Violations, $Stats)

    $Stats.TotalChecks++

    # CREATE TABLE without IF NOT EXISTS / IF OBJECT_ID guard
    $tableMatches = [regex]::Matches($Content, '(?im)^\s*CREATE\s+TABLE\s+(\[?[\w.]+\]?\.?\[?[\w]+\]?)')
    foreach ($m in $tableMatches) {
        $lineNum = Get-LineNumber -Content $Content -Position $m.Index
        $tableName = $m.Groups[1].Value

        # Check preceding 5 lines for guard
        $startLine = [Math]::Max(0, $lineNum - 6)
        $precedingBlock = ($Lines[$startLine..($lineNum - 1)]) -join "`n"

        if ($precedingBlock -notmatch 'IF\s+(NOT\s+EXISTS|OBJECT_ID)' -and
            $Content -notmatch "(?i)CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+$([regex]::Escape($tableName))") {
            $null = $Violations.Add(@{
                check      = 'idempotency'
                severity   = 'blocking'
                file       = $File
                line       = $lineNum
                message    = "CREATE TABLE $tableName without idempotency guard"
                suggestion = "Add IF OBJECT_ID('$tableName', 'U') IS NULL before CREATE TABLE"
            })
        }
    }

    # CREATE PROCEDURE/VIEW/FUNCTION without CREATE OR ALTER or DROP IF EXISTS
    $procMatches = [regex]::Matches($Content, '(?im)^\s*CREATE\s+(PROCEDURE|PROC|VIEW|FUNCTION)\s+(\[?[\w.]+\]?\.?\[?[\w]+\]?)')
    foreach ($m in $procMatches) {
        $lineNum = Get-LineNumber -Content $Content -Position $m.Index
        $objType = $m.Groups[1].Value
        $objName = $m.Groups[2].Value

        # Check if it's CREATE OR ALTER
        $lineText = $Lines[$lineNum - 1]
        if ($lineText -match '(?i)CREATE\s+OR\s+ALTER') { continue }

        # Check preceding 5 lines for DROP IF EXISTS
        $startLine = [Math]::Max(0, $lineNum - 6)
        $precedingBlock = ($Lines[$startLine..($lineNum - 1)]) -join "`n"
        if ($precedingBlock -match '(?i)DROP\s+(PROCEDURE|PROC|VIEW|FUNCTION)\s+IF\s+EXISTS') { continue }

        $null = $Violations.Add(@{
            check      = 'idempotency'
            severity   = 'blocking'
            file       = $File
            line       = $lineNum
            message    = "CREATE $objType $objName without idempotency guard"
            suggestion = "Use CREATE OR ALTER $objType or DROP ... IF EXISTS + CREATE"
        })
    }
}

# ============================================================
# CHECK 2: Hardcoded DB Names
# ============================================================

function Test-HardcodedDbNames {
    param($Content, $Lines, $File, $Violations, $Stats)

    $Stats.TotalChecks++

    # Match USE [DbName] or USE DbName — but not USE @variable
    $useMatches = [regex]::Matches($Content, '(?im)^\s*USE\s+(\[?[A-Za-z][\w]*\]?)\s*;?\s*$')
    foreach ($m in $useMatches) {
        $lineNum = Get-LineNumber -Content $Content -Position $m.Index
        $dbName = $m.Groups[1].Value

        # Skip if it's a variable like @dbName
        if ($dbName -match '^@') { continue }
        # Skip master/tempdb (system DB references are sometimes needed)
        if ($dbName -match '(?i)^(\[?(master|tempdb|msdb|model)\]?)$') { continue }

        $null = $Violations.Add(@{
            check      = 'hardcoded_db_name'
            severity   = 'blocking'
            file       = $File
            line       = $lineNum
            message    = "Hardcoded database name: USE $dbName"
            suggestion = "Remove USE statement — scripts must work against the connected database"
        })
    }
}

# ============================================================
# CHECK 3: SET Options
# ============================================================

function Test-SetOptions {
    param($Content, $Lines, $File, $Violations, $Warnings, $Stats)

    $Stats.TotalChecks++

    # Only check files that create/alter procedures, views, functions
    if ($Content -notmatch '(?i)(CREATE|ALTER)\s+(OR\s+ALTER\s+)?(PROCEDURE|PROC|VIEW|FUNCTION)') { return }

    if ($Content -notmatch '(?i)SET\s+ANSI_NULLS\s+ON') {
        $null = $Violations.Add(@{
            check      = 'set_options'
            severity   = 'warning'
            file       = $File
            line       = 1
            message    = "Missing SET ANSI_NULLS ON before CREATE/ALTER"
            suggestion = "Add SET ANSI_NULLS ON; at the top of the file"
        })
    }

    if ($Content -notmatch '(?i)SET\s+QUOTED_IDENTIFIER\s+ON') {
        $null = $Violations.Add(@{
            check      = 'set_options'
            severity   = 'warning'
            file       = $File
            line       = 1
            message    = "Missing SET QUOTED_IDENTIFIER ON before CREATE/ALTER"
            suggestion = "Add SET QUOTED_IDENTIFIER ON; at the top of the file"
        })
    }
}

# ============================================================
# CHECK 4: Reserved Word Brackets
# ============================================================

function Test-ReservedWordBrackets {
    param($Content, $Lines, $File, $Violations, $Warnings, $Stats)

    $Stats.TotalChecks++

    foreach ($word in $script:ReservedWords) {
        # Match reserved word used as identifier (after dot, in column list, after AS, in CREATE TABLE columns)
        # but NOT when already bracketed [Word] and NOT in comments or strings
        # We check for common patterns: .Word, (Word, ,Word, AS Word in column contexts

        # Pattern: table.Word or .Word (without bracket)
        $pattern = "(?i)(?<!\[)\.($word)(?!\])\b"
        $matches = [regex]::Matches($Content, $pattern)
        foreach ($m in $matches) {
            $lineNum = Get-LineNumber -Content $Content -Position $m.Index
            $lineText = $Lines[$lineNum - 1]
            # Skip if it's in a comment
            if ($lineText -match '^\s*--') { continue }

            $null = $Warnings.Add(@{
                check      = 'reserved_word_brackets'
                severity   = 'warning'
                file       = $File
                line       = $lineNum
                message    = "Reserved word '$word' used as identifier without brackets"
                suggestion = "Use [$word] instead of $word"
            })
            break  # One warning per word per file is enough
        }

        # Pattern: column definition in CREATE TABLE — Word datatype
        $colPattern = "(?im)^\s+($word)\s+(INT|BIGINT|VARCHAR|NVARCHAR|BIT|DATETIME|UNIQUEIDENTIFIER|DECIMAL|FLOAT|MONEY|TEXT|NTEXT|CHAR|NCHAR|BINARY|VARBINARY|XML|DATE|TIME|SMALLINT|TINYINT)"
        $colMatches = [regex]::Matches($Content, $colPattern)
        foreach ($m in $colMatches) {
            $lineNum = Get-LineNumber -Content $Content -Position $m.Index
            $lineText = $Lines[$lineNum - 1]
            if ($lineText -match '^\s*--') { continue }
            # Check it's not already bracketed
            if ($lineText -match "\[$word\]") { continue }

            $null = $Warnings.Add(@{
                check      = 'reserved_word_brackets'
                severity   = 'warning'
                file       = $File
                line       = $lineNum
                message    = "Reserved word '$word' used as column name without brackets"
                suggestion = "Use [$word] instead of $word in column definition"
            })
            break
        }
    }
}

# ============================================================
# CHECK 5: Column Existence Preflights
# ============================================================

function Test-ColumnExistencePreflights {
    param($Content, $Lines, $File, $Violations, $Stats)

    $Stats.TotalChecks++

    # ALTER TABLE ... ADD (column) without guard
    $addMatches = [regex]::Matches($Content, '(?im)^\s*ALTER\s+TABLE\s+(\[?[\w.]+\]?\.?\[?[\w]+\]?)\s+ADD\s+(\[?[\w]+\]?)\s+')
    foreach ($m in $addMatches) {
        $lineNum = Get-LineNumber -Content $Content -Position $m.Index
        $tableName = $m.Groups[1].Value
        $colName   = $m.Groups[2].Value

        # Skip CONSTRAINT additions
        if ($colName -match '(?i)^(CONSTRAINT|PRIMARY|FOREIGN|INDEX|DEFAULT|CHECK|UNIQUE)$') { continue }

        # Check preceding 5 lines for COL_LENGTH or INFORMATION_SCHEMA guard
        $startLine = [Math]::Max(0, $lineNum - 6)
        $precedingBlock = ($Lines[$startLine..($lineNum - 1)]) -join "`n"

        if ($precedingBlock -notmatch '(?i)(COL_LENGTH|INFORMATION_SCHEMA|IF\s+NOT\s+EXISTS|COLUMNPROPERTY)') {
            $null = $Violations.Add(@{
                check      = 'column_existence_preflight'
                severity   = 'blocking'
                file       = $File
                line       = $lineNum
                message    = "ALTER TABLE ADD $colName without existence check"
                suggestion = "Guard with: IF COL_LENGTH('$tableName', '$colName') IS NULL"
            })
        }
    }

    # ALTER TABLE ... DROP COLUMN without guard
    $dropMatches = [regex]::Matches($Content, '(?im)^\s*ALTER\s+TABLE\s+(\[?[\w.]+\]?\.?\[?[\w]+\]?)\s+DROP\s+COLUMN\s+(\[?[\w]+\]?)')
    foreach ($m in $dropMatches) {
        $lineNum = Get-LineNumber -Content $Content -Position $m.Index
        $tableName = $m.Groups[1].Value
        $colName   = $m.Groups[2].Value

        $startLine = [Math]::Max(0, $lineNum - 6)
        $precedingBlock = ($Lines[$startLine..($lineNum - 1)]) -join "`n"

        if ($precedingBlock -notmatch '(?i)(COL_LENGTH|INFORMATION_SCHEMA|IF\s+EXISTS|COLUMNPROPERTY)') {
            $null = $Violations.Add(@{
                check      = 'column_existence_preflight'
                severity   = 'blocking'
                file       = $File
                line       = $lineNum
                message    = "ALTER TABLE DROP COLUMN $colName without existence check"
                suggestion = "Guard with: IF COL_LENGTH('$tableName', '$colName') IS NOT NULL"
            })
        }
    }
}

# ============================================================
# CHECK 6: FK on Missing Tables
# ============================================================

function Test-ForeignKeyGuards {
    param($Content, $Lines, $File, $Violations, $Warnings, $Stats)

    $Stats.TotalChecks++

    # FOREIGN KEY ... REFERENCES TableName
    $fkMatches = [regex]::Matches($Content, '(?im)REFERENCES\s+(\[?[\w.]+\]?\.?\[?[\w]+\]?)\s*\(')
    foreach ($m in $fkMatches) {
        $lineNum = Get-LineNumber -Content $Content -Position $m.Index
        $refTable = $m.Groups[1].Value

        # Check if the referenced table is created in the same file
        $escapedTable = [regex]::Escape($refTable)
        if ($Content -match "(?i)CREATE\s+TABLE\s+$escapedTable") { continue }

        # Check if there's an OBJECT_ID guard around the FK
        $startLine = [Math]::Max(0, $lineNum - 10)
        $precedingBlock = ($Lines[$startLine..($lineNum - 1)]) -join "`n"

        if ($precedingBlock -notmatch '(?i)(IF\s+OBJECT_ID|IF\s+EXISTS)') {
            $null = $Warnings.Add(@{
                check      = 'fk_missing_table'
                severity   = 'warning'
                file       = $File
                line       = $lineNum
                message    = "FOREIGN KEY REFERENCES $refTable — referenced table may not exist"
                suggestion = "Guard FK creation with IF OBJECT_ID('$refTable', 'U') IS NOT NULL"
            })
        }
    }
}

# ============================================================
# CHECK 7: Migration Idempotency
# ============================================================

function Test-MigrationIdempotency {
    param($Content, $Lines, $File, $SqlFile, $Violations, $Warnings, $Stats)

    $Stats.TotalChecks++

    # Only check files that look like migrations (name pattern or path)
    $isMigration = ($File -match '(?i)(migrat|schema[\\/]|deploy[\\/]|upgrade[\\/]|\d{3}[_-])') -or
                   ($SqlFile.Name -match '^\d{3}[_-]')

    if (-not $isMigration) { return }

    # Check for __MigrationHistory or similar guard
    $hasHistoryCheck = $Content -match '(?i)(__MigrationHistory|SchemaVersions|MigrationLog|@@VERSION|IF\s+NOT\s+EXISTS.*migrat)'

    if (-not $hasHistoryCheck) {
        # Check if the entire file is idempotent (all statements guarded)
        $hasGuards = $Content -match '(?i)(IF\s+NOT\s+EXISTS|IF\s+OBJECT_ID|IF\s+COL_LENGTH|CREATE\s+OR\s+ALTER)'
        if (-not $hasGuards) {
            $null = $Warnings.Add(@{
                check      = 'migration_idempotency'
                severity   = 'warning'
                file       = $File
                line       = 1
                message    = "Migration file lacks idempotency guards or __MigrationHistory check"
                suggestion = "Check __MigrationHistory before running, or guard all statements with IF NOT EXISTS"
            })
        }
    }
}

# ============================================================
# CHECK 8: Seed Data Safety
# ============================================================

function Test-SeedDataSafety {
    param($Content, $Lines, $File, $SqlFile, $Violations, $Warnings, $Stats)

    $Stats.TotalChecks++

    # Only check files that look like seed/data files
    $isSeed = ($File -match '(?i)(seed|data[\\/]|insert|initial)') -or
              ($SqlFile.Name -match '(?i)(seed|data)')

    # Also check any file with INSERT statements
    $hasInserts = $Content -match '(?i)\bINSERT\s+INTO\b'

    if (-not $isSeed -and -not $hasInserts) { return }

    $insertMatches = [regex]::Matches($Content, '(?im)^\s*INSERT\s+INTO\s+(\[?[\w.]+\]?\.?\[?[\w]+\]?)')
    foreach ($m in $insertMatches) {
        $lineNum = Get-LineNumber -Content $Content -Position $m.Index
        $tableName = $m.Groups[1].Value

        # Check if it's guarded by MERGE, IF NOT EXISTS, WHERE NOT EXISTS, or is part of a MERGE
        $startLine = [Math]::Max(0, $lineNum - 8)
        $endLine   = [Math]::Min($Lines.Count - 1, $lineNum + 2)
        $surroundingBlock = ($Lines[$startLine..$endLine]) -join "`n"

        $isGuarded = $surroundingBlock -match '(?i)(MERGE\s+INTO|WHERE\s+NOT\s+EXISTS|IF\s+NOT\s+EXISTS|NOT\s+EXISTS\s*\(|ON\s+CONFLICT|EXCEPT)'

        if (-not $isGuarded) {
            $null = $Warnings.Add(@{
                check      = 'seed_data_safety'
                severity   = 'warning'
                file       = $File
                line       = $lineNum
                message    = "INSERT INTO $tableName without idempotency guard"
                suggestion = "Use MERGE pattern or IF NOT EXISTS guard for seed data"
            })
        }
    }
}

# ============================================================
# CHECK 9: Error Handling
# ============================================================

function Test-ErrorHandling {
    param($Content, $Lines, $File, $Violations, $Warnings, $Stats)

    $Stats.TotalChecks++

    # Check stored procedures for TRY...CATCH
    $procMatches = [regex]::Matches($Content, '(?im)(CREATE\s+(OR\s+ALTER\s+)?(PROCEDURE|PROC))\s+(\[?[\w.]+\]?\.?\[?[\w]+\]?)')
    foreach ($m in $procMatches) {
        $lineNum  = Get-LineNumber -Content $Content -Position $m.Index
        $procName = $m.Groups[4].Value

        # Find the procedure body (from AS to next GO or end of file)
        $procStart = $m.Index
        $afterProc = $Content.Substring($procStart)

        # Check for BEGIN TRY ... END TRY pattern
        if ($afterProc -notmatch '(?i)BEGIN\s+TRY') {
            $null = $Warnings.Add(@{
                check      = 'error_handling'
                severity   = 'warning'
                file       = $File
                line       = $lineNum
                message    = "Stored procedure $procName lacks BEGIN TRY...END TRY error handling"
                suggestion = "Add BEGIN TRY...END TRY / BEGIN CATCH...END CATCH with THROW"
            })
        }

        # Check for SET NOCOUNT ON
        $nextGoMatch = [regex]::Match($afterProc, '(?im)^\s*GO\s*$')
        $procBody = if ($nextGoMatch.Success) { $afterProc.Substring(0, $nextGoMatch.Index) } else { $afterProc }

        if ($procBody -notmatch '(?i)SET\s+NOCOUNT\s+ON') {
            $null = $Warnings.Add(@{
                check      = 'error_handling'
                severity   = 'warning'
                file       = $File
                line       = $lineNum
                message    = "Stored procedure $procName missing SET NOCOUNT ON"
                suggestion = "Add SET NOCOUNT ON; at the beginning of the procedure body"
            })
        }
    }
}

# ============================================================
# CHECK 10: Schema-variant Safety
# ============================================================

function Test-SchemaVariantSafety {
    param($Content, $Lines, $File, $Violations, $Warnings, $Stats)

    $Stats.TotalChecks++

    # Flag UPDATE/DELETE statements that reference columns in WHERE that could be missing
    # This is a heuristic — we flag ALTER + UPDATE/DELETE in same file on same table
    $alterTables = [regex]::Matches($Content, '(?im)ALTER\s+TABLE\s+(\[?[\w.]+\]?\.?\[?[\w]+\]?)\s+ADD\s+(\[?[\w]+\]?)')
    foreach ($m in $alterTables) {
        $tableName = $m.Groups[1].Value
        $colName   = $m.Groups[2].Value.Trim('[', ']')

        # Skip constraints
        if ($colName -match '(?i)^(CONSTRAINT|PRIMARY|FOREIGN|INDEX|DEFAULT|CHECK|UNIQUE)$') { continue }

        $escapedTable = [regex]::Escape($tableName)
        $escapedCol   = [regex]::Escape($colName)

        # Check if the same file then uses this column in UPDATE SET/WHERE or SELECT WHERE
        $usagePattern = "(?i)(UPDATE|DELETE|SELECT).*$escapedTable.*WHERE.*$escapedCol"
        if ($Content -match $usagePattern) {
            $lineNum = Get-LineNumber -Content $Content -Position $m.Index
            $null = $Warnings.Add(@{
                check      = 'schema_variant_safety'
                severity   = 'warning'
                file       = $File
                line       = $lineNum
                message    = "Column '$colName' added to $tableName and referenced in same file — may fail if column doesn't exist yet"
                suggestion = "Use dynamic SQL with COL_LENGTH check, or ensure column is added before any reference"
            })
        }
    }

    # Flag NEWSEQUENTIALID() usage (common misuse)
    if ($Content -match '(?i)NEWSEQUENTIALID\s*\(\s*\)') {
        $nsidMatch = [regex]::Match($Content, '(?i)NEWSEQUENTIALID\s*\(\s*\)')
        $lineNum = Get-LineNumber -Content $Content -Position $nsidMatch.Index
        $null = $Warnings.Add(@{
            check      = 'schema_variant_safety'
            severity   = 'warning'
            file       = $File
            line       = $lineNum
            message    = "NEWSEQUENTIALID() can only be used as DEFAULT constraint — verify usage"
            suggestion = "NEWSEQUENTIALID() is only valid in DEFAULT constraints. Use NEWID() for variables/inserts."
        })
    }
}

# ============================================================
# HELPER: Get line number from character position
# ============================================================

function Get-LineNumber {
    param(
        [string]$Content,
        [int]$Position
    )

    if ($Position -le 0) { return 1 }
    $beforeText = $Content.Substring(0, [Math]::Min($Position, $Content.Length))
    return ($beforeText -split "`n").Count
}

# ============================================================
# HELPER: Write report to .gsd/database/
# ============================================================

function Write-DbValidationReport {
    param(
        [string]$GsdDir,
        [hashtable]$Result
    )

    $dbDir = Join-Path $GsdDir "database"
    if (-not (Test-Path $dbDir)) {
        New-Item -Path $dbDir -ItemType Directory -Force | Out-Null
    }

    $reportPath = Join-Path $dbDir "db-validation-report.json"

    $report = @{
        timestamp  = (Get-Date -Format "o")
        passed     = $Result.passed
        stats      = $Result.stats
        violations = $Result.violations
        warnings   = $Result.warnings
    }

    $report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportPath -Encoding UTF8

    Write-Host "  [DB-VALIDATOR] Report written to $reportPath" -ForegroundColor Gray
}
