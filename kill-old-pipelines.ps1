# Kill old pipeline processes, keep only PID 26736
$keepPid = 26736
$procs = Get-Process pwsh -ErrorAction SilentlyContinue
foreach ($p in $procs) {
    try {
        $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $($p.Id)").CommandLine
        if ($cmd -like '*gsd-update*' -and $p.Id -ne $keepPid) {
            Write-Output "Killing old pipeline PID $($p.Id) (started $($p.StartTime))"
            Stop-Process -Id $p.Id -Force
        }
    } catch {}
}
Write-Output "Done. Kept PID $keepPid"
