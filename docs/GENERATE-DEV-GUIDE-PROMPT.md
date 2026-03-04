# Prompt: Generate GSD Developer Guide (Word Document)

Use this prompt with Claude Code, ChatGPT, or any LLM capable of generating .docx files via python-docx.

---

## Prompt

You are a technical writer producing a professional developer guide as a Microsoft Word document (.docx). Read every file listed below, then generate a polished, comprehensive document titled **"GSD Autonomous Development Engine - Developer Guide"**.

### Source Files to Read (ALL required)

**Documentation (read every file):**
- `docs/GSD-Architecture.md` - System architecture, data flow, agent assignment
- `docs/GSD-Script-Reference.md` - All commands, functions, parameters
- `docs/GSD-Configuration.md` - Config files, JSON schemas, environment variables
- `docs/GSD-Installation-Guide.md` - Prerequisites, install steps, first project setup
- `docs/GSD-Troubleshooting.md` - Common errors and fixes
- `readme.md` - Project overview

**Scripts (read the header comments and key logic of each):**
- `scripts/install-gsd-all.ps1` - Master installer (execution order)
- `scripts/install-gsd-prerequisites.ps1` - Prerequisite checker/installer
- `scripts/install-gsd-global.ps1` - Core engine installer (prompts, config, profile)
- `scripts/install-gsd-blueprint.ps1` - Blueprint pipeline installer
- `scripts/setup-gsd-convergence.ps1` - Per-project convergence setup
- `scripts/patch-gsd-resilience.ps1` - Resilience module (retry, checkpoint, lock)
- `scripts/patch-gsd-hardening.ps1` - Hardening (quota, network, boundary)
- `scripts/patch-gsd-figma-make.ps1` - Multi-interface detection
- `scripts/patch-gsd-supervisor.ps1` - Self-healing supervisor
- `scripts/patch-gsd-final-validation.ps1` - Final validation gate
- `scripts/token-cost-calculator.ps1` - Cost estimation and tracking
- `scripts/final-patch-1-spec-check.ps1` through `final-patch-7-spec-resolve.ps1` - Integration patches
- `scripts/patch-false-converge-fix.ps1` - False convergence fix
- `scripts/patch-gsd-council.ps1` - LLM Council multi-agent review
- `scripts/patch-gsd-parallel-execute.ps1` - Parallel sub-task execution
- `scripts/patch-gsd-resilience-hardening.ps1` - Token tracking, quota cap, agent rotation
- `scripts/patch-gsd-quality-gates.ps1` - DB completeness, security standards, spec validation
- `scripts/patch-gsd-multi-model.ps1` - Multi-model LLM integration (4 REST agents)
- `scripts/install-gsd-keybindings.ps1` - VS Code shortcuts
- `scripts/setup-gsd-api-keys.ps1` - API key management

### Document Structure

Generate the Word document with the following structure. Use professional formatting: title page, table of contents, numbered headings, tables, code blocks with monospace font, page numbers, and consistent styling throughout.

---

#### FRONT MATTER
- **Title Page**: "GSD Autonomous Development Engine - Developer Guide", Version 1.6.0, Date, "Confidential - Internal Use Only"
- **Table of Contents**: Auto-generated from headings
- **Document History**: Version 1.0.0 (Initial Release), Version 1.1.0 (Codex CLI update, multi-agent support, supervisor, cost tracking), Version 1.2.0 (LLM Council, parallel execution, resilience hardening), Version 1.5.0 (Quality gates, chunked council reviews), Version 1.6.0 (Multi-model LLM integration with 4 REST agents, API/Database interface auto-detection, REST agent error handling)

---

#### CHAPTER 1: INTRODUCTION

**1.1 Why We Built This**
Write a compelling 2-3 paragraph narrative explaining the problem:
- Traditional software development with AI assistants is manual, fragile, and expensive. A developer has to copy-paste prompts, manually review output, fix issues, and repeat. There is no memory between sessions, no automatic recovery from failures, no way to verify completeness against specifications.
- The GSD Engine automates the entire develop-review-fix loop. It orchestrates 7 AI agents -- 3 CLI (Claude, Codex, Gemini) and 4 REST API (Kimi K2.5, DeepSeek V3, GLM-5, MiniMax M2.5) -- assigns each to the tasks they do best, and runs autonomously until the codebase matches the specification. It handles crashes, quota limits, network failures, JSON corruption, agent boundary violations, stalls, and even specification contradictions without human intervention. When the engine reaches 100% health, it runs a full validation gate (compilation, tests, security audit, database completeness) before declaring success.
- The result: a developer writes specifications, runs one command, and gets a fully built, verified, compliant codebase. What used to take weeks of manual AI-assisted development happens overnight. The engine tracks actual API costs in real time, generates developer handoff documentation, auto-commits to git with code review text, and sends push notifications to your phone so you can monitor progress from anywhere.

