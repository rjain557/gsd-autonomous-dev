$proc = Start-Process pwsh -ArgumentList "-NoExit","-File","D:\vscode\gsd-autonomous-dev\gsd-autonomous-dev\v3\scripts\gsd-update.ps1","-RepoRoot","D:\vscode\tech-web-chatai.v8\tech-web-chatai.v8" -WindowStyle Normal -PassThru
Write-Output "PID: $($proc.Id)"
