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
- `scripts/install-gsd-keybindings.ps1` - VS Code shortcuts
- `scripts/setup-gsd-api-keys.ps1` - API key management

### Document Structure

Generate the Word document with the following structure. Use professional formatting: title page, table of contents, numbered headings, tables, code blocks with monospace font, page numbers, and consistent styling throughout.

---

#### FRONT MATTER
- **Title Page**: "GSD Autonomous Development Engine - Developer Guide", Version 1.1.0, Date, "Confidential - Internal Use Only"
- **Table of Contents**: Auto-generated from headings
- **Document History**: Version 1.0.0 (Initial Release), Version 1.1.0 (Codex CLI update, multi-agent support, supervisor, cost tracking)

---

#### CHAPTER 1: INTRODUCTION

**1.1 Why We Built This**
Write a compelling 2-3 paragraph narrative explaining the problem:
- Traditional software development with AI assistants is manual, fragile, and expensive. A developer has to copy-paste prompts, manually review output, fix issues, and repeat. There is no memory between sessions, no automatic recovery from failures, no way to verify completeness against specifications.
- The GSD Engine automates the entire develop-review-fix loop. It orchestrates multiple AI agents (Claude, Codex, Gemini), assigns each to the tasks they do best, and runs autonomously until the codebase matches the specification. It handles crashes, quota limits, network failures, and agent errors without human intervention.
- The result: a developer writes specifications, runs one command, and gets a fully built, verified, compliant codebase. What used to take weeks of manual AI-assisted development happens overnight.

**1.2 Design Philosophy**
- Token-optimized agent assignment (Claude for judgment, Codex/Gemini for generation)
- Specification-driven (code matches specs, not the other way around)
- Self-healing (retry, checkpoint, rollback, supervisor recovery)
- Idempotent (safe to re-run, safe to interrupt and resume)
- Observable (health scores, push notifications, cost tracking)

**1.3 What Was Built**
High-level summary of the three capabilities: `gsd-assess`, `gsd-converge`, `gsd-blueprint`. Include a comparison table showing when to use each.

---

#### CHAPTER 2: ARCHITECTURE

**2.1 System Overview**
Describe the overall architecture. Include a text-based diagram showing the flow between the developer, the GSD engine, and the three AI agents.

**2.2 Agent Assignment**
Table showing which agent handles which phase, why, and approximate token usage. Include Claude, Codex, and Gemini roles.

**2.3 Convergence Loop (5-Phase)**
Detailed walkthrough of the code-review -> create-phases -> research -> plan -> execute cycle. Explain what each phase does, which agent runs it, and what artifacts it produces.

**2.4 Blueprint Pipeline (3-Phase)**
Detailed walkthrough of blueprint -> build -> verify. Explain how it differs from convergence and when to use it.

**2.5 Data Flow Diagrams**
Text-based diagrams for:
- gsd-assess flow
- gsd-converge per-iteration flow
- gsd-blueprint per-iteration flow

