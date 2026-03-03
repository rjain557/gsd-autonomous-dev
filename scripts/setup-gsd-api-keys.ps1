<#
.SYNOPSIS
    Sets up API key environment variables for GSD AI agents.
    Keys are stored as persistent User-level environment variables (not in code, not in git).

.DESCRIPTION
    The GSD engine uses three AI agents: Claude (Anthropic), Codex (OpenAI), and Gemini (Google).
    Each CLI can authenticate via interactive login OR via API key environment variables.
    API keys bypass interactive rate limits and allow higher throughput for autonomous pipelines.

    This script sets the following User-level environment variables:
      ANTHROPIC_API_KEY  - Used by Claude Code CLI
      OPENAI_API_KEY     - Used by Codex CLI
      GOOGLE_API_KEY     - Used by Gemini CLI

    Keys persist across terminal sessions (stored in Windows registry, not in code).
    Run this script once per machine. Re-run to update keys.

.PARAMETER AnthropicKey
    Anthropic API key for Claude Code (starts with sk-ant-)

.PARAMETER OpenAIKey
    OpenAI API key for Codex (starts with sk-)

.PARAMETER GoogleKey
    Google API key for Gemini (starts with AIza)

.PARAMETER Show
    Show currently configured keys (masked) without changing anything

.PARAMETER Clear
    Remove all GSD API key environment variables

.EXAMPLE
    # Interactive - prompts for each key
    .\setup-gsd-api-keys.ps1

    # Pass keys directly
    .\setup-gsd-api-keys.ps1 -AnthropicKey "sk-ant-..." -OpenAIKey "sk-..." -GoogleKey "AIza..."

    # Check current status
    .\setup-gsd-api-keys.ps1 -Show

    # Remove all keys
    .\setup-gsd-api-keys.ps1 -Clear
#>
param(
    [string]$AnthropicKey = "",
    [string]$OpenAIKey = "",
    [string]$GoogleKey = "",
    [switch]$Show,
    [switch]$Clear
)

$ErrorActionPreference = "Continue"

# Key definitions: env var name, CLI name, expected prefix, docs URL
$keys = @(
    @{ Var = "ANTHROPIC_API_KEY"; CLI = "Claude Code"; Prefix = "sk-ant-"; URL = "https://console.anthropic.com/settings/keys" },
    @{ Var = "OPENAI_API_KEY";    CLI = "Codex";       Prefix = "sk-";     URL = "https://platform.openai.com/api-keys" },
    @{ Var = "GOOGLE_API_KEY";    CLI = "Gemini";      Prefix = "AIza";    URL = "https://aistudio.google.com/apikey" }
)

