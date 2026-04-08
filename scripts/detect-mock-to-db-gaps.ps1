<#
.SYNOPSIS
    GSD V3 Mock-to-DB Gap Detector — finds mock data entities with missing full-stack infrastructure.
.DESCRIPTION
    Runs mock data pattern detection, derives entity names from mock variable names,
    then checks for gaps in: DB tables (via migration .sql files or live sqlcmd),
    controllers, and service/repository files.

    For each gap found, outputs a requirement template that can be injected into
    the requirements matrix to drive the pipeline to create the missing pieces.
.PARAMETER RepoRoot
    Repository root path. Defaults to current directory.
.PARAMETER ConnectionString
    Optional SQL Server connection string. If provided, queries INFORMATION_SCHEMA live.
    If omitted, checks for CREATE TABLE statements in migration .sql files.
.PARAMETER OutputPath
    Where to save the JSON gap report. Defaults to .gsd/mock-gap-report.json.
.PARAMETER InjectIntoMatrix
    If set, auto-injects generated requirement templates into the requirements matrix.
.EXAMPLE
    .\detect-mock-to-db-gaps.ps1 -RepoRoot D:\vscode\myproject\myproject
    .\detect-mock-to-db-gaps.ps1 -RepoRoot . -ConnectionString "Server=localhost;Database=MyDb;Trusted_Connection=true"
#>

param(
    [string]$RepoRoot = (Get-Location).Path,
    [string]$ConnectionString = "",
    [string]$OutputPath = "",
    [switch]$InjectIntoMatrix
)

$ErrorActionPreference = "Continue"
$RepoRoot = (Resolve-Path $RepoRoot).Path.TrimEnd('\', '/')

if (-not $OutputPath) {
    $OutputPath = Join-Path $RepoRoot ".gsd/mock-gap-report.json"
}

# ============================================================
# Load mock-data-detector module
# ============================================================

$moduleDir = Join-Path $PSScriptRoot ".." | Join-Path -ChildPath "v3/lib/modules"
$mockDetectorPath = Join-Path $moduleDir "mock-data-detector.ps1"

if (-not (Test-Path $mockDetectorPath)) {
    # Try relative to script location
    $mockDetectorPath = Join-Path $PSScriptRoot "../v3/lib/modules/mock-data-detector.ps1"
}

if (Test-Path $mockDetectorPath) {
    . $mockDetectorPath
    Write-Host "[GAP-DETECT] Loaded mock-data-detector module" -ForegroundColor Cyan
} else {
    Write-Host "[GAP-DETECT] WARNING: mock-data-detector.ps1 not found at $mockDetectorPath" -ForegroundColor Yellow
    Write-Host "[GAP-DETECT] Will use built-in mock pattern scanning" -ForegroundColor Yellow
}

# ============================================================
# HELPER: Derive entity name from mock variable name
# ============================================================

function Get-EntityName {
    param([string]$VariableName)

    # Strip mock/fake/dummy/sample/stub prefix (case-insensitive)
    $stripped = $VariableName -replace '^(mock|fake|dummy|sample|stub|test|hardcoded)', '' -replace '^(Mock|Fake|Dummy|Sample|Stub|Test|Hardcoded)', ''

    # PascalCase or camelCase: keep as-is if already title-cased
    if ($stripped -cmatch '^[A-Z]') {
        return $stripped
    }

    # Capitalize first letter
    if ($stripped.Length -gt 0) {
        return $stripped.Substring(0, 1).ToUpper() + $stripped.Substring(1)
    }

    return $VariableName
}

# ============================================================
# HELPER: Check if a DB table exists
# ============================================================

function Test-DbTableExists {
    param(
        [string]$EntityName,
        [string]$ConnectionString,
        [string]$RepoRoot
    )

    $result = @{
        Exists = $false
        Method = "unknown"
        Evidence = ""
    }

    # Singular/plural candidates
    $candidates = @(
        $EntityName,
        ($EntityName -replace 's$', ''),       # strip trailing s
        ($EntityName + "s"),                    # add s
        ($EntityName -replace 'ies$', 'y'),     # notifications -> notification
        ($EntityName + "ies" -replace 'ys$', 'ies')
    ) | Select-Object -Unique

    if ($ConnectionString) {
        # Live DB check via sqlcmd
        foreach ($candidate in $candidates) {
            $query = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = '$candidate'"
            try {
                $output = & sqlcmd -S . -Q $query -b 2>&1
                if ($output -match '^\s*1\s*$') {
                    $result.Exists = $true
                    $result.Method = "sqlcmd-live"
                    $result.Evidence = "Table '$candidate' confirmed in INFORMATION_SCHEMA"
                    return $result
                }
            } catch { }
        }
        $result.Method = "sqlcmd-live"
    } else {
        # Scan migration .sql files for CREATE TABLE
        $sqlFiles = Get-ChildItem -Path $RepoRoot -Recurse -Filter "*.sql" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](node_modules|bin|obj|\.git)[\\/]' }

        foreach ($sqlFile in $sqlFiles) {
            $content = Get-Content $sqlFile.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }

            foreach ($candidate in $candidates) {
                if ($content -imatch "CREATE\s+TABLE\s+(\[?dbo\]?\.\s*)?(\[?$candidate\]?)") {
                    $result.Exists = $true
                    $result.Method = "migration-scan"
                    $result.Evidence = "CREATE TABLE $candidate found in $($sqlFile.Name)"
                    return $result
                }
            }
        }
        $result.Method = "migration-scan"
    }

    return $result
}

