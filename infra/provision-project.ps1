<#
.SYNOPSIS
  Provision a GSD AI-Dev project on this box: SQL DB + IIS site/app-pool +
  SPA fallback (+ optional ARR /mcp reverse-proxy), registered in gsd_dev_memory.
  Idempotent — safe to re-run.

.NOTES
  This MODIFIES shared IIS state (new site + bindings on the host). Use -DryRun
  first to preview. The server-wide ARR proxy enable is gated behind -EnableArr
  (a one-time, host-wide change) so default runs never flip server config.

.EXAMPLE
  ./infra/provision-project.ps1 -Project myhr -RepoPath D:\VSCode\myhr -DryRun
  ./infra/provision-project.ps1 -Project myhr -RepoPath D:\VSCode\myhr
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Project,
    [string]$RepoPath,
    [string]$Subdomain,
    [int]$McpPort = 0,
    [string]$SiteRootBase = 'C:\inetpub\gsd',
    [switch]$EnableArr,     # also flip server-wide ARR proxy on (host-wide; off by default)
    [switch]$DryRun         # print intended actions, change nothing
)
. (Join-Path $PSScriptRoot 'deploy-lib.ps1')

function Step([string]$desc, [scriptblock]$do) {
    if ($DryRun) { Write-Host "  [dry] $desc" -ForegroundColor DarkYellow }
    else { & $do; Write-Host "  [ok]  $desc" }
}

if ($Project -notmatch '^[a-z][a-z0-9-]{1,40}$') {
    throw "Project name must be lowercase letters/digits/dash, starting with a letter: '$Project'"
}
if (-not $Subdomain) { $Subdomain = "$Project.rjain.technijian.com" }
$siteRoot = Join-Path $SiteRootBase $Project
$webDir   = Join-Path $siteRoot 'web'
$apiDir   = Join-Path $siteRoot 'api'
$adminDir = Join-Path $siteRoot 'mcp-admin'
$pool     = "gsd-$Project"
$site     = "gsd-$Project"

Write-Host "== Provision '$Project' -> $Subdomain $(if($DryRun){'(DRY RUN)'}) ==" -ForegroundColor Cyan

# --- 1. SQL database --------------------------------------------------------
Step "create SQL database [$Project] if missing" { Invoke-Sql -Query "IF DB_ID('$Project') IS NULL CREATE DATABASE [$Project];" | Out-Null }

# --- 2. Register project + 5 components in gsd_dev_memory -------------------
$repoLit = ConvertTo-SqlLiteral $RepoPath
$subLit  = ConvertTo-SqlLiteral $Subdomain
Step "register project '$Project' in gsd_dev_memory" {
    Invoke-Sql -Database $script:DevMemoryDb -Query @"
SET NOCOUNT ON;
IF NOT EXISTS(SELECT 1 FROM dbo.Projects WHERE Name=N'$Project')
    INSERT INTO dbo.Projects(Name,RepoPath,Subdomain,Status) VALUES(N'$Project',$repoLit,$subLit,'building');
ELSE
    UPDATE dbo.Projects SET RepoPath=$repoLit, Subdomain=$subLit, Status='building', UpdatedAt=SYSUTCDATETIME() WHERE Name=N'$Project';
"@ | Out-Null
}

$projId = if ($DryRun) { 0 } else { Get-ProjectId $Project }
if ($McpPort -le 0) { $McpPort = 53000 + [int]$projId }

$comp = @(
    @{k='web';        n="$Project-web";       p=$webDir;   bhost=$Subdomain; port=$null;   fw='React 18 + Fluent v9'; health="http://$Subdomain/"},
    @{k='api';        n="$Project-api";       p=$apiDir;   bhost=$Subdomain; port=$null;   fw='net10.0';              health="http://$Subdomain/api/health"},
    @{k='database';   n="$Project";           p=$null;     bhost='localhost';port=$null;   fw='SQL Server 2025';      health=$null},
    @{k='mcp-server'; n="$Project-mcp";       p=$null;     bhost=$Subdomain; port=$McpPort;fw='node/.NET MCP';        health="http://$Subdomain/mcp"},
    @{k='mcp-admin';  n="$Project-mcp-admin"; p=$adminDir; bhost=$Subdomain; port=$null;   fw='web';                  health="http://$Subdomain/mcp-admin"}
)
Step "register 5 components (mcp port $McpPort)" {
    foreach ($c in $comp) {
        $portLit = if ($null -eq $c.port) { 'NULL' } else { "$($c.port)" }
        Invoke-Sql -Database $script:DevMemoryDb -Query @"
IF NOT EXISTS(SELECT 1 FROM dbo.Components WHERE ProjectId=$projId AND Kind=N'$($c.k)')
  INSERT INTO dbo.Components(ProjectId,Kind,Name,Path,BindingHost,Port,Framework,HealthUrl)
  VALUES($projId,N'$($c.k)',$(ConvertTo-SqlLiteral $c.n),$(ConvertTo-SqlLiteral $c.p),$(ConvertTo-SqlLiteral $c.bhost),$portLit,$(ConvertTo-SqlLiteral $c.fw),$(ConvertTo-SqlLiteral $c.health));
"@ | Out-Null
    }
}

