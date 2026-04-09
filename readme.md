# GSD Engine - Goal-Spec-Done Autonomous Development System

**Version:** 4.1.0 | **Platform:** Windows + PowerShell 5.1+ / Node.js 18+ | **Agents:** 8 typed agents (Claude, Codex, Gemini + DeepSeek, MiniMax fallbacks)

The GSD Engine is a PowerShell-based autonomous development framework that orchestrates seven configured models across CLI and REST providers to drive codebases from specification to 100% implementation through iterative convergence loops. It runs unattended with comprehensive self-healing for network failures, quota limits, agent crashes, and stalls.

## What It Does

1. **Assesses** your codebase against specs (what exists, what is missing, what is broken)
2. **Converges** existing code toward spec compliance (fix issues, apply patterns)
3. **Builds** missing features from blueprint manifests (new screens, SPs, components)

## Quick Start

```powershell
# Install (runs 36 installer steps in dependency order)
powershell -ExecutionPolicy Bypass -File scripts/install-gsd-all.ps1

# Restart terminal, then:
cd C:\path\to\your\repo    # Must be git root with .sln

gsd-assess                  # Analyze codebase
gsd-converge                # Fix existing code toward 100%
gsd-blueprint               # Build from specs (greenfield)
```

## Important: Run From Git Root

Always cd into the directory containing .git, .sln, and source code. If nested project folders exist, run from the inner one.

## Agents (Seven-Model Strategy)

| Agent | Role | Phases |
|-------|------|--------|
| **Claude Code** | Reasoning & analysis | Review, plan, verify, blueprint |
| **Codex CLI** | Code generation | Execute, build |
| **Gemini CLI** | Research & spec-fix (optional) | Research, spec-fix |
| **Kimi / DeepSeek / GLM-5 / MiniMax** | Fallback review and research pool | Council, fallback, burst throughput |

Each provider draws from an independent quota pool, maximizing throughput. Gemini is optional for core routing; the REST agents expand review and fallback capacity.

## Key Features

- **Seven-model orchestration** with independent quota pools and automatic fallback
- **Self-healing supervisor** that root-causes stalls, modifies prompts, and restarts (up to 5 attempts)
- **Final validation gate** at 100% health: builds, tests, SQL, and security audits
- **Developer handoff report** auto-generated at pipeline exit with build commands, DB setup, costs
- **Actual token cost tracking** across all agent calls with estimated vs actual comparison
- **Client quoting** with configurable markup (5-10x) and three-tier pricing
- **Multi-interface detection** (web, MCP, browser, mobile, agent)
- **Figma Make integration** with _analysis/ and _stubs/ auto-discovery
- **Live file map** updated every iteration for agent spatial awareness
- **Adaptive batch sizing**, crash recovery, checkpoint/resume, quota management
- **Spec consistency pre-check** with auto-resolution via Gemini
- **Storyboard-aware verification** tracing data paths end-to-end
- **Git auto-commit** with code review text as commit body and auto-push
- **Push notifications** via ntfy.sh with mobile monitoring and progress commands
- **Remote monitoring** via QR code (gsd-remote)
- **Dynamic pricing** from LiteLLM with pipeline comparison and subscription analysis
- **Idempotent installer** (install or update with same command)

## Commands

| Command | Description |
|---------|-------------|
| `gsd-assess` | Scan codebase, detect interfaces, generate file map |
| `gsd-converge` | 5-phase convergence loop (review, research, plan, execute, verify) |
| `gsd-blueprint` | 3-phase spec-to-code pipeline (blueprint, build, verify) |
| `gsd-status` | Health dashboard for current project |
| `gsd-init` | Initialize .gsd/ folder without running iterations |
| `gsd-remote` | Launch remote monitoring with QR code |
| `gsd-costs` | Estimate API costs, compare pipelines, generate client quotes |

## Documentation

