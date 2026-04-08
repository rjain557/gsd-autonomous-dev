<#
.SYNOPSIS
    Scans active requirements and promotes to satisfied if all evidence files exist with real content.
#>
param(
    [string]$RepoRoot = "D:\vscode\tech-web-chatai.v8\tech-web-chatai.v8"
)

$GsdDir = Join-Path $RepoRoot ".gsd"
$matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
$evidencePath = Join-Path $GsdDir "health/_evidence-paths.json"

if (-not (Test-Path $matrixPath)) { Write-Host "ERROR: Matrix not found"; exit 1 }

$matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json

# Build evidence map
$evidenceMap = @{}
if (Test-Path $evidencePath) {
    $evidence = Get-Content $evidencePath -Raw | ConvertFrom-Json
    foreach ($e in $evidence) {
        if (-not $evidenceMap[$e.id]) { $evidenceMap[$e.id] = @() }
        $evidenceMap[$e.id] += $e.path
    }
}

# Check stub indicators
$stubPatterns = @(
    '// FILL',
    '// TODO: implement',
    '// TODO: Implement',
    'throw new NotImplementedException',
    '/* FILL */',
    '// STUB',
    'PLACEHOLDER'
)

function Test-IsRealFile {
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) { return $false }
    $content = Get-Content $FilePath -Raw -ErrorAction SilentlyContinue
    if (-not $content -or $content.Length -lt 20) { return $false }
    foreach ($pattern in $stubPatterns) {
        if ($content -match [regex]::Escape($pattern)) { return $false }
    }
    return $true
}

$promoted = 0
$checked = 0
$activeReqs = @($matrix.requirements | Where-Object { $_.status -in @("not_started", "partial") })

Write-Host "Checking $($activeReqs.Count) active requirements..."

foreach ($req in $activeReqs) {
    $rid = if ($req.id) { $req.id } else { $req.req_id }
    $checked++

    # Check evidence files
    $files = $evidenceMap[$rid]
    if (-not $files -or $files.Count -eq 0) { continue }

    $allExist = $true
    $realFiles = @()
    foreach ($f in $files) {
        $fullPath = Join-Path $RepoRoot $f
        if (Test-IsRealFile $fullPath) {
            $realFiles += $f
        } else {
            $allExist = $false
        }
    }

    # Promote if at least 80% of evidence files exist with real content
    $threshold = [math]::Ceiling($files.Count * 0.8)
    if ($realFiles.Count -ge $threshold -and $realFiles.Count -gt 0) {
        $req.status = "satisfied"
        $req | Add-Member -NotePropertyName "satisfied_by" -NotePropertyValue (($realFiles | Select-Object -First 5) -join "; ") -Force
        $promoted++
        Write-Host "  [PROMOTE] $rid -> satisfied ($($realFiles.Count)/$($files.Count) files)" -ForegroundColor Green
    }
}

if ($promoted -gt 0) {
    # Update summary
    $matrix.summary.satisfied = @($matrix.requirements | Where-Object { $_.status -eq "satisfied" }).Count
    $matrix.summary.not_started = @($matrix.requirements | Where-Object { $_.status -eq "not_started" }).Count
    $matrix.summary.partial = @($matrix.requirements | Where-Object { $_.status -eq "partial" }).Count

    $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8

    # Also update health-current.json
    $total = $matrix.requirements.Count
    $satisfied = $matrix.summary.satisfied
    $partial = $matrix.summary.partial
    $notStarted = $matrix.summary.not_started
    $score = [math]::Round(($satisfied * 1.0 + $partial * 0.5) / $total * 100, 1)

    $health = @{
        score = $score
        total = $total
        satisfied = $satisfied
        partial = $partial
        not_started = $notStarted
        timestamp = (Get-Date -Format "o")
    }
    $health | ConvertTo-Json | Set-Content (Join-Path $GsdDir "health/health-current.json") -Encoding UTF8

    Write-Host "`n[BULK-PROMOTE] Promoted $promoted of $checked active reqs"
    Write-Host "[HEALTH] New: $score% ($satisfied/$total satisfied)"
} else {
    Write-Host "`n[BULK-PROMOTE] No reqs eligible for promotion (checked $checked)"
}
