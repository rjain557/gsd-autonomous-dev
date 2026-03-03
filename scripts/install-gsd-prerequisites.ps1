<#
.SYNOPSIS
    GSD Prerequisites Installer and Verifier
    Checks for all required tools, installs missing ones, validates the environment.
    Checks npm packages for latest versions and upgrades if outdated.
    Configures API keys for Claude, Codex, and Gemini agents.

.USAGE
    powershell -ExecutionPolicy Bypass -File install-gsd-prerequisites.ps1

    Flags:
      -SkipOptional       Skip optional tools (sqlcmd)
      -VerifyOnly         Check everything, install nothing
      -Force              Reinstall even if already present
      -SkipAuth           Skip API key configuration
      -AnthropicKey "sk-ant-..."   Set Anthropic API key (Claude)
      -OpenAIKey "sk-..."          Set OpenAI API key (Codex)
      -GoogleKey "AIza..."         Set Google API key (Gemini)

.EXAMPLE
    # Full run with API keys
    .\install-gsd-prerequisites.ps1 -AnthropicKey "sk-ant-..." -OpenAIKey "sk-..." -GoogleKey "AIza..."

    # Interactive - prompts for keys during auth section
    .\install-gsd-prerequisites.ps1

    # Verify only, skip auth
    .\install-gsd-prerequisites.ps1 -VerifyOnly -SkipAuth
#>

param(
    [switch]$SkipOptional,
    [switch]$VerifyOnly,
    [switch]$Force,
    [switch]$SkipAuth,
    [string]$AnthropicKey = "",
    [string]$OpenAIKey = "",
    [string]$GoogleKey = ""
)

$ErrorActionPreference = "Continue"

$REQUIRED_TOOLS = @(
    @{
        Name = "Node.js"; Command = "node"; VersionCmd = "node --version"
        MinMajor = 18; WingetId = "OpenJS.NodeJS.LTS"; NpmPackage = $null
        Category = "required"; Purpose = "JavaScript runtime for npm and frontend builds"
    }
    @{
        Name = "npm"; Command = "npm"; VersionCmd = "npm --version"
        MinMajor = 8; WingetId = $null; NpmPackage = $null
        Category = "required"; Purpose = "Package manager (comes with Node.js)"
    }
    @{
        Name = "Git"; Command = "git"; VersionCmd = "git --version"
        MinMajor = 2; WingetId = "Git.Git"; NpmPackage = $null
        Category = "required"; Purpose = "Version control for snapshots and rollback"
    }
    @{
        Name = ".NET SDK"; Command = "dotnet"; VersionCmd = "dotnet --version"
        MinMajor = 8; WingetId = "Microsoft.DotNet.SDK.8"; NpmPackage = $null
        Category = "required"; Purpose = "Backend build validation"
    }
    @{
        Name = "Claude Code CLI"; Command = "claude"; VersionCmd = "claude --version"
        MinMajor = $null; WingetId = $null; NpmPackage = "@anthropic-ai/claude-code"
        Category = "required"; Purpose = "AI agent for blueprint, verify, review, plan"
    }
    @{
        Name = "Codex CLI"; Command = "codex"; VersionCmd = "codex --version"
        MinMajor = $null; WingetId = $null; NpmPackage = "@openai/codex"
        Category = "required"; Purpose = "AI agent for build, execute, research"
    }
    @{
        Name = "sqlcmd"; Command = "sqlcmd"; VersionCmd = "sqlcmd --version"
        MinMajor = $null; WingetId = "Microsoft.Sqlcmd"; NpmPackage = $null
        Category = "optional"; Purpose = "SQL syntax validation (optional)"
    }
)

# --- Display helpers (ASCII safe) ---

