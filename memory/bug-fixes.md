# Bug Fixes History

## GSD v2.0 Pipeline Bugs (2026-03-10, session 4+5)
5. **CLAUDECODE env var nesting**: When pipeline launched from Claude Code session, child Claude CLI refuses with "cannot be launched inside another Claude Code session". Fix: Each wrapper script (claude/codex/gemini) does `Remove-Item Env:CLAUDECODE` as first line. Also created `launch-pipeline.ps1` helper. **DO NOT use cmd.exe /c wrapper** — cmd.exe exits immediately, orphaning child processes and making WaitForExit return instantly.
6. **Gemini plan mode blocks file writes**: agent-router.ps1 defaulted `$GeminiMode = "--approval-mode plan"` which prevents gemini from writing requirement files. Agent outputs JSON to stdout but never creates the file. Fix: changed default to `--yolo`.
8. **cmd.exe /c orphans child processes**: Using `Start-Process cmd.exe /c "... & powershell.exe ..."` causes cmd.exe to exit as soon as it spawns powershell. `WaitForExit` returns immediately, agent-router records empty output as error, moves to next artifact. Actual agent runs as orphan. Fix: reverted to `Start-Process powershell.exe` directly.
7. **Step 2 artifact discovery too narrow**: Only searched `docs/` root for `Phase-A*`, `Phase-B*`, `Phase-D*`, `Phase-E*` patterns. Missed all subdirectories (sdlc/docs/, phases/, architecture/, intake/, spec/) and Figma v8 analysis. Fix: rewrote discovery to recursively scan all docs/ subdirs, group by phase/category, and fallback-scan design/ for `_analysis/` dirs.

11. **$label: variable reference parse error**: `Write-Host "    [TRIM] $label: ..."` — PowerShell interprets `$label:` as scoped variable reference (like `$env:PATH`). With ErrorActionPreference=Stop, crashes entire discovery. Fix: changed to `${label}:`.
12. **Supervisor checkpoint parsing re-runs Step 1**: supervisor-wrapper.ps1 line 170 matches `01-complete` → extracts `01` → sets `$StartStep = 1` → Step 1 redundantly re-runs every supervisor attempt. Same bug as pipeline.ps1 checkpoint resume. Fix: added `-complete` suffix check, `$StartStep = [int]$Matches[1] + 1`.
13. **Step 2 infinite restart loop (supervisor + timeout)**: Codex agents take >20 min for large artifacts. Step 2's 20-min timeout marks running jobs as `timeout_or_crash`. If ALL jobs timeout, `$succeeded = 0` → `Success = $false`. Pipeline throws, supervisor retries. But orphaned codex processes (survived Stop-Job) actually DO write files to disk. Fix: Step 2 now counts requirement JSON files on disk (>100 bytes) as success, not just job completion status. `$isSuccess = ($succeeded -gt 0) -or ($filesCount -gt 0)`.

9. **Start-Job missing api-agents.ps1**: Start-Job scriptblock only dot-sourced agent-router.ps1 but not api-agents.ps1. When REST agents (kimi/deepseek/glm5/minimax) were assigned, `Invoke-ApiAgent` was undefined → job crash. Fix: added `$ApiAgentsPath` param and `. $ApiAgentsPath` to job scriptblock.
10. **Regex crash kills Step 2 artifact discovery**: `$relPath -split '[/\\]'` throws `Unterminated [] set` regex parse error. With `$ErrorActionPreference = "Stop"` set in pipeline.ps1, this becomes a terminating exception. Discovery loop crashes after 1-2 files → only 1 artifact → only 1 agent job → no parallelism. Fix: replaced regex `-split` with `.Split(@('/','\'), [StringSplitOptions]::RemoveEmptyEntries)`.

