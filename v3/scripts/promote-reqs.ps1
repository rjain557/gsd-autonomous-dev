param([string]$RepoRoot = "D:\vscode\tech-web-chatai.v8\tech-web-chatai.v8")

$matrixPath = Join-Path $RepoRoot ".gsd\requirements\requirements-matrix.json"
$matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
$notStarted = @($matrix.requirements | Where-Object { $_.status -eq "not_started" -and $_.target_files })
Write-Host "Not started with target_files: $($notStarted.Count)"

$promoted = 0
foreach ($req in $notStarted) {
    $allExist = $true
    foreach ($f in $req.target_files) {
        $full = Join-Path $RepoRoot $f
        if (-not (Test-Path $full)) { $allExist = $false; break }
    }
    if ($allExist -and $req.target_files.Count -gt 0) {
        $req.status = "satisfied"
        $promoted++
        Write-Host "  [PROMOTE] $($req.id) ($($req.target_files.Count) files)" -ForegroundColor Green
    }
}

if ($promoted -gt 0) {
    $matrix.summary.satisfied = @($matrix.requirements | Where-Object { $_.status -eq "satisfied" }).Count
    $matrix.summary.not_started = @($matrix.requirements | Where-Object { $_.status -eq "not_started" }).Count
    $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8
    Write-Host "`nPromoted $promoted reqs to satisfied" -ForegroundColor Green
    Write-Host "New satisfied: $($matrix.summary.satisfied)" -ForegroundColor Cyan
} else {
    Write-Host "No reqs eligible for promotion (files missing)"
}
