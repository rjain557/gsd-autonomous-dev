$procs = Get-Process pwsh -ErrorAction SilentlyContinue
foreach ($p in $procs) {
    try {
        $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $($p.Id)").CommandLine
        if ($cmd -like '*gsd-update*') {
            Write-Output "FOUND pipeline: PID=$($p.Id) CPU=$($p.CPU) Start=$($p.StartTime)"
            Write-Output "CMD: $cmd"
        }
    } catch {}
}
if (-not $found) {
    Write-Output "No pipeline process found"
    Write-Output "All pwsh processes:"
    Get-Process pwsh -ErrorAction SilentlyContinue | Select-Object Id, CPU, StartTime | Format-Table
}