# ============================================================
# HELPER: Check if a controller exists for an entity
# ============================================================

function Test-ControllerExists {
    param([string]$EntityName, [string]$RepoRoot)

    $result = @{ Exists = $false; File = "" }

    $patterns = @(
        "class\s+${EntityName}Controller",
        "class\s+${EntityName}sController",
        "\[Route.*${EntityName}"
    )

    $csFiles = Get-ChildItem -Path $RepoRoot -Recurse -Filter "*Controller*.cs" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](bin|obj|\.git|node_modules)[\\/]' }

    # Also look for any .cs file named {Entity}Controller
    $namedFiles = Get-ChildItem -Path $RepoRoot -Recurse -Filter "${EntityName}*Controller.cs" -ErrorAction SilentlyContinue
    if (-not $namedFiles) {
        $namedFiles = Get-ChildItem -Path $RepoRoot -Recurse -Filter "${EntityName}sController.cs" -ErrorAction SilentlyContinue
    }

    $allControllerFiles = @()
    if ($csFiles) { $allControllerFiles += $csFiles }
    if ($namedFiles) { $allControllerFiles += $namedFiles }
    $allControllerFiles = $allControllerFiles | Sort-Object FullName -Unique

    foreach ($file in $allControllerFiles) {
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        foreach ($pattern in $patterns) {
            if ($content -imatch $pattern) {
                $result.Exists = $true
                $result.File = $file.FullName.Replace($RepoRoot, '').TrimStart('\', '/')
                return $result
            }
        }
    }

    return $result
}

# ============================================================
# HELPER: Check if a service/repository exists for an entity
# ============================================================

function Test-ServiceExists {
    param([string]$EntityName, [string]$RepoRoot)

    $result = @{ Exists = $false; File = "" }

    $candidates = @(
        "${EntityName}Service.cs",
        "${EntityName}sService.cs",
        "${EntityName}Repository.cs",
        "${EntityName}sRepository.cs",
        "I${EntityName}Service.cs",
        "I${EntityName}Repository.cs"
    )

    foreach ($candidate in $candidates) {
        $found = Get-ChildItem -Path $RepoRoot -Recurse -Filter $candidate -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](bin|obj|\.git|node_modules)[\\/]' } |
            Select-Object -First 1

        if ($found) {
            $result.Exists = $true
            $result.File = $found.FullName.Replace($RepoRoot, '').TrimStart('\', '/')
            return $result
        }
    }

    return $result
}

# ============================================================
# STEP 1: Detect mock data patterns
# ============================================================

Write-Host ""
Write-Host "=== Mock-to-DB Gap Detector ===" -ForegroundColor Cyan
Write-Host "Repo: $RepoRoot" -ForegroundColor DarkGray
Write-Host ""

Write-Host "[GAP-DETECT] Scanning for mock data patterns..." -ForegroundColor Cyan

$mockFindings = @()

if (Get-Command Find-MockDataPatterns -ErrorAction SilentlyContinue) {
    $mockFindings = @(Find-MockDataPatterns -RepoRoot $RepoRoot)
} else {
    # Built-in fallback scanner for mock variable patterns
    Write-Host "[GAP-DETECT] Using built-in scanner (mock-data-detector not loaded)" -ForegroundColor Yellow

    $mockVarPattern = '(?i)(const|let|var)\s+(mock|fake|dummy|sample|stub)\w*\s*=\s*[\[\{]'
    $tsFiles = Get-ChildItem -Path $RepoRoot -Recurse -Include @("*.ts", "*.tsx", "*.js", "*.jsx") -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](node_modules|bin|obj|dist|\.git|design)[\\/]' }

    foreach ($file in $tsFiles) {
        $lines = Get-Content $file.FullName -ErrorAction SilentlyContinue
        if (-not $lines) { continue }
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $mockVarPattern) {
                $mockFindings += [PSCustomObject]@{
                    File       = $file.FullName.Replace($RepoRoot, '').TrimStart('\', '/')
                    Line       = $i + 1
                    Pattern    = "Mock data variable"
                    Severity   = "high"
                    Match      = $Matches[0].Substring(0, [Math]::Min(80, $Matches[0].Length))
                }
            }
        }
    }
}