**1.2 Design Philosophy**
- Token-optimized agent assignment (Claude for judgment, Codex/Gemini for generation)
- Specification-driven (code matches specs, not the other way around)
- Self-healing (retry, checkpoint, rollback, supervisor recovery)
- Idempotent (safe to re-run, safe to interrupt and resume)
- Observable (health scores, push notifications, cost tracking)
- Quality-gated (DB completeness, security compliance, spec clarity, council review)

**1.3 What Was Built**
High-level summary of the three core capabilities (`gsd-assess`, `gsd-converge`, `gsd-blueprint`) with comparison table showing when to use each. Include supporting utilities table (`gsd-status`, `gsd-init`, `gsd-remote`, `gsd-costs`).

---

#### CHAPTER 2: ARCHITECTURE

**2.1 System Overview**
Describe the overall architecture. Include a text-based diagram showing the flow between the developer, the GSD engine (PowerShell orchestrator), the 7 AI agents (3 CLI: Claude Code, Codex CLI, Gemini CLI + 4 REST: Kimi K2.5, DeepSeek V3, GLM-5, MiniMax M2.5), the resilience layer, and the quality gates layer. Show how all UI interfaces communicate with the database through the API layer.

**2.2 Agent Assignment**
Table showing which agent handles which phase, why, and approximate token usage. Include Claude, Codex, and Gemini primary roles. Note that Gemini is optional (falls back to Codex). Mention the 4 REST agents (Kimi, DeepSeek, GLM-5, MiniMax) as rotation/council review pool. Mention supervisor agent override, parallel execution round-robin, and registry-driven rotation pool from model-registry.json.

**2.3 Convergence Loop (5-Phase)**
Detailed walkthrough of the code-review -> create-phases -> research -> plan -> execute cycle. Include text-based diagram. Explain what each phase does, which agent runs it, what artifacts it produces, and where council gates appear (post-research non-blocking, pre-execute non-blocking, convergence blocking at 100%). Include phase details table with agent, input, output, and token columns.

**2.4 Blueprint Pipeline (3-Phase)**
Detailed walkthrough of blueprint -> build -> verify. Include text-based diagram. Explain how it differs from convergence and when to use it. Include "When to Use Each Pipeline" comparison table with 5 scenarios.

**2.5 Data Flow Diagrams**
Text-based diagrams for:
- gsd-assess flow (interfaces -> file map -> assessment)
- gsd-converge per-iteration flow (code-review -> research -> plan -> execute -> health check -> council/validation)
- gsd-blueprint per-iteration flow (verify -> build -> health check -> validation)

