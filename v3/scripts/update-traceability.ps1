<#
.SYNOPSIS
    Updates traceability matrix — maps satisfied requirements to their implementing code files.
.DESCRIPTION
    Scans the evidence-paths and execution logs to build a req→file mapping,
    then updates requirements-matrix.json with satisfied_by fields.
    Also generates a traceability report.
#>
param(
    [string]$RepoRoot = "D:\vscode\tech-web-chatai.v8\tech-web-chatai.v8"
)

$GsdDir = Join-Path $RepoRoot ".gsd"
$matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
$evidencePath = Join-Path $GsdDir "health/_evidence-paths.json"

if (-not (Test-Path $matrixPath)) { Write-Host "ERROR: Matrix not found at $matrixPath"; exit 1 }

# Load matrix
$matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json

# Build evidence map: req_id → list of files
$evidenceMap = @{}
if (Test-Path $evidencePath) {
    $evidence = Get-Content $evidencePath -Raw | ConvertFrom-Json
    foreach ($e in $evidence) {
        $id = $e.id
        $file = $e.path -replace '\\', '/'
        if (-not $evidenceMap[$id]) { $evidenceMap[$id] = @() }
        if ($file -notin $evidenceMap[$id]) {
            $evidenceMap[$id] += $file
        }
    }
}

# Scan execution logs for additional file mappings
$execLogDir = Join-Path $GsdDir "iterations/execution-log"
if (Test-Path $execLogDir) {
    $logFiles = Get-ChildItem $execLogDir -Filter "*.txt" -ErrorAction SilentlyContinue
    foreach ($logFile in $logFiles) {
        $reqId = $logFile.BaseName
        $content = Get-Content $logFile.FullName -Raw -ErrorAction SilentlyContinue
        if ($content) {
            # Extract file paths from execution logs
            $fileMatches = [regex]::Matches($content, '(?:WRITE|PASS|OK)\]\s+(\S+\.\w+)')
            foreach ($m in $fileMatches) {
                $file = $m.Groups[1].Value -replace '\\', '/'
                if (-not $evidenceMap[$reqId]) { $evidenceMap[$reqId] = @() }
                if ($file -notin $evidenceMap[$reqId]) {
                    $evidenceMap[$reqId] += $file
                }
            }
        }
    }
}

# Also scan the v3 pipeline log for WRITE events mapped to req IDs
$latestLog = Get-ChildItem "D:\vscode\gsd-autonomous-dev\gsd-autonomous-dev\logs\v3-pipeline-*.log" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latestLog) {
    $logContent = Get-Content $latestLog.FullName -Raw -ErrorAction SilentlyContinue
    # Match patterns like "[OK] CL-144 (1234 tokens)" and nearby "[WRITE] path"
    # This is complex in the log format, so we'll rely on evidence-paths primarily
}

# Update matrix with satisfied_by
$updated = 0
$traceReport = @()
foreach ($req in $matrix.requirements) {
    $rid = if ($req.id) { $req.id } else { $req.req_id }

    if ($evidenceMap[$rid] -and $evidenceMap[$rid].Count -gt 0) {
        $files = $evidenceMap[$rid] | Select-Object -Unique
        # Verify files actually exist
        $existingFiles = @()
        foreach ($f in $files) {
            $fullPath = Join-Path $RepoRoot $f
            if (Test-Path $fullPath) { $existingFiles += $f }
        }

        if ($existingFiles.Count -gt 0) {
            $satisfiedBy = ($existingFiles | Select-Object -First 5) -join "; "

            # Add satisfied_by to req
            if (-not $req.satisfied_by -or $req.satisfied_by -ne $satisfiedBy) {
                $req | Add-Member -NotePropertyName "satisfied_by" -NotePropertyValue $satisfiedBy -Force
                $updated++
            }

            $traceReport += [PSCustomObject]@{
                ReqId = $rid
                Status = $req.status
                FileCount = $existingFiles.Count
                Files = $satisfiedBy
            }
        }
    }
}

# Save updated matrix
$matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8
Write-Host "[TRACEABILITY] Updated $updated requirements with satisfied_by mappings"

# Generate traceability report
$reportPath = Join-Path $GsdDir "health/traceability-report.md"
$report = @"
# Traceability Matrix Report
Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

## Summary
- Total Requirements: $($matrix.requirements.Count)
- Satisfied: $(@($matrix.requirements | Where-Object { $_.status -eq 'satisfied' }).Count)
- Partial: $(@($matrix.requirements | Where-Object { $_.status -eq 'partial' }).Count)
- Not Started: $(@($matrix.requirements | Where-Object { $_.status -eq 'not_started' }).Count)
- Requirements with file mappings: $($traceReport.Count)

## Requirements → Code Mapping

| Req ID | Status | Files | Implementing Code |
|--------|--------|-------|-------------------|
"@

foreach ($t in ($traceReport | Sort-Object ReqId)) {
    $report += "| $($t.ReqId) | $($t.Status) | $($t.FileCount) | $($t.Files) |`n"
}

# Unmapped reqs
$unmapped = @($matrix.requirements | Where-Object {
    $rid = if ($_.id) { $_.id } else { $_.req_id }
    -not $evidenceMap[$rid] -and $_.status -ne "satisfied"
})
if ($unmapped.Count -gt 0) {
    $report += "`n## Unmapped Active Requirements ($($unmapped.Count))`n"
    foreach ($u in $unmapped | Select-Object -First 50) {
        $rid = if ($u.id) { $u.id } else { $u.req_id }
        $desc = if ($u.description.Length -gt 80) { $u.description.Substring(0, 80) + "..." } else { $u.description }
        $report += "- **$rid** ($($u.status)): $desc`n"
    }
}

Set-Content $reportPath -Value $report -Encoding UTF8
Write-Host "[TRACEABILITY] Report saved to $reportPath"
Write-Host "[TRACEABILITY] $($traceReport.Count) reqs mapped to code files"