Write-Host "[GAP-DETECT] Found $($mockFindings.Count) mock data occurrences" -ForegroundColor $(if ($mockFindings.Count -gt 0) { "Yellow" } else { "Green" })

# ============================================================
# STEP 2: Extract entity names from mock findings
# ============================================================

$entityNames = [System.Collections.Generic.HashSet[string]]::new()

foreach ($finding in $mockFindings) {
    # Extract variable name from match text
    if ($finding.Match -match '(?i)(mock|fake|dummy|sample|stub|test|hardcoded)(\w+)') {
        $rawEntityName = $Matches[2]
        if ($rawEntityName.Length -gt 2) {
            $entityName = Get-EntityName -VariableName ($Matches[1] + $rawEntityName)
            if ($entityName -and $entityName.Length -gt 2) {
                [void]$entityNames.Add($entityName)
            }
        }
    }
    # Also check file path for entity hints
    if ($finding.File -match '[\\/](use(\w+)|(\w+)Service|(\w+)Hook)\.(ts|tsx)') {
        $candidate = if ($Matches[2]) { $Matches[2] } elseif ($Matches[3]) { $Matches[3] } else { $Matches[4] }
        if ($candidate -and $candidate.Length -gt 2) {
            [void]$entityNames.Add($candidate)
        }
    }
}

Write-Host "[GAP-DETECT] Derived entity names: $($entityNames -join ', ')" -ForegroundColor DarkCyan

# ============================================================
# STEP 3: Check full-stack gaps for each entity
# ============================================================

Write-Host ""
Write-Host "[GAP-DETECT] Checking full-stack gaps..." -ForegroundColor Cyan

$gapReport = @{
    timestamp        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    repo_root        = $RepoRoot
    mock_findings    = $mockFindings.Count
    entities_checked = @()
    gaps_found       = @()
    requirement_templates = @()
}

$autoReqCounter = 1

foreach ($entity in ($entityNames | Sort-Object)) {
    Write-Host "  Checking: $entity" -ForegroundColor DarkGray

    $dbCheck   = Test-DbTableExists   -EntityName $entity -ConnectionString $ConnectionString -RepoRoot $RepoRoot
    $ctrlCheck = Test-ControllerExists -EntityName $entity -RepoRoot $RepoRoot
    $svcCheck  = Test-ServiceExists    -EntityName $entity -RepoRoot $RepoRoot

    $entityResult = @{
        entity             = $entity
        db_table_exists    = $dbCheck.Exists
        db_check_method    = $dbCheck.Method
        db_evidence        = $dbCheck.Evidence
        controller_exists  = $ctrlCheck.Exists
        controller_file    = $ctrlCheck.File
        service_exists     = $svcCheck.Exists
        service_file       = $svcCheck.File
        gaps               = @()
    }

    $hasGap = $false

    if (-not $dbCheck.Exists) {
        $entityResult.gaps += "missing_db_table"
        $hasGap = $true

        $gapReport.requirement_templates += @{
            id          = "AUTO-MOCK-{0:D3}" -f $autoReqCounter
            description = "Create DB migration + seed data for $entity to replace mock data"
            interface   = "database"
            priority    = "high"
            status      = "not_started"
            rationale   = "Mock data detected for $entity — no DB table found via $($dbCheck.Method)"
        }
        $autoReqCounter++

        $gapReport.requirement_templates += @{
            id          = "AUTO-MOCK-{0:D3}" -f $autoReqCounter
            description = "Create stored procedure usp_${entity}_List returning all $entity records"
            interface   = "database"
            priority    = "high"
            status      = "not_started"
            rationale   = "Required by $($entity)Repository once DB table is created"
        }
        $autoReqCounter++
    }

    if (-not $ctrlCheck.Exists) {
        $entityResult.gaps += "missing_controller"
        $hasGap = $true

        $gapReport.requirement_templates += @{
            id          = "AUTO-MOCK-{0:D3}" -f $autoReqCounter
            description = "Create ${entity}Controller with GET /api/${entity} endpoint wired to ${entity}Repository"
            interface   = "backend"
            priority    = "high"
            status      = "not_started"
            rationale   = "Mock data detected for $entity — no controller found"
        }
        $autoReqCounter++
    }

    if (-not $svcCheck.Exists) {
        $entityResult.gaps += "missing_service"
        $hasGap = $true

        $gapReport.requirement_templates += @{
            id          = "AUTO-MOCK-{0:D3}" -f $autoReqCounter
            description = "Create ${entity}Repository implementing I${entity}Repository with Dapper + usp_${entity}_List"
            interface   = "backend"
            priority    = "high"
            status      = "not_started"
            rationale   = "Mock data detected for $entity — no service/repository found"
        }
        $autoReqCounter++
    }

    # Always add a hook rewire requirement if mock data exists for this entity
    $gapReport.requirement_templates += @{
        id          = "AUTO-MOCK-{0:D3}" -f $autoReqCounter
        description = "Rewire use${entity} hook to call real GET /api/${entity} endpoint (remove mock data)"
        interface   = "web"
        priority    = "high"
        status      = "not_started"
        rationale   = "Mock data detected for $entity — hook must call real API"
    }
    $autoReqCounter++

    $gapReport.entities_checked += $entityResult

    if ($hasGap) {
        $gapReport.gaps_found += $entity
        $status = "GAPS: $($entityResult.gaps -join ', ')"
        Write-Host "    $entity -> $status" -ForegroundColor Yellow
    } else {
        Write-Host "    $entity -> OK (db=$($dbCheck.Exists), ctrl=$($ctrlCheck.Exists), svc=$($svcCheck.Exists))" -ForegroundColor Green
    }
}

