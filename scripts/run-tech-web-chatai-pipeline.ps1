$ErrorActionPreference = "Stop"

$workspace = "d:\vscode\gsd-autonomous-dev\gsd-autonomous-dev"
$repo = "D:\vscode\tech-web-chatai.v8\tech-web-chatai.v8"
$testUsers = '[{"email":"ssingh@technijian.com"},{"email":"kjagota@technijian.com"}]'

Set-Location $workspace

pwsh -File ".\v3\scripts\gsd-full-pipeline.ps1" `
    -RepoRoot $repo `
    -StartFrom runtime `
    -BackendPort 5000 `
    -FrontendPort 3000 `
    -TestUsers $testUsers