## GSD v2.0 Pipeline Bugs (2026-03-10, session 4) [ORIGINAL]
1. **Em-dash encoding crash**: `supervisor-wrapper.ps1`, `pipeline.ps1`, `step-07b-plan.ps1` had UTF-8 em-dash chars that garbled when PowerShell read without BOM → `Unexpected token '}' at line 179`. Fix: replaced with ASCII dashes, saved supervisor-wrapper.ps1 with UTF-8 BOM.
2. **Update-FileMap param mismatch**: `pipeline.ps1:107` called `Update-FileMap -RepoRoot $RepoRoot -GsdDir $GsdDir` but `resilience.ps1:2414` expects `-Root` and `-GsdPath`. Caused `Cannot bind argument to parameter 'Path' because it is an empty string`. Fix: changed to `-Root $RepoRoot -GsdPath $GsdDir`.
3. **$script: scope isolation crash**: `agent-router.ps1` used `$script:AgentQuotaExhausted` etc. Step scripts called via `&` operator run in child scope where `$script:` vars are `$null` → `Cannot index into a null array` on every Step 1 entry. Fix: changed ALL `$script:` to `$global:` for state vars + agent pool constants. Added null guards.
4. **Lock file not cleaned on crash**: Pipeline crash leaves `.gsd/.gsd-lock`. Supervisor retries all fail with "Another GSD process is running". Supervisor should clear lock between attempts (v2 gap vs v1.5 which did this).
4. **WhatsApp bridge conflict**: Old bridge process (PID from hours ago) stays alive, new bridge connects → stream conflict (replaced) → disconnect loop. Fix: always kill old node processes before starting bridge.

## Known Runtime Bug Fixes (v2.3.x patches)
Applied to live ~/.gsd-global AND mirrored back into repo patch scripts (commit 445ce3a):
- **$GsdGlobalDir → $GlobalDir**: convergence-loop.ps1 lines 663/831 (LOC tracking) — undefined var caused Join-Path crash
- **AUTH_ERROR 480-min cooldown**: patch-gsd-resilience-hardening.ps1 — auth-failed agents were retried every iteration
- **Research quota cascade**: convergence-loop.ps1 pre-check + Get-NextAvailableAgent $Phase filter — prevented Claude/Codex being selected for research rotation
- **Boundary phase-awareness**: patch-gsd-hardening.ps1 $boundaryAgent switch — Claude in execute phase now uses codex boundary rules
- **Council synthesis 80KB cap**: patch-gsd-council.ps1 both synthesis paths (chunked + monolithic) — prevented exit code 1 on large projects; MaxAttempts 2→3
- **Get-FailureDiagnosis STEP 13C idempotency**: patch-gsd-multi-model.ps1 — check was matching enhanced version, leaving original unpatched (caused "Unknown agent 'kimi'" errors)
- **Two Get-FailureDiagnosis versions**: resilience.ps1 has original (~line 298, Invoke-WithRetryCore) AND enhanced (~line 1512, Invoke-WithRetry override). Multi-model patch must patch both; idempotency check must be version-specific.

## Critical convergence-loop.ps1 Bugs Fixed (2026-03-08)
Three bugs found and fixed in both live (~/.gsd-global) and repo scripts:
1. **Diff-skip not actually skipping**: `elseif (ChangedFiles.Count -eq 0)` branch printed "skipping" but left `$useDiffReview = $false`, so `if (-not $useDiffReview)` ran the full review anyway. Fix: add `$useDiffReview = $true` in skip branch.
2. **Gemini fallback for code-review**: `if (claude fails) → Invoke-WithRetry -Agent "gemini" --approval-mode yolo` caused gemini strict traceability audit → sat=0 every iteration. Fix: changed fallback agent to `codex`.
3. **Gemini fallback for plan**: same pattern — changed to codex.
- Both fallback log file names changed from `iter${N}-1-gemini.log` / `iter${N}-3-gemini.log` to `iter${N}-1-fallback.log` / `iter${N}-3-fallback.log`