| Document | Description |
|----------|-------------|
| [GSD-Architecture.md](docs/GSD-Architecture.md) | Engine overview, data flow, agents, resilience, notifications, specs |
| [GSD-Script-Reference.md](docs/GSD-Script-Reference.md) | All commands, parameters, functions, VS Code integration |
| [GSD-Installation-Guide.md](docs/GSD-Installation-Guide.md) | Prerequisites, quick start, first project setup, mobile monitoring |
| [GSD-Configuration.md](docs/GSD-Configuration.md) | JSON schemas, pricing cache, per-project configs, environment variables |
| [GSD-Troubleshooting.md](docs/GSD-Troubleshooting.md) | Installation, runtime, supervisor, cost tracking, common workflows |
| [GSD-V4-Implementation-Status.md](docs/GSD-V4-Implementation-Status.md) | V4.1 TypeScript harness — all 47 gaps closed |
| [GSD-Installation-Graphify.md](docs/GSD-Installation-Graphify.md) | Graphify knowledge graph setup, querying, MCP server |
| [GSD-Workstation-Setup.md](docs/GSD-Workstation-Setup.md) | Full new workstation setup (15 min, all tools) |

## V4.1 TypeScript Agent Harness

The TypeScript harness (`src/`) provides 8 typed agents with vault-integrated memory, rate-limited CLI-first LLM routing, and orchestrated deployment with rollback. **100% complete** as of v4.1.0.

```bash
npm install
npx ts-node src/index.ts pipeline run --trigger manual --dry-run
```

| Component | Status | Notes |
|-----------|--------|-------|
| Type system | Complete | All agent I/O contracts typed, ProjectPaths interface |
| Vault adapter | Complete | OS-level file locking via proper-lockfile |
| Hook system | Complete | 8 events, 7 default handlers, all 7 stages validated |
| Orchestrator | Complete | Stage routing, decision logging, configurable project paths, resilient task graph parsing |
| Deploy + rollback | Complete | Cross-platform (Node fs.cp, http); rollback stops on first failure |
| State restoration | Complete | Saves after each stage, restores on `--from-stage` |
| LLM integration | Complete | CLI-first ($0 marginal) + Anthropic SDK fallback; model-aware cost tracking |
| Security scanning | Complete | 11 regex patterns + Semgrep SAST (preflight warns if missing) |
| E2E validation | Complete | 6 categories + Playwright browser testing (headless Chromium) |
| PostDeploy validation | Complete | Real SP existence + DTO mismatch detection |
| Eval framework | Complete | 6/6 test cases; vault markdown parser for dynamic loading |
| Preflight checks | Complete | CLI availability, vault path, env var, Semgrep detection |
| GitHub MCP | Configured | PR creation, issue tracking, review comments via MCP server |

Full status: [GSD-V4-Implementation-Status.md](docs/GSD-V4-Implementation-Status.md)

## Graphify Knowledge Graph Integration

The pipeline integrates with [Graphify](https://github.com/safishamsi/graphify), an open-source knowledge graph that converts the codebase into a queryable graph for structural navigation instead of flat file scanning (up to 71x token reduction).

```bash
pip install graphifyy
graphify claude install     # Hook into Claude Code
/graphify .                 # Build knowledge graph (from Claude Code)
```

Agents consult `graphify-out/GRAPH_REPORT.md` for god nodes and community structure before searching raw files. See [GSD-Installation-Graphify.md](docs/GSD-Installation-Graphify.md) for full setup instructions.

## Quality & Automation Tools

| Tool | Purpose | Install |
|---|---|---|
| [Semgrep](https://semgrep.dev/) | SAST security scanning (2000+ rules) | `pip install semgrep` |
| [Playwright](https://playwright.dev/) | Headless browser E2E testing | `npm install playwright && npx playwright install chromium` |
| [GitHub MCP](https://github.com/modelcontextprotocol/servers) | Autonomous PR/issue management | Configured in `.claude/settings.json` |

Semgrep and Playwright are checked at pipeline startup (preflight). If Semgrep is missing, security scanning falls back to regex patterns. If Playwright is missing, E2E tests fall back to HTTP status checks.

## Scripts

The repository currently contains 54 PowerShell scripts in total, with `scripts/install-gsd-all.ps1` executing 36 installer steps in dependency order. Run `install-gsd-all.ps1` to install everything.
