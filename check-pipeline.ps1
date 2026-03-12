Get-Process pwsh -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*gsd-update*' } | Select-Object Id, CPU, StartTime | Format-Table
