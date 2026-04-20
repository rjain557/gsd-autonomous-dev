# GSD Engine — Goal Spec Done

**Version:** 6.1.0 (canonical) | **Architecture:** `memory/architecture/v6-design.md` | **Platform:** Windows + Node.js 18+ | **Agents:** 14 SDLC/Pipeline + 4 V6 (scout, researcher, review-auditor, milestone-orchestrator) | **Cost:** $0 marginal (CLI subscriptions, API key auto-fallback) | **Per-project stack overrides:** `docs/gsd/stack-overrides.md` in target project (default .NET 8; may declare `net9.0` / `net10.0`)

An AI-native autonomous development pipeline covering the complete Technijian SDLC — from requirements gathering through alpha deployment — with a TypeScript agent harness, hierarchical Milestone → Slice → Task decomposition, hybrid SQLite + Obsidian vault memory, git worktree isolation, and a full V6 augmentation stack for code intelligence, MCP automation, security review, and browser validation.

## What It Does

One command. Tell it where you are in the project.

```bash
gsd run requirements      # "I'm starting a new project"
gsd run figma-prompts     # "I need Figma Make prompts"
gsd run figma-uploaded    # "Figma designs are done"
gsd run contracts         # "Ready to freeze contracts"
gsd run blueprint         # "Ready for code pipeline"
gsd run deploy            # "Ready for alpha"
gsd run full              # "Do everything"
gsd status                # "Where am I?"
```

## Quick Start

### 1. Clone + install (~5 min)

```bash
git clone https://github.com/rjain557/gsd-autonomous-dev.git
cd gsd-autonomous-dev/gsd-autonomous-dev
npm install
```

### 2. Verify the repo is healthy (~30 sec)

```bash
npm run typecheck         # should emit no output
npm run test:v6           # should report: 31 passed, 0 failed
```

If both pass, the V6 harness is working. You don't need any AI CLIs or external tools yet — those are needed only when you actually run a milestone.

### 3. Explore the CLI (~30 sec)

```bash
npx ts-node src/index.ts help                        # full command reference
npx ts-node src/index.ts query stack                 # show default stack context (no override)
npx ts-node src/index.ts status                      # "no state.db yet — will be created on first run"
```

### 4. Install the agent stack (required before your first milestone run)

```bash
# Browser + security scanners
npx playwright install chromium
pip install graphifyy semgrep

# Code intelligence + MCP servers (npm-global)
npm install -g gitnexus @modelcontextprotocol/server-github

# AI CLIs (at least `claude` is required; `codex` and `gemini` are fallbacks)
npm install -g @anthropic-ai/claude-code @openai/codex @google/gemini-cli
claude auth
codex auth
gemini auth

# Per-repo wiring
graphify claude install && graphify install
gitnexus analyze && gitnexus setup
claude mcp add context7 -- npx -y @upstash/context7-mcp@latest
```

### 5. Configure environment (one-time)

Copy `.env.example` → `.env` and fill in at minimum `ANTHROPIC_API_KEY` + `GITHUB_PERSONAL_ACCESS_TOKEN`. Set them as persistent Windows user env vars so they survive terminal restarts. See [`.env.example`](.env.example) and [`docs/workstation.md`](docs/workstation.md) for the exact setup.

### 6. Run your first milestone

```bash
# Against a target project (any project that has source code you want to generate/review)
gsd run requirements \
    --project "MyApp" \
    --description "Multi-tenant SaaS" \
    --project-root /path/to/myapp

# Check progress
gsd status

# Inspect the milestone
gsd query milestones
gsd query milestone <id>
```

### 7. If your target project isn't .NET 8

Create `docs/gsd/stack-overrides.md` in the **target project** (not this repo) — copy [`docs/stack-overrides-template.md`](docs/stack-overrides-template.md) and edit the fields you need. GSD will honor the declared framework. Verify with:

```bash
gsd query stack --project-root /path/to/myapp
```

Expected: `"source": "override"` and your declared `backendFramework`.

### Where to go next

- Full workstation guide (for fresh machines): [`docs/GSD-Workstation-Setup.md`](docs/GSD-Workstation-Setup.md)
- Per-workstation memory-stack setup: [`docs/workstation.md`](docs/workstation.md)
- Full developer guide with all chapters: [`docs/GSD-Developer-Guide.md`](docs/GSD-Developer-Guide.md)
- CLI reference: Developer Guide Appendix A, or `gsd help`
- Architecture: [`memory/architecture/v6-design.md`](memory/architecture/v6-design.md)

## SDLC Pipeline (Phases A-G)

