---
name: feedback-partial-promotion-cron
description: CRITICAL - Every cron tick must check for partial requirements and promote to satisfied when files exist
type: feedback
---

Every OPTIMIZER cron tick must include a partial→satisfied promotion step.

**Why:** User explicitly requested this. 317 partials were sitting as "partial" even though their referenced files existed. A single promotion pass jumped health from 70.3% to 81.1%. The pipeline's Verify phase only checks 100 reqs per iteration, so partials accumulate faster than they get promoted.

**How to apply:** Add this step to every cron tick (after log check, before cross-session update):

```powershell
# Promote partials where satisfied_by file(s) exist
$matrixPath = "path\to\requirements-matrix.json"
$matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
$promoted = 0
foreach ($r in $matrix.requirements) {
    if ($r.status -ne "partial") { continue }
    if (-not $r.satisfied_by) { continue }
    $files = $r.satisfied_by -split '[,;]' | ForEach-Object { $_.Trim() }
    $anyExists = $false
    foreach ($f in $files) {
        if ($f -and (Test-Path "REPO_ROOT\$f")) { $anyExists = $true; break }
    }
    if ($anyExists) { $r.status = "satisfied"; $promoted++ }
}
if ($promoted -gt 0) { $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8 }
```

Only run if partials > 0. Report count in cross-session update.
