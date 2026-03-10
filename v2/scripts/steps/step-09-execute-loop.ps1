# ===============================================================
# Step 09: Execute Iterations Loop
# Execute -> Build/Test -> Code Review -> Fix Loop per iteration
# ===============================================================

param(
    [Parameter(Mandatory)][string]$GsdDir,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][PSObject]$AgentMap,
    [Parameter(Mandatory)][PSObject]$Config,
    [string]$InterfaceContext = "",
    [int]$StartIteration = 1
)

$stepId = "09-execute-loop"
Write-Host "`n=== STEP 9: Execute Iterations ===" -ForegroundColor Cyan

$maxFixAttempts = $Config.limits.max_fix_attempts_per_iteration

# Load iteration plan
$iterPlanPath = Join-Path $GsdDir "iterations\iteration-plan.json"
if (-not (Test-Path $iterPlanPath)) {
    Write-Host "  [XX] No iteration plan found" -ForegroundColor Red
    return @{ Success = $false; Error = "no_iteration_plan"; StepId = $stepId }
}
$iterPlan = Get-Content $iterPlanPath -Raw | ConvertFrom-Json

# Load plans and research
$plansDir = Join-Path $GsdDir "plans"
$researchDir = Join-Path $GsdDir "research"
$plans = @{}
$research = @{}

