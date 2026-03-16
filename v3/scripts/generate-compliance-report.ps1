<#
.SYNOPSIS
    Generates a compliance traceability matrix report for a GSD-managed project.
.DESCRIPTION
    Reads the requirements matrix, review iterations, and execution logs to produce:
    - A JSON traceability matrix at .gsd/compliance/traceability-matrix.json
    - A Markdown summary at .gsd/compliance/traceability-summary.md
.PARAMETER RepoRoot
    Path to the project repository root (must contain .gsd/ directory).
.EXAMPLE
    .\generate-compliance-report.ps1 -RepoRoot "D:\vscode\tech-web-chatai.v8\tech-web-chatai.v8"
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$gsdDir        = Join-Path $RepoRoot '.gsd'
$matrixPath    = Join-Path $gsdDir 'requirements\requirements-matrix.json'
$reviewsDir    = Join-Path $gsdDir 'iterations\reviews'
$execLogDir    = Join-Path $gsdDir 'iterations\execution-log'
$complianceDir = Join-Path $gsdDir 'compliance'

if (-not (Test-Path $matrixPath)) {
    Write-Error "Requirements matrix not found at $matrixPath"
    return
}

# Ensure output directory
if (-not (Test-Path $complianceDir)) {
    New-Item -ItemType Directory -Path $complianceDir -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Load requirements matrix
# ---------------------------------------------------------------------------
Write-Host "[1/6] Loading requirements matrix..." -ForegroundColor Cyan
$matrixRaw = Get-Content $matrixPath -Raw
$matrix    = $matrixRaw | ConvertFrom-Json
$reqs      = $matrix.requirements
Write-Host "       Loaded $($reqs.Count) requirements"

# ---------------------------------------------------------------------------
# Load review iterations (build lookup: req_id -> iteration + status)
# ---------------------------------------------------------------------------
Write-Host "[2/6] Loading review iterations..." -ForegroundColor Cyan
$reviewLookup = @{}  # req_id -> @{ iteration; status }

if (Test-Path $reviewsDir) {
    $reviewFiles = Get-ChildItem -Path $reviewsDir -Filter 'iteration-*.json' -File
    foreach ($rf in $reviewFiles) {
        $raw = Get-Content $rf.FullName -Raw
        # Strip markdown code fences if present
        $raw = $raw -replace '^\s*```json\s*', '' -replace '\s*```\s*$', ''
        try {
            $reviewData = $raw | ConvertFrom-Json
        } catch {
            Write-Host "       WARNING: Could not parse $($rf.Name)" -ForegroundColor Yellow
            continue
        }
        $iterNum = $reviewData.iteration
        if ($reviewData.reviews) {
            foreach ($rev in $reviewData.reviews) {
                $rid = $rev.req_id
                # Keep the latest iteration for each req
                if (-not $reviewLookup.ContainsKey($rid) -or $iterNum -gt $reviewLookup[$rid].iteration) {
                    $reviewLookup[$rid] = @{
                        iteration = $iterNum
                        status    = $rev.status
                    }
                }
            }
        }
    }
}
Write-Host "       Found review data for $($reviewLookup.Count) requirements across $($reviewFiles.Count) iterations"

# ---------------------------------------------------------------------------
# Load execution log filenames (for file inference)
# ---------------------------------------------------------------------------
Write-Host "[3/6] Loading execution logs..." -ForegroundColor Cyan
$execLogReqs = @()
if (Test-Path $execLogDir) {
    $execLogReqs = Get-ChildItem -Path $execLogDir -Filter '*.txt' -File | ForEach-Object {
        $_.BaseName  # e.g. CL-020
    }
}
Write-Host "       Found $($execLogReqs.Count) execution log entries"

# ---------------------------------------------------------------------------
# Compliance keyword maps
# ---------------------------------------------------------------------------
$complianceKeywords = @{
    'HIPAA' = @('patient', 'health', 'medical', 'phi', 'audit', 'encryption', 'access control', 'hipaa', 'protected health')
    'SOC2'  = @('auth', 'security', 'logging', 'monitoring', 'backup', 'access', 'soc2', 'soc 2', 'mfa', 'multi-factor', 'rbac', 'role-based')
    'PCI'   = @('payment', 'card', 'billing', 'transaction', 'encrypt', 'pci', 'stripe', 'charge', 'invoice')
    'GDPR'  = @('consent', 'data subject', 'erasure', 'privacy', 'personal data', 'cookie', 'gdpr', 'right to be forgotten', 'data retention')
}

# ---------------------------------------------------------------------------
# Interface -> file path prefix inference map
# ---------------------------------------------------------------------------
$interfacePathMap = @{
    'backend'     = 'src/Server/Technijian.Api/'
    'frontend'    = 'src/Client/technijian-spa/'
    'web'         = 'src/Client/technijian-spa/'
    'database'    = 'db/'
    'security'    = 'src/Server/Technijian.Api/Security/'
    'integration' = 'src/Server/Technijian.Api/Services/'
    'shared'      = 'src/shared/'
}

# ---------------------------------------------------------------------------
# Process each requirement
# ---------------------------------------------------------------------------
Write-Host "[4/6] Processing requirements..." -ForegroundColor Cyan

$results       = @()
$countMapped   = 0
$countReviewed = 0
$countTagged   = 0
$complianceCounts = @{ 'HIPAA' = 0; 'SOC2' = 0; 'PCI' = 0; 'GDPR' = 0 }

$statusCounts = @{}

foreach ($req in $reqs) {
    $id          = $req.id
    $desc        = if ($req.PSObject.Properties['description'] -and $req.description) { $req.description } else { '' }
    $iface       = if ($req.PSObject.Properties['interface'] -and $req.interface) { $req.interface } else { 'other' }
    $status      = if ($req.PSObject.Properties['status'] -and $req.status) { $req.status } else { 'unknown' }
    $satisfiedBy = if ($req.PSObject.Properties['satisfied_by'] -and $req.satisfied_by) { $req.satisfied_by } else { '' }
    $notes       = if ($req.PSObject.Properties['notes'] -and $req.notes) { $req.notes } else { '' }

    # Count statuses
    if (-not $statusCounts.ContainsKey($status)) { $statusCounts[$status] = 0 }
    $statusCounts[$status]++

    # --- File mapping ---
    $files = @()
    $mappingSource = 'unmapped'

    if ($satisfiedBy -and $satisfiedBy -notmatch '^direct-fix-session' -and $satisfiedBy -notmatch '^iteration-' -and $satisfiedBy -match '[/\\]') {
        # Has a real file path in satisfied_by
        $files = @($satisfiedBy -split ',\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $mappingSource = 'matrix'
    }
    elseif ($satisfiedBy -match '^direct-fix-session') {
        # Direct fix - try to infer from interface
        if ($interfacePathMap.ContainsKey($iface)) {
            $files = @($interfacePathMap[$iface] + '*')
            $mappingSource = 'inferred'
        }
    }

    # If still unmapped but satisfied, try inference from interface
    if ($files.Count -eq 0 -and $status -eq 'satisfied' -and $interfacePathMap.ContainsKey($iface)) {
        $files = @($interfacePathMap[$iface] + '*')
        $mappingSource = 'inferred'
    }

    if ($files.Count -gt 0) { $countMapped++ }

    # --- Review evidence ---
    $reviewed = $false
    $reviewIteration = $null
    if ($reviewLookup.ContainsKey($id)) {
        $reviewed = $true
        $reviewIteration = $reviewLookup[$id].iteration
        $countReviewed++
    }

    # --- Compliance tagging ---
    $searchText = ($desc + ' ' + $iface + ' ' + $notes).ToLower()
    $tags = @()
    foreach ($cat in $complianceKeywords.Keys) {
        foreach ($kw in $complianceKeywords[$cat]) {
            if ($searchText.Contains($kw)) {
                $tags += $cat
                break
            }
        }
    }
    if ($tags.Count -gt 0) {
        $countTagged++
        foreach ($t in $tags) {
            $complianceCounts[$t]++
        }
    }

    # --- Evidence summary ---
    $evidence = ''
    if ($status -eq 'satisfied' -and $notes) {
        # Truncate notes to 120 chars for evidence
        $evidence = if ($notes.Length -gt 120) { $notes.Substring(0, 120) + '...' } else { $notes }
    }
    elseif ($status -eq 'satisfied') {
        $evidence = "Marked satisfied; satisfied_by=$satisfiedBy"
    }

    # Build output object (use ordered hashtable for JSON key order)
    $entry = [ordered]@{
        id                  = $id
        description         = $desc
        interface           = $iface
        status              = $status
        files               = $files
        file_mapping_source = $mappingSource
        reviewed            = $reviewed
        review_iteration    = $reviewIteration
        compliance_tags     = $tags
        evidence            = $evidence
    }
    $results += $entry
}

# ---------------------------------------------------------------------------
# Build summary
# ---------------------------------------------------------------------------
$summary = [ordered]@{
    total            = $reqs.Count
    satisfied        = if ($statusCounts.ContainsKey('satisfied')) { $statusCounts['satisfied'] } else { 0 }
    partial          = if ($statusCounts.ContainsKey('partial')) { $statusCounts['partial'] } else { 0 }
    not_started      = if ($statusCounts.ContainsKey('not_started')) { $statusCounts['not_started'] } else { 0 }
    mapped_to_files  = $countMapped
    reviewed         = $countReviewed
    compliance_tagged = $countTagged
}

# ---------------------------------------------------------------------------
# Build final report
# ---------------------------------------------------------------------------
Write-Host "[5/6] Writing JSON report..." -ForegroundColor Cyan

$report = [ordered]@{
    generated_at  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    project       = 'tech-web-chatai.v8'
    summary       = $summary
    by_compliance = [ordered]@{
        HIPAA = $complianceCounts['HIPAA']
        SOC2  = $complianceCounts['SOC2']
        PCI   = $complianceCounts['PCI']
        GDPR  = $complianceCounts['GDPR']
    }
    requirements  = $results
}

# PS5.1-compatible JSON serialization
# ConvertTo-Json -Depth handles nested objects
$jsonOut = $report | ConvertTo-Json -Depth 6 -Compress:$false
$jsonOutPath = Join-Path $complianceDir 'traceability-matrix.json'
[System.IO.File]::WriteAllText($jsonOutPath, $jsonOut, [System.Text.Encoding]::UTF8)
Write-Host "       Written to $jsonOutPath"

# ---------------------------------------------------------------------------
# Generate Markdown summary
# ---------------------------------------------------------------------------
Write-Host "[6/6] Writing Markdown summary..." -ForegroundColor Cyan

$md = @()
$md += '# Compliance Traceability Matrix'
$md += ''
$md += "**Project:** tech-web-chatai.v8"
$md += "**Generated:** $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC"
$md += ''
$md += '## Summary'
$md += ''
$md += "| Metric | Count |"
$md += "|--------|------:|"
$md += "| Total Requirements | $($summary.total) |"
$md += "| Satisfied | $($summary.satisfied) |"
$md += "| Partial | $($summary.partial) |"
$md += "| Not Started | $($summary.not_started) |"
$md += "| Mapped to Files | $($summary.mapped_to_files) |"
$md += "| Reviewed | $($summary.reviewed) |"
$md += "| Compliance Tagged | $($summary.compliance_tagged) |"
$md += ''
$md += '## Compliance Coverage'
$md += ''
$md += "| Category | Requirements |"
$md += "|----------|------------:|"
$md += "| HIPAA | $($complianceCounts['HIPAA']) |"
$md += "| SOC2 | $($complianceCounts['SOC2']) |"
$md += "| PCI | $($complianceCounts['PCI']) |"
$md += "| GDPR | $($complianceCounts['GDPR']) |"
$md += ''
$md += '## By Interface'
$md += ''
$md += "| Interface | Total | Satisfied | Compliance Tagged |"
$md += "|-----------|------:|----------:|------------------:|"

# Group by interface
$ifaceGroups = @{}
foreach ($r in $results) {
    $ikey = $r.interface
    if (-not $ifaceGroups.ContainsKey($ikey)) {
        $ifaceGroups[$ikey] = @{ total = 0; satisfied = 0; tagged = 0 }
    }
    $ifaceGroups[$ikey].total++
    if ($r.status -eq 'satisfied') { $ifaceGroups[$ikey].satisfied++ }
    if ($r.compliance_tags.Count -gt 0) { $ifaceGroups[$ikey].tagged++ }
}
foreach ($ikey in ($ifaceGroups.Keys | Sort-Object)) {
    $g = $ifaceGroups[$ikey]
    $md += "| $ikey | $($g.total) | $($g.satisfied) | $($g.tagged) |"
}

$md += ''
$md += '## Compliance-Tagged Requirements (sample)'
$md += ''
$md += "| ID | Interface | Status | Compliance | Description (truncated) |"
$md += "|----|-----------|--------|------------|------------------------|"

$taggedSample = $results | Where-Object { $_.compliance_tags.Count -gt 0 } | Select-Object -First 40
foreach ($r in $taggedSample) {
    $descShort = if ($r.description.Length -gt 60) { $r.description.Substring(0, 60) + '...' } else { $r.description }
    $tagsStr = ($r.compliance_tags -join ', ')
    $md += "| $($r.id) | $($r.interface) | $($r.status) | $tagsStr | $descShort |"
}

$md += ''
$md += '## Unmapped Requirements (no file association)'
$md += ''
$unmapped = $results | Where-Object { $_.file_mapping_source -eq 'unmapped' -and $_.status -eq 'satisfied' }
$md += "**$($unmapped.Count) satisfied requirements** have no file mapping."
$md += ''
if ($unmapped.Count -gt 0) {
    $md += "| ID | Interface | Description (truncated) |"
    $md += "|----|-----------|------------------------|"
    $unmappedSample = $unmapped | Select-Object -First 20
    foreach ($r in $unmappedSample) {
        $descShort = if ($r.description.Length -gt 70) { $r.description.Substring(0, 70) + '...' } else { $r.description }
        $md += "| $($r.id) | $($r.interface) | $descShort |"
    }
    if ($unmapped.Count -gt 20) {
        $md += ""
        $md += "*(showing first 20 of $($unmapped.Count))*"
    }
}

$md += ''
$md += '---'
$md += '*Generated by generate-compliance-report.ps1*'

$mdPath = Join-Path $complianceDir 'traceability-summary.md'
$mdContent = $md -join "`r`n"
[System.IO.File]::WriteAllText($mdPath, $mdContent, [System.Text.Encoding]::UTF8)
Write-Host "       Written to $mdPath"

# ---------------------------------------------------------------------------
# Print summary to console
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  COMPLIANCE TRACEABILITY REPORT COMPLETE"   -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Total Requirements:   $($summary.total)"
Write-Host "  Satisfied:            $($summary.satisfied)"
Write-Host "  Partial:              $($summary.partial)"
Write-Host "  Not Started:          $($summary.not_started)"
Write-Host "  Mapped to Files:      $($summary.mapped_to_files)"
Write-Host "  Reviewed:             $($summary.reviewed)"
Write-Host "  Compliance Tagged:    $($summary.compliance_tagged)"
Write-Host ""
Write-Host "  HIPAA:  $($complianceCounts['HIPAA'])   SOC2: $($complianceCounts['SOC2'])   PCI: $($complianceCounts['PCI'])   GDPR: $($complianceCounts['GDPR'])"
Write-Host ""
Write-Host "  JSON:     $jsonOutPath"
Write-Host "  Markdown: $mdPath"
Write-Host ""
