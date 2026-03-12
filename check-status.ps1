$ErrorActionPreference = 'SilentlyContinue'
# Find the pipeline by looking for the largest pwsh process (pipeline uses most memory)
$allPwsh = Get-Process -Name pwsh -EA SilentlyContinue | Sort-Object WorkingSet64 -Descending
$pipe = $allPwsh | Select-Object -First 1
if ($pipe -and $pipe.WorkingSet64 -gt 100MB) {
    $mb = [math]::Round($pipe.WorkingSet64/1MB)
    Write-Output "PIPELINE: ALIVE PID=$($pipe.Id) CPU=$($pipe.CPU) MB=$mb"
} else {
    Write-Output "PIPELINE: LIKELY DEAD (no large pwsh process)"
    $allPwsh | ForEach-Object {
        $mb2 = [math]::Round($_.WorkingSet64/1MB)
        Write-Output "  pwsh PID=$($_.Id) CPU=$($_.CPU) MB=$mb2"
    }
}

# Check critical files
$prog = (Get-Content "D:\vscode\tech-web-chatai.v8\tech-web-chatai.v8\src\Server\Technijian.Api\Program.cs" -EA SilentlyContinue | Measure-Object -Line).Lines
$auth = (Get-Content "D:\vscode\tech-web-chatai.v8\tech-web-chatai.v8\src\Server\Technijian.Api\Controllers\AuthController.cs" -EA SilentlyContinue | Measure-Object -Line).Lines
Write-Output "Program.cs: $prog lines"
Write-Output "AuthController.cs: $auth lines"

# PowerShell Measure-Object -Line counts ~659 for the 758-line file (line ending diff vs wc -l)
if ($prog -lt 620) { Write-Output "DISEASE-14: Program.cs OVERWRITTEN! Needs restore!" }
if ($auth -lt 560) { Write-Output "DISEASE-14: AuthController.cs OVERWRITTEN! Needs restore!" }

# Check FILL stubs
$fills = Get-ChildItem "D:\vscode\tech-web-chatai.v8\tech-web-chatai.v8\src\Server\Technijian.Api" -Recurse -Filter "*.cs" | Select-String -Pattern "// FILL" -List
if ($fills) {
    Write-Output "FILL STUBS FOUND:"
    foreach ($f in $fills) { Write-Output "  $($f.Path)" }
} else {
    Write-Output "FILL STUBS: NONE"
}

# Health
$r = "D:/vscode/tech-web-chatai.v8/tech-web-chatai.v8"
$h = Get-Content "$r/.gsd/health/health-current.json" -Raw -EA SilentlyContinue | ConvertFrom-Json
if ($h) { Write-Output "Health: $($h.health_score)% ($($h.satisfied)/$($h.partial)/$($h.not_started))" }

# Recent pipeline log
Write-Output "--- LAST 30 LOG LINES ---"
Get-Content "D:\vscode\gsd-autonomous-dev\gsd-autonomous-dev\v3-pipeline.log" -Tail 30 -EA SilentlyContinue
