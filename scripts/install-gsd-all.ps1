<#
.SYNOPSIS
    GSD Master Installer - Runs ALL 21 scripts in correct order.
.USAGE
    powershell -ExecutionPolicy Bypass -File install-gsd-all.ps1

    # With API keys (recommended)
    powershell -ExecutionPolicy Bypass -File install-gsd-all.ps1 -AnthropicKey "sk-ant-..." -OpenAIKey "sk-..." -GoogleKey "AIza..."
#>

param(
    [string]$AnthropicKey = "",
    [string]$OpenAIKey = "",
    [string]$GoogleKey = ""
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$GSD_VERSION = "1.5.0"
$GSD_DATE = "2026-03-04"

# Run prerequisites check first if the script exists
$prereqScript = Join-Path $scriptDir "install-gsd-prerequisites.ps1"
if (Test-Path $prereqScript) {
    Write-Host ""
    Write-Host "  Running prerequisites check first..." -ForegroundColor Cyan
    Write-Host ""
    $prereqArgs = @{}
    if ($AnthropicKey) { $prereqArgs["AnthropicKey"] = $AnthropicKey }
    if ($OpenAIKey)    { $prereqArgs["OpenAIKey"]    = $OpenAIKey }
    if ($GoogleKey)    { $prereqArgs["GoogleKey"]     = $GoogleKey }
    & $prereqScript @prereqArgs

    $hasGit = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
    $hasNode = $null -ne (Get-Command node -ErrorAction SilentlyContinue)

    if (-not $hasGit -or -not $hasNode) {
        Write-Host ""
        Write-Host "  Critical prerequisites missing (Git and/or Node.js)." -ForegroundColor Red
        Write-Host "  Run:  powershell -ExecutionPolicy Bypass -File install-gsd-prerequisites.ps1" -ForegroundColor Yellow
        Write-Host "  Then restart your terminal and re-run this script." -ForegroundColor Yellow
        exit 1
    }

    $hasClaude = $null -ne (Get-Command claude -ErrorAction SilentlyContinue)
    $hasCodex = $null -ne (Get-Command codex -ErrorAction SilentlyContinue)
    $hasGemini = $null -ne (Get-Command gemini -ErrorAction SilentlyContinue)

    if (-not $hasClaude -or -not $hasCodex) {
        Write-Host ""
        Write-Host "  Claude Code or Codex CLI not found." -ForegroundColor Yellow
        Write-Host "  Run:  powershell -ExecutionPolicy Bypass -File install-gsd-prerequisites.ps1" -ForegroundColor Yellow
        Write-Host "  The engine will install but won't function until both CLIs are available." -ForegroundColor Yellow
        Write-Host ""
    }

    if (-not $hasGemini) {
        Write-Host ""
        Write-Host "  Gemini CLI not found (optional - used for research + spec-fix)." -ForegroundColor DarkYellow
        Write-Host "  Install:  npm install -g @google/gemini-cli" -ForegroundColor Yellow
        Write-Host "  Then:     gemini  (first run authenticates)" -ForegroundColor Yellow
        Write-Host "  Without Gemini, research/spec-fix will fall back to Codex." -ForegroundColor DarkGray
        Write-Host ""
    }

    Write-Host ""
}

$scripts = @(
    @{ File="install-gsd-global.ps1";                Desc="GSD Convergence Engine (5-phase loop)" }
    @{ File="install-gsd-blueprint.ps1";             Desc="Blueprint Pipeline (3-phase spec-to-code)" }
    @{ File="patch-gsd-partial-repo.ps1";            Desc="Partial Repo Support (assess existing code)" }
    @{ File="patch-gsd-resilience.ps1";              Desc="Self-Healing (retry, checkpoint, lock, rollback)" }
    @{ File="patch-gsd-hardening.ps1";               Desc="Full Autonomous (quota sleep, network poll, JSON backup)" }
    @{ File="patch-gsd-final-validation.ps1";        Desc="Final Validation Gate + Developer Handoff Report" }
    @{ File="patch-gsd-council.ps1";                 Desc="LLM Council (multi-agent review gate at 100% health)" }
    @{ File="patch-gsd-figma-make.ps1";              Desc="Figma Make Integration (multi-interface, _analysis/)" }
    @{ File="final-patch-1-spec-check.ps1";          Desc="Spec Consistency Pre-Check" }
    @{ File="final-patch-2-sql-cli.ps1";             Desc="SQL + CLI Enhancements" }
    @{ File="final-patch-3-storyboard-verify.ps1";   Desc="Storyboard Verify (logical correctness)" }
    @{ File="final-patch-4-blueprint-pipeline.ps1";  Desc="Blueprint Pipeline Final (all integrations)" }
    @{ File="final-patch-5-convergence-pipeline.ps1"; Desc="Convergence Pipeline Final (all integrations)" }
    @{ File="final-patch-6-assess-limitations.ps1";  Desc="Multi-Interface Assess + Final Docs" }
    @{ File="final-patch-7-spec-resolve.ps1";       Desc="Spec Conflict Auto-Resolution (Gemini)" }
    @{ File="patch-gsd-supervisor.ps1";             Desc="Supervisor (self-healing recovery, error context, pattern memory)" }
    @{ File="patch-false-converge-fix.ps1";         Desc="Fix false convergence exit + orphaned profile code" }
    @{ File="patch-gsd-parallel-execute.ps1";     Desc="Parallel Sub-Task Execution (split batch, round-robin agents)" }
    @{ File="patch-gsd-resilience-hardening.ps1"; Desc="Resilience Hardening (token tracking, auth fix, quota cap, agent rotation)" }
    @{ File="patch-gsd-quality-gates.ps1";       Desc="Quality Gates (DB completeness, security standards, spec validation)" }
    @{ File="patch-gsd-multi-model.ps1";        Desc="Multi-Model LLM Integration (Kimi K2.5, DeepSeek, GLM-5, MiniMax via REST API)" }
)

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  GSD Master Installer" -ForegroundColor Cyan
Write-Host "  Installs all 21 components in correct dependency order" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""

# Pre-check: verify all files exist
$missing = @()
foreach ($s in $scripts) {
    $path = Join-Path $scriptDir $s.File
    if (-not (Test-Path $path)) {
        $missing += $s.File
    }
}

if ($missing.Count -gt 0) {
    Write-Host "  Missing scripts:" -ForegroundColor Red
    foreach ($m in $missing) {
        Write-Host "     - $m" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  Place all .ps1 files in: $scriptDir" -ForegroundColor Yellow
    Write-Host "  Then re-run this script." -ForegroundColor Yellow
    exit 1
}

Write-Host "  All $($scripts.Count) scripts found in: $scriptDir" -ForegroundColor Green
Write-Host ""

# Execute in order
$step = 0
$failed = @()

foreach ($s in $scripts) {
    $step++
    $path = Join-Path $scriptDir $s.File

    Write-Host "-----------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  [$step/$($scripts.Count)] $($s.File)" -ForegroundColor White
    Write-Host "  $($s.Desc)" -ForegroundColor DarkGray
    Write-Host "-----------------------------------------------------------------" -ForegroundColor DarkGray

    try {
        & $path
        Write-Host "  [$step/$($scripts.Count)] Complete" -ForegroundColor DarkGreen
    } catch {
        Write-Host "  [$step/$($scripts.Count)] FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $failed += $s.File
    }

    Write-Host ""
}

# Summary
Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host "=================================================================" -ForegroundColor Green
    Write-Host "  ALL $($scripts.Count) SCRIPTS COMPLETED SUCCESSFULLY" -ForegroundColor Green
    Write-Host "  Version: $GSD_VERSION ($GSD_DATE)" -ForegroundColor Green
    Write-Host "=================================================================" -ForegroundColor Green

    # Write version stamp to installed engine
    $versionFile = Join-Path $env:USERPROFILE ".gsd-global\VERSION"
    Set-Content -Path $versionFile -Value "version=$GSD_VERSION`ndate=$GSD_DATE`ninstalled=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Encoding UTF8
} else {
    Write-Host "=================================================================" -ForegroundColor Yellow
    Write-Host "  $($failed.Count) script(s) had errors:" -ForegroundColor Yellow
    foreach ($f in $failed) {
        Write-Host "     - $f" -ForegroundColor Red
    }
    Write-Host "=================================================================" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  RESTART YOUR TERMINAL for commands to work" -ForegroundColor Yellow
Write-Host ""
Write-Host "  COMMANDS AVAILABLE AFTER RESTART:" -ForegroundColor White
Write-Host "    gsd-assess       Analyze existing codebase" -ForegroundColor Cyan
Write-Host "    gsd-blueprint    Spec + Figma to Code" -ForegroundColor Cyan
Write-Host "    gsd-converge     5-phase maintenance loop" -ForegroundColor Cyan
Write-Host "    gsd-status       Health dashboard" -ForegroundColor Cyan
Write-Host "    gsd-remote       Remote monitor (QR code for phone)" -ForegroundColor Cyan
Write-Host "    gsd-costs        Token cost calculator + client quotes" -ForegroundColor Cyan
Write-Host ""