## Rate Limiter Disease Fixes (2026-03-10)
Applied to live ~/.gsd-global/lib/modules/resilience.ps1:
1. **Invoke-AgentFallback bypass**: Added `Wait-ForRateWindow` before + `Register-AgentCall` after all fallback agent calls. CLI agents (kimi/codex/claude/gemini) were completely bypassing the rate limiter on every retry fallback.
2. **Double registration for REST agents**: `Invoke-WithRetry` line 1789 now skips `Register-AgentCall` for OpenAI-compat agents since `Invoke-OpenAICompatibleAgent` already registers (was counting each REST call 2x → halving effective RPM).
3. **Parallel job race condition**: Added `Global\GsdRateTracker` named mutex to `Register-AgentCall` and `Wait-ForRateWindow` for atomic file access across `Start-Job` processes. Was: 5 concurrent jobs read stale tracker → all call same agent → stampede.
4. **Build auto-fix bypass**: Added `Wait-ForRateWindow`/`Register-AgentCall` to dotnet and npm auto-fix codex calls (lines ~642, ~728).

## Execute Phase Disease Fixes (2026-03-10, session 2, patch #42)
Applied to live ~/.gsd-global:
1. **Execute cascade (max_concurrent 5→2)**: Blasting 5 sub-tasks simultaneously exhausted all agents in minutes. Now dispatches waves of 2 with 15s inter-wave cooldown.
2. **Codex over-targeting**: Was first in agent pool (always got first pick). Reordered: deepseek first (cheapest $0.28/M, 48 RPM), claude last (most expensive).
3. **Kimi "Unknown agent" crashes**: model-registry.json had kimi as type:cli (no CLI binary exists). Fixed to openai-compat. Added registry check in Invoke-WithRetry + Invoke-AgentFallback so kimi falls through to REST adapter.
4. **REST fallback in AgentFallback**: Added `Test-IsOpenAICompatAgent` path in fallback dispatch — was missing, so REST agents called as fallback would crash.
5. **Job failure traceability**: Extract agent name + req ID from subtask assignment list when jobs crash without returning results. Was logging "unknown" agent.
6. **Inter-wave cooldown configurable**: agent-map.json → `execute_parallel.inter_wave_cooldown_seconds` (default 15s).

## Iteration Flow Restructure (2026-03-10, session 2)
Applied to live convergence-loop.ps1:
1. **Added req-assess phase**: Lightweight matrix scan (no LLM) at start of each iteration — shows satisfied/partial/pending counts before any LLM work.
2. **Code review stays at start but is focused**: Differential review only reviews changed files, updates statuses for affected requirements only. Not a full codebase scan.
3. **Decompose moved before research**: Sub-reqs get wave research before plan/execute.
4. **Full code review deferred to convergence complete**: Final validation gate (100% health) does full spec/Figma/quality gate verification + developer-handoff.md.

**Correct iteration flow:**
```
req-assess → focused code-review → decompose → wave-research → plan → execute → loop
```
**At 100% convergence:** Full code review + spec/Figma verification + quality gate → developer-handoff.md

## Wave Research + Decompose Fixes (2026-03-10, session 2)
Applied to live ~/.gsd-global:
1. **Invoke-PartialDecompose never existed in resilience.ps1**: The snippet file existed but was never appended. Function didn't exist → `Get-Command` returned null → silently skipped every iteration. Fix: appended full function to resilience.ps1.
2. **Decompose gated by $Iteration -gt 1**: First iteration (or any restart) always skipped decompose. Fix: removed iteration gate from convergence-loop.ps1 line 484.
3. **Decompose required queue-current.json**: If queue file missing (fresh run), silently skipped. Fix: fallback to scanning ALL partial requirements with long descriptions (>100 chars) or >3 acceptance criteria.
4. **Research blasted entire phases**: 3 agents each got ALL requirements for 2+ phases → massive prompts → quota exhaustion → cascade cooldown. Fix: new wave-based targeted research in `Invoke-ParallelResearch` — picks top 6 pending/partial reqs, splits into waves of 2, dispatches to available agents round-robin with 10s gaps. Falls back to phase-based if targeted prompt missing.
5. **New prompt template**: `prompts/shared/research-targeted.md` — focused on specific requirement IDs, max 8K tokens output.
6. **Config additions**: `global-config.json → parallel_research.max_target_reqs` (default 6), `wave_size` (default 2).
7. **Rate limit integration**: Decompose now calls `Wait-ForRateWindow`/`Register-AgentCall` before/after Claude calls.

