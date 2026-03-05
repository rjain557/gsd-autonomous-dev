# Prompt: Generate GSD Developer Guide (Word Document)

Use this prompt with Claude Code, ChatGPT, or any LLM capable of generating .docx files via python-docx.

---

## Prompt

You are a technical writer producing a professional developer guide as a Microsoft Word document (.docx). Your job is to **discover** all features, scripts, configurations, and standards from the source files, then generate a polished, comprehensive document titled **"GSD Autonomous Development Engine - Developer Guide"**.

### Discovery Process (CRITICAL)

Before writing any content, you MUST perform a complete discovery of the codebase. Do NOT rely on hardcoded assumptions — read the actual files and extract current values.

**Step 1: Scan all scripts**
- Read every `.ps1` file in `scripts/` — extract functions, parameters, constants, config values, and features
- Read `scripts/install-gsd-all.ps1` to determine the exact install chain order and total script count
- For each script, note: purpose, functions added/modified, key constants, artifacts created

**Step 2: Read all documentation**
- Read every `.md` file in `docs/` — extract architecture, commands, configurations, troubleshooting
- Read `readme.md` for project overview

**Step 3: Read prompt templates (standards and conventions)**
- Read ALL files in `%USERPROFILE%\.gsd-global\prompts\shared\` — these define the coding standards, security rules, and database conventions that the engine enforces
- Read ALL files in `%USERPROFILE%\.gsd-global\prompts\claude\`, `prompts\codex\`, `prompts\gemini\`, `prompts\council\` — these define agent roles and review criteria
- Each prompt template file is an authoritative source for its topic — extract ALL rules, patterns, naming conventions, and compliance requirements

**Step 4: Read runtime modules**
- Read `%USERPROFILE%\.gsd-global\lib\modules\resilience.ps1` — extract all functions, constants, error categories
- Read `%USERPROFILE%\.gsd-global\lib\modules\interfaces.ps1` — extract interface types, auto-detection logic
- Read `%USERPROFILE%\.gsd-global\config\global-config.json` — extract all configuration fields
- Read `%USERPROFILE%\.gsd-global\config\agent-map.json` — extract agent assignments and parallel config
- Read `%USERPROFILE%\.gsd-global\config\model-registry.json` (if exists) — extract all registered agents, types, pricing

**Step 5: Cross-reference and validate**
- Count total scripts, agents, interface types, quality gates, council types, notification events, error categories
- Verify all constants match between scripts and documentation
- Identify any features in scripts not yet documented in the .md files — these MUST be included in the guide

### Content Generation Rules

1. **Every feature discovered in scripts MUST appear in the guide** — if a script adds a function, that function must be documented
2. **Every constant discovered MUST appear in Appendix F** — read actual values from source, don't guess
3. **Every prompt template file becomes source material** for its corresponding chapter (coding standards from coding-conventions.md, security from security-standards.md, database from database-completeness-review.md)
4. **Tables over prose** — use tables for rules, constants, parameters, configurations, agent lists
5. **Actual values, not placeholders** — read the real version number, real script count, real agent count from the source files
6. **Cross-references** — use "See Section X.X" format to link related content across chapters

---

### Document Structure

Generate the Word document with the following structure. Use professional formatting: title page, table of contents, numbered headings, tables, code blocks with monospace font, page numbers, and consistent styling throughout.

---

#### FRONT MATTER
- **Title Page**: "GSD Autonomous Development Engine - Developer Guide", Version [READ FROM install-gsd-all.ps1 $GSD_VERSION], Date [READ FROM install-gsd-all.ps1 $GSD_DATE], "Confidential - Internal Use Only"
- **Table of Contents**: Auto-generated from headings
- **Document History**: Build version history from git log or script comments. Include at minimum:
  - Version 1.0.0 (Initial Release)
  - Version 1.1.0 (Codex CLI update, multi-agent support, supervisor, cost tracking)
  - Version 1.2.0 (LLM Council, parallel execution, resilience hardening)
  - Version 1.5.0 (Quality gates, chunked council reviews)
  - [Latest version: read from $GSD_VERSION with description of what changed]

---

#### CHAPTER 1: INTRODUCTION

**1.1 Why We Built This**
Write a compelling 2-3 paragraph narrative explaining the problem:
- Traditional software development with AI assistants is manual, fragile, and expensive
- The GSD Engine automates the entire develop-review-fix loop — orchestrates [DISCOVER: count agents from model-registry.json] AI agents, assigns each to tasks they do best, runs autonomously until codebase matches specification
- Handles crashes, quota limits, network failures, JSON corruption, agent boundary violations, stalls, and specification contradictions without human intervention
- At 100% health, runs full validation gate (compilation, tests, security audit, database completeness) before declaring success

**1.2 Design Philosophy**
- Token-optimized agent assignment (Claude for judgment, Codex/Gemini for generation)
- Specification-driven (code matches specs, not the other way around)
- Self-healing (retry, checkpoint, rollback, supervisor recovery)
- Idempotent (safe to re-run, safe to interrupt and resume)
- Observable (health scores, push notifications, cost tracking)
- Quality-gated (DB completeness, security compliance, spec clarity, council review)

**1.3 What Was Built**
High-level summary of the core capabilities with comparison table. Discover commands from gsd-profile-functions.ps1 or the bin/ directory.

---

#### CHAPTER 2: ARCHITECTURE

**2.1 System Overview**
Describe the overall architecture. Include a text-based diagram showing: developer → GSD engine (PowerShell orchestrator) → [DISCOVER: all agents from model-registry.json with their types] → resilience layer → quality gates layer. Show how all UI interfaces communicate with the database through the API layer.

**2.2 Agent Assignment**
Table showing which agent handles which phase. Read from agent-map.json for primary assignments. Read from model-registry.json for agent types (CLI vs REST). Include supervisor agent override and parallel execution round-robin.

**2.3 Convergence Loop (5-Phase)**
Detailed walkthrough of the convergence cycle. Read phase_order from global-config.json. For each phase: which agent, what artifacts, where council gates appear. Include text-based diagram and phase details table.

**2.4 Blueprint Pipeline (3-Phase)**
Detailed walkthrough of blueprint → build → verify. Read from final-patch-4-blueprint-pipeline.ps1. Include comparison table: when to use convergence vs blueprint.

**2.5 Data Flow Diagrams**
Text-based diagrams for gsd-assess, gsd-converge per-iteration, gsd-blueprint per-iteration.

**2.6 Installed Directory Structure**
Full tree of `%USERPROFILE%\.gsd-global\` — read the actual directory and document every subdirectory and key file.

**2.7 Per-Project State (.gsd/ Folder)**
Full tree of the `.gsd/` folder — read from setup-gsd-convergence.ps1 for the 16+ subdirectories created.

---

#### CHAPTER 3: INSTALLATION

**3.1 Prerequisites**
Tables of required and optional software. Read from install-gsd-prerequisites.ps1 for the exact tool list, versions, and install commands.

**3.2 API Key Configuration**
Step-by-step for all API keys. Read from setup-gsd-api-keys.ps1 for supported keys (CLI + REST agent keys). Include the three modes (Set/Show/Clear) and environment variable table.

**3.3 Running the Master Installer**
Read install-gsd-all.ps1 for the exact execution order. Generate table of ALL scripts in order with one-line descriptions. Separately list standalone utility scripts.

**3.4 Post-Install Verification**
Commands to verify installation: reload profile, gsd-status, prerequisites verify.

**3.5 VS Code Integration**
Read install-gsd-keybindings.ps1 for exact keyboard shortcuts. Include tasks and shortcuts table.

**3.6 Multi-Workstation Setup**
Two-place state model (global engine vs project state). Lock file handling.

**3.7 Updating and Uninstalling**
Idempotent update (re-run installer). Uninstall steps.

---

#### CHAPTER 4: USAGE GUIDE

**4.1 First Project Setup**
Expected project structure tree. Step-by-step for new project (blueprint) and existing project (convergence).

**4.2 Running gsd-assess**
Read flags from final-patch-6-assess-limitations.ps1 or the assess.ps1 script.

**4.3 Running gsd-converge**
Read ALL parameters from final-patch-5-convergence-pipeline.ps1. Generate parameter table with actual default values.

**4.4 Running gsd-blueprint**
Read ALL parameters from final-patch-4-blueprint-pipeline.ps1. Generate parameter table with actual default values.

**4.5 Running gsd-status**
Dashboard contents from gsd-profile-functions.ps1.

**4.6 Running gsd-costs**
Read ALL parameters from token-cost-calculator.ps1. Include usage examples and client quote complexity tiers.

**4.7 Monitoring a Running Pipeline**
- Terminal output interpretation
- Push notifications via ntfy.sh — read notification events from patch-gsd-hardening.ps1
- Remote monitoring via gsd-remote
- Reading state files directly

**4.8 Interrupting and Resuming**
How to safely Ctrl+C, what state is preserved, how to resume.

---

#### CHAPTER 5: RESILIENCE AND SELF-HEALING

Read ALL constants and functions from patch-gsd-resilience.ps1, patch-gsd-hardening.ps1, and patch-gsd-resilience-hardening.ps1. For each section below, use the actual constant values discovered.

**5.1 Retry with Batch Reduction** — Invoke-WithRetry: RETRY_MAX, BATCH_REDUCTION_FACTOR, MIN_BATCH_SIZE, RETRY_DELAY_SECONDS
**5.2 Checkpoint and Recovery** — Save-Checkpoint / Restore-Checkpoint with JSON schema
**5.3 Lock File Management** — New-Lock / Remove-Lock: LOCK_STALE_MINUTES
**5.4 Health Regression Protection** — HEALTH_REGRESSION_THRESHOLD
**5.5 Quota and Rate Limit Handling** — Wait-ForQuotaReset: backoff schedule, cumulative cap, agent rotation threshold, REST agent HTTP error mapping
**5.6 Network Failure Handling** — Test-NetworkAvailability: NETWORK_POLL_SECONDS, NETWORK_MAX_POLLS
**5.7 Build Validation and Auto-Fix** — BUILD_TIMEOUT_SECONDS
**5.8 Agent Watchdog** — AGENT_WATCHDOG_MINUTES
**5.9 The Supervisor** — Read from patch-gsd-supervisor.ps1: 3-layer architecture, max attempts, pattern memory, escalation
**5.10 Final Validation Gate** — Read from patch-gsd-final-validation.ps1: all 9 checks, hard/warning types, handoff document sections

---

#### CHAPTER 6: CONFIGURATION REFERENCE

Read each config file directly and document its complete JSON schema.

**6.1 Global Configuration (global-config.json)** — Read from file. Subsections for: notifications, patterns, phase_order, council (including chunking), quality_gates
**6.2 Agent Assignment (agent-map.json)** — Read from file. Include execute_parallel config
**6.3 Blueprint Configuration (blueprint-config.json)** — Read from file
**6.4 Per-Project State Files** — JSON schemas for: health-current.json, engine-status.json, final-validation.json, token-usage.jsonl, cost-summary.json, supervisor-state.json
**6.5 Model Registry (model-registry.json)** — Read from file. Document all agent entries with types and pricing
**6.6 Environment Variables** — Compile from all scripts: CLI API keys, REST API keys, system variables
**6.7 Pricing Cache** — Read from token-cost-calculator.ps1: all supported models, cache freshness rules

---

#### CHAPTER 7: MULTI-INTERFACE SUPPORT

Read from patch-gsd-figma-make.ps1 and lib/modules/interfaces.ps1.

**7.1 Component Architecture** — Three-layer model: UI Interfaces → REST API → Database
**7.2 Interface Types** — Read INTERFACE_TYPES from interfaces.ps1. Table with all types, descriptions, detection patterns, color coding
**7.3 Directory Structure** — Expected design/ folder layout
**7.4 Figma Make Integration** — 12 deliverables in _analysis/, 3 stubs in _stubs/
**7.5 Auto-Discovery** — How Find-ProjectInterfaces scans the repo
**7.6 Auto-Detection from Project Structure** — API detection (.sln/.csproj) and Database detection (.sql files)

---

#### CHAPTER 8: SCRIPT REFERENCE

**8.1 User Commands** — Discover from bin/ directory or gsd-profile-functions.ps1
**8.2 Installation Scripts** — Read install-gsd-all.ps1 for exact order. For EACH script: read its header, extract functions added, artifacts created, key parameters
**8.3 Standalone Utilities** — Scripts not in the install chain
**8.4 Key Internal Functions** — Grep resilience.ps1 for all `function ` definitions. Document each with signature + description

---

#### CHAPTER 9: TROUBLESHOOTING

Read from docs/GSD-Troubleshooting.md AND discover additional issues from error handling code in scripts.

**9.1 Installation Issues** — Common problems and fixes
**9.2 Runtime Issues** — Stale locks, quota, network, exit codes, health regression
**9.3 Agent-Specific Issues** — Per-agent troubleshooting (CLI + REST agents)
**9.4 Spec Consistency Conflicts** — From final-patch-1-spec-check.ps1 and final-patch-7-spec-resolve.ps1
**9.5 Quality Gate Issues** — From patch-gsd-quality-gates.ps1
**9.6 Reading Error Logs** — Error categories from Write-GsdError in resilience.ps1

---

#### CHAPTER 10: COST MANAGEMENT

Read from token-cost-calculator.ps1 for all pricing, estimation logic, and client quoting.

**10.1 Token Budget Per Iteration** — Per-phase cost tables for both pipelines
**10.2 Pre-Run Estimation** — gsd-costs usage and token estimates per item type
**10.3 Live Cost Tracking** — token-usage.jsonl and cost-summary.json
**10.4 Client Quoting** — Complexity tiers, subscription comparison, markup guidance

---

#### CHAPTER 11: QUALITY GATES

Read from patch-gsd-quality-gates.ps1 and patch-gsd-final-validation.ps1.

**11.1 Overview** — Summary table of ALL quality gates with: when they run, cost, failure action
**11.2 Spec Quality Gate** — From Invoke-SpecQualityGate: 3 checks, scoring thresholds
**11.3 Database Completeness** — From Test-DatabaseCompleteness: chain validation, tier structure, coverage threshold
**11.4 Security Compliance** — From Test-SecurityCompliance: pattern table with severity levels
**11.5 Final Validation Gate** — 9-check matrix, hard vs warning, max attempts
**11.6 LLM Council Review** — From patch-gsd-council.ps1: council types, chunking, consensus

---

#### CHAPTER 12: LLM MODELS AND CAPABILITIES

Read from model-registry.json, patch-gsd-multi-model.ps1, and token-cost-calculator.ps1.

**12.1 Supported Models** — Table of ALL agents discovered from model-registry.json: name, provider, model_id, type, pricing, context window
**12.2 Model Selection and Roles** — Phase-to-model mapping from agent-map.json + why each model was chosen
**12.3 Model Configuration** — model-registry.json schema, how to add/disable agents, rotation pool
**12.4 Model Performance Characteristics** — Context windows, latency, strengths/weaknesses per model
**12.5 Model Cost Comparison** — Detailed pricing from model-registry.json + per-iteration cost tables
**12.6 Model-Specific Tips and Limitations** — Per-agent operational notes

---

#### CHAPTER 13: CODING STANDARDS & METHODOLOGIES

**IMPORTANT**: Read `%USERPROFILE%\.gsd-global\prompts\shared\coding-conventions.md` and reproduce ALL rules, naming conventions, and patterns as the authoritative source. This chapter must be comprehensive enough to serve as a standalone coding standards reference.

**13.1 .NET 8 / C# Naming Conventions** — Complete naming table (classes, interfaces, methods, parameters, fields, constants, DTOs) from coding-conventions.md

**13.2 .NET Formatting Standards** — Indentation, line length, braces style, string interpolation, using directives

**13.3 .NET Architecture Patterns** — Repository pattern, service layer, controller conventions, DTOs, dependency injection, one class per file

**13.4 .NET Error Handling** — Specific exceptions, using statements, async/await, structured logging

**13.5 SOLID Principles** — All 5 principles with descriptions and examples as enforced by the engine

**13.6 React 18 Conventions** — Component structure, naming table (components, files, hooks, props, CSS modules, constants), patterns (error boundaries, loading states, input validation, accessibility)

**13.7 SQL Server Conventions** — Naming table (tables, columns, SPs, views, functions, indexes, PKs, FKs), structure rules (SET NOCOUNT ON, TRY/CATCH, audit columns, explicit columns, idempotent migrations, GRANT EXECUTE, seed data patterns)

---

#### CHAPTER 14: DATABASE CODING STANDARDS

**IMPORTANT**: Read `%USERPROFILE%\.gsd-global\prompts\shared\database-completeness-review.md` and `coding-conventions.md` (SQL section) to reproduce ALL database standards. This chapter must be comprehensive enough to serve as a standalone database development reference.

**14.1 Required Data Chain** — End-to-end chain: API Endpoint → Controller → Repository/Service → SP → Functions/Views → Tables → Seed Data. Every link must exist.

**14.2 Enhanced Blueprint Tier Structure** — Complete tier table (Tier 1 through 6) from database-completeness-review.md with contents per tier

**14.3 Stored Procedure Patterns** — Naming (usp_Entity_Action), CRUD patterns (GetById, GetAll, Create, Update, Delete, Search), structure requirements (TRY/CATCH, SET NOCOUNT ON, explicit params, audit column handling)

**14.4 Migration Patterns** — Naming convention (V001__Description.sql), idempotent IF EXISTS checks, table creation, index creation, constraint addition

**14.5 Seed Data Standards** — MERGE/IF NOT EXISTS for idempotency, FK consistency, realistic timestamps, Figma mock data matching, grouping by entity

**14.6 Verification Rules** — All 10 verification rules from database-completeness-review.md

**14.7 Cross-Reference Sources** — Which _analysis/ and _stubs/ files feed database validation

**14.8 View and Function Patterns** — When to use views (3+ table JOINs), scalar functions (reusable calculations), table-valued functions, naming conventions (vw_, fn_)

---

#### CHAPTER 15: COMPLIANCE & SECURITY CODING

**IMPORTANT**: Read `%USERPROFILE%\.gsd-global\prompts\shared\security-standards.md` and reproduce ALL rules with their IDs. This chapter must be comprehensive enough to serve as a standalone security compliance reference. Every rule has a unique ID (SEC-NET-xx, SEC-SQL-xx, SEC-FE-xx, COMP-xxx-xx) that must be preserved.

**15.1 .NET 8 Backend Security** — ALL rules from security-standards.md .NET section:
- Authentication & Authorization (SEC-NET-01 through SEC-NET-09)
- Input Validation (SEC-NET-10 through SEC-NET-14)
- Data Protection & Cryptography (SEC-NET-15 through SEC-NET-22)
- Security Headers (SEC-NET-23 through SEC-NET-27)
- Error Handling & Logging (SEC-NET-28 through SEC-NET-33)
- Deserialization & SSRF (SEC-NET-34 through SEC-NET-38)

**15.2 SQL Server Security** — ALL rules from security-standards.md SQL section:
- Access Control (SEC-SQL-01 through SEC-SQL-06)
- Structure & Patterns (SEC-SQL-07 through SEC-SQL-15)
- Encryption & Backup (SEC-SQL-16 through SEC-SQL-18)

**15.3 React 18 Frontend Security** — ALL rules from security-standards.md React section:
- XSS Prevention (SEC-FE-01 through SEC-FE-04)
- Data & Token Handling (SEC-FE-05 through SEC-FE-09)
- Error Handling (SEC-FE-10 through SEC-FE-13)
- Dependencies (SEC-FE-14 through SEC-FE-16)

**15.4 HIPAA Compliance (Health Data)** — ALL rules: COMP-HIPAA-01 through COMP-HIPAA-07

**15.5 SOC 2 Compliance (Trust & Security)** — ALL rules: COMP-SOC2-01 through COMP-SOC2-06

**15.6 PCI DSS Compliance (Payment Card Data)** — ALL rules: COMP-PCI-01 through COMP-PCI-06

**15.7 GDPR Compliance (EU Privacy)** — ALL rules: COMP-GDPR-01 through COMP-GDPR-06

---

#### CHAPTER 16: SPEED OPTIMIZATIONS

Read from patch-gsd-differential-review.ps1 and patch-gsd-speed-optimizations.ps1.

**16.1 Overview** — Summary table of all speed optimizations with estimated savings

**16.2 Differential Code Review** — How Get-DifferentialContext + Save-ReviewedCommit work, git diff integration, cache management, fallback thresholds, code-review-differential.md prompt. Config: differential_review in global-config.json.

**16.3 Conditional Research Skip** — When research is skipped (health improving, no new requirements), Test-ShouldSkipResearch logic, estimated savings per iteration

**16.4 Smart Batch Sizing** — Get-OptimalBatchSize formula (context_limit * 0.7 / avg_tokens_per_req), historical data tracking, min/max bounds

**16.5 Prompt Template Deduplication** — {{SECURITY_STANDARDS}} and {{CODING_CONVENTIONS}} template variables, Resolve-PromptWithDedup function, single source of truth principle

**16.6 Token Budget Headers** — Output Constraints and Input Context blocks added to all prompts, inter-agent handoff protocol

---

#### CHAPTER 17: VALIDATION GATES REFERENCE

Read from patch-gsd-pre-execute-gate.ps1, patch-gsd-acceptance-tests.ps1, patch-gsd-api-contract-validation.ps1, patch-gsd-visual-validation.ps1, patch-gsd-design-token-enforcement.ps1, and existing quality gate scripts.

**17.1 Complete Validation Gate Inventory** — Master table of ALL 14 validation gates: name, type, cost, when they run, blocking behavior

**17.2 Pre-Execute Compile Gate** — Invoke-PreExecuteGate flow: build before commit, fix-compile-errors.md prompt, max fix attempts, fallthrough behavior. Config: pre_execute_gate in global-config.json.

**17.3 Per-Requirement Acceptance Tests** — Test-RequirementAcceptance: 5 test types (file_exists, pattern_match, build_check, dotnet_test, npm_test), queue-current.json acceptance_test field schema, results storage. Config: acceptance_tests in global-config.json.

**17.4 Contract-First API Validation** — Test-ApiContractCompliance: 6 validation checks (route coverage, HTTP methods, parameter types, [Authorize], inline SQL, SP mapping), 06-api-contracts.md cross-reference. Config: api_contract_validation in global-config.json.

**17.5 Visual Validation** — Invoke-VisualValidation: Playwright screenshot capture, Figma export comparison, pixel diff threshold, component-match fallback. Config: visual_validation in global-config.json.

**17.6 Design Token Enforcement** — Test-DesignTokenCompliance: hardcoded value detection (colors, fonts, spacing, borders), design token cross-reference, allowed exceptions. Config: design_token_enforcement in global-config.json.

---

#### CHAPTER 18: COMPLIANCE ENGINE AND AGENT INTELLIGENCE

Read from patch-gsd-compliance-engine.ps1 and patch-gsd-agent-intelligence.ps1.

**18.1 Per-Iteration Compliance Audit** — Invoke-PerIterationCompliance: structured rule engine with 20+ SEC-*/COMP-* rules, every-iteration scanning, severity levels (critical/high/medium), rule results table. Config: compliance_engine.per_iteration_audit in global-config.json.

**18.2 Database Migration Validation** — Test-DatabaseMigrationIntegrity: FK consistency, index coverage, seed data referential integrity, zero-cost SQL scan. Config: compliance_engine.db_migration in global-config.json.

**18.3 PII Flow Tracking** — Invoke-PiiFlowAnalysis: configurable PII field registry, logging check (critical), encryption check (high), UI masking check (high), flow tracing across API/controller/SP/table. Config: compliance_engine.pii_tracking in global-config.json.

**18.4 Agent Performance Scoring** — Update-AgentPerformanceScore + Get-BestAgentForPhase: efficiency metric (requirements/1K tokens), reliability metric (1 - regression rate), overall score formula, min_samples threshold, data-driven agent routing. Output: agent-scores.json. Config: agent_intelligence.performance_scoring in global-config.json.

**18.5 Warm-Start for New Projects** — Save-ProjectPatterns + Get-WarmStartPatterns: project type detection (dotnet-react, dotnet-api, react-spa), global pattern cache, cross-project pattern sharing. Output: ~/.gsd-global/intelligence/pattern-cache.json. Config: agent_intelligence.warm_start in global-config.json.

---

#### CHAPTER 19: LOC TRACKING AND COST-PER-LINE METRICS

Read from patch-gsd-loc-tracking.ps1 and the LOC-related changes in final-patch-5-convergence-pipeline.ps1 and final-patch-4-blueprint-pipeline.ps1.

**19.1 Overview** — Purpose of LOC tracking: measure AI-generated code output, correlate with API costs, surface metrics in notifications and developer handoff.

**19.2 How It Works** — Update-LocMetrics: git diff --numstat parsing, source file filtering (include_extensions, exclude_paths), per-iteration and cumulative tracking, file-level detail (top 20 files by lines added).

**19.3 Cost-per-Line Calculation** — Cross-reference with cost-summary.json: cost_per_added_line, cost_per_net_line formulas, example calculation.

**19.4 Notification Integration** — Get-LocNotificationText: per-iteration format ("LOC: +250 / -30 net 220 | 12 files"), cumulative format with cost-per-line. Patched into: per-iteration notifications, completion, stalled, max-iterations, heartbeat.

**19.5 Developer Handoff LOC Section** — LOC metrics table in developer-handoff.md: cumulative metrics, cost-per-line, per-iteration breakdown table.

**19.6 Configuration** — loc_tracking block in global-config.json: enabled, include_extensions, exclude_paths, track_per_file, cost_per_line. Output: .gsd/costs/loc-metrics.json.

---

#### APPENDICES

**Appendix A: Complete File Inventory**
Scan `%USERPROFILE%\.gsd-global\` and list every file with path and one-line description. Organize by directory: bin/, config/, lib/modules/, scripts/, blueprint/, prompts/ (all subdirectories), supervisor/.

**Appendix B: Prompt Templates**
Scan all `prompts\` subdirectories (claude/, codex/, gemini/, council/, shared/). Table with: template path, agent, purpose, approximate output size.

**Appendix C: Notification Events**
Read from patch-gsd-hardening.ps1 — extract ALL notification event names, triggers, and content descriptions.

**Appendix D: Error Categories**
Read from Write-GsdError in resilience.ps1 — extract ALL error category names with descriptions and auto-recovery behavior.

**Appendix E: Glossary**
Compile 30+ key terms discovered across all source files. Include every domain-specific term used in the guide.

**Appendix F: Constants and Defaults**
Read ALL `$script:` constants from resilience.ps1, plus config defaults from global-config.json and agent-map.json. Table with: constant name, value, source file, description. Include batch sizes, interface types count, agent pool size.

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
9. **Total target**: 120-180 pages (expanded with speed optimizations, validation gates, compliance engine, agent intelligence, and LOC tracking chapters)

### Output

Generate the document as a Python script using `python-docx` that produces `GSD-Developer-Guide.docx`. The script should be complete and runnable with only `pip install python-docx` as a dependency.

Alternatively, generate the content as a comprehensive Markdown file that can be converted to Word via pandoc:
```
pandoc GSD-Developer-Guide.md -o GSD-Developer-Guide.docx --reference-doc=template.docx --toc --toc-depth=3
```
