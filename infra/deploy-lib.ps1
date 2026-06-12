# ============================================================================
# GSD infra — shared helpers for local provisioning / build / deploy.
# Dot-source: . (Join-Path $PSScriptRoot 'deploy-lib.ps1')
# Targets the local SQL Server 2025 + IIS on this box. Windows PowerShell 5.1.
# ============================================================================
$ErrorActionPreference = 'Stop'

$script:SqlServer   = 'localhost'
$script:DevMemoryDb = 'gsd_dev_memory'
$script:Appcmd      = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'

function Get-DotNet {
    $c = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
    if (Test-Path $p) { return $p }
    throw 'dotnet not found — install the .NET SDK.'
}

function ConvertTo-SqlLiteral([string]$s) {
    if ($null -eq $s -or $s -eq '') { return 'NULL' }
    return "N'" + ($s -replace "'", "''") + "'"
}

# Run T-SQL via sqlcmd (trusted, trust-cert, quoted-identifier on). Query is
# written to a temp .sql file so embedded quotes/metachars are never shell-parsed.
function Invoke-Sql {
    param(
        [Parameter(Mandatory)][string]$Query,
        [string]$Database = 'master',
        [switch]$NoHeaders
    )
    $sqlFile = [System.IO.Path]::GetTempFileName() + '.sql'
    [System.IO.File]::WriteAllText($sqlFile, $Query, (New-Object System.Text.UTF8Encoding($false)))
    try {
        $a = @('-S', $script:SqlServer, '-E', '-C', '-I', '-b', '-d', $Database, '-i', $sqlFile)
        if ($NoHeaders) { $a += @('-h', '-1') }
        $out = & sqlcmd @a 2>&1
        if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed ($LASTEXITCODE): $out" }
        return $out
    } finally { Remove-Item $sqlFile -ErrorAction SilentlyContinue }
}

function Get-ProjectId([string]$Name) {
    $o = Invoke-Sql -Database $script:DevMemoryDb -NoHeaders -Query `
        "SET NOCOUNT ON; SELECT Id FROM dbo.Projects WHERE Name = $(ConvertTo-SqlLiteral $Name);"
    $line = $o | Where-Object { "$_".Trim() -match '^\d+$' } | Select-Object -First 1
    if ($line) { return [int]("$line".Trim()) }
    return $null
}

function Write-DevLog {
    param([string]$Project, [string]$Phase, [string]$Action, [string]$Detail)
    $pj = if ($Project) { Get-ProjectId $Project } else { $null }
    $pjLit = if ($pj) { "$pj" } else { 'NULL' }
    Invoke-Sql -Database $script:DevMemoryDb -Query `
        "INSERT INTO dbo.DevLog(ProjectId,Phase,Action,Detail) VALUES($pjLit,$(ConvertTo-SqlLiteral $Phase),$(ConvertTo-SqlLiteral $Action),$(ConvertTo-SqlLiteral $Detail));" | Out-Null
}

function Write-BuildRun {
    param([string]$Project, [string]$Phase, [string]$Result, [string]$Detail, [int]$DurationMs = 0)
    $pj = if ($Project) { Get-ProjectId $Project } else { $null }
    $pjLit = if ($pj) { "$pj" } else { 'NULL' }
    Invoke-Sql -Database $script:DevMemoryDb -Query `
        "INSERT INTO dbo.BuildRuns(ProjectId,Phase,Result,DurationMs,Detail) VALUES($pjLit,$(ConvertTo-SqlLiteral $Phase),$(ConvertTo-SqlLiteral $Result),$DurationMs,$(ConvertTo-SqlLiteral $Detail));" | Out-Null
}

function Set-ComponentStatus {
    param([string]$Project, [string]$Kind, [string]$Status, [string]$HealthUrl)
    $pj = Get-ProjectId $Project
    if (-not $pj) { return }
    $hu = if ($HealthUrl) { ", HealthUrl=$(ConvertTo-SqlLiteral $HealthUrl)" } else { '' }
    Invoke-Sql -Database $script:DevMemoryDb -Query `
        "UPDATE dbo.Components SET Status=$(ConvertTo-SqlLiteral $Status), LastCheckAt=SYSUTCDATETIME(), UpdatedAt=SYSUTCDATETIME()$hu WHERE ProjectId=$pj AND Kind=$(ConvertTo-SqlLiteral $Kind);" | Out-Null
}

# appcmd existence checks (return $true/$false)
function Test-IisSite([string]$Name)    { (& $script:Appcmd list site /name:"$Name" 2>$null) -match [regex]::Escape($Name) }
function Test-IisAppPool([string]$Name) { (& $script:Appcmd list apppool /name:"$Name" 2>$null) -match [regex]::Escape($Name) }

Write-Verbose 'deploy-lib loaded'