**2.6 Installed Directory Structure**
Full tree of `%USERPROFILE%\.gsd-global\` with descriptions of every directory and key file. Include bin/, config/, lib/modules/, prompts/ (claude, codex, gemini, council, shared), blueprint/, scripts/, supervisor/.

**2.7 Per-Project State (.gsd/ Folder)**
Full tree of the `.gsd/` folder created in each project, with descriptions of every file. Include health/, code-review/, generation-queue/, agent-handoff/, research/, specs/, assessment/, blueprint/, costs/, logs/, supervisor/.

---

#### CHAPTER 3: INSTALLATION

**3.1 Prerequisites**
Tables of required software (PowerShell, Node.js, npm, .NET SDK, Git, Claude Code CLI, Codex CLI) and optional software (Gemini CLI, sqlcmd, ntfy app) with versions, install commands, and purpose.

**3.2 API Key Configuration**
Step-by-step instructions for setting up Anthropic, OpenAI, and Google API keys. Include both interactive login (Method 1) and API key (Method 2) methods. Table of environment variables with CLI mapping and key source URLs. Include REST agent API keys section: KIMI_API_KEY, DEEPSEEK_API_KEY, GLM_API_KEY, MINIMAX_API_KEY (optional, warn-only if missing -- REST agents are disabled individually when key is not set).

**3.3 Running the Master Installer**
Step-by-step walkthrough of `install-gsd-all.ps1`. Table of all 21 scripts in execution order with one-line descriptions. Table of 4 optional standalone scripts.

**3.4 Post-Install Verification**
Commands to verify the installation: reload profile, gsd-status, prerequisites verify, version check.

**3.5 VS Code Integration**
Tasks (GSD: Convergence Loop, GSD: Blueprint Pipeline) and keyboard shortcuts table (Ctrl+Shift+G chords for convergence, blueprint, status).

**3.6 Multi-Workstation Setup**
Two-place state model (global engine vs project state). How to install on second workstation and resume. Lock file handling for concurrent access.

**3.7 Updating and Uninstalling**
Idempotent update (re-run installer). Uninstall steps: remove global dir, clean profile, clear API keys, remove per-project .gsd.

---

#### CHAPTER 4: USAGE GUIDE

**4.1 First Project Setup**
Expected project structure tree (design/, docs/, src/) with all Figma Make deliverables. Step-by-step guide for new project (blueprint) and existing project (convergence).

**4.2 Running gsd-assess**
Full usage with all flags (-MapOnly, -DryRun). What it produces, how to read the output.

**4.3 Running gsd-converge**
Full usage with all flags. Include parameter table with defaults: -DryRun, -SkipInit, -SkipResearch, -SkipSpecCheck, -AutoResolve, -BatchSize (8), -MaxIterations (50), -StallThreshold (3), -ThrottleSeconds (0), -NtfyTopic, -SupervisorAttempts (5), -NoSupervisor.

**4.4 Running gsd-blueprint**
Full usage with all flags. Include parameter table: -DryRun, -BlueprintOnly, -BuildOnly, -VerifyOnly, -BatchSize (15), -MaxIterations (50), -StallThreshold (3), -ThrottleSeconds (0), -SkipSpecCheck, -AutoResolve.

**4.5 Running gsd-status**
How to check project health at any time. Dashboard contents: health score, requirement breakdown, current phase, iteration count, costs.

**4.6 Running gsd-costs**
Full parameter table with all flags. Include usage examples for: quick estimate, manual estimate, pipeline comparison, model override, detailed breakdown, client quote, actual costs, pricing refresh. Include client quote complexity tiers table (Standard/Complex/Enterprise/Enterprise+).

**4.7 Monitoring a Running Pipeline**
- Terminal output interpretation (icons, phases, batch sizes) with example output
- Push notifications via ntfy.sh (setup, subscribing, full event list table with descriptions)
- All notifications include running token cost data
- Remote monitoring via gsd-remote (QR code)
- Reading state files directly (health, engine status, costs, errors) with PowerShell commands

**4.8 Interrupting and Resuming**
How to safely Ctrl+C, what state is preserved (6 items: health, matrix, code, costs, errors, supervisor), how to resume with -SkipInit or -BuildOnly. How to transfer to another workstation via git.

---

#### CHAPTER 5: RESILIENCE AND SELF-HEALING

**5.1 Retry with Batch Reduction**
How Invoke-WithRetry works. Max retries: 3, batch reduction: 50%, minimum batch: 2, retry delay: 10s. Token costs tracked on ALL attempts (success and failure) with estimation when no JSON.

**5.2 Checkpoint and Recovery**
How Save-Checkpoint and Restore-Checkpoint work. Include checkpoint JSON schema. Checkpoint read by background heartbeat job for ntfy notifications.

**5.3 Lock File Management**
How New-Lock and Remove-Lock work. Lock file path (.gsd/.gsd-lock). Contains PID. Stale lock detection (120 min default). Concurrent run prevention.

**5.4 Health Regression Protection**
Automatic revert when health drops >5% after an iteration. Steps: restore checkpoint, log regression, send ntfy, reduce batch.

**5.5 Quota and Rate Limit Handling**
Wait-ForQuotaReset behavior: exponential backoff (5 -> 10 -> 20 -> 40 -> 60 min cap), up to 24 cycles. Cumulative cap: 120 minutes total. Agent rotation after 1 consecutive failure (reduced from 3 by multi-model patch for immediate rotation across 7 agents). Agent cooldowns tracked in JSON. Auth detection hardening (403 = rate limit not auth, Gemini 403 routes to quota backoff). REST agents: HTTP 429 -> rate_limit, 402 -> quota_exhausted, 401 -> unauthorized (mapped to same GSD error taxonomy as CLI agents). Get-FailureDiagnosis handles REST agent errors with fallback to claude for read-only phases.

**5.6 Network Failure Handling**
Test-NetworkAvailability behavior: 30-second polling, multiple endpoints, auto-resume, ntfy notification on drop/recovery.

**5.7 Build Validation and Auto-Fix**
Post-execution: dotnet build, npm run build. On failure: dispatch Codex to fix, retry build.

**5.8 Agent Watchdog**
30-minute watchdog timer per agent call. Process killed on timeout. Retry with reduced batch. Logged to errors.jsonl. ntfy notification sent.

**5.9 The Supervisor**
Self-healing supervisor loop with text-based diagram. Three layers: L1 pattern match (free), L2 AI diagnosis (~1 call), L3 AI fix (~1 call). Max 5 attempts, then escalation-report.md + urgent notification. Pattern memory across projects (~/.gsd-global/supervisor/pattern-memory.jsonl). Won't repeat same fix (strategies_tried). Parameters: -SupervisorAttempts (5), -NoSupervisor.

**5.10 Final Validation Gate**
9 checks at 100% health in table format (check, type hard/warning, failure action). Checks: dotnet build, npm build, dotnet test, npm test, SQL validation, dotnet audit, npm audit, DB completeness, security compliance. Max 3 validation attempts. New-DeveloperHandoff generates 10-section handoff document. Handoff committed and pushed.

---

#### CHAPTER 6: CONFIGURATION REFERENCE

**6.1 Global Configuration (global-config.json)**
Full JSON schema with all fields. Subsections for:
- **notifications**: ntfy_topic ("auto" for per-project), notify_on (full 20-event list)
- **patterns**: backend, database, frontend, api, compliance
- **phase_order**: convergence loop phase sequence
- **council**: enabled, max_attempts, consensus_threshold. Council types table (6 types with pipeline, blocking, reviewers, synthesizer columns). council.chunking: enabled, max_chunk_size (25), min_group_size (5), strategy ("auto"/"field:X"/"id-range"), cooldown_seconds (5), min_requirements_to_chunk (30)
- **quality_gates**: database_completeness (enabled, require_seed_data, min_coverage_pct), security_compliance (enabled, block_on_critical, warn_on_high), spec_quality (enabled, min_clarity_score, check_cross_artifact)

**6.2 Agent Assignment (agent-map.json)**
Full JSON schema with phase-to-agent mapping. execute_parallel config table: enabled, max_concurrent (3), agent_pool, strategy ("round-robin"/"all-same"), fallback_to_sequential, subtask_timeout_minutes (30).

**6.3 Blueprint Configuration (blueprint-config.json)**
Per-project config with manifest path, batch size, stall threshold.

**6.4 Per-Project State Files**
Detailed JSON schemas for:
- health-current.json (health_score, total_requirements, satisfied, partial, not_started, iteration)
- engine-status.json (pid, state, phase, agent, iteration, attempt, batch_size, health_score, heartbeat, sleep_until/reason, errors) with state field values table
- final-validation.json (passed, hard_failures, warnings, checks with per-check detail)
- token-usage.jsonl (append-only: timestamp, pipeline, iteration, phase, agent, batch_size, success, tokens, cost_usd, duration)
- cost-summary.json (project_start, total_calls, total_cost_usd, total_tokens, by_agent, by_phase, runs)
- supervisor-state.json (pipeline, attempt, max_attempts, strategies_tried, diagnoses)

**6.5 Model Registry (model-registry.json)**
Central agent configuration created by `patch-gsd-multi-model.ps1`. JSON schema with agent entries (type: cli/openai-compat, endpoint, api_key_env, model_id, enabled, pricing). rotation_pool_default array. Agent types table (7 agents with type, model, provider, pricing).

**6.6 Environment Variables**
API key variables table (variable, CLI, expected prefix, key source) -- include ANTHROPIC_API_KEY, OPENAI_API_KEY, GOOGLE_API_KEY for CLI agents. REST agent API key variables table (KIMI_API_KEY, DEEPSEEK_API_KEY, GLM_API_KEY, MINIMAX_API_KEY -- optional, warn-only). System variables table (USERPROFILE, USERNAME, PATH).

**6.7 Pricing Cache**
Location, auto-generated by gsd-costs. Supported models table (10 models with cache key, model name, default role): Claude Sonnet/Opus/Haiku, GPT 5.3 Codex, GPT-5.1 Codex, Gemini 3.1 Pro, Kimi K2.5, DeepSeek V3, GLM-5, MiniMax M2.5. Cache freshness table (<14d fresh, 14-60d aging, >60d stale, no cache fetches/fallback).

---

#### CHAPTER 7: MULTI-INTERFACE SUPPORT

**7.1 Component Architecture**
A complete project has three foundational layers. All UI interfaces communicate with the database through the API:
```
UI Interfaces (web, mobile, mcp, browser, agent)
        |
    REST API / Backend (.NET Controllers -> Services -> Dapper)
        |
    Database (SQL Server stored procs -> tables -> seed data)