**2.6 Installed Directory Structure**
Full tree of `%USERPROFILE%\.gsd-global\` with descriptions of every directory and key file.

**2.7 Per-Project State (.gsd/ folder)**
Full tree of the `.gsd/` folder created in each project, with descriptions of every file.

---

#### CHAPTER 3: INSTALLATION

**3.1 Prerequisites**
Table of all required and optional software with versions and install commands.

**3.2 API Key Configuration**
Step-by-step instructions for setting up Anthropic, OpenAI, and Google API keys. Include both interactive and command-line methods.

**3.3 Running the Master Installer**
Step-by-step walkthrough of `install-gsd-all.ps1`. List all 16 scripts in execution order with one-line descriptions.

**3.4 Post-Install Verification**
Commands to verify the installation succeeded.

**3.5 VS Code Integration**
Tasks, keyboard shortcuts (Ctrl+Shift+G chords), and how to use them.

**3.6 Multi-Workstation Setup**
How to install on a second workstation and transfer work between machines (git push/pull, lock file handling).

**3.7 Updating and Uninstalling**
How to update to a new version, how to completely remove GSD.

---

#### CHAPTER 4: USAGE GUIDE

**4.1 First Project Setup**
Step-by-step guide from empty repo to first pipeline run. Include the expected project structure (design/, docs/, src/).

**4.2 Running gsd-assess**
Full usage with all flags (-MapOnly, -DryRun). What it produces, how to read the output.

**4.3 Running gsd-converge**
Full usage with all flags (-SkipResearch, -DryRun, -MaxIterations, -SkipInit, -StallThreshold, -BatchSize). What to expect during a run. How to monitor progress.

**4.4 Running gsd-blueprint**
Full usage with all flags (-BlueprintOnly, -BuildOnly, -VerifyOnly, -DryRun, -MaxIterations, -BatchSize). When to switch from blueprint to convergence.

**4.5 Running gsd-status**
How to check project health at any time.

**4.6 Running gsd-costs**
How to estimate costs before a run and track actual costs during/after. Include the cost comparison table and client quoting tiers.

**4.7 Monitoring a Running Pipeline**
- Terminal output interpretation (icons, phases, batch sizes)
- Push notifications via ntfy.sh (setup, subscribing, event types)
- Remote monitoring via gsd-remote (QR code, phone control)
- Reading .gsd/health/ files directly

**4.8 Interrupting and Resuming**
How to safely Ctrl+C, what state is preserved, how to resume. How to transfer to another workstation.

---

#### CHAPTER 5: RESILIENCE AND SELF-HEALING

**5.1 Retry with Batch Reduction**
How Invoke-WithRetry works. Retry count, batch reduction factor, minimum batch size.

**5.2 Checkpoint and Recovery**
How Save-Checkpoint and Restore-Checkpoint work. What's saved, how crash recovery works.

**5.3 Lock File Management**
How New-Lock and Remove-Lock work. Stale lock detection (120 min default). Concurrent run prevention.

**5.4 Health Regression Protection**
Automatic revert when health drops >5% after an iteration.

**5.5 Quota and Rate Limit Handling**
Wait-ForQuotaReset behavior: 60-minute sleep cycles, up to 24 cycles (24 hours).

**5.6 Network Failure Handling**
Test-NetworkAvailability behavior: 30-second polling until connection restored.

**5.7 Build Validation and Auto-Fix**
Post-execution dotnet build + npm run build. Auto-fix via Codex on failure.

**5.8 Agent Watchdog**
30-minute timeout per agent call. Automatic process kill and retry.

**5.9 The Supervisor**
Self-healing supervisor loop: diagnosis, fix, pattern memory, escalation. How it learns from failures across projects. When it escalates to human intervention. Escalation report format.

**5.10 Final Validation Gate**
What happens at 100% health: compilation, tests, SQL validation, vulnerability audit. Health set to 99% on failure with auto-fix loop.

---

#### CHAPTER 6: CONFIGURATION REFERENCE

**6.1 Global Configuration (global-config.json)**
Full schema with all fields, types, defaults, and descriptions. Include the notifications and patterns sections.

**6.2 Agent Assignment (agent-map.json)**
Phase-to-agent mapping. Token budget allocation.

**6.3 Blueprint Configuration (blueprint-config.json)**
Full schema.

**6.4 Per-Project State Files**
Detailed schema for: health-current.json, health-history.jsonl, requirements-matrix.json, queue-current.json, blueprint.json, .gsd-checkpoint.json, engine-status.json, final-validation.json, token-usage.jsonl, cost-summary.json, supervisor-state.json.

**6.5 Environment Variables**
All API key variables, system variables, and how they're used.

**6.6 Pricing Cache**
How the pricing cache works, freshness thresholds, model keys and their LiteLLM lookup.

---

#### CHAPTER 7: MULTI-INTERFACE SUPPORT

**7.1 Interface Types**
Supported types: web, mcp, browser, mobile, agent. How they're detected.

**7.2 Directory Structure**
Expected design/ folder layout with version folders.

**7.3 Figma Make Integration**
The 12 expected deliverable files in _analysis/. How _stubs/ works.

**7.4 Auto-Discovery**
How Find-ProjectInterfaces recursively scans the repo.

---

#### CHAPTER 8: SCRIPT REFERENCE

**8.1 User Commands**
Full reference for: gsd-assess, gsd-converge, gsd-blueprint, gsd-status, gsd-costs, gsd-init, gsd-remote.

**8.2 Installation Scripts**
One paragraph + key details for each of the 16 scripts run by the installer.

**8.3 Standalone Utilities**
setup-gsd-api-keys.ps1, setup-gsd-convergence.ps1, install-gsd-keybindings.ps1, token-cost-calculator.ps1.

**8.4 Key Internal Functions**
Reference for: Invoke-WithRetry, Update-FileMap, Save-Checkpoint, Restore-Checkpoint, Wait-ForQuotaReset, Test-NetworkAvailability, Save-GsdSnapshot, Find-ProjectInterfaces, Invoke-SpecConsistencyCheck, Invoke-FinalValidation, Invoke-SupervisorDiagnosis, Invoke-SupervisorFix.

---

#### CHAPTER 9: TROUBLESHOOTING

**9.1 Installation Issues**
Common problems and fixes: execution policy, command not found, profile not loaded.

**9.2 Runtime Issues**
Stale lock file, quota exhausted, network unavailable, codex exit code 2, health regression.

**9.3 Agent-Specific Issues**
Claude auth, Codex flag changes, Gemini OAuth.

**9.4 Spec Consistency Conflicts**
How to read the spec-consistency-report.json. Common conflict types and resolution strategies.

**9.5 Reading Error Logs**
How to read .gsd/logs/errors.jsonl. Error categories and what they mean.

---

#### CHAPTER 10: COST MANAGEMENT

**10.1 Token Budget Per Iteration**
Table showing expected token usage per phase per agent per iteration for both pipelines.

**10.2 Pre-Run Estimation**
How to use gsd-costs to estimate before starting. Token estimates per item type table.

**10.3 Live Cost Tracking**
How token-usage.jsonl and cost-summary.json are populated during runs. How to view with gsd-costs -ShowActual.

**10.4 Client Quoting**
Complexity tiers, suggested markups, subscription cost comparisons.

---

#### APPENDICES

**Appendix A: Complete File Inventory**
Every file created by the installer with path and one-line description.

**Appendix B: Prompt Templates**
Summary of all prompt templates (claude/code-review.md, claude/plan.md, codex/execute.md, etc.) with purpose and approximate token output.

**Appendix C: Notification Events**
Full list of ntfy notification events with descriptions.

**Appendix D: Error Categories**
Full list of error categories logged in errors.jsonl with descriptions.

**Appendix E: Glossary**
Key terms: convergence, blueprint, health score, iteration, batch size, stall threshold, supervisor, etc.

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