## Deep Analysis Disease Fixes (2026-03-10, session 3, patch #43)
Applied to live ~/.gsd-global:
1. **Execute pool REST agents**: kimi/deepseek/glm5/minimax were in execute_parallel.agent_pool but can't write files (REST-only). Fixed: pool now CLI-only `["codex","gemini","claude"]`.
2. **$Pipeline undefined**: All 4 `Invoke-LlmCouncil` calls in convergence-loop.ps1 received `$null` for `-Pipeline`. Fixed: added `$Pipeline = "converge"` at line 215.
3. **Invoke-ParallelResearch unwrapped**: Could crash entire loop on JSON parse errors. Fixed: wrapped in try/catch.
4. **Decompose param name mismatch**: `Wait-ForRateWindow -Agent` should be `-AgentName`, `-GlobalDir` should be `-GsdDir`. `Register-AgentCall -Agent` should be `-AgentName`. Fixed in resilience.ps1 Invoke-PartialDecompose.
5. **Plan prompt no decomposed-awareness**: Planner re-queued decomposed parents alongside their sub-reqs. Fixed: added "Decomposed Requirements" section to plan.md.
6. **Health formula counts decomposed parents**: Made 100% unreachable since decomposed parents stay "partial" in denominator. Fixed: added exclusion rule to code-review.md.
7. **Invoke-PartialDecompose crash (prior fix)**: Already wrapped in try/catch in convergence-loop.ps1 line 408.

**Additional fixes applied (session 3, second pass):**
8. **Mutex acquisition check**: `Wait-ForRateWindow` and `Register-AgentCall` now track `$acquired` flag, only call `ReleaseMutex()` when mutex was actually acquired.
9. **Stop-Job before Remove-Job**: `Invoke-ParallelExecute` now calls `Stop-Job` before `Remove-Job -Force` for timed-out jobs, preventing orphaned background processes.
10. **New-GitSnapshot stash pop removed**: Was doing `git stash push` then immediately `git stash pop` (no-op). Now stash persists as actual revert point.
11. **7 more try/catch wrappers**: `Invoke-LlmCouncil` (4 calls), `Invoke-BuildValidation` (2 calls), `Invoke-CouncilRequirements` (1 call) — all wrapped with non-fatal error handling.

