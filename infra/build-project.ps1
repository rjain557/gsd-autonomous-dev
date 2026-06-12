<#
.SYNOPSIS
  Build, deploy, and verify a provisioned GSD project's components from its repo:
  web (npm/Vite) + API (dotnet publish .NET 10) + SQL (db/*.sql) + MCP admin,
  then health-check and record everything in gsd_dev_memory.
  Run ./infra/provision-project.ps1 first.

.EXAMPLE
  ./infra/build-project.ps1 -Project myhr -RepoPath D:\VSCode\myhr -DryRun
  ./infra/build-project.ps1 -Project myhr
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Project,
    [string]$RepoPath,
    [string]$SiteRootBase = 'C:\inetpub\gsd',
    [switch]$DryRun
)
. (Join-Path $PSScriptRoot 'deploy-lib.ps1')

$projId = Get-ProjectId $Project
if (-not $projId) { throw "Project '$Project' not registered. Run provision-project.ps1 first." }
if (-not $RepoPath) {
    $RepoPath = (Invoke-Sql -Database $script:DevMemoryDb -NoHeaders -Query "SET NOCOUNT ON; SELECT RepoPath FROM dbo.Projects WHERE Id=$projId;" | Where-Object { "$_".Trim() } | Select-Object -First 1)
    $RepoPath = "$RepoPath".Trim()
}
if (-not $RepoPath -or -not (Test-Path $RepoPath)) { throw "RepoPath not found: '$RepoPath'" }

$siteRoot = Join-Path $SiteRootBase $Project
$webDir   = Join-Path $siteRoot 'web'
$apiDir   = Join-Path $siteRoot 'api'
$adminDir = Join-Path $siteRoot 'mcp-admin'
$Subdomain = "$Project.rjain.technijian.com"
$dotnet = Get-DotNet

function Phase([string]$kind, [string]$name, [scriptblock]$do) {
    if ($DryRun) { Write-Host "  [dry] $name" -ForegroundColor DarkYellow; return }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $do
        $sw.Stop()
        Write-BuildRun -Project $Project -Phase $kind -Result 'ok' -Detail $name -DurationMs $sw.ElapsedMilliseconds
        Write-Host "  [ok]  $name ($($sw.ElapsedMilliseconds)ms)"
    } catch {
        $sw.Stop()
        Write-BuildRun -Project $Project -Phase $kind -Result 'fail' -Detail "$name :: $($_.Exception.Message)" -DurationMs $sw.ElapsedMilliseconds
        Write-Host "  [FAIL] $name :: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

# Find first existing subdir from a list, else $null
function Find-Dir([string[]]$candidates) { foreach ($c in $candidates) { $p = Join-Path $RepoPath $c; if (Test-Path $p) { return $p } }; return $null }

Write-Host "== Build '$Project' from $RepoPath $(if($DryRun){'(DRY RUN)'}) ==" -ForegroundColor Cyan

# --- WEB (React + Fluent v9) ------------------------------------------------
$webSrc = Find-Dir @('web', 'client', 'frontend', 'src/web', '.')
if ($webSrc -and (Test-Path (Join-Path $webSrc 'package.json'))) {
    Phase 'build' "web: npm ci + build -> $webDir" {
        Push-Location $webSrc
        try {
            & npm ci 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { & npm install 2>&1 | Out-Null }
            & npm run build 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'npm run build failed' }
            $out = Find-Dir @('dist', 'build'); if (-not $out) { $out = Join-Path $webSrc 'dist' }
            $out = if (Test-Path (Join-Path $webSrc 'dist')) { Join-Path $webSrc 'dist' } elseif (Test-Path (Join-Path $webSrc 'build')) { Join-Path $webSrc 'build' } else { throw 'no dist/build output' }
            Copy-Item -Path (Join-Path $out '*') -Destination $webDir -Recurse -Force
        } finally { Pop-Location }
    }
    Set-ComponentStatus -Project $Project -Kind 'web' -Status 'deployed' -HealthUrl "http://$Subdomain/"
} else { Write-Host "  [skip] no web package.json found" -ForegroundColor DarkGray }

# --- API (.NET 10) ----------------------------------------------------------
$apiCsproj = Get-ChildItem -Path $RepoPath -Recurse -Filter '*.csproj' -ErrorAction SilentlyContinue |
    Where-Object { (Select-String -Path $_.FullName -Pattern 'Microsoft.NET.Sdk.Web' -Quiet) } | Select-Object -First 1
if ($apiCsproj) {
    Phase 'publish' "api: dotnet publish -> $apiDir" {
        & $dotnet publish "$($apiCsproj.FullName)" -c Release -o "$apiDir" 2>&1 | Select-Object -Last 3
        if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }
    }
    Set-ComponentStatus -Project $Project -Kind 'api' -Status 'deployed' -HealthUrl "http://$Subdomain/api/health"
} else { Write-Host "  [skip] no ASP.NET Core .csproj found" -ForegroundColor DarkGray }

# --- DATABASE (db/*.sql) ----------------------------------------------------
$dbDir = Find-Dir @('db', 'database', 'sql', 'src/db')
if ($dbDir) {
    Phase 'deploy' "database: apply $dbDir/*.sql to [$Project]" {
        Get-ChildItem -Path $dbDir -Filter '*.sql' | Sort-Object Name | ForEach-Object {
            Invoke-Sql -Database $Project -Query ([System.IO.File]::ReadAllText($_.FullName)) | Out-Null
        }
    }
    Set-ComponentStatus -Project $Project -Kind 'database' -Status 'healthy'
} else { Write-Host "  [skip] no db/ scripts found" -ForegroundColor DarkGray }

# --- MCP ADMIN PORTAL -------------------------------------------------------
$adminSrc = Find-Dir @('mcp-admin', 'admin')
if ($adminSrc -and (Test-Path (Join-Path $adminSrc 'package.json'))) {
    Phase 'build' "mcp-admin: npm ci + build -> $adminDir" {
        Push-Location $adminSrc
        try {
            & npm ci 2>&1 | Out-Null; & npm run build 2>&1 | Out-Null
            $out = if (Test-Path (Join-Path $adminSrc 'dist')) { Join-Path $adminSrc 'dist' } else { Join-Path $adminSrc 'build' }
            Copy-Item -Path (Join-Path $out '*') -Destination $adminDir -Recurse -Force
        } finally { Pop-Location }
    }
    Set-ComponentStatus -Project $Project -Kind 'mcp-admin' -Status 'deployed' -HealthUrl "http://$Subdomain/mcp-admin"
} else { Write-Host "  [skip] no mcp-admin package.json found" -ForegroundColor DarkGray }

# --- MCP SERVER (note only — daemonization handled separately) --------------
$mcpSrc = Find-Dir @('mcp-server', 'mcp')
if ($mcpSrc) { Write-Host "  [note] mcp-server source at $mcpSrc - run it on its port behind the /mcp ARR proxy (service/PM2/nssm)." -ForegroundColor DarkGray }

# --- VERIFY (health checks via localhost + Host header) ---------------------
if (-not $DryRun) {
    foreach ($check in @(@{k='web';u="http://localhost/"}, @{k='api';u="http://localhost/api/health"})) {
        try {
            $r = Invoke-WebRequest -Uri $check.u -Headers @{Host=$Subdomain} -UseBasicParsing -TimeoutSec 8
            $ok = $r.StatusCode -lt 400
            Set-ComponentStatus -Project $Project -Kind $check.k -Status ($(if($ok){'healthy'}else{'broken'}))
            Write-Host "  [verify] $($check.k): HTTP $($r.StatusCode)"
        } catch { Set-ComponentStatus -Project $Project -Kind $check.k -Status 'broken'; Write-Host "  [verify] $($check.k): FAIL ($($_.Exception.Message))" -ForegroundColor Yellow }
    }
    Invoke-Sql -Database $script:DevMemoryDb -Query "UPDATE dbo.Projects SET Status='deployed', UpdatedAt=SYSUTCDATETIME() WHERE Id=$projId;" | Out-Null
    Write-DevLog -Project $Project -Phase 'build' -Action 'build complete' -Detail "web/api/db/mcp-admin processed from $RepoPath"
}
Write-Host "== '$Project' build $(if($DryRun){'(dry-run preview)'}else{'done'}). http://$Subdomain ==" -ForegroundColor Green