```

**7.2 Interface Types**
Supported types table (7 types): web, api, database, mcp, browser, mobile, agent with descriptions, detection patterns, and color coding. Note that api and database support dual detection (design-dir based AND auto-detected from project structure).

**7.3 Directory Structure**
Expected design/ folder layout with interface type folders and version subfolders. Include design\api\v## and design\database\v## alongside design\web\v##.

**7.4 Figma Make Integration**
The 12 expected deliverable files in `_analysis/` (table with #, file, content). The 3 backend stubs in `_stubs/` (table with file, content).

**7.5 Auto-Discovery**
How Find-ProjectInterfaces recursively scans the repo. 4-step process: check design/ folder, find latest version, detect _analysis/_stubs, return interface objects.

**7.6 Auto-Detection from Project Structure**
When design\api\ or design\database\ directories don't exist, the engine auto-detects these interfaces from the project:
- **API detection**: Scans for .sln or .csproj files. Discovers Controllers/, Services/, Models/, Repositories/, Middleware/ directories. Marked as "Auto-detected from {solution-name}.sln".
- **Database detection**: Scans for database/, db/, sql/, migrations/ directories containing .sql files. Marked as "Auto-detected from N SQL files".
Auto-detected interfaces appear in the summary with limited metadata (no _analysis/ or _stubs/) but are still tracked as components.

---

#### CHAPTER 8: SCRIPT REFERENCE

**8.1 User Commands**
Full reference for each command with usage examples and output description:
- gsd-assess (flags: -MapOnly, -DryRun)
- gsd-converge (see Section 4.3 for full parameter reference)
- gsd-blueprint (see Section 4.4 for full parameter reference)
- gsd-status
- gsd-costs (see Section 4.6 for full parameter reference)
- gsd-init
- gsd-remote

**8.2 Installation Scripts**
One paragraph + key details for each of the 21 scripts run by the installer. Include the functions each script adds and the artifacts it creates:
1. install-gsd-global.ps1 - Core engine installer
2. install-gsd-blueprint.ps1 - Blueprint pipeline installer
3. patch-gsd-partial-repo.ps1 - gsd-assess + Update-FileMap
4. patch-gsd-resilience.ps1 - Invoke-WithRetry, New-Lock, Save-Checkpoint, etc.
5. patch-gsd-hardening.ps1 - JSON validation, quota, network, heartbeat, notifications
6. patch-gsd-final-validation.ps1 - Invoke-FinalValidation + New-DeveloperHandoff
7. patch-gsd-figma-make.ps1 - Find-ProjectInterfaces (7 interface types + auto-detection)
8. final-patch-1-spec-check.ps1 - Invoke-SpecConsistencyCheck
9. final-patch-2-sql-cli.ps1 - SQL validation, CLI checks, Test-SqlFiles
10. final-patch-3-storyboard-verify.ps1 - verify-storyboard.md prompt
11. final-patch-4-blueprint-pipeline.ps1 - Complete blueprint pipeline
12. final-patch-5-convergence-pipeline.ps1 - Complete convergence loop
13. final-patch-6-assess-limitations.ps1 - Final assess with KNOWN-LIMITATIONS
14. final-patch-7-spec-resolve.ps1 - Invoke-SpecConflictResolution
15. patch-gsd-supervisor.ps1 - Save-TerminalSummary, Invoke-SupervisorDiagnosis/Fix, New-EscalationReport
16. patch-false-converge-fix.ps1 - Variable init fix + orphan cleanup
17. patch-gsd-council.ps1 - Invoke-LlmCouncil, Build-RequirementChunks
18. patch-gsd-parallel-execute.ps1 - Invoke-ParallelExecute
19. patch-gsd-resilience-hardening.ps1 - Token tracking, auth fix, quota cap, agent rotation
20. patch-gsd-quality-gates.ps1 - Test-DatabaseCompleteness, Test-SecurityCompliance, Invoke-SpecQualityGate
21. patch-gsd-multi-model.ps1 - Invoke-OpenAICompatibleAgent, Test-IsOpenAICompatAgent, model-registry.json, REST agent dispatch/fallback/diagnosis (steps 13B/13C), council pool expansion, 4 REST agents

**8.3 Standalone Utilities**
- setup-gsd-api-keys.ps1 (interactive setup, -Show, -Clear)
- setup-gsd-convergence.ps1 (per-project bootstrap, 16 subdirectories)
- install-gsd-keybindings.ps1 (VS Code Ctrl+Shift+G chords)
- token-cost-calculator.ps1 (~1048 lines, 10 models, client quoting)

**8.4 Key Internal Functions**
Function signature + description for each:
- Invoke-WithRetry - Retry, batch reduction, token tracking, error logging
- Update-FileMap - File inventory generation
- Save-Checkpoint / Restore-Checkpoint - Crash recovery
- Wait-ForQuotaReset - Exponential backoff, cumulative cap
- Test-NetworkAvailability - Connectivity polling
- Invoke-FinalValidation - 9-check validation gate
- Invoke-LlmCouncil - Multi-agent review with 6 council types
- Invoke-SupervisorDiagnosis / Invoke-SupervisorFix - L2/L3 supervisor recovery
- Test-DatabaseCompleteness - Zero-token static DB chain scan
- Test-SecurityCompliance - Zero-token OWASP regex scan with pattern table
- Invoke-SpecQualityGate - Spec consistency + clarity + cross-artifact
- Find-ProjectInterfaces - Multi-interface auto-discovery (7 types + auto-detect API/DB)
- Invoke-ParallelExecute - Round-robin parallel sub-task dispatch
- Get-NextAvailableAgent / Set-AgentCooldown - Agent rotation for quota management (registry-driven 7-agent pool)
- Get-FailureDiagnosis - Agent error analysis (CLI + REST HTTP error mapping) with fallback recommendations
- Invoke-OpenAICompatibleAgent - Generic REST adapter for OpenAI-compatible APIs
- Test-IsOpenAICompatAgent - Registry lookup for REST vs CLI agent type

---

#### CHAPTER 9: TROUBLESHOOTING

**9.1 Installation Issues**
Common problems and fixes:
- "running scripts is disabled on this system" (execution policy bypass)
- "gsd-assess is not recognized" (profile not loaded, how to verify)
- "command claude/codex not found" (npm install commands)
- "command gemini not found" (optional, fallback explanation)
- Install script fails partway through (idempotent re-run)

**9.2 Runtime Issues**
- Stale lock file (check age, manual remove, 120-min auto-reclaim)
- Quota exhausted (automatic handling: backoff, rotation, cap, manual reset)
- Network unavailable (30s polling, auto-resume)
- Codex exit code 2 (log, reduce batch, retry, fallback to Claude)
- Health regression after iteration (auto-revert, checkpoint restore, batch reduce)

**9.3 Agent-Specific Issues**
- Claude Code auth failure (re-authenticate, set API key)
- Codex CLI flag changes (version check, update, untested version warning)
- Gemini OAuth expired (re-authenticate via browser)
- REST agent "Unknown agent" error (re-run install -- patch-gsd-multi-model.ps1 steps 13B/13C patch Get-FailureDiagnosis)
- REST agent auth failure (check API key env var, verify in model-registry.json)
- REST agent not in rotation pool (check API key set, agent enabled in registry, agent in rotation_pool_default)

**9.4 Spec Consistency Conflicts**
How to read spec-consistency-report.json and markdown version. Common conflict types table (data type mismatch, API contract conflict, navigation conflict, business rule conflict) with resolution strategies. Auto-resolution with -AutoResolve flag.

**9.5 Quality Gate Issues**
- Database completeness check failing (error example, auto-fix behavior, manual override via config)
- Security compliance violations (error examples, critical vs high severity, pattern list)
- Spec quality gate blocking pipeline (error example, fix specs or lower threshold)
- Cross-artifact consistency mismatches (error example, fix Figma Make outputs)

**9.6 Reading Error Logs**
How to read .gsd/logs/errors.jsonl with PowerShell command. Error categories table (12 categories: quota, network, disk, corrupt_json, boundary_violation, agent_crash, health_regression, spec_conflict, watchdog_timeout, build_fail, fallback_success, validation_fail) with descriptions.

---

#### CHAPTER 10: COST MANAGEMENT

**10.1 Token Budget Per Iteration**
Convergence pipeline table (code-review, research, plan, execute with agent, input/output tokens, cost per Sonnet, total ~$1.37/iter). Blueprint pipeline table (verify, build with total ~$1.29/iter). Note one-time costs: blueprint phase (~$0.35), council reviews (~$0.30 each).

**10.2 Pre-Run Estimation**
Usage examples with gsd-costs. Token estimates per item type table (13 types: sql-migration, stored-procedure, controller, service, dto, component, hook, middleware, config, test, compliance, routing, default).

**10.3 Live Cost Tracking**
How token-usage.jsonl and cost-summary.json are populated during runs. View commands: gsd-costs -ShowActual, raw JSON, per-call detail. Token costs tracked on ALL attempts with estimation fallback.

**10.4 Client Quoting**
Usage example. Complexity tiers table (4 tiers with item count, suggested markup, rationale). Subscription cost comparison table (Claude Pro, Claude Max, ChatGPT Plus, ChatGPT Pro, Gemini Advanced, minimum bundle).

---

#### CHAPTER 11: QUALITY GATES

**11.1 Overview**
Summary table of all quality gates (5 gates with when they run, cost, and failure action): Spec Quality Gate, DB Completeness, Security Compliance, Final Validation, LLM Council.

**11.2 Spec Quality Gate**
Runs once at pipeline start. Three checks:
1. Spec Consistency Check -- contradictions in data types, API contracts, navigation, business rules
2. Spec Clarity Check (Claude) -- 0-100 scoring with thresholds (90-100 PASS, 70-89 WARN, 0-69 BLOCK)
3. Cross-Artifact Consistency (Claude) -- entity names, field names, endpoint-to-SP mapping, table-to-seed chain, mock data IDs

**11.3 Database Completeness**
Zero-token-cost static analysis of the full database chain (API -> Controller -> Repository -> SP -> Functions/Views -> Tables -> Seed Data). Enhanced tier structure table (7 tiers from Tables through Compliance). How it works (7-step process). Writes db-completeness.json. Fails if coverage < 90%.

**11.4 Security Compliance**
Zero-token-cost regex scan. Pattern table (9 patterns with severity and what each catches): SQL injection, XSS, eval/Function, localStorage secrets, hardcoded credentials, BinaryFormatter, missing auth, missing audit columns, sensitive data in logs. Critical = hard failure, High = warning. Output: security-compliance.json.

**11.5 Security Standards Reference**
88+ rules organized by layer:
- .NET 8 Backend (28 rules): authentication, data protection, security headers, anti-CSRF, deserialization, SSRF
- SQL Server (18 rules): parameterized queries, no dynamic SQL, RLS, audit triggers, least privilege
- React 18 (16 rules): no dangerouslySetInnerHTML, no eval, HTTPS only, no localStorage secrets, CSP, sanitization
- Compliance (26 rules): HIPAA (encrypt PHI, audit, retention), SOC 2 (RBAC, change mgmt), PCI (tokenize, never store raw), GDPR (consent, export, deletion)

**11.6 Coding Conventions**
Enforced via agent prompts:
- .NET Conventions: PascalCase classes/methods, camelCase params, _camelCase fields, Allman braces, SOLID, one class per file
- React Conventions: functional components + hooks, one per file, hooks at top, Props interface above, named exports
- SQL Conventions: PascalCase singular tables, usp_Entity_Action SPs, SET NOCOUNT ON, TRY/CATCH, explicit columns

---

#### CHAPTER 12: LLM MODELS AND CAPABILITIES

**12.1 Supported Models**
Table of all 7 agents with columns: Agent Name, Provider, Model ID, Type (CLI/REST), Input $/M, Output $/M, Context Window. CLI agents: Claude (Anthropic, claude-sonnet-4-20250514, $3.00/$15.00), Codex (OpenAI, codex, $1.50/$6.00), Gemini (Google, gemini-2.5-pro, $1.25/$10.00). REST agents: Kimi K2.5 (Moonshot AI, moonshot-v1-128k, $0.60/$2.50), DeepSeek V3 (DeepSeek, deepseek-chat, $0.28/$0.42), GLM-5 (Zhipu AI, glm-5, $1.00/$3.20), MiniMax M2.5 (MiniMax, abab6.5s-chat, $0.29/$1.20).

**12.2 Model Selection and Roles**
Table of model-to-phase assignments: Claude = judgment-heavy phases (code-review, plan, council synthesis), Codex = code generation (execute, fix), Gemini = research (read-only plan mode), REST agents = council reviews and rotation fallback pool. Explain why: Claude has best judgment, Codex is fastest for code generation, Gemini excels at research with plan mode. REST agents expand the rotation pool to reduce quota downtime. Rotation pool defined in model-registry.json rotation_pool_default.

**12.3 Model Configuration**
model-registry.json schema: agents object (per-agent: type, endpoint, api_key_env, model_id, enabled, pricing), rotation_pool_default array. How to add a new REST agent. How to disable an agent (set enabled:false or remove API key). How to change the rotation pool order. Agent-map.json council.reviewers for council pool expansion.

**12.4 Model Performance Characteristics**
Table comparing models: context window sizes, typical response latency, strengths/weaknesses. Note that REST agents typically have higher latency due to network round-trip but are cheaper. CLI agents have local process overhead but lower latency for established connections.

**12.5 Model Cost Comparison**
Detailed pricing table (7 agents with input/output/cache-read pricing). Per-iteration cost comparison: convergence pipeline cost by model choice, blueprint pipeline cost by model choice. Cost savings from multi-model rotation (cheaper REST agents for council reviews). Reference token-cost-calculator.ps1 for project-specific estimates.

**12.6 Model-Specific Tips and Limitations**
- **Claude**: Best all-around, most expensive. Use for judgment phases. Falls back to as last resort.
- **Codex**: Fast code generation but limited reasoning. Use --full-auto for execution. Loop detection limits.
- **Gemini**: Excellent research in plan mode (read-only). OAuth can expire mid-run. Falls back to Codex.
- **Kimi K2.5**: Good multilingual support. 128K context. May timeout on very large prompts.
- **DeepSeek V3**: Cheapest option ($0.28/$0.42). Good for code review. Rate limits can be aggressive.
- **GLM-5**: Good general reasoning. Chinese-origin model with English support.
- **MiniMax M2.5**: Balanced price/performance. Good for council reviews.

---

#### APPENDICES

**Appendix A: Complete File Inventory**
Every file created by the installer with path and one-line description. Organized as table for global engine files (~/.gsd-global/) covering: bin/, config/ (global-config.json, agent-map.json, model-registry.json), lib/modules/ (resilience.ps1, interfaces.ps1, interface-wrapper.ps1), scripts/, blueprint/, prompts/ (claude, codex, gemini, council, shared), supervisor/, and root files.

**Appendix B: Prompt Templates**
Summary table of all prompt templates with columns: template path, agent, purpose, approximate output. Cover all claude/, codex/, gemini/, and council/ templates.

**Appendix C: Notification Events**
Full table of all 20 ntfy notification events with trigger and content columns: iteration_complete, no_progress, execute_failed, build_failed, regression_reverted, converged, stalled, quota_exhausted, error, heartbeat, agent_timeout, progress_response, supervisor_active, supervisor_diagnosis, supervisor_fix, supervisor_restart, supervisor_recovered, supervisor_escalation, validation_failed, validation_passed.

**Appendix D: Error Categories**
Full table of 12 error categories logged in errors.jsonl with description and auto-recovery columns: quota, network, disk, corrupt_json, boundary_violation, agent_crash, health_regression, spec_conflict, watchdog_timeout, build_fail, fallback_success, validation_fail.

**Appendix E: Glossary**
Key terms table (30+ terms): convergence, blueprint, health score, iteration, batch size, stall threshold, supervisor, council, agent override, checkpoint, pattern memory, escalation, Figma Make, quality gate, spec clarity score, token budget, developer handoff, drift report, heartbeat, agent cooldown, chunked review, model registry, REST agent, OpenAI-compatible, rotation pool, interface auto-detection, component architecture, API layer, database layer.

**Appendix F: Constants and Defaults**
Constants table (12 constants): SUPERVISOR_MAX_ATTEMPTS (5), SUPERVISOR_TIMEOUT_HOURS (24), AGENT_WATCHDOG_MINUTES (30), RETRY_MAX (3), MIN_BATCH_SIZE (2), BATCH_REDUCTION_FACTOR (0.5), RETRY_DELAY_SECONDS (10), LOCK_STALE_MINUTES (120), HEALTH_REGRESSION_THRESHOLD (5), QUOTA_CUMULATIVE_MAX_MINUTES (120), QUOTA_CONSECUTIVE_FAILS_BEFORE_ROTATE (1 -- reduced from 3 by multi-model patch for immediate rotation), HEARTBEAT_INTERVAL_SECONDS (60). Default batch sizes table (blueprint 15, convergence 8). Interface types count: 7 (web, api, database, mcp, browser, mobile, agent). Agent pool size: 7 (3 CLI + 4 REST).

---

### Formatting Requirements

1. **Font**: Calibri 11pt body, Calibri Light for headings
2. **Code blocks**: Consolas 9pt, light gray background (#F5F5F5), 1pt border
3. **Tables**: Professional table style with header row shading (dark blue #2B579A, white text), alternating row colors
4. **Headings**: H1 = 24pt bold, H2 = 18pt bold, H3 = 14pt bold, H4 = 12pt bold italic
5. **Page layout**: Letter size, 1-inch margins, header with document title, footer with page numbers
6. **Diagrams**: Use text-based box diagrams with Unicode box-drawing characters
7. **Color scheme**: Professional blue (#2B579A) for headings and table headers
8. **Cross-references**: Use "See Section X.X" format
9. **Total target**: 80-120 pages

### Output

Generate the document as a Python script using `python-docx` that produces `GSD-Developer-Guide.docx`. The script should be complete and runnable with only `pip install python-docx` as a dependency.

Alternatively, generate the content as a comprehensive Markdown file that can be converted to Word via pandoc:
```
pandoc GSD-Developer-Guide.md -o GSD-Developer-Guide.docx --reference-doc=template.docx --toc --toc-depth=3
```