```
Phase A: Requirements ──→ Intake Pack (RACI, NFRs, risks, acceptance criteria)
Phase B: Architecture ──→ Architecture Pack (Mermaid diagrams, OpenAPI draft, threat model)
Phase C: Figma ─────────→ Validate 12/12 analysis files + stubs from Figma Make
Phase A/B: Reconcile ───→ Update requirements based on what prototyping revealed
Phase D: Blueprint ─────→ Frozen UI/UX specification (immutable after this point)
Phase E: Contracts ─────→ SCG1 gate (OpenAPI, API↔SP Map, DB Plan, Test Plan)
Phase F: Code Pipeline ─→ Blueprint analysis → code review → remediation → quality gate → E2E
Phase G: Deploy ────────→ Alpha deploy with rollback + post-deploy validation
```

Each phase writes artifacts to `docs/sdlc/` and saves state for resume. Use `--review` flag to pause after each phase for human review.

## Agents (14)

### SDLC Agents (Phases A-E)

| Agent | Phase | Purpose |
|---|---|---|
| RequirementsAgent | A | Draft Intake Pack from project description |
| ArchitectureAgent | B | Generate diagrams, OpenAPI, threat model |
| FigmaIntegrationAgent | C | Validate 12/12 Figma Make deliverables |
| PhaseReconcileAgent | A/B | Gap analysis + update requirements post-Figma |
| BlueprintFreezeAgent | D | Synthesize frozen UI/UX blueprint |
| ContractFreezeAgent | E | Generate SCG1 contracts + validation report |

### Pipeline Agents (Phases F-G)

| Agent | Stage | Purpose |
|---|---|---|
| Orchestrator | All | Route work, decide retry/escalate/halt |
| BlueprintAnalysisAgent | Blueprint | Detect spec drift |
| CodeReviewAgent | Review | Standard + adversarial design review |
| RemediationAgent | Remediate | Fix issues with blast radius awareness |
| QualityGateAgent | Gate | Build, test, coverage, Semgrep SAST |
| E2EValidationAgent | E2E | 8 categories + Playwright browser testing |
| DeployAgent | Deploy | Deploy with mandatory rollback |
| PostDeployValidationAgent | Post-deploy | SPA cache, auth flow, SP/DTO validation |

All agents use CLI-first LLM routing (Claude/Codex/Gemini) with dynamic model selection per stage and automatic API fallback (DeepSeek/MiniMax) if all subscriptions exhausted.

## Integrated Tooling and Model Stack (11)