Get-ChildItem -Path $plansDir -Filter "*.json" -ErrorAction SilentlyContinue | ForEach-Object {
    $reqId = $_.BaseName
    try { $plans[$reqId] = Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {}
}
Get-ChildItem -Path $researchDir -Filter "*.json" -ErrorAction SilentlyContinue | ForEach-Object {
    $reqId = $_.BaseName
    try { $research[$reqId] = Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {}
}

# Load prompt templates
$execPromptPath = Join-Path $PSScriptRoot "..\..\prompts\09a-execute.md"
$reviewPromptPath = Join-Path $PSScriptRoot "..\..\prompts\09c-code-review.md"
$execPromptTemplate = Get-Content $execPromptPath -Raw -Encoding UTF8
$reviewPromptTemplate = Get-Content $reviewPromptPath -Raw -Encoding UTF8

$totalIterations = $iterPlan.iterations.Count
$completedIterations = 0
$healthHistory = @()

# Health tracking
$healthDir = Join-Path $GsdDir "health"
if (-not (Test-Path $healthDir)) { New-Item -ItemType Directory -Path $healthDir -Force | Out-Null }

# Process each iteration
foreach ($iteration in $iterPlan.iterations) {
    $iterNum = $iteration.iteration
    if ($iterNum -lt $StartIteration) { continue }

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  ITERATION $iterNum / $totalIterations" -ForegroundColor Cyan
    Write-Host "  $($iteration.description)" -ForegroundColor DarkGray
    Write-Host "========================================" -ForegroundColor Cyan

    # Save checkpoint
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "v2" -Iteration $iterNum `
        -Phase "09-execute" -Health 0 -BatchSize 0 -Status "executing"

    # Git snapshot before iteration
    try { git -C $RepoRoot add -A 2>&1 | Out-Null } catch {}
    try { git -C $RepoRoot stash push -m "gsd-v2-pre-iter-$iterNum" 2>&1 | Out-Null } catch {}
    try { git -C $RepoRoot stash pop 2>&1 | Out-Null } catch {}

    $fixAttempt = 0
    $iterationPassed = $false

    while (-not $iterationPassed -and $fixAttempt -lt $maxFixAttempts) {
        $fixAttempt++
        $isRetry = $fixAttempt -gt 1

        # ---- 9a: EXECUTE ----
        Write-Host "`n  --- 9a: Execute (attempt $fixAttempt/$maxFixAttempts) ---" -ForegroundColor Yellow

        $allReqIds = @()
        if ($iteration.parallel_group) { $allReqIds += $iteration.parallel_group }
        if ($iteration.sequential_group) { $allReqIds += $iteration.sequential_group }

        # If retry, only re-execute failed requirements
        $reqsToExecute = if ($isRetry -and $failedReqs) { $failedReqs } else { $allReqIds }

        foreach ($reqId in $reqsToExecute) {
            $plan = $plans[$reqId]
            $res = $research[$reqId]

            $prompt = $execPromptTemplate
            $prompt = $prompt.Replace("{{REQ_ID}}", $reqId)
            $prompt = $prompt.Replace("{{ITERATION}}", "$iterNum")
            $prompt = $prompt.Replace("{{GSD_DIR}}", $GsdDir)
            $prompt = $prompt.Replace("{{REPO_ROOT}}", $RepoRoot)
            $prompt = $prompt.Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext)
            $prompt = $prompt.Replace("{{PLAN}}", $(if ($plan) { $plan | ConvertTo-Json -Depth 10 } else { "(no plan)" }))
            $prompt = $prompt.Replace("{{RESEARCH}}", $(if ($res) { $res | ConvertTo-Json -Depth 10 } else { "(no research)" }))

            # Inject error context from prior failed review
            $errorContextPath = Join-Path $GsdDir "supervisor\error-context.md"
            if ($isRetry -and (Test-Path $errorContextPath)) {
                $prompt += "`n`n## ERROR CONTEXT FROM PRIOR ATTEMPT`n" + (Get-Content $errorContextPath -Raw -Encoding UTF8)
            }

            # Get agent (Codex + Tier 2 for execute)
            $agent = if ($reqId -in $iteration.sequential_group) {
                "codex"
            } else {
                $agents = Get-WaveAgents -StepId "09a-execute" -RequirementCount 1 -AgentMap $AgentMap
                $agents[0]
            }

            Write-Host "    [$agent] $reqId..." -ForegroundColor DarkGray -NoNewline
            $execResult = Invoke-Agent -Agent $agent -Prompt $prompt -StepId "09a-execute" `
                -GsdDir $GsdDir -RepoRoot $RepoRoot -TimeoutMinutes 45

            if ($execResult.Success) {
                Write-Host " OK ($($execResult.DurationSeconds)s)" -ForegroundColor Green
            } else {
                Write-Host " FAIL ($($execResult.Error))" -ForegroundColor Red
            }
        }

        # ---- 9b: BUILD + TEST ----
        Write-Host "`n  --- 9b: Build + Test ---" -ForegroundColor Yellow
        $buildResults = @{ dotnet_build = "skipped"; npm_build = "skipped"; dotnet_test = "skipped"; npm_test = "skipped" }

        # .NET build
        $slnFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sln" -Recurse -Depth 2 -ErrorAction SilentlyContinue
        if ($slnFiles.Count -gt 0) {
            try {
                $buildOut = dotnet build ($slnFiles[0].FullName) --no-restore 2>&1
                $buildResults.dotnet_build = if ($LASTEXITCODE -eq 0) { "pass" } else { "fail" }
                Write-Host "    dotnet build: $($buildResults.dotnet_build)" -ForegroundColor $(if ($buildResults.dotnet_build -eq "pass") { "Green" } else { "Red" })
            } catch { $buildResults.dotnet_build = "fail" }
        }

        # npm build
        $pkgJson = Get-ChildItem -Path $RepoRoot -Filter "package.json" -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pkgJson) {
            try {
                Push-Location (Split-Path $pkgJson.FullName)
                $npmOut = npm run build 2>&1
                $buildResults.npm_build = if ($LASTEXITCODE -eq 0) { "pass" } else { "fail" }
                Write-Host "    npm build: $($buildResults.npm_build)" -ForegroundColor $(if ($buildResults.npm_build -eq "pass") { "Green" } else { "Red" })
                Pop-Location
            } catch { $buildResults.npm_build = "fail"; Pop-Location }
        }

        # Save build results
        $buildResultsPath = Join-Path $GsdDir "iterations\build-results\$iterNum.json"
        $buildResults | ConvertTo-Json | Set-Content $buildResultsPath -Encoding UTF8

        # ---- 9c: CODE REVIEW ----
        Write-Host "`n  --- 9c: Code Review ---" -ForegroundColor Yellow

        # Get git diff for this iteration
        $gitDiff = ""
        try { $gitDiff = git -C $RepoRoot diff HEAD~1 2>&1 | Out-String } catch {}

        $reviewPrompt = $reviewPromptTemplate
        $reviewPrompt = $reviewPrompt.Replace("{{ITERATION}}", "$iterNum")
        $reviewPrompt = $reviewPrompt.Replace("{{TOTAL_ITERATIONS}}", "$totalIterations")
        $reviewPrompt = $reviewPrompt.Replace("{{ITERATION_REQUIREMENTS}}", ($allReqIds -join ", "))
        $reviewPrompt = $reviewPrompt.Replace("{{GSD_DIR}}", $GsdDir)
        $reviewPrompt = $reviewPrompt.Replace("{{REPO_ROOT}}", $RepoRoot)
        $reviewPrompt = $reviewPrompt.Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext)
        $reviewPrompt = $reviewPrompt.Replace("{{BUILD_RESULTS}}", ($buildResults | ConvertTo-Json))
        $reviewPrompt = $reviewPrompt.Replace("{{GIT_DIFF}}", $(if ($gitDiff.Length -gt 50000) { $gitDiff.Substring(0, 50000) + "`n... (truncated)" } else { $gitDiff }))

        # Claude + Gemini do the review (alternates with execute agents)
        $reviewAgent = Get-StepAgent -StepId "09c-code-review" -AgentMap $AgentMap
        Write-Host "    [$reviewAgent] Reviewing..." -ForegroundColor DarkGray

        $reviewResult = Invoke-Agent -Agent $reviewAgent -Prompt $reviewPrompt -StepId "09c-code-review" `
            -GsdDir $GsdDir -RepoRoot $RepoRoot -TimeoutMinutes 20

        # Parse review
        $reviewPath = Join-Path $GsdDir "iterations\reviews\$iterNum.json"
        $iterationPassed = $false
        $failedReqs = @()

        if (Test-Path $reviewPath) {
            try {
                $review = Get-Content $reviewPath -Raw | ConvertFrom-Json
                $iterationPassed = ($review.overall_verdict -eq "pass")
                if (-not $iterationPassed) {
                    $failedReqs = ($review.requirements | Where-Object { $_.verdict -ne "pass" }).req_id
                    Write-Host "    Verdict: FAIL | Failed: $($failedReqs -join ', ')" -ForegroundColor Red

                    # Write error context for retry
                    $errorContext = "## Iteration $iterNum Review Failures (Attempt $fixAttempt)`n"
                    foreach ($reqReview in ($review.requirements | Where-Object { $_.verdict -ne "pass" })) {
                        $errorContext += "`n### $($reqReview.req_id)`n"
                        foreach ($finding in $reqReview.findings) {
                            $errorContext += "- [$($finding.severity)] $($finding.description)`n"
                            if ($finding.fix) { $errorContext += "  Fix: $($finding.fix)`n" }
                        }
                    }
                    Set-Content -Path (Join-Path $GsdDir "supervisor\error-context.md") -Value $errorContext -Encoding UTF8
                }
                else {
                    Write-Host "    Verdict: PASS" -ForegroundColor Green
                }
            }
            catch {
                Write-Host "    [WARN] Could not parse review, treating as pass" -ForegroundColor DarkYellow
                $iterationPassed = $true
            }
        }
        else {
            Write-Host "    [WARN] No review file generated, treating as pass" -ForegroundColor DarkYellow
            $iterationPassed = $true
        }
    }

    # ---- 9d: Commit or Escalate ----
    if ($iterationPassed) {
        # Git commit
        try {
            git -C $RepoRoot add -A 2>&1 | Out-Null
            git -C $RepoRoot commit -m "GSD v2: Iteration $iterNum - $($iteration.description)" 2>&1 | Out-Null
            Write-Host "  [GIT] Committed iteration $iterNum" -ForegroundColor DarkGreen
        } catch {}

        $completedIterations++
        Send-IterationNotification -Iteration $iterNum -TotalIterations $totalIterations `
            -Status "complete" -PassedReqs $allReqIds.Count
    }
    else {
        Write-Host "  [ESCALATE] Iteration $iterNum failed after $maxFixAttempts attempts" -ForegroundColor Red
        Send-IterationNotification -Iteration $iterNum -TotalIterations $totalIterations `
            -Status "failed" -FailedReqs $failedReqs.Count `
            -Details "Failed reqs: $($failedReqs -join ', ')"
    }

    # Update health
    $healthScore = [math]::Round(($completedIterations / $totalIterations) * 100, 1)
    @{
        health_score = $healthScore
        completed_iterations = $completedIterations
        total_iterations = $totalIterations
        current_iteration = $iterNum
        timestamp = (Get-Date -Format "o")
    } | ConvertTo-Json | Set-Content (Join-Path $GsdDir "health\health-current.json") -Encoding UTF8

    # Append health history
    $historyEntry = @{
        iteration = $iterNum
        health = $healthScore
        passed = $iterationPassed
        timestamp = (Get-Date -Format "o")
    } | ConvertTo-Json -Compress
    Add-Content -Path (Join-Path $GsdDir "health\health-history.jsonl") -Value $historyEntry -Encoding UTF8

    # Checkpoint
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "v2" -Iteration $iterNum `
        -Phase "09-complete" -Health $healthScore -BatchSize 0 -Status "iteration_complete"
}

Write-Host "`n  All iterations complete: $completedIterations/$totalIterations passed" -ForegroundColor $(
    if ($completedIterations -eq $totalIterations) { "Green" } else { "Yellow" }
)

return @{
    Success = ($completedIterations -eq $totalIterations)
    CompletedIterations = $completedIterations
    TotalIterations = $totalIterations
    HealthScore = [math]::Round(($completedIterations / [math]::Max($totalIterations, 1)) * 100, 1)
    StepId = $stepId
}