function Mask-Key([string]$key) {
    if (-not $key -or $key.Length -lt 8) { return "(not set)" }
    return $key.Substring(0, 7) + ("*" * ($key.Length - 11)) + $key.Substring($key.Length - 4)
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD API Key Setup" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# -- Show mode --
if ($Show) {
    Write-Host "  Current API key status:" -ForegroundColor White
    Write-Host ""
    foreach ($k in $keys) {
        $current = [System.Environment]::GetEnvironmentVariable($k.Var, "User")
        $status = if ($current) { Mask-Key $current } else { "(not set)" }
        $color = if ($current) { "Green" } else { "DarkYellow" }
        Write-Host "  $($k.Var.PadRight(22)) $status" -ForegroundColor $color
        Write-Host "    CLI: $($k.CLI) | Get key: $($k.URL)" -ForegroundColor DarkGray
    }
    Write-Host ""
    return
}

# -- Clear mode --
if ($Clear) {
    Write-Host "  Removing all GSD API key environment variables..." -ForegroundColor Yellow
    Write-Host ""
    foreach ($k in $keys) {
        $current = [System.Environment]::GetEnvironmentVariable($k.Var, "User")
        if ($current) {
            [System.Environment]::SetEnvironmentVariable($k.Var, $null, "User")
            Write-Host "  [OK] Removed $($k.Var)" -ForegroundColor Green
        } else {
            Write-Host "  [--] $($k.Var) was not set" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Write-Host "  Done. Restart your terminal for changes to take effect." -ForegroundColor White
    Write-Host ""
    return
}

# -- Set mode --
Write-Host "  API keys are stored as User-level environment variables." -ForegroundColor White
Write-Host "  They persist across sessions and are NEVER committed to git." -ForegroundColor White
Write-Host "  Press Enter to skip a key (keeps existing value)." -ForegroundColor DarkGray
Write-Host ""

# Map param values to keys
$paramValues = @{
    "ANTHROPIC_API_KEY" = $AnthropicKey
    "OPENAI_API_KEY"    = $OpenAIKey
    "GOOGLE_API_KEY"    = $GoogleKey
}

$changed = 0

foreach ($k in $keys) {
    $current = [System.Environment]::GetEnvironmentVariable($k.Var, "User")
    $currentDisplay = if ($current) { Mask-Key $current } else { "(not set)" }

    Write-Host "  --- $($k.CLI) ---" -ForegroundColor Cyan
    Write-Host "  Env var:  $($k.Var)" -ForegroundColor White
    Write-Host "  Current:  $currentDisplay" -ForegroundColor $(if ($current) { "Green" } else { "DarkYellow" })
    Write-Host "  Get key:  $($k.URL)" -ForegroundColor DarkGray

    # Use param value if provided, otherwise prompt
    $newKey = $paramValues[$k.Var]
    if (-not $newKey) {
        $prompt = "  Enter key (or Enter to skip): "
        Write-Host $prompt -NoNewline -ForegroundColor White
        $newKey = Read-Host
    }

    if ($newKey -and $newKey.Trim()) {
        $newKey = $newKey.Trim()

        # Validate prefix
        if ($k.Prefix -and -not $newKey.StartsWith($k.Prefix)) {
            Write-Host "  [!!] Warning: Expected key to start with '$($k.Prefix)'" -ForegroundColor Yellow
            Write-Host "       Setting it anyway - verify it's correct." -ForegroundColor DarkYellow
        }

        [System.Environment]::SetEnvironmentVariable($k.Var, $newKey, "User")
        # Also set in current session so it's immediately available
        [System.Environment]::SetEnvironmentVariable($k.Var, $newKey, "Process")
        Write-Host "  [OK] $($k.Var) = $(Mask-Key $newKey)" -ForegroundColor Green
        $changed++
    } else {
        if ($current) {
            Write-Host "  [--] Kept existing value" -ForegroundColor DarkGray
        } else {
            Write-Host "  [--] Skipped (not set)" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
}

# -- Summary --
Write-Host "=========================================================" -ForegroundColor Cyan
if ($changed -gt 0) {
    Write-Host "  $changed key(s) updated." -ForegroundColor Green
    Write-Host ""
    Write-Host "  IMPORTANT: Restart your terminal for changes to take" -ForegroundColor Yellow
    Write-Host "  effect in new processes. Current session is already updated." -ForegroundColor Yellow
} else {
    Write-Host "  No changes made." -ForegroundColor DarkGray
}
Write-Host ""

# -- Verify all keys are set --
Write-Host "  Final status:" -ForegroundColor White
$allSet = $true
foreach ($k in $keys) {
    $val = [System.Environment]::GetEnvironmentVariable($k.Var, "User")
    $status = if ($val) { "OK" } else { "MISSING" }
    $color = if ($val) { "Green" } else { "Red" }
    $icon = if ($val) { "[OK]" } else { "[!!]" }
    Write-Host "  $icon $($k.CLI.PadRight(12)) $($k.Var)" -ForegroundColor $color
    if (-not $val) { $allSet = $false }
}
Write-Host ""

if (-not $allSet) {
    Write-Host "  Some keys are missing. Agents without API keys will fall back" -ForegroundColor DarkYellow
    Write-Host "  to interactive auth (may have lower rate limits)." -ForegroundColor DarkYellow
    Write-Host ""
}

Write-Host "  To check status later:  .\setup-gsd-api-keys.ps1 -Show" -ForegroundColor DarkGray
Write-Host "  To remove all keys:     .\setup-gsd-api-keys.ps1 -Clear" -ForegroundColor DarkGray
Write-Host ""
