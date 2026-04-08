# Cross-Session Pattern Analysis

## Recurring Diseases (root causes that keep appearing)

### 1. Patch Scripts Overriding Config (HIGH PRIORITY)
- **Pattern**: New patch scripts (e.g., #43) hardcode agent pools/configs that override user's agent-map.json settings
- **Example**: Patch #43 forced `execute_parallel.agent_pool = @("codex","claude")` and added `execute` to `$cliOnlyPhase`
- **Impact**: 12+ hours of stagnation at 82% health (2026-03-10)
- **Fix**: Always check resilience.ps1 for hardcoded overrides after installing patches
- **Prevention**: Patches should READ from agent-map.json, not hardcode values

### 2. Gemini Plan Mode in Council (FIXED)
- **Pattern**: All council agent definitions passed `--approval-mode plan` to Gemini → "plan mode blocked a write operation"
- **Fix**: Removed plan mode from all 6 council type definitions
- **Prevention**: Council reviewers should NEVER use plan mode

### 3. Watchdog Restart Loops (FIXED)
- **Pattern**: Watchdog kills bridge before it has time to connect, because health file is stale from previous PID
- **Fix**: Added 3-min grace period after restart before checking staleness
- **Prevention**: Any health-based watchdog needs a startup grace period

### 4. Quota Exhaustion → Stagnation
- **Pattern**: When 2 CLI agents exhaust quota and REST agents are excluded from execute pool, pipeline stalls completely
- **Symptom**: Health stuck at same % for hours, errors.jsonl shows `quota_exhausted` + `agent_rotate` cycling
- **Fix**: Always include all 7 agents in execute pool; clear cooldowns when stagnant
- **Prevention**: Monitor agent-cooldowns.json; if >3 agents cooled down simultaneously, clear all cooldowns

### 5. Hardcoded "claude" Agent References (SYSTEMIC)
- **Pattern**: Multiple places in convergence-loop.ps1 and resilience.ps1 hardcode `claude` as the agent for plan, code-review, spec-quality, decompose
- **Impact**: Claude burns through quota while cheaper agents sit idle; single-agent failure = phase failure
- **Fixes applied (2026-03-10)**:
  - Plan: rotates codex → gemini → claude (cheapest first)
  - Decompose: parallel across 3 CLI agents (claude/codex/gemini round-robin)
  - Spec quality gate: codex → gemini → claude preference order
  - Code review label: changed from "CLAUDE" to "review-rotate"
- **Prevention**: NEVER hardcode a single agent. Always use rotation or parallel dispatch.

### 6. REST Agents Can't Write Files (FIXED 2026-03-10)
- **Pattern**: REST agents (deepseek/kimi/minimax/glm5) return text via HTTP API but cannot write files to disk like CLI agents can
- **Impact**: Research phase completed with 0 output files — plan phase had no research findings
- **Fix**: Start-Job scriptblock now captures `$subResult.Output` and writes to `req-{ID}.md` via `Set-Content`
- **Prevention**: ANY phase using REST agents must explicitly save their output to disk from the calling script

### 8. $script: Scope Isolation in v2 Pipeline (FIXED 2026-03-10)
- **Pattern**: v2 agent-router.ps1 uses `$script:` for state vars. Step scripts invoked via `&` run in child scope where `$script:` is invisible → `Cannot index into a null array`
- **Impact**: Pipeline crashed at every Step 1 entry, supervisor burned all 5 attempts
- **Fix**: Changed all `$script:` to `$global:` in agent-router.ps1
- **Prevention**: In v2, always use `$global:` for module state that step scripts need to access

### 7. Council Token Overhead
- **Pattern**: Council phases (post-research, pre-execute, convergence) consume 60-70% of token budget before execute starts
- **Impact**: Less budget for actual code generation
- **Mitigation**: Use `-SkipResearch`, consider disabling post-research council for iterations >1
- **Future**: Track council cost vs execute cost per iteration

### 9. Verify/Review JSON Truncation (FIXED 2026-03-11)
- **Pattern**: When active requirements exceed ~100, verify and review phases generate JSON responses that exceed max_tokens, causing truncated/unparseable JSON
- **Symptom**: Health score stuck (66.9%) across multiple iterations. Verify returns empty/truncated results, review returns partial data. `validate 10/10 fail` in logs
- **Root cause**: 553 active reqs × tokens per req overwhelmed the fixed max_tokens budget
- **Fix**: (1) Verify capped to 100 active reqs per batch call (2) Both phases scale MaxTokens dynamically: verify 80 tokens/req (min 4K, max 12K), review 800 tokens/item (min 4K, max 12K)
- **Impact**: 3 iterations wasted (~2 hours) before diagnosis
- **Prevention**: Any LLM phase that generates structured output proportional to input size MUST scale max_tokens dynamically. Never use fixed max_tokens with variable-length inputs.
- **Key learning**: Pipeline restart required to load fixes (modules are dot-sourced at startup)

### 10. Codex Mini Timeout on Large Files (OBSERVED 2026-03-11)
- **Pattern**: Codex Mini times out at 180s on large fill operations (complex multi-file changes)
- **Symptom**: `HttpClient.Timeout of 180 seconds elapsing` for specific CL items
- **Impact**: Low — fallback chain catches it (DeepSeek succeeded with 4439 tokens)
- **Note**: This is expected behavior, not a bug. The fallback chain works as designed.

### 11. Path/Namespace Mismatch Disease (FIXED 2026-03-11)
- **Pattern**: Pipeline generates backend code to `backend/` path with `namespace backend.X`, but real project lives at `src/Server/Technijian.Api/` with `namespace Technijian.Api.X`
- **Symptom**: All local validation fails (0/10 pass) because generated files land in wrong directory. If manually copied, wrong namespaces cause compilation errors (CS0246, CS0101, CS0104).
- **Root cause**: `global-config.json` has `"output_dir": "backend/"` for backend interface. Codex generates code targeting that path.
- **Fix**: (1) Path remapping in Write-GeneratedFiles: `backend/` → `src/Server/Technijian.Api/` (2) Namespace remapping: `namespace backend.` → `namespace Technijian.Api.` and `using backend.` → `using Technijian.Api.`
- **Impact**: 5 iterations of 0% validation pass rate
- **Prevention**: For any project, verify `output_dir` in config matches actual project structure. Add path/namespace remapping for any mismatch.

### 12. Verify Phase Not Writing Back (ROOT CAUSE - FIXED 2026-03-11)
- **Pattern**: Verify phase evaluates requirement statuses via LLM but never writes updated statuses back to requirements-matrix.json
- **Symptom**: Health score stuck at exact same value across multiple iterations despite code being generated and reviewed
- **Root cause**: Phase-orchestrator.ps1 parsed verify output but only used it for logging, never updated the matrix file
- **Fix**: Added writeback code in phase-orchestrator.ps1 that updates requirement statuses from `result.Parsed.requirements_status` back to the matrix JSON
- **Impact**: Health stuck at 66.9% for 5 iterations (~$5 wasted)
- **Prevention**: Any phase that evaluates/updates requirement status MUST write back to the source of truth

## Health Velocity Benchmarks
| Date | Project | Start % | End % | Hours | Velocity | Notes |
|------|---------|---------|-------|-------|----------|-------|
| 2026-03-09 | chatai v8 | 79% | 82% | 12 | +0.25%/hr | Stalled: CLI-only execute, quota issues |
| 2026-03-10 | chatai v8 | 82% | 82% | 8 | 0%/hr | V2 pipeline, 7-model, stalled on council overhead |
| 2026-03-10→11 | chatai v8 (V3) | 52% | 66.9% | 2 | +7.5%/hr | V3 iter 1: 52→66.9%, iters 2-3 wasted (truncation bug) |
| 2026-03-11 | chatai v8 (V3) | 66.9% | TBD | TBD | TBD | V3 iter 4+, truncation fixes loaded |

## Cost Efficiency Patterns
- Direct Claude Code fixes for small reqs: ~$0.01-0.05 per req (vs $0.50-2.00 via pipeline)
- Good candidates for direct fix: UI additions (banners, flags), static class additions, seed data, simple component wiring
- Bad candidates: Complex multi-file refactors, database schema changes, security implementations

### 13. WhatsApp Bridge EPIPE Crash (OBSERVED 2026-03-11)
- **Pattern**: bridge.mjs crashes with `EPIPE: broken pipe, write` in an infinite loop when the parent PowerShell window is closed/killed (e.g., VS Code terminal restart)
- **Symptom**: bridge-health.json shows stale PID (doesn't match any running node process), bridge.log filled with EPIPE stack traces, no WhatsApp notifications delivered
- **Root cause**: bridge.mjs writes to both console and a log file stream. When the parent terminal dies, stdout becomes a broken pipe. The `uncaughtException` handler tries to `console.error()` the EPIPE → which itself throws EPIPE → infinite loop
- **Fix**: Kill stale process, restart bridge in new visible PowerShell window (`-NoExit`). Auth state persists in `auth_state/` dir so no re-pairing needed
- **Prevention**: (1) Always use watchdog.ps1 or cron monitor to detect stale health file (2) Bridge code should check if stdout is writable before logging (3) Consider a fix to bridge.mjs: catch EPIPE in the uncaughtException handler itself to break the loop
- **Detection**: Compare bridge-health.json PID against running `node.exe` processes. If PID not found → bridge is dead

### 14. Pipeline Overwrites Implemented Files with FILL Stubs (RECURRING 2026-03-11)
- **Pattern**: Every pipeline iteration regenerates the same files (Auth, Security, GDPR, Monitoring, Health, etc.) and overwrites manually-implemented code with new FILL stubs. Also destroys Program.cs (756→24 lines) and AuthController.cs (654→50 lines) by remapping `backend/Program.cs` onto the production file.
- **Symptom**: After each iteration, 20+ backend files revert to `// FILL` + `throw new NotImplementedException()`. Critical production files shrink to stub size.
- **Root cause**: Pipeline's Execute:Fill phase generates new code for same requirements each iteration. Write-GeneratedFiles overwrites without checking if file already has real implementation. Each iteration may also change the interface shape (different method signatures, different dependencies).
- **Files always affected**: JwtTokenService.cs, TokenBlacklistService.cs, JwtBlacklistValidationHandler.cs, SecurityMonitoringService.cs, SecurityMonitoringMiddleware.cs, GdprService.cs, GdprController.cs, BackupHealthCheck.cs, BlobBackupHealthCheck.cs, DataClassificationMiddleware.cs, DataClassificationPolicy.cs, KeyVaultService.cs, CouncilMetricsService.cs, CouncilMetricsMiddleware.cs, RateLimitExceededMiddleware.cs, TcaiRateLimitingExtensions.cs, Program.cs, AuthController.cs
- **Additional disease**: Pipeline writes bare namespaces (`namespace Security`, `namespace Middleware`) instead of `Technijian.Api.*`
- **Fix**: Monitoring cron every 1 min: (1) restore Program.cs/AuthController.cs via `git checkout HEAD --` (2) re-implement all FILL stubs (3) fix bare namespaces
- **Prevention needed**: Pipeline should skip writing files that already have real implementations (no FILL stubs). Or use a file lock/skip list.

## Agent Reliability (observed)
| Agent | Reliability | Notes |
|-------|------------|-------|
| claude | High (quota limited) | Best for judgment phases, quota caps at ~8 RPM |
| codex | High (quota limited) | Best for bulk code gen, quota caps at ~8 RPM |
| gemini | Medium | Plan mode causes errors in council; good for research |
| deepseek | High | Cheapest, $0.28/$0.42/M, good for execute |
| kimi | Medium | International endpoint (Cloudflare CDN), sometimes exit code 1 |
| minimax | Medium | $0.29/$1.20/M, decent for execute |
| glm5 | Low-Medium | China-only endpoint (open.bigmodel.cn), connectivity issues |
