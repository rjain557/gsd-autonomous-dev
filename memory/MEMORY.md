# GSD Autonomous Dev - Project Memory

## Project Overview
- **V6 (canonical)**: Full Technijian SDLC lifecycle in TypeScript with 14 typed agents, Milestone → Slice → Task → Stage hierarchy, hybrid SQLite + Obsidian vault memory, git worktree isolation per milestone, execution graph scheduler, unified `gsd run <milestone>` CLI, and dual-auth LLM routing ($0 marginal).
- **V6 augmentation stack**: Graphify, GitNexus, Context7, Semgrep, Playwright, GitHub MCP, OWASP Security, Shannon Lite, Claude Max, ChatGPT Max/Codex, Gemini Ultra.
- **Claude Memory Stack**: `claude-memory/` vault (Obsidian, OneDrive-synced) with retrieval/consolidate/health hooks and `/vault-status`, `/review`, `/consolidate`, `/contradictions`, `/volatility`, `/graduate` commands.
- **Graphify**: Knowledge graph integration — `graphify-out/` has GRAPH_REPORT.md, graph.json, graph.html
- **Repo wiring**: `.claude/settings.json` registers all V6 hooks (retrieve, impact-check, reindex, consolidate, health-check, preference-extract) + GitHub MCP; `.claude/skills/` holds project skills; `.agents/skills/` holds OWASP + Shannon reference skills.
- Backend: .NET 8 + Dapper + SQL Server stored procs | Frontend: React 18 + Fluent UI v9 | Compliance: HIPAA, SOC 2, PCI, GDPR
- **Pre-V6 artifacts:** Legacy docs archived in `docs/legacy/`. Do not use for current development.

## Key Directories
- Engine install: `%USERPROFILE%\.gsd-global\`
- Per-project state: `.gsd\` in each repo
- Scripts: `scripts/` (46 scripts: 1 master installer + 1 pre-flight + 36 in install chain + standalone)
- Supervisor state: `.gsd\supervisor\` per-project, `%USERPROFILE%\.gsd-global\supervisor\` cross-project
- Docs: `docs/` (developer guide, workstation/setup docs, implementation status, skills reference, architecture/troubleshooting, Word export tooling)
- Pricing cache: `%USERPROFILE%\.gsd-global\pricing-cache.json`
- Intelligence: `%USERPROFILE%\.gsd-global\intelligence\` (agent scores, pattern cache)

## Documentation Structure (V6 canon)
1. **GSD-Developer-Guide.md** - Full V6 SDLC + pipeline guide; canonical source for Word export
2. **GSD-Workstation-Setup.md** - Fresh-machine base toolchain setup
3. **workstation.md** - Per-workstation Claude memory stack + hooks config
4. **GSD-Installation-Graphify.md** - Graphify-first augmentation stack setup: Graphify, GitNexus, Context7, Semgrep, Playwright, GitHub MCP, OWASP, Shannon
5. **GSD-Claude-Code-Skills.md** - SQL/UI/design skill reference for `.claude/skills/`
6. **GSD-Configuration.md** - Runtime configuration reference
7. **GSD-Troubleshooting.md** - Installation, runtime, health, JSON, and boundary issues
8. **memory/architecture/v6-design.md** - Canonical V6 architecture design
9. **docs/legacy/** - Pre-V6 archived docs (do not use)
10. **docs/GSD-v7.0-Feature-Benefits.md** - Plain-English V7 feature list and pipeline benefits
11. **docs/GSD-v7.0-Managed-Agents-Addendum.md** + **memory/managed-agents/** - V7 external-link review, managed source-agent catalog, and per-source watch contracts

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
- Developer guide V6 source of truth: `docs/GSD-Developer-Guide.md`; Word export via `docs/generate-docx.py`
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

## V6 Architecture (vault-based)
- [agents/](agents/) - 8 agent vault notes with frontmatter (model, tools, timeouts)
- [architecture/agent-system-design.md](architecture/agent-system-design.md) - 7-step task graph, agent roster
- [architecture/state-schema.md](architecture/state-schema.md) - TypeScript type definitions for all agent I/O
- [architecture/hook-registry.md](architecture/hook-registry.md) - Lifecycle events and default hook implementations
- [knowledge/project-paths.md](knowledge/project-paths.md) - Configurable design doc paths for E2E/post-deploy
- [knowledge/quality-gates.md](knowledge/quality-gates.md) - Build, coverage, security thresholds
- [knowledge/deploy-config.md](knowledge/deploy-config.md) - Alpha environment deploy targets
- [knowledge/model-strategy.md](knowledge/model-strategy.md) - 3 CLI subscriptions + 2 API fallbacks
- [evals/test-cases.md](evals/test-cases.md) - 6 golden test cases for agent validation
- [managed-agents/](managed-agents/) - V7 managed external source agents for watched links, model probes, SkillForge inputs, routing research, and production-runtime references