function Write-Banner {
    Write-Host ""
    Write-Host "=================================================================" -ForegroundColor Cyan
    Write-Host "  GSD Prerequisites - Install and Verify" -ForegroundColor Cyan
    Write-Host "  Run this before install-gsd-all.ps1" -ForegroundColor Cyan
    Write-Host "=================================================================" -ForegroundColor Cyan
    if ($VerifyOnly) { Write-Host "  MODE: Verify Only (no installs)" -ForegroundColor Yellow }
    if ($Force) { Write-Host "  MODE: Force Reinstall" -ForegroundColor Yellow }
    Write-Host ""
}

function Write-Check {
    param([string]$Name, [string]$Status, [string]$Detail, [string]$Color = "Green")
    $icon = "[  ]"
    switch ($Status) {
        "pass"    { $icon = "[OK]" }
        "warn"    { $icon = "[!!]" }
        "fail"    { $icon = "[XX]" }
        "install" { $icon = "[->]" }
        "skip"    { $icon = "[--]" }
    }
    Write-Host "  $icon " -NoNewline -ForegroundColor $Color
    Write-Host "$Name" -NoNewline -ForegroundColor $Color
    if ($Detail) {
        Write-Host "  -  $Detail" -ForegroundColor DarkGray
    } else {
        Write-Host ""
    }
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "  --- $Title ---" -ForegroundColor White
    Write-Host ""
}

# --- Utility functions ---