| Tool | Purpose | Cost |
|---|---|---|
| [Graphify](https://github.com/safishamsi/graphify) | Knowledge graph — community detection, god nodes, 71x token reduction | Free |
| [GitNexus](https://github.com/abhigyanpatwari/GitNexus) | Blast radius, execution flows, impact analysis, safe rename | Free |
| [Context7](https://github.com/upstash/context7) | Live library docs for .NET, React, Dapper (MCP server) | Free |
| [Semgrep](https://semgrep.dev/) | SAST security scanning — 2000+ rules | Free |
| [Playwright](https://playwright.dev/) | Headless Chromium browser E2E testing | Free |
| [OWASP Skill](https://github.com/agamm/claude-code-owasp) | OWASP Top 10:2025, ASVS 5.0, C#/TS security patterns | Free |
| [Shannon Lite](https://github.com/KeygraphHQ/shannon) | White-box pentesting — 96% exploit rate, 50+ vuln types | Free (uses your LLM subscription) |
| [GitHub MCP](https://github.com/modelcontextprotocol/servers) | PR creation, issue tracking, review comments | Free |
| Claude Max | Primary reasoning agent (10 RPM) | $200/mo subscription |
| ChatGPT Max (Codex) | Code generation agent (10 RPM) | $200/mo subscription |
| Gemini Ultra | Research/synthesis agent (15 RPM) | $20/mo subscription |

**Total: ~$420/mo fixed. $0 per-run marginal cost.** API key backup auto-activates when CLI hits limits, auto-returns to CLI after 5-min cooldown.

This 11-item stack is the combination of:

- 8 augmentation tools on the workstation or in Claude Code.
- 3 paid CLI subscriptions that provide the primary reasoning and execution models.

## Repo-Bundled Skills and Wiring

The repository also includes local skill packs and hook wiring beyond the vault itself:

- `.claude/skills/` contains the GitNexus skill pack plus SQL, React UI, composition, and web design skills.
- `.agents/skills/` contains the OWASP Security and Shannon reference skills used by the 4.2 security workflow.
- `.claude/settings.json` wires the Graphify `PreToolUse` reminder and the GitHub MCP server configuration committed with the repo.

## Key Features

- **Unified CLI** — one command (`gsd run <milestone>`), tell it where you are
- **14 typed agents** with vault-based system prompts and structured I/O contracts
- **7-layer quality defense** — spec gate, requirement quality, research quality, plan quality, build validation, adversarial code review, final validation
- **Dynamic agent routing** — distributes work across 3 CLI subscriptions per stage
- **Parallel execution** — E2E validation (8 categories), build checks (dotnet + npm), all concurrent
- **5-strategy JSON recovery** — reduces retry waste from malformed LLM responses
- **Obsidian vault memory** — 14 agent configs, 8 knowledge notes, 3 architecture docs
- **Dual knowledge graphs** — Graphify (community structure) + GitNexus (blast radius)
- **MCP + hook augmentation** — Graphify search guidance, GitHub automation, live docs via Context7
- **State persistence** — resume from any phase/stage with `--from-phase` or `--from-stage`
- **Human review gates** — `--review` flag pauses after each SDLC phase
- **Milestone validation** — prerequisite checks prevent out-of-order execution
- **Artifact persistence** — all SDLC phases write JSON artifacts to `docs/sdlc/`
- **Adversarial code review** — challenges design decisions (simplicity, scalability, coupling)
- **Figma Make integration** — validates 12/12 analysis deliverables + DTO naming
- **Deploy with rollback** — hard gate enforcement, rollback stops on first failure
- **$0 cost model** — all LLM calls via subscription CLIs, no per-token charges

## Documentation

| Document | Description |
|---|---|
| [GSD-Workstation-Setup.md](docs/GSD-Workstation-Setup.md) | Complete setup guide — tools, skills, MCPs, secrets, and verification checklist |
| [GSD-Figma-Make-Integration.md](docs/GSD-Figma-Make-Integration.md) | Figma Make export structure, 12/12 deliverables, version numbering |
| [GSD-V4-Implementation-Status.md](docs/GSD-V4-Implementation-Status.md) | Implementation status — all 52 gaps closed |
| [GSD-Installation-Graphify.md](docs/GSD-Installation-Graphify.md) | Graphify-first augmentation setup: Graphify, GitNexus, Semgrep, Playwright, MCPs, and security skills |
| [GSD-Architecture.md](docs/GSD-Architecture.md) | Engine architecture, data flow, resilience |
| [GSD-Script-Reference.md](docs/GSD-Script-Reference.md) | Legacy PowerShell commands reference |
| [GSD-Configuration.md](docs/GSD-Configuration.md) | JSON schemas, per-project configs |
| [GSD-Troubleshooting.md](docs/GSD-Troubleshooting.md) | Common issues and solutions |

## Tech Stack (Enforced)

All projects built by GSD use:

| Layer | Technology |
|---|---|
| Backend | .NET Web API (configurable, default .NET 8; declare `net9.0`/`net10.0` in `docs/gsd/stack-overrides.md`) + Dapper + SQL Server stored procedures (no EF Core) |
| Frontend | React 18 + TypeScript + Fluent UI React v9 |
| Auth | JWT Bearer, role-based, multi-tenant with TenantId |
| Database | SQL Server, SP-Only pattern (usp_{Entity}_{Action}) |
| Compliance | HIPAA, SOC 2, PCI, GDPR |

## Directory Structure

```
gsd-autonomous-dev/
  src/
    harness/              Orchestrators, types, hooks, vault adapter, rate limiter
    agents/               14 agents (8 pipeline + 6 SDLC)
    evals/                Test framework with 6 golden test cases
  memory/
    agents/               14 agent vault notes with system prompts
    knowledge/            Quality gates, deploy config, tools reference, project paths
    architecture/         Task graph, state schema, hook registry
  .claude/skills/         Project skill pack (gitnexus, SQL, React UI, composition, web design)
  .agents/skills/         Shared/security skills (OWASP, Shannon)
  .claude/settings.json   Graphify hook + GitHub MCP repo config
  graphify-out/           Knowledge graph output (per-machine, gitignored)
  .gitnexus/              GitNexus index (per-machine, gitignored)
  docs/                   All documentation
  test-fixtures/          Eval test data
  v2/, v3/                Legacy PowerShell pipelines
  scripts/                Legacy scripts + Figma generation prompt
```

## Legacy Commands

The PowerShell engine (v1.5/v2/v3) is still available:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/install-gsd-all.ps1
gsd-assess       # Analyze codebase
gsd-converge     # 5-phase convergence loop
gsd-blueprint    # 3-phase spec-to-code pipeline
```