## Quota Rotation Phase-Awareness Fix (2026-03-09, disease #16)
- **Root cause**: `$cliOnlyPhase` regex in `Invoke-WithRetry` (line 1842) only matched `council-requirements|council-verify`
- Execute/plan/spec phases defaulted to `$CliOnly:$false`, allowing REST agents (kimi/deepseek/glm5/minimax) into rotation pool
- Kimi as execute agent → exit code 1 (can't write files via REST) → retry loop → subtask failure
- **Fix**: Expanded regex to `council-requirements|council-verify|execute|plan|spec` (both occurrences via replace_all)
- CheapFirstReview and BatchScopedResearch are now wired into convergence loop (fixed in session 3)

**Remaining known issues (design-level, not bugs):**
- Old Invoke-AgentFallback v1 (line 324) lacks rate limiting (overridden by v2 at line 1557, harmless)

## V3 Pipeline Fixes (2026-03-10, session 6)
19. **MaxConcurrent=15 floods rate bucket**: `phase-orchestrator.ps1:634` passed `-MaxConcurrent 15` to `Invoke-CodexMiniParallel`, but config says 2. With 15 concurrent skeleton requests, all hit 429 simultaneously. Fix: changed to `-MaxConcurrent 2`.
20. **model-registry.json retry config stale**: codex-mini entry had `max_retries: 3, backoff: [2,4,8]` but api-client.ps1 uses `5, [5,15,30,60,120]`. Synced registry to match actual behavior.
21. **Stale lock blocks restart**: gsd-update.ps1 preflight checks lock file from dead PID → refuses to start. Fix: auto-clear lock file on startup before any preflight checks.
22. **DeepSeek fallback for Codex Mini**: When Codex Mini fails after all retries (ANY error: 429/400/404/timeout), auto-fallback to DeepSeek (`deepseek-chat` via `api.deepseek.com`). Added `Invoke-DeepSeekFallback` function + `DeepSeek` config block in api-client.ps1. DeepSeek is only working backup — China models (Kimi/GLM5/MiniMax) unreachable from corporate network.
23. **Fast-fail retries**: Codex Mini retries reduced 5→1 with 3s backoff. With DeepSeek fallback, each item takes ~6s instead of ~245s. Skeleton phase: ~41min → ~3min for 10 items.
24. **Plan batch too large**: feature_update `batch_size_max` was 10 → plan JSON exceeded max_tokens → truncated → JSON parse error → skipped iteration. Fix: reduced to 5 in global-config.json.
25. **Plan token multiplier too low**: `4096 + (count * 2800)` = 32K for 10 reqs not enough. Bumped to `4096 + (count * 4000)` in phase-orchestrator.ps1.
26. **Kimi + MiniMax fallback chain**: Added both as fallback models in api-client.ps1 config. Chain: Codex Mini → DeepSeek → Kimi → MiniMax. Replaced Invoke-DeepSeekFallback with generic Invoke-OpenAICompatFallback.
27. **MiniMax wrong model + endpoint**: Was `abab6.5s-chat` at `api.minimax.chat`. Correct: `MiniMax-Text-01` at `api.minimax.io`.
28. **DeepSeek max_tokens=8192 cap**: Pipeline sent `max_tokens=16384` but DeepSeek limit is [1,8192]. Returns 400. Fix: added MaxOutputTokens=8192 to DeepSeek config, fallback function respects per-model cap.

## V3 Pipeline Fixes (2026-03-11, session 14)
34. **Sonnet timeout restored**: Plan phase timed out at 120s. Restored to 300s.
35-39. **Codex timeout bumped**: Fill phase timed out at 120s, bumped to 240s. DeepSeek fallback catches remaining.
36. **Review truncation**: Hardcoded 4000 max_tokens too low for 10 failed items. Scaled to 800/item, min 4K, max 12K.
37. **Verify truncation**: 553 active reqs overwhelmed 3000 max_tokens. Capped to 100 reqs + scaled tokens.
38. **Silent crashes**: Added Start-Transcript + try/catch + fatal-crash.log.
40. **Research→Plan truncation**: Plan only saw 44% of research (8000/18000 chars). Increased to 16000 chars.
41. **Backend .csproj path**: Local validator ran `dotnet build` from repo root. Fixed to use `src/Server/Technijian.Api` dir.
42. **Health stall ROOT CAUSE**: Verify phase got requirement status updates but NEVER wrote them back to requirements-matrix.json. Added writeback code in phase-orchestrator.ps1. Health stuck at 66.9% for 5 iterations because of this.
43. **Path remapping**: Pipeline writes to `backend/` but real project is at `src/Server/Technijian.Api/`. Added path remapping in `Write-GeneratedFiles`.
44. **Namespace remapping**: Generated .cs files use `namespace backend.X`. Added content remapping to `namespace Technijian.Api.X` + `using backend.` → `using Technijian.Api.` in Write-GeneratedFiles.
- **Build repair**: Removed 29 files with wrong namespaces from src/Server/Technijian.Api/. Fixed 4 CS1744 errors in BackupHealthCheck.cs and BlobBackupHealthCheck.cs (HealthCheckResult duplicate named args).

## Stash-Pop Conflict Markers (chatai project specific)
- Every supervisor restart stashes `.gsd/` files, then `git stash pop` inserts conflict markers in `.gsd/cache/reviewed-files.json` etc.
- Fix: `.gitattributes` with `-merge` flag for `.gsd/cache/*.json` and other operational files (committed to chatai repo at 1892f71)
- Gemini traceability audit: added anti-traceability guard to `.gsd/supervisor/prompt-hints.md`
- Gemini cooldown: extended to 20:00 UTC when it causes damage; use `agent-cooldowns.json`