# ============================================================
# STEP 4: Save report
# ============================================================

$outputDir = Split-Path $OutputPath -Parent
if (-not (Test-Path $outputDir)) {
    New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
}

$gapReport | ConvertTo-Json -Depth 10 | Set-Content $OutputPath -Encoding UTF8
Write-Host ""
Write-Host "[GAP-DETECT] Report saved: $OutputPath" -ForegroundColor Cyan
Write-Host "[GAP-DETECT] Entities with gaps: $($gapReport.gaps_found.Count) / $($gapReport.entities_checked.Count)" -ForegroundColor $(if ($gapReport.gaps_found.Count -gt 0) { "Yellow" } else { "Green" })
Write-Host "[GAP-DETECT] Requirement templates generated: $($gapReport.requirement_templates.Count)" -ForegroundColor Cyan

# ============================================================
# STEP 5: Optionally inject into requirements matrix
# ============================================================

if ($InjectIntoMatrix -and $gapReport.requirement_templates.Count -gt 0) {
    $matrixPath = Join-Path $RepoRoot ".gsd/requirements/requirements-matrix.json"

    if (Test-Path $matrixPath) {
        Write-Host ""
        Write-Host "[GAP-DETECT] Injecting $($gapReport.requirement_templates.Count) requirements into matrix..." -ForegroundColor Cyan

        $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json

        # Renumber AUTO-MOCK IDs to avoid conflicts
        $existingAutoMock = @($matrix.requirements | Where-Object {
            $id = if ($_.id) { $_.id } else { $_.req_id }
            $id -match '^AUTO-MOCK-'
        })
        $startN = $existingAutoMock.Count + 1

        $injected = 0
        foreach ($template in $gapReport.requirement_templates) {
            # Check if a similar requirement already exists
            $desc = $template.description
            $exists = $matrix.requirements | Where-Object {
                $existing = if ($_.description) { $_.description } else { "" }
                $existing -eq $desc
            }
            if ($exists) {
                Write-Host "    SKIP (exists): $desc" -ForegroundColor DarkGray
                continue
            }

            $template.id = "AUTO-MOCK-{0:D3}" -f $startN
            $startN++
            $matrix.requirements += [PSCustomObject]$template
            $injected++
            Write-Host "    INJECTED: $($template.id) — $($template.description.Substring(0, [Math]::Min(70, $template.description.Length)))" -ForegroundColor Green
        }

        # Update summary counts
        if ($matrix.PSObject.Properties.Name -contains 'summary') {
            $matrix.summary.total = $matrix.requirements.Count
            $matrix.summary.not_started = @($matrix.requirements | Where-Object { $_.status -eq "not_started" }).Count
        }

        $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8
        Write-Host "[GAP-DETECT] Injected $injected new requirements into matrix" -ForegroundColor Green
    } else {
        Write-Host "[GAP-DETECT] WARNING: requirements-matrix.json not found — cannot inject" -ForegroundColor Yellow
    }
}

# ============================================================
# STEP 6: Print summary of requirement templates
# ============================================================

if ($gapReport.requirement_templates.Count -gt 0) {
    Write-Host ""
    Write-Host "=== Requirement Templates ===" -ForegroundColor Cyan
    Write-Host "(Add these to your requirements matrix to unblock pipeline)" -ForegroundColor DarkGray
    Write-Host ""

    foreach ($tmpl in $gapReport.requirement_templates) {
        Write-Host "  [$($tmpl.id)] ($($tmpl.interface)) $($tmpl.description)" -ForegroundColor White
    }

    Write-Host ""
    Write-Host "To inject automatically: .\detect-mock-to-db-gaps.ps1 -InjectIntoMatrix" -ForegroundColor DarkCyan
}

return $gapReport
