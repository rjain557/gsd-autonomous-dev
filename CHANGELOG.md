# Changelog

All notable changes to GSD (Goal Spec Done) are documented here.

Format roughly follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [SemVer](https://semver.org/).

## [6.1.0] — 2026-04-19

### Added
- **Per-project backend framework override** via `docs/gsd/stack-overrides.md` on the target project. Projects can declare `backendFramework` (`net8.0` / `net9.0` / `net10.0`), `backendSdk`, `solutionFileFormat` (`sln` / `slnx`), `dataAccessPattern`, `database`, `frontendFramework`, `frontendUiLibrary`, `frontendBuildTool`, `mobileFramework`, `mobileToolchain`, `agentLanguage`, and `complianceFrameworks`.
- [`src/harness/project-stack-context.ts`](src/harness/project-stack-context.ts) — `ProjectStackContext` typed interface + `getProjectStackContext()` reader + `parseStackOverrides()` parser + `normalizeFramework()` helper + `renderStackContextBlock()` prompt-injection renderer + `DEFAULT_STACK_CONTEXT` constant.
- [`src/harness/v6/stack-leak-validator.ts`](src/harness/v6/stack-leak-validator.ts) — `validateStackLeaks()` scans generated artifacts (`.csproj`, `.json`, `.md`, `.yaml`, `.xml`) for framework values that contradict the resolved stack context. Heuristic false-positive filter skips migration / changelog / archived contexts.
- `PROJECT STACK CONTEXT` prompt block injected by `BaseAgent.buildSystemPrompt()` into every agent's system prompt. Agents honor the declared framework when generating artifacts.
- New `BaseAgent.setProjectStackContext(ctx)` method; wired from `SdlcOrchestrator` and `Orchestrator` during `initialize()`.
- CLI flag `--project-root <path>` on `gsd run`, `gsd pipeline run`, `gsd sdlc run`, `gsd query stack`, and `gsd validate-stack`. Defaults to `process.cwd()` for backward compatibility.
- CLI command `gsd query stack [--project-root <path>]` — returns the resolved stack context as JSON (useful for CI inspection).
- CLI command `gsd validate-stack [--project-root <path>] [--json] [--fail-on-findings]` — standalone leak scanner for CI pipelines.
- Stack-leak validator wired into `MilestoneOrchestrator` post-SDLC: findings are logged to observability (`gate-results` category) and persisted as decisions in `state.db`.
- Test fixtures: `test-fixtures/stack-overrides/net9-full.md`, `net8-minimal.md`, `empty.md`.
- 7 new unit tests in [`src/harness/v6/__tests__/v6-tests.ts`](src/harness/v6/__tests__/v6-tests.ts) covering parser (full/minimal/empty), reader (missing path, real file), normalizer, and prompt-block renderer.
- [`CHANGELOG.md`](CHANGELOG.md) — this file.
- [`docs/stack-overrides-template.md`](docs/stack-overrides-template.md) — copy-and-paste template for target projects.

### Changed
- GSD Developer Guide §1.4 Backend row updated to "configurable, default .NET 8".
- GSD Developer Guide §1.4.1 added — full documentation of override mechanism, supported frameworks, CLI usage, and backward-compatibility guarantees.
- [`CLAUDE.md`](CLAUDE.md) — backend pattern softened to "configurable, default .NET 8".
- [`memory/agents/requirements-agent.md`](memory/agents/requirements-agent.md) — technology stack now fully references the PROJECT STACK CONTEXT block for every layer (backend, data access, database, frontend, mobile, auth, compliance).
- [`memory/agents/architecture-agent.md`](memory/agents/architecture-agent.md) — mandatory-stack section restructured to derive every layer from the context block; explicit prohibition on emitting `net8.0` artifacts when the block declares a newer framework.
- [`memory/knowledge/quality-gates.md`](memory/knowledge/quality-gates.md) — .NET SDK version note added (determined by context, not pinned).
- [`src/agents/requirements-agent.ts`](src/agents/requirements-agent.ts) — `AUTHORITATIVE_STACK` constant replaced with `buildAuthoritativeStack()` factory that derives backend framework, data access, frontend, and compliance from the injected stack context.
- [`docs/workstation.md`](docs/workstation.md) — added stack-overrides bootstrap section.
- [`AGENTS.md`](AGENTS.md) — added v6.1.0 behavior notes.

### Fixed
- Several vault notes (`requirements-agent.md`, `architecture-agent.md`) previously contained hardcoded `.NET 8` references that would leak into generated artifacts even for projects declaring a different framework. Those are now stack-context-aware.

### Unchanged (backward compatibility)
- Projects without `docs/gsd/stack-overrides.md` continue to receive `.NET 8` defaults. `source: 'default'` is reported in the stack context.
- All existing agents, tools, CLI commands, vault notes, and workflows continue to function identically for projects that have not opted into the override.
- Existing 19 V6 unit tests continue to pass unchanged.
- Public CLI surface is purely additive (new commands + new flag). No commands or flags were removed, renamed, or repurposed.
- No MCP server, external tool dependency, or LLM provider was added.

## [6.0.0] — 2026-04-19

Canonical V6 architecture. See [`memory/architecture/v6-design.md`](memory/architecture/v6-design.md) for the full design document.

### Added
- Milestone → Slice → Task hierarchical decomposition
- Hybrid state model: SQLite (`memory/state.db`) + markdown narrative (`memory/milestones/M{id}/`)
- Git worktree isolation per milestone (`.gsd-worktrees/M{id}/`)
- Execution graph scheduler (`src/harness/v6/execution-graph.ts`)
- Timeout hierarchy (soft/idle/hard) in `BaseAgent.execute()`
- Stuck-loop detection via `PatchSet` hash in remediation loop
- Auto-lock + session forensics (`memory/state.db.lock`)
- Turn-level git transactions around destructive agents
- Budget-pressure model router (50/75/90% thresholds)
- Capability-aware router with weighted agent scoring
- Mechanical-fix band (lint/prettier/dotnet format) before Remediation
- Tool-output compaction (raw persisted to disk, summary injected into context)
- Observability logger (JSONL per category)
- `ReviewAuditorAgent` cross-review gate between QualityGate and Deploy
- Scout and Researcher subagents
- Capability-gap escalation handler
- Golden-rules-as-code (5 Semgrep rules under `memory/knowledge/rules/`)
- `AGENTS.md` top-level progressive-disclosure agent map
- `gsd query`, `gsd forensics`, `gsd worktree`, `gsd doc-garden`, `gsd harvest`, `gsd migrate` CLI commands
- Claude memory stack (`claude-memory/`) with retrieval hooks, consolidate, health, preferences, and weekly review workflow
- V5→V6 state migration via `gsd migrate`
- 19 unit tests covering all V6 primitives

### Archived
- All pre-V6 docs moved to `docs/legacy/` (GSD-V4-Implementation-Status, GSD-Pipeline-Guide, GSD-Architecture, GSD-Installation-Guide, GSD-Script-Reference, GSD-Monitoring-Guide)