function Test-CommandExists {
    param([string]$Cmd)
    try {
        $null = Get-Command $Cmd -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Get-ToolVersion {
    param([string]$VersionCmd)
    try {
        $output = Invoke-Expression $VersionCmd 2>&1 | Out-String
        $m = [regex]::Match($output, '(\d+)\.(\d+)\.?(\d*)')
        if ($m.Success) {
            return @{
                Full = $m.Value
                Major = [int]$m.Groups[1].Value
                Minor = [int]$m.Groups[2].Value
            }
        }
        return $null
    } catch {
        return $null
    }
}

function Test-WingetAvailable {
    try {
        $null = Get-Command winget -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Test-NpmGlobalInPath {
    try {
        $npmPrefix = (npm config get prefix 2>$null)
        if ($npmPrefix) {
            $envPath = $env:PATH -split ";"
            $found = $envPath | Where-Object { $_ -like "$($npmPrefix)*" }
            return ($found.Count -gt 0)
        }
        return $false
    } catch {
        return $false
    }
}

function Refresh-PathFromRegistry {
    # Reload PATH from both Machine and User registry so newly-installed tools are found
    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:PATH = "$machinePath;$userPath"
}

function Add-ToUserPath {
    param([string]$Directory)
    $currentUserPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    if ($currentUserPath -and $currentUserPath -split ";" | Where-Object { $_ -eq $Directory }) {
        return $false  # already present
    }
    $newPath = if ($currentUserPath) { "$currentUserPath;$Directory" } else { $Directory }
    [System.Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    # Also update current session
    $env:PATH = "$env:PATH;$Directory"
    return $true
}

function Install-ViaWinget {
    param([string]$PackageId, [string]$Name, [switch]$Upgrade)

    if ($VerifyOnly) {
        if ($Upgrade) {
            Write-Check $Name "fail" "Version too low (verify-only mode, needs upgrade)" "Red"
        } else {
            Write-Check $Name "fail" "Not installed (verify-only mode)" "Red"
        }
        return $false
    }

    $action = if ($Upgrade) { "Upgrading" } else { "Installing" }
    Write-Check $Name "install" "$action via winget..." "Yellow"
    try {
        if ($Upgrade) {
            $output = winget upgrade --id $PackageId --accept-package-agreements --accept-source-agreements 2>&1
        } else {
            $output = winget install --id $PackageId --accept-package-agreements --accept-source-agreements 2>&1
        }
        $outputStr = "$output"
        if ($LASTEXITCODE -eq 0 -or $outputStr -match "Successfully installed" -or $outputStr -match "successfully installed" -or $outputStr -match "No applicable upgrade found") {
            # Refresh PATH so the tool is immediately available in this session
            Refresh-PathFromRegistry
            Write-Check $Name "pass" "$action completed successfully" "Green"
            return $true
        } else {
            Write-Check $Name "fail" "winget $($action.ToLower()) failed. Try manually: winget install $PackageId" "Red"
            return $false
        }
    } catch {
        Write-Check $Name "fail" "Install error: $($_.Exception.Message)" "Red"
        return $false
    }
}

function Get-NpmLatestVersion {
    param([string]$Package)
    try {
        $json = npm view $Package version --json 2>$null | Out-String
        $ver = $json.Trim().Trim('"')
        if ($ver -match '^\d+\.\d+') { return $ver }
        return $null
    } catch {
        return $null
    }
}

function Install-ViaNpm {
    param([string]$Package, [string]$Name, [switch]$Upgrade)

    if ($VerifyOnly) {
        if ($Upgrade) {
            Write-Check $Name "fail" "Outdated (verify-only mode, needs upgrade)" "Red"
        } else {
            Write-Check $Name "fail" "Not installed (verify-only mode)" "Red"
        }
        return $false
    }

    $action = if ($Upgrade) { "Upgrading" } else { "Installing" }
    Write-Check $Name "install" "$action via npm..." "Yellow"
    try {
        $output = npm install -g $Package 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            # Refresh PATH in case npm global bin changed
            Refresh-PathFromRegistry
            Write-Check $Name "pass" "$action completed via npm" "Green"
            return $true
        } else {
            Write-Check $Name "fail" "npm $($action.ToLower()) failed: $output" "Red"
            Write-Host "    Try manually: npm install -g $Package" -ForegroundColor DarkYellow
            return $false
        }
    } catch {
        Write-Check $Name "fail" "Install error: $($_.Exception.Message)" "Red"
        return $false
    }
}

function Verify-PostInstall {
    param([hashtable]$Tool)
    # Re-check that the tool is now available and meets version requirements
    $exists = Test-CommandExists $Tool.Command
    if (-not $exists) {
        return @{ Success = $false; Message = "Command '$($Tool.Command)' still not found after install. Restart terminal and re-run." }
    }
    if ($null -ne $Tool.MinMajor) {
        $ver = Get-ToolVersion $Tool.VersionCmd
        if ($ver -and $ver.Major -lt $Tool.MinMajor) {
            return @{ Success = $false; Message = "v$($ver.Full) installed but v$($Tool.MinMajor).x+ required" }
        }
    }
    return @{ Success = $true; Message = "Verified" }
}

# ================================================================
# MAIN
# ================================================================

Write-Banner

$results = @{ Passed = 0; Failed = 0; Installed = 0; Skipped = 0; Warnings = 0 }
$needsRestart = $false

# --- Environment ---
Write-Section "Environment"

$psVer = $PSVersionTable.PSVersion
$hasPwsh = $false
try { $null = Get-Command pwsh -ErrorAction Stop; $hasPwsh = $true } catch {}
if ($psVer.Major -ge 7) {
    Write-Check "PowerShell" "pass" "v$($psVer.Major).$($psVer.Minor) (PS7+)" "Green"
    $results.Passed++
} elseif ($hasPwsh) {
    $pwshVer = (pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null)
    Write-Check "PowerShell" "pass" "v$psVer (PS7 available: pwsh v$pwshVer)" "Green"
    Write-Host "    Note: GSD commands auto-detect pwsh. Current session is PS $($psVer.Major).$($psVer.Minor)." -ForegroundColor DarkGray
    $results.Passed++
} else {
    # PS 5.1 without PS7 installed - need to install PowerShell 7
    Write-Check "PowerShell" "warn" "v$($psVer.Major).$($psVer.Minor) - GSD requires PowerShell 7+" "Yellow"
    if ($VerifyOnly) {
        Write-Host "    Install PowerShell 7: winget install Microsoft.PowerShell" -ForegroundColor DarkYellow
        $results.Failed++
    } elseif ($hasWinget) {
        Write-Check "PowerShell 7" "install" "Installing via winget..." "Yellow"
        try {
            $output = winget install --id Microsoft.PowerShell --accept-package-agreements --accept-source-agreements 2>&1
            $outputStr = "$output"
            if ($LASTEXITCODE -eq 0 -or $outputStr -match "Successfully installed" -or $outputStr -match "No applicable upgrade found") {
                Refresh-PathFromRegistry
                Write-Check "PowerShell 7" "pass" "Installed. Restart terminal to use 'pwsh'." "Green"
                $results.Installed++
                $needsRestart = $true
            } else {
                Write-Check "PowerShell 7" "fail" "winget install failed. Try: winget install Microsoft.PowerShell" "Red"
                $results.Failed++
            }
        } catch {
            Write-Check "PowerShell 7" "fail" "Install error: $($_.Exception.Message)" "Red"
            $results.Failed++
        }
    } else {
        Write-Check "PowerShell" "fail" "v$($psVer.Major).$($psVer.Minor) - Need PS 7+. Install: winget install Microsoft.PowerShell" "Red"
        $results.Failed++
    }
}

$hasWinget = Test-WingetAvailable
if ($hasWinget) {
    Write-Check "winget" "pass" "Available" "Green"
    $results.Passed++
} else {
    Write-Check "winget" "warn" "Not available. Some tools may need manual install" "Yellow"
    Write-Host "    winget is required for installing Node.js, Git, .NET SDK, and sqlcmd." -ForegroundColor DarkYellow
    Write-Host "    Install from: https://aka.ms/getwinget" -ForegroundColor DarkYellow
    $results.Warnings++
}

$policy = Get-ExecutionPolicy
if ($policy -in @("RemoteSigned", "Unrestricted", "Bypass")) {
    Write-Check "Execution Policy" "pass" "$policy" "Green"
    $results.Passed++
} else {
    if ($VerifyOnly) {
        Write-Check "Execution Policy" "warn" "$policy - may block scripts. Run: Set-ExecutionPolicy RemoteSigned -Scope CurrentUser" "Yellow"
        $results.Warnings++
    } else {
        Write-Check "Execution Policy" "install" "Setting to RemoteSigned for current user..." "Yellow"
        try {
            Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force -ErrorAction Stop
            Write-Check "Execution Policy" "pass" "Set to RemoteSigned" "Green"
            $results.Installed++
        } catch {
            Write-Check "Execution Policy" "warn" "Could not set automatically. Run: Set-ExecutionPolicy RemoteSigned -Scope CurrentUser" "Yellow"
            $results.Warnings++
        }
    }
}

# --- Required Tools ---
Write-Section "Required Tools"

foreach ($tool in $REQUIRED_TOOLS) {

    if ($tool.Category -eq "optional" -and $SkipOptional) {
        Write-Check $tool.Name "skip" "Skipped (optional)" "DarkGray"
        $results.Skipped++
        continue
    }

    $exists = Test-CommandExists $tool.Command

    if ($exists -and -not $Force) {
        $ver = Get-ToolVersion $tool.VersionCmd

        if ($ver) {
            $versionOk = ($null -eq $tool.MinMajor) -or ($ver.Major -ge $tool.MinMajor)
            if ($versionOk) {
                # For npm packages, check if a newer version is available
                if ($tool.NpmPackage -and (Test-CommandExists "npm")) {
                    $latest = Get-NpmLatestVersion $tool.NpmPackage
                    if ($latest -and $latest -ne $ver.Full) {
                        Write-Check $tool.Name "warn" "v$($ver.Full) installed, v$latest available" "Yellow"
                        $upgraded = Install-ViaNpm -Package $tool.NpmPackage -Name $tool.Name -Upgrade
                        if ($upgraded) {
                            $results.Installed++
                        } else {
                            # Upgrade failed but current version is functional
                            $results.Warnings++
                        }
                        continue
                    }
                }
                Write-Check $tool.Name "pass" "v$($ver.Full)" "Green"
                $results.Passed++
                continue
            } else {
                # Version is too low - attempt upgrade
                if ($tool.WingetId -and $hasWinget) {
                    Write-Check $tool.Name "warn" "v$($ver.Full) found, need v$($tool.MinMajor).x+ - attempting upgrade..." "Yellow"
                    $upgraded = Install-ViaWinget -PackageId $tool.WingetId -Name $tool.Name -Upgrade
                    if ($upgraded) {
                        $postCheck = Verify-PostInstall -Tool $tool
                        if ($postCheck.Success) {
                            $results.Installed++
                            $needsRestart = $true
                        } else {
                            Write-Check $tool.Name "warn" "Upgrade ran but: $($postCheck.Message)" "Yellow"
                            $results.Warnings++
                            $needsRestart = $true
                        }
                    } else {
                        $results.Failed++
                    }
                } elseif ($tool.NpmPackage) {
                    Write-Check $tool.Name "warn" "v$($ver.Full) found, need v$($tool.MinMajor).x+ - attempting npm upgrade..." "Yellow"
                    $upgraded = Install-ViaNpm -Package $tool.NpmPackage -Name $tool.Name
                    if ($upgraded) {
                        $results.Installed++
                    } else {
                        $results.Failed++
                    }
                } else {
                    Write-Check $tool.Name "warn" "v$($ver.Full) - need v$($tool.MinMajor).x+. Upgrade manually or install Node.js to get latest npm" "Yellow"
                    $results.Warnings++
                }
                continue
            }
        } else {
            Write-Check $tool.Name "pass" "Found (version not parsed)" "Green"
            $results.Passed++
            continue
        }
    }

    if (-not $exists -or $Force) {
        if ($tool.NpmPackage) {
            # npm-based tool - need npm first
            if (-not (Test-CommandExists "npm")) {
                Write-Check $tool.Name "fail" "Cannot install - npm not available yet" "Red"
                Write-Host "    npm is installed with Node.js. Ensure Node.js installs first, then restart terminal." -ForegroundColor DarkYellow
                $results.Failed++
                $needsRestart = $true
                continue
            }
            $installed = Install-ViaNpm -Package $tool.NpmPackage -Name $tool.Name
            if ($installed) {
                $postCheck = Verify-PostInstall -Tool $tool
                if ($postCheck.Success) {
                    $results.Installed++
                } else {
                    Write-Check $tool.Name "warn" "Installed but: $($postCheck.Message)" "Yellow"
                    $results.Installed++
                    $needsRestart = $true
                }
            } elseif ($tool.Category -eq "optional") {
                $results.Skipped++
            } else {
                $results.Failed++
            }

        } elseif ($tool.WingetId -and $hasWinget) {
            $installed = Install-ViaWinget -PackageId $tool.WingetId -Name $tool.Name
            if ($installed) {
                $postCheck = Verify-PostInstall -Tool $tool
                if ($postCheck.Success) {
                    $results.Installed++
                } else {
                    Write-Check $tool.Name "warn" "Installed but: $($postCheck.Message). Restart terminal and re-run." "Yellow"
                    $results.Installed++
                    $needsRestart = $true
                }
            } elseif ($tool.Category -eq "optional") {
                $results.Skipped++
            } else {
                $results.Failed++
            }

        } elseif ($tool.WingetId -and -not $hasWinget) {
            if ($VerifyOnly) {
                Write-Check $tool.Name "fail" "Not installed (verify-only mode)" "Red"
            } else {
                Write-Check $tool.Name "fail" "Not installed and winget not available" "Red"
                # Provide manual install instructions per tool
                switch ($tool.Name) {
                    "Node.js" {
                        Write-Host "    Install from: https://nodejs.org/en/download/" -ForegroundColor DarkYellow
                    }
                    "Git" {
                        Write-Host "    Install from: https://git-scm.com/download/win" -ForegroundColor DarkYellow
                    }
                    ".NET SDK" {
                        Write-Host "    Install from: https://dotnet.microsoft.com/download/dotnet/8.0" -ForegroundColor DarkYellow
                    }
                    "sqlcmd" {
                        Write-Host "    Install from: https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-utility" -ForegroundColor DarkYellow
                    }
                    default {
                        Write-Host "    Search for '$($tool.Name)' install instructions online" -ForegroundColor DarkYellow
                    }
                }
            }
            if ($tool.Category -eq "optional") {
                $results.Skipped++
            } else {
                $results.Failed++
            }

        } else {
            # No winget ID and no npm package (e.g., npm itself comes with Node.js)
            if ($VerifyOnly) {
                Write-Check $tool.Name "fail" "Not found (verify-only mode)" "Red"
            } else {
                Write-Check $tool.Name "fail" "Not found. Comes with Node.js - ensure Node.js is installed and restart terminal" "Red"
            }
            if ($tool.Category -eq "optional") {
                $results.Skipped++
            } else {
                $results.Failed++
                $needsRestart = $true
            }
        }
    }
}

# --- PATH ---
Write-Section "PATH Configuration"

if (Test-CommandExists "npm") {
    $npmInPath = Test-NpmGlobalInPath
    if ($npmInPath) {
        Write-Check "npm global in PATH" "pass" "Confirmed" "Green"
        $results.Passed++
    } else {
        $prefix = npm config get prefix 2>$null
        if ($VerifyOnly) {
            Write-Check "npm global in PATH" "warn" "npm prefix ($prefix) not in PATH" "Yellow"
            Write-Host "    Fix: Add $prefix to your PATH, then restart terminal" -ForegroundColor DarkYellow
            $results.Warnings++
        } else {
            Write-Check "npm global in PATH" "install" "Adding npm prefix ($prefix) to user PATH..." "Yellow"
            try {
                $added = Add-ToUserPath -Directory $prefix
                if ($added) {
                    Write-Check "npm global in PATH" "pass" "Added $prefix to user PATH" "Green"
                    $results.Installed++
                    $needsRestart = $true
                } else {
                    Write-Check "npm global in PATH" "pass" "Already in PATH (session may need refresh)" "Green"
                    $results.Passed++
                }
            } catch {
                Write-Check "npm global in PATH" "warn" "Could not add automatically: $($_.Exception.Message)" "Yellow"
                Write-Host "    Fix: Add $prefix to your PATH manually, then restart terminal" -ForegroundColor DarkYellow
                $results.Warnings++
            }
        }
    }
} else {
    Write-Check "npm global in PATH" "skip" "npm not installed yet" "DarkGray"
}

$profilePath = $PROFILE.CurrentUserAllHosts
# Fallback when $PROFILE is empty (non-interactive / invoked from bash)
if ([string]::IsNullOrWhiteSpace($profilePath)) {
    $profilePath = Join-Path $env:USERPROFILE "Documents\PowerShell\profile.ps1"
}
if (Test-Path $profilePath) {
    $profileContent = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
    if ($profileContent -match "gsd-global") {
        Write-Check "PowerShell Profile" "pass" "GSD functions registered" "Green"
        $results.Passed++
    } else {
        Write-Check "PowerShell Profile" "warn" "Exists but no GSD functions (install-gsd-all.ps1 will add them)" "Yellow"
        $results.Warnings++
    }
} else {
    Write-Check "PowerShell Profile" "warn" "Does not exist (install-gsd-all.ps1 will create it)" "Yellow"
    $results.Warnings++
}

# --- API Keys ---
if (-not $SkipAuth) {
    Write-Section "API Keys"

    Write-Host "  API keys are stored as User-level environment variables." -ForegroundColor White
    Write-Host "  They persist across sessions and are NEVER committed to git." -ForegroundColor White
    Write-Host ""

    # Key definitions: env var, display name, expected prefix, param value, docs URL
    $apiKeys = @(
        @{ Var = "ANTHROPIC_API_KEY"; Name = "Claude (Anthropic)"; Prefix = "sk-ant-"; ParamVal = $AnthropicKey; URL = "https://console.anthropic.com/settings/keys" },
        @{ Var = "OPENAI_API_KEY";    Name = "Codex (OpenAI)";     Prefix = "sk-";     ParamVal = $OpenAIKey;    URL = "https://platform.openai.com/api-keys" },
        @{ Var = "GOOGLE_API_KEY";    Name = "Gemini (Google)";    Prefix = "AIza";    ParamVal = $GoogleKey;    URL = "https://aistudio.google.com/apikey" }
    )

    function Mask-Key([string]$key) {
        if (-not $key -or $key.Length -lt 8) { return "(not set)" }
        return $key.Substring(0, 7) + ("*" * [Math]::Max(0, $key.Length - 11)) + $key.Substring($key.Length - 4)
    }

    foreach ($ak in $apiKeys) {
        $current = [System.Environment]::GetEnvironmentVariable($ak.Var, "User")

        # Determine the new key: parameter > prompt > skip
        $newKey = $ak.ParamVal
        if (-not $newKey -and -not $VerifyOnly) {
            if ($current) {
                $masked = Mask-Key $current
                Write-Host "  $($ak.Name)" -ForegroundColor Cyan
                Write-Host "    Current: $masked" -ForegroundColor Green
                Write-Host "    Press Enter to keep, or paste a new key: " -NoNewline -ForegroundColor White
                $newKey = Read-Host
            } else {
                Write-Host "  $($ak.Name)" -ForegroundColor Cyan
                Write-Host "    Current: (not set)" -ForegroundColor DarkYellow
                Write-Host "    Get key: $($ak.URL)" -ForegroundColor DarkGray
                Write-Host "    Paste your API key (or Enter to skip): " -NoNewline -ForegroundColor White
                $newKey = Read-Host
            }
        }

        if ($newKey -and $newKey.Trim()) {
            $newKey = $newKey.Trim()

            # Validate prefix
            if ($ak.Prefix -and -not $newKey.StartsWith($ak.Prefix)) {
                Write-Check $ak.Name "warn" "Expected key starting with '$($ak.Prefix)' - setting anyway, verify it's correct" "Yellow"
            }

            # Store persistently (User level) and in current session (Process level)
            [System.Environment]::SetEnvironmentVariable($ak.Var, $newKey, "User")
            [System.Environment]::SetEnvironmentVariable($ak.Var, $newKey, "Process")
            Write-Check $ak.Name "pass" "$($ak.Var) = $(Mask-Key $newKey)" "Green"
            $results.Installed++
        } else {
            if ($current) {
                if ($VerifyOnly) {
                    Write-Check $ak.Name "pass" "$($ak.Var) = $(Mask-Key $current)" "Green"
                } else {
                    Write-Check $ak.Name "pass" "Kept existing: $(Mask-Key $current)" "Green"
                }
                $results.Passed++
            } else {
                Write-Check $ak.Name "warn" "$($ak.Var) not set. Agent will use interactive auth (lower rate limits)" "Yellow"
                $results.Warnings++
            }
        }
        Write-Host ""
    }
}

# --- GSD Status ---
Write-Section "GSD Installation Status"

$gsdGlobalDir = Join-Path $env:USERPROFILE ".gsd-global"
if (Test-Path $gsdGlobalDir) {
    $configFile = Join-Path $gsdGlobalDir "blueprint\config\blueprint-config.json"
    if (Test-Path $configFile) {
        try {
            $config = Get-Content $configFile -Raw | ConvertFrom-Json
            $ver = if ($config.version) { $config.version } else { "unknown" }
            Write-Check "GSD Engine" "pass" "Installed (v$ver)" "Green"
        } catch {
            Write-Check "GSD Engine" "warn" "Config may be corrupt" "Yellow"
        }
    } else {
        Write-Check "GSD Engine" "warn" "Partial install. Re-run install-gsd-all.ps1" "Yellow"
    }

    $modules = @("resilience.ps1", "interfaces.ps1", "interface-wrapper.ps1")
    $modulesDir = Join-Path $gsdGlobalDir "lib\modules"
    $moduleCount = 0
    foreach ($m in $modules) {
        if (Test-Path (Join-Path $modulesDir $m)) { $moduleCount++ }
    }
    if ($moduleCount -eq $modules.Count) {
        Write-Check "GSD Modules" "pass" "$moduleCount/$($modules.Count) present" "Green"
    } elseif ($moduleCount -gt 0) {
        Write-Check "GSD Modules" "warn" "$moduleCount/$($modules.Count). Re-run install-gsd-all.ps1" "Yellow"
    } else {
        Write-Check "GSD Modules" "skip" "Not installed yet" "DarkGray"
    }
} else {
    Write-Check "GSD Engine" "skip" "Not installed (run install-gsd-all.ps1 after prerequisites pass)" "DarkGray"
}

# ================================================================
# SUMMARY
# ================================================================

Write-Host ""
if ($results.Failed -eq 0) {
    Write-Host "=================================================================" -ForegroundColor Green
} else {
    Write-Host "=================================================================" -ForegroundColor Red
}

Write-Host "  RESULTS" -ForegroundColor White
Write-Host "    [OK] Passed:    $($results.Passed)" -ForegroundColor Green
if ($results.Installed -gt 0) {
    Write-Host "    [->] Installed: $($results.Installed)" -ForegroundColor Cyan
}
if ($results.Warnings -gt 0) {
    Write-Host "    [!!] Warnings:  $($results.Warnings)" -ForegroundColor Yellow
}
if ($results.Failed -gt 0) {
    Write-Host "    [XX] Failed:    $($results.Failed)" -ForegroundColor Red
}
if ($results.Skipped -gt 0) {
    Write-Host "    [--] Skipped:   $($results.Skipped)" -ForegroundColor DarkGray
}

if ($results.Failed -eq 0) {
    Write-Host "=================================================================" -ForegroundColor Green
} else {
    Write-Host "=================================================================" -ForegroundColor Red
}

if ($needsRestart -and $results.Installed -gt 0) {
    Write-Host ""
    Write-Host "  ** RESTART REQUIRED **" -ForegroundColor Yellow
    Write-Host "  Tools were installed/updated. Close this terminal, open a new one," -ForegroundColor Yellow
    Write-Host "  then re-run to verify everything is in PATH:" -ForegroundColor Yellow
    Write-Host "    powershell -ExecutionPolicy Bypass -File install-gsd-prerequisites.ps1 -VerifyOnly" -ForegroundColor Cyan
    Write-Host ""
}

if ($results.Failed -eq 0 -and $results.Warnings -eq 0 -and -not $needsRestart) {
    Write-Host ""
    Write-Host "  ALL PREREQUISITES MET" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Next step:" -ForegroundColor White
    Write-Host "    powershell -ExecutionPolicy Bypass -File install-gsd-all.ps1" -ForegroundColor Cyan
    Write-Host ""
} elseif ($results.Failed -eq 0 -and -not $needsRestart) {
    Write-Host ""
    Write-Host "  PREREQUISITES MET WITH WARNINGS" -ForegroundColor Yellow
    Write-Host "  You can proceed, but review the warnings above." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Next step:" -ForegroundColor White
    Write-Host "    powershell -ExecutionPolicy Bypass -File install-gsd-all.ps1" -ForegroundColor Cyan
    Write-Host ""
} elseif ($results.Failed -gt 0) {
    Write-Host ""
    Write-Host "  PREREQUISITES NOT MET" -ForegroundColor Red
    Write-Host "  Fix the failed items above before running install-gsd-all.ps1" -ForegroundColor Red
    Write-Host ""
}
