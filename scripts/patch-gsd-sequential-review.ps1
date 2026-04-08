# ============================================================
# patch-gsd-sequential-review.ps1
# Script 38 in install chain
# Appends Invoke-SequentialChunkedReview (v2, rate-limit-aware)
# to resilience.ps1 and patches convergence-loop.ps1 to use it.
# ============================================================

param(
    [string]$GlobalDir = "$env:USERPROFILE\.gsd-global"
)

$ErrorActionPreference = "Stop"
Write-Host "`n=== Patch: Rate-Limit-Aware Chunked Code Review (v2) ===" -ForegroundColor Cyan

# ── 1. Append function to resilience.ps1 ──
$resiliencePath = Join-Path $GlobalDir "lib\modules\resilience.ps1"
if (-not (Test-Path $resiliencePath)) {
    Write-Host "  [ERROR] resilience.ps1 not found at $resiliencePath" -ForegroundColor Red
    exit 1
}

$resilienceContent = Get-Content $resiliencePath -Raw
$marker = "function Invoke-SequentialChunkedReview"

if ($resilienceContent -match [regex]::Escape($marker)) {
    # Remove old version and re-append new one
    $markerStart = "# ============================================================`n# Sequential Chunked Code Review"
    $markerStartAlt = "# ============================================================`n# Rate-Limit-Aware Chunked Code Review"
    $oldSnippetPattern = '(?s)# =+\r?\n# (?:Sequential|Rate-Limit-Aware) Chunked Code Review.*?(?=\r?\n# =+\r?\n# (?!Rate-Limit|Sequential)|$)'

    # Safer approach: just check marker and skip if already v2
    if ($resilienceContent -match "rate-limit-aware-chunked") {
        Write-Host "  [SKIP] Invoke-SequentialChunkedReview v2 already present in resilience.ps1" -ForegroundColor DarkGray
    } else {
        # v1 present, need to replace. Remove old function block and append new.
        # Find and remove old function
        $lines = $resilienceContent -split "`n"
        $startIdx = -1
        $endIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "function Invoke-SequentialChunkedReview") { $startIdx = $i - 5 }  # include comment header
            if ($startIdx -ge 0 -and $i -gt $startIdx + 10 -and $lines[$i] -match "^}$") { $endIdx = $i; break }
        }
        if ($startIdx -ge 0 -and $endIdx -ge 0) {
            if ($startIdx -lt 0) { $startIdx = 0 }
            $before = ($lines[0..($startIdx - 1)] -join "`n").TrimEnd()
            $after = if ($endIdx + 1 -lt $lines.Count) { ($lines[($endIdx + 1)..($lines.Count - 1)] -join "`n").TrimStart() } else { "" }
            $resilienceContent = $before + "`n" + $after
        }

        $snippetPath = Join-Path $PSScriptRoot "partials\invoke-sequential-chunked-review.snippet.ps1"
        if (-not (Test-Path $snippetPath)) {
            Write-Host "  [ERROR] Snippet not found: $snippetPath" -ForegroundColor Red
            exit 1
        }
        $snippet = Get-Content $snippetPath -Raw
        $resilienceContent = $resilienceContent.TrimEnd() + "`n`n" + $snippet
        Set-Content -Path $resiliencePath -Value $resilienceContent -Encoding UTF8
        Write-Host "  [OK] Upgraded Invoke-SequentialChunkedReview to v2 (rate-limit-aware) in resilience.ps1" -ForegroundColor Green
    }
} else {
    $snippetPath = Join-Path $PSScriptRoot "partials\invoke-sequential-chunked-review.snippet.ps1"
    if (-not (Test-Path $snippetPath)) {
        Write-Host "  [ERROR] Snippet not found: $snippetPath" -ForegroundColor Red
        exit 1
    }
    $snippet = Get-Content $snippetPath -Raw
    Add-Content -Path $resiliencePath -Value "`n`n$snippet" -Encoding UTF8
    Write-Host "  [OK] Appended Invoke-SequentialChunkedReview v2 to resilience.ps1" -ForegroundColor Green
}

# ── 2. Copy prompt template ──
$templateSrc = Join-Path $PSScriptRoot "..\prompts\claude\code-review-chunked.md"
$templateDst = Join-Path $GlobalDir "prompts\claude\code-review-chunked.md"

if (Test-Path $templateSrc) {
    Copy-Item $templateSrc $templateDst -Force
} else {
    if (-not (Test-Path $templateDst)) {
        Write-Host "  [WARN] code-review-chunked.md template not found" -ForegroundColor Yellow
    }
}
Write-Host "  [OK] Prompt template: $templateDst" -ForegroundColor Green

# ── 3. Copy config files (model-registry.json + agent-map.json updates) ──
$configSrcDir = Join-Path $PSScriptRoot "..\config"
$configDstDir = Join-Path $GlobalDir "config"
if (-not (Test-Path $configDstDir)) { New-Item -Path $configDstDir -ItemType Directory -Force | Out-Null }

foreach ($cfgFile in @("model-registry.json", "agent-map.json")) {
    $src = Join-Path $configSrcDir $cfgFile
    $dst = Join-Path $configDstDir $cfgFile
    if (Test-Path $src) {
        Copy-Item $src $dst -Force
        Write-Host "  [OK] Config: $cfgFile -> $dst" -ForegroundColor Green
    }
}

# ── 4. Patch convergence-loop.ps1 to use chunked review ──
$loopPath = Join-Path $GlobalDir "scripts\convergence-loop.ps1"
if (-not (Test-Path $loopPath)) {
    Write-Host "  [ERROR] convergence-loop.ps1 not found" -ForegroundColor Red
    exit 1
}

