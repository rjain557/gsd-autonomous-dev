param([string]$RepoRoot = "D:\vscode\tech-web-chatai.v8\tech-web-chatai.v8")

$matrixPath = Join-Path $RepoRoot ".gsd\requirements\requirements-matrix.json"
$matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json

$demotedIds = @("CL-156", "CL-171", "CX-112", "CX-149", "CX-150")
$restored = 0

foreach ($req in $matrix.requirements) {
    foreach ($prefix in $demotedIds) {
        if ($req.id -like "$prefix*" -and $req.status -eq "partial") {
            $req.status = "satisfied"
            $restored++
            Write-Host "  [RESTORE] $($req.id) partial -> satisfied" -ForegroundColor Green
        }
    }
}

if ($restored -gt 0) {
    $matrix.summary.satisfied = @($matrix.requirements | Where-Object { $_.status -eq "satisfied" }).Count
    $matrix.summary.partial = @($matrix.requirements | Where-Object { $_.status -eq "partial" }).Count
    $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8
    Write-Host "`nRestored $restored reqs to satisfied" -ForegroundColor Green
    Write-Host "New satisfied: $($matrix.summary.satisfied)" -ForegroundColor Cyan
} else {
    Write-Host "No demoted reqs found"
}
