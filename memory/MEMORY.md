# GSD Autonomous Dev - Project Memory

## Project Overview
- **V4.2 (current)**: Full Technijian SDLC v6.0 lifecycle in TypeScript with 14 typed agents, Obsidian vault memory, unified `gsd run <milestone>` CLI, and CLI-first LLM routing ($0 marginal).
- **V4.2 augmentation stack**: Graphify, GitNexus, Context7, Semgrep, Playwright, GitHub MCP, OWASP Security, Shannon Lite, Claude Max, ChatGPT Max/Codex, Gemini Ultra.
- **V4.1**: Pipeline-only TypeScript harness with 8 typed agents, Obsidian vault memory, CLI-first LLM routing ($0 marginal). 100% complete.
- **V3 (legacy)**: 2-model API-only pipeline (Sonnet + Codex Mini). Still in `v3/` directory
- **V2 (legacy)**: 7-agent CLI+REST system (44 install scripts). Still in `v2/` + `scripts/`
- **Graphify**: Knowledge graph integration — `graphify-out/` has GRAPH_REPORT.md, graph.json, graph.html
- **Repo wiring**: `.claude/settings.json` commits the Graphify `PreToolUse` reminder and GitHub MCP config; `.claude/skills/` holds project skills; `.agents/skills/` holds OWASP + Shannon reference skills.
- Backend: .NET 8 + Dapper + SQL Server stored procs | Frontend: React 18 | Compliance: HIPAA, SOC 2, PCI, GDPR