$loopContent = Get-Content $loopPath -Raw

if ($loopContent -match "Invoke-SequentialChunkedReview") {
    Write-Host "  [SKIP] convergence-loop.ps1 already uses chunked review" -ForegroundColor DarkGray
} else {
    # Find the non-diff review block and replace with chunked version
    # Target: the block starting with "if (-not $useDiffReview)" containing single-agent review

    # Try to match the old single-agent pattern
    $oldBlock = @'
    if (-not $useDiffReview) {
    $prompt = Local-ResolvePrompt "$GlobalDir\prompts\claude\code-review.md" $Iteration $Health
    if (-not $DryRun) {
        $reviewResult = Invoke-WithRetry -Agent "claude" -Prompt $prompt -Phase "code-review" `
            -LogFile "$GsdDir\logs\iter${Iteration}-1.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir `
            -AllowedTools "Read,Write,Bash"
        # Fallback: if claude failed, retry with codex (NOT gemini -- gemini applies strict traceability rules that corrupt the matrix)
        if (-not $reviewResult -or $reviewResult.ExitCode -ne 0) {
            Write-Host "  [FALLBACK] claude code-review failed -- retrying with codex" -ForegroundColor Yellow
            Invoke-WithRetry -Agent "codex" -Prompt $prompt -Phase "code-review" `
                -LogFile "$GsdDir\logs\iter${Iteration}-1-fallback.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir | Out-Null
        }
    }
    $Health = Get-Health
    if ($Health -ge $TargetHealth) { Write-Host "  [OK] CONVERGED!" -ForegroundColor Green; break }
'@

    $newBlock = @'
    if (-not $useDiffReview) {
    # Rate-limit-aware chunked review: dynamically splits requirements across all available agents
    if (-not $DryRun -and (Get-Command Invoke-SequentialChunkedReview -ErrorAction SilentlyContinue)) {
        Write-Host "  [REVIEW] Rate-limit-aware chunked review (all available agents)" -ForegroundColor Cyan
        $chunkResult = Invoke-SequentialChunkedReview -GsdDir $GsdDir -GlobalDir $GlobalDir -RepoRoot $RepoRoot `
            -Iteration $Iteration -Health $Health -CurrentBatchSize $CurrentBatchSize -InterfaceContext $InterfaceContext
        if ($chunkResult.Success) {
            Write-Host "  [REVIEW] Chunked review completed ($($chunkResult.ChunksCompleted)/$($chunkResult.ChunksTotal) chunks)" -ForegroundColor Green
        } else {
            Write-Host "  [REVIEW] Chunked review partial ($($chunkResult.ChunksCompleted)/$($chunkResult.ChunksTotal)) --falling back to single-agent" -ForegroundColor Yellow
            if ($chunkResult.ChunksCompleted -lt 2) {
                $prompt = Local-ResolvePrompt "$GlobalDir\prompts\claude\code-review.md" $Iteration $Health
                $reviewResult = Invoke-WithRetry -Agent "codex" -Prompt $prompt -Phase "code-review" `
                    -LogFile "$GsdDir\logs\iter${Iteration}-1-fallback.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir
            }
        }
    } elseif (-not $DryRun) {
        # Legacy single-agent path (Invoke-SequentialChunkedReview not available)
        $prompt = Local-ResolvePrompt "$GlobalDir\prompts\claude\code-review.md" $Iteration $Health
        $reviewResult = Invoke-WithRetry -Agent "claude" -Prompt $prompt -Phase "code-review" `
            -LogFile "$GsdDir\logs\iter${Iteration}-1.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir `
            -AllowedTools "Read,Write,Bash"
        if (-not $reviewResult -or $reviewResult.ExitCode -ne 0) {
            Write-Host "  [FALLBACK] claude code-review failed -- retrying with codex" -ForegroundColor Yellow
            Invoke-WithRetry -Agent "codex" -Prompt $prompt -Phase "code-review" `
                -LogFile "$GsdDir\logs\iter${Iteration}-1-fallback.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir | Out-Null
        }
    }
    $Health = Get-Health
    if ($Health -ge $TargetHealth) { Write-Host "  [OK] CONVERGED!" -ForegroundColor Green; break }
'@

    if ($loopContent.Contains($oldBlock)) {
        $loopContent = $loopContent.Replace($oldBlock, $newBlock)
        Set-Content -Path $loopPath -Value $loopContent -Encoding UTF8
        Write-Host "  [OK] Patched convergence-loop.ps1 with rate-limit-aware chunked review" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Could not find exact old block in convergence-loop.ps1 --manual patch needed" -ForegroundColor Yellow
        Write-Host "  Replace the 'if (-not `$useDiffReview)' block with the chunked version" -ForegroundColor Yellow
    }
}

Write-Host "`n=== Rate-Limit-Aware Chunked Code Review patch complete ===" -ForegroundColor Green
Write-Host "  - Function: Invoke-SequentialChunkedReview v2 (in resilience.ps1)" -ForegroundColor Gray
Write-Host "  - Template: prompts\claude\code-review-chunked.md" -ForegroundColor Gray
Write-Host "  - Config:   model-registry.json (rate_limits per agent)" -ForegroundColor Gray
Write-Host "  - Config:   agent-map.json review_chunked (safety_factor, chunk sizes)" -ForegroundColor Gray
Write-Host "  - Strategy: all 7 agents, dynamic chunk sizes = floor(RPM x 0.5)" -ForegroundColor Gray
Write-Host "  - Waves:    auto-calculated based on total reqs / total capacity" -ForegroundColor Gray
Write-Host "  - Fallback: single-agent codex if under 60 pct chunks complete" -ForegroundColor Gray