# --- 3. Physical directories ------------------------------------------------
Step "create site dirs under $siteRoot" {
    foreach ($d in @($webDir, $apiDir, $adminDir)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    if (-not (Test-Path (Join-Path $webDir 'index.html'))) {
        Set-Content -Path (Join-Path $webDir 'index.html') -Encoding UTF8 -Value "<!doctype html><title>$Project</title><h1>$Project - provisioned</h1>"
    }
}

# --- 4. IIS app pool + site + sub-apps (No Managed Code for ANCM in-proc) ----
Step "IIS app pool '$pool' (No Managed Code)" {
    if (-not (Test-IisAppPool $pool)) { & $script:Appcmd add apppool /name:"$pool" /managedRuntimeVersion:"" /startMode:"AlwaysRunning" | Out-Null }
}
Step "IIS site '$site' bound to ${Subdomain}:80" {
    if (-not (Test-IisSite $site)) {
        & $script:Appcmd add site /name:"$site" /bindings:"http/*:80:$Subdomain" /physicalPath:"$webDir" | Out-Null
        & $script:Appcmd set app "$site/" /applicationPool:"$pool" | Out-Null
    }
    foreach ($sub in @(@{path='/api';dir=$apiDir}, @{path='/mcp-admin';dir=$adminDir})) {
        $appName = "$site$($sub.path)"
        if (-not ((& $script:Appcmd list app /app.name:"$appName" 2>$null) -match [regex]::Escape($appName))) {
            & $script:Appcmd add app /site.name:"$site" /path:"$($sub.path)" /physicalPath:"$($sub.dir)" | Out-Null
            & $script:Appcmd set app "$appName" /applicationPool:"$pool" | Out-Null
        }
    }
}

# --- 5. web.config (SPA fallback + /mcp proxy rule) -------------------------
$webConfig = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <rewrite>
      <rules>
        <rule name="mcp-proxy" stopProcessing="true">
          <match url="^mcp/?(.*)" />
          <action type="Rewrite" url="http://localhost:$McpPort/{R:1}" />
        </rule>
        <rule name="spa-fallback" stopProcessing="true">
          <match url=".*" />
          <conditions logicalGrouping="MatchAll">
            <add input="{REQUEST_FILENAME}" matchType="IsFile" negate="true" />
            <add input="{REQUEST_FILENAME}" matchType="IsDirectory" negate="true" />
            <add input="{REQUEST_URI}" pattern="^/(api|mcp|mcp-admin)/" negate="true" />
          </conditions>
          <action type="Rewrite" url="/index.html" />
        </rule>
      </rules>
    </rewrite>
  </system.webServer>
</configuration>
"@
Step "write web.config (SPA fallback + /mcp -> localhost:$McpPort)" {
    Set-Content -Path (Join-Path $webDir 'web.config') -Value $webConfig -Encoding UTF8
}

# --- 6. ARR server-wide proxy (host-wide change — opt-in only) --------------
if ($EnableArr) {
    Step "enable server-wide ARR proxy (HOST-WIDE)" { & $script:Appcmd set config -section:system.webServer/proxy /enabled:"true" /commit:apphost 2>$null | Out-Null }
} else {
    Write-Host "  [skip] server-wide ARR proxy NOT enabled. /mcp proxy needs it once: re-run with -EnableArr (host-wide), or an admin sets system.webServer/proxy enabled=true." -ForegroundColor Yellow
}

if (-not $DryRun) { Write-DevLog -Project $Project -Phase 'provision' -Action 'provisioned' -Detail "site=$Subdomain pool=$pool mcpPort=$McpPort db=$Project arr=$EnableArr" }
Write-Host "== '$Project' $(if($DryRun){'(dry-run preview)'}else{'provisioned'}). Dev: http://$Subdomain | alpha target: alpha-$Project.technijian.com ==" -ForegroundColor Green
Write-Host "   Next: ./infra/build-project.ps1 -Project $Project -RepoPath <repo>" -ForegroundColor DarkGray