## Key Directories
- Engine install: `%USERPROFILE%\.gsd-global\`
- Per-project state: `.gsd\` in each repo
- Scripts: `scripts/` (46 scripts: 1 master installer + 1 pre-flight + 36 in install chain + standalone)
- Supervisor state: `.gsd\supervisor\` per-project, `%USERPROFILE%\.gsd-global\supervisor\` cross-project
- Docs: `docs/` (developer guide, workstation/setup docs, implementation status, skills reference, architecture/troubleshooting, Word export tooling)
- Pricing cache: `%USERPROFILE%\.gsd-global\pricing-cache.json`
- Intelligence: `%USERPROFILE%\.gsd-global\intelligence\` (agent scores, pattern cache)

## Documentation Structure (current canon)
1. **GSD-Developer-Guide.md** - Full v4.2 SDLC + pipeline guide; canonical source for Word export
2. **GSD-Workstation-Setup.md** - Fresh-machine setup for tools, skills, MCPs, secrets, verification
3. **GSD-Installation-Graphify.md** - Graphify-first augmentation stack setup: Graphify, GitNexus, Context7, Semgrep, Playwright, GitHub MCP, OWASP, Shannon
4. **GSD-Claude-Code-Skills.md** - SQL/UI/design skill reference for `.claude/skills/`
5. **GSD-V4-Implementation-Status.md** - Current 4.2 implementation and maturity snapshot
6. **GSD-Architecture.md** - Engine overview, data flow, agents, resilience, notifications
7. **GSD-Troubleshooting.md** - Installation, runtime, health, JSON, and boundary issues

## Iteration Flow (2026-03-10)
```
req-assess -> focused code-review -> decompose -> wave-research -> plan -> execute -> loop
```
At 100% convergence: Full code review + spec/Figma verification + quality gate -> developer-handoff.md

## Commit Style
- Descriptive first line, bullet-point details below
- Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>

## User Preferences
- User creates Word developer guides from the markdown docs
- Docs should be comprehensive enough for standalone Word doc export
- Developer guide v4.2 source of truth: `docs/GSD-Developer-Guide.md`; Word export via `docs/generate-docx.py`
- 2026-04-10 docs alignment: `readme.md`, `docs/GSD-Workstation-Setup.md`, `docs/GSD-Installation-Graphify.md`, and `docs/GSD-Developer-Guide.md` are aligned to the full 4.2 augmentation stack and current skill layout
- User charges clients 5-10x markup on calculated token costs (7x default)
- **Window management**: ALWAYS kill the old process BEFORE starting a new one. Never leave orphaned PowerShell windows
- **Visible PowerShell**: ALWAYS start pipeline in a visible PowerShell window (WindowStyle Normal, -NoExit) so user can see output. NEVER use -WindowStyle Hidden or redirect stdout/stderr to files.
- **PROACTIVE NOT REACTIVE**: Always anticipate problems and fix them BEFORE they cause failures. Don't wait for user to report issues. Detect diseases, fix code, restart processes, and report what was done. This is a CORE requirement — user has repeated this multiple times.
- **Proactive monitoring**: 2-min health checks, immediate disease diagnosis, pattern recognition
- **Never close session**: Do NOT end/close the session unless explicitly asked. Crons die when session ends.
- **All 7 models for execute**: deepseek, codex, kimi, minimax, glm5, claude, gemini -- ALWAYS
- **Code review**: Only claude, codex, gemini (quality assurance)
- **Memory updates**: Maintain short-term (active-tasks.md) and long-term (MEMORY.md, patterns.md) memory every session
- **Direct fixes**: Fix easy/small requirements directly via Claude Code when cheaper than pipeline

## Active Project: ChatAI (tech-web-chatai.v8)
- Repo: `D:\vscode\tech-web-chatai.v8\tech-web-chatai.v8`
- V3 running in feature_update mode (2026-03-10)
- 1160 requirements: 607 satisfied, 337 partial, 216 not_started (52% health)

## Session Recovery Note
- VS Code updates will kill Claude Code terminal sessions
- Always read MEMORY.md + active-tasks.md + session-state.md on restart

## Topic Files (detailed reference)
- [v3-pipeline.md](v3-pipeline.md) - V3 architecture, model IDs, phases, bugs fixed
- [v2-systems.md](v2-systems.md) - Supervisor, council, parallel execute, resilience, quality gates, multi-model, rate limiter, maintenance mode
- [install-chain.md](install-chain.md) - All 44 install chain scripts in order
- [bug-fixes.md](bug-fixes.md) - Bug fix history (v2.0, v2.3.x, convergence-loop, rate limiter, execute, wave research)
- [patterns.md](patterns.md) - Cross-session pattern analysis, recurring diseases, agent reliability
- [active-tasks.md](active-tasks.md) - Current running tasks and monitoring checklist
- [session-state.md](session-state.md) - Crash recovery state, active PIDs, cron IDs
- [model-api-reference.md](model-api-reference.md) - ALL model endpoints, formats, auth, pitfalls (ALWAYS READ before API calls)
- [cross-session.md](cross-session.md) - Shared message board for coordinating between multiple Claude sessions
- [feedback_proactive_monitoring.md](feedback_proactive_monitoring.md) - CRITICAL: Stop passive monitoring, actively fix root causes every tick
- [feedback_autonomous_behavior.md](feedback_autonomous_behavior.md) - CRITICAL: Be truly autonomous — detect, diagnose, fix, restart without user telling you
- [feedback_notification_format.md](feedback_notification_format.md) - WhatsApp gets full message first, ntfy gets short summary only
- [feedback_mark_reqs_complete.md](feedback_mark_reqs_complete.md) - ALWAYS mark fixed reqs as satisfied + update health score immediately
- [feedback_close_windows.md](feedback_close_windows.md) - When killing a pipeline, ALSO close its PowerShell window
- [feedback_partial_promotion.md](feedback_partial_promotion.md) - Every cron tick: promote partial reqs to satisfied when referenced files exist
- [telegram-bridge.md](telegram-bridge.md) - Telegram bridge setup, config, bot token, startup commands, known issues

## V4.1 Architecture (vault-based)
- [agents/](agents/) - 8 agent vault notes with frontmatter (model, tools, timeouts)
- [architecture/agent-system-design.md](architecture/agent-system-design.md) - 7-step task graph, agent roster
- [architecture/state-schema.md](architecture/state-schema.md) - TypeScript type definitions for all agent I/O
- [architecture/hook-registry.md](architecture/hook-registry.md) - Lifecycle events and default hook implementations
- [knowledge/project-paths.md](knowledge/project-paths.md) - Configurable design doc paths for E2E/post-deploy
- [knowledge/quality-gates.md](knowledge/quality-gates.md) - Build, coverage, security thresholds
- [knowledge/deploy-config.md](knowledge/deploy-config.md) - Alpha environment deploy targets
- [knowledge/model-strategy.md](knowledge/model-strategy.md) - 3 CLI subscriptions + 2 API fallbacks
- [evals/test-cases.md](evals/test-cases.md) - 6 golden test cases for agent validation
