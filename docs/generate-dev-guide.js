const fs = require("fs");
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell,
  Header, Footer, AlignmentType, LevelFormat, HeadingLevel,
  BorderStyle, WidthType, ShadingType, PageNumber, PageBreak,
  TableOfContents,
} = require("docx");

const FONT = "Arial";
const ACCENT = "1B5E8C";
const ACCENT_LIGHT = "D5E8F0";
const GRAY_LIGHT = "F5F5F5";
const GRAY_BORDER = "CCCCCC";
const PAGE_W = 12240; const PAGE_H = 15840; const MARGIN = 1440;
const CONTENT_W = PAGE_W - 2 * MARGIN;

const border = { style: BorderStyle.SINGLE, size: 1, color: GRAY_BORDER };
const borders = { top: border, bottom: border, left: border, right: border };
const cellMargins = { top: 80, bottom: 80, left: 120, right: 120 };

function h1(t) { return new Paragraph({ heading: HeadingLevel.HEADING_1, spacing: { before: 360, after: 200 }, children: [new TextRun({ text: t, bold: true, font: FONT, size: 32, color: ACCENT })] }); }
function h2(t) { return new Paragraph({ heading: HeadingLevel.HEADING_2, spacing: { before: 280, after: 160 }, children: [new TextRun({ text: t, bold: true, font: FONT, size: 26, color: ACCENT })] }); }
function h3(t) { return new Paragraph({ heading: HeadingLevel.HEADING_3, spacing: { before: 200, after: 120 }, children: [new TextRun({ text: t, bold: true, font: FONT, size: 22 })] }); }
function p(t, o = {}) { return new Paragraph({ spacing: { after: 120 }, children: [new TextRun({ text: t, font: FONT, size: 21, ...o })] }); }
function pRuns(...runs) { return new Paragraph({ spacing: { after: 120 }, children: runs }); }
function b(t) { return new TextRun({ text: t, font: FONT, size: 21, bold: true }); }
function r(t) { return new TextRun({ text: t, font: FONT, size: 21 }); }
function code(t) { return new Paragraph({ spacing: { after: 40 }, indent: { left: 360 }, children: [new TextRun({ text: t, font: "Consolas", size: 18, color: "333333" })] }); }
function bullet(t, ref = "bullets") { return new Paragraph({ numbering: { reference: ref, level: 0 }, spacing: { after: 80 }, children: [new TextRun({ text: t, font: FONT, size: 21 })] }); }
function bulletBold(label, desc) { return new Paragraph({ numbering: { reference: "bullets", level: 0 }, spacing: { after: 80 }, children: [b(label + " "), r(desc)] }); }
function num(t) { return new Paragraph({ numbering: { reference: "numbers", level: 0 }, spacing: { after: 80 }, children: [new TextRun({ text: t, font: FONT, size: 21 })] }); }
function numBold(label, desc) { return new Paragraph({ numbering: { reference: "numbers", level: 0 }, spacing: { after: 80 }, children: [b(label + " "), r(desc)] }); }
function pb() { return new Paragraph({ children: [new PageBreak()] }); }

function tableRow(cells, hdr = false) {
  return new TableRow({ children: cells.map((t, i) => new TableCell({
    borders, width: { size: Math.floor(CONTENT_W / cells.length), type: WidthType.DXA },
    shading: hdr ? { fill: ACCENT, type: ShadingType.CLEAR } : (i === 0 ? { fill: GRAY_LIGHT, type: ShadingType.CLEAR } : undefined),
    margins: cellMargins,
    children: [new Paragraph({ children: [new TextRun({ text: String(t), font: FONT, size: 19, bold: hdr, color: hdr ? "FFFFFF" : undefined })] })],
  })) });
}
function tbl(headers, rows) {
  const w = Math.floor(CONTENT_W / headers.length);
  return new Table({ width: { size: CONTENT_W, type: WidthType.DXA }, columnWidths: headers.map(() => w), rows: [tableRow(headers, true), ...rows.map(r => tableRow(r))] });
}

const doc = new Document({
  styles: {
    default: { document: { run: { font: FONT, size: 21 } } },
    paragraphStyles: [
      { id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true, run: { size: 32, bold: true, font: FONT, color: ACCENT }, paragraph: { spacing: { before: 360, after: 200 }, outlineLevel: 0 } },
      { id: "Heading2", name: "Heading 2", basedOn: "Normal", next: "Normal", quickFormat: true, run: { size: 26, bold: true, font: FONT, color: ACCENT }, paragraph: { spacing: { before: 280, after: 160 }, outlineLevel: 1 } },
      { id: "Heading3", name: "Heading 3", basedOn: "Normal", next: "Normal", quickFormat: true, run: { size: 22, bold: true, font: FONT }, paragraph: { spacing: { before: 200, after: 120 }, outlineLevel: 2 } },
    ],
  },
  numbering: { config: [
    { reference: "bullets", levels: [{ level: 0, format: LevelFormat.BULLET, text: "\u2022", alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 720, hanging: 360 } } } }] },
    { reference: "numbers", levels: [{ level: 0, format: LevelFormat.DECIMAL, text: "%1.", alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 720, hanging: 360 } } } }] },
  ]},
  sections: [
    // ═══ COVER ═══
    { properties: { page: { size: { width: PAGE_W, height: PAGE_H }, margin: { top: MARGIN, right: MARGIN, bottom: MARGIN, left: MARGIN } } },
      children: [
        new Paragraph({ spacing: { before: 3600 } }),
        new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 200 }, children: [new TextRun({ text: "GSD V4.1", font: FONT, size: 72, bold: true, color: ACCENT })] }),
        new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 100 }, children: [new TextRun({ text: "Autonomous Multi-Agent Development Pipeline", font: FONT, size: 28, color: "555555" })] }),
        new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 100 }, children: [new TextRun({ text: "Developer Guide", font: FONT, size: 36, bold: true })] }),
        new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 600 }, children: [new TextRun({ text: "From 7 Manual Commands to 1 Autonomous Pipeline", font: FONT, size: 22, color: "777777", italics: true })] }),
        new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 100 }, children: [new TextRun({ text: "Version 4.1.0  |  April 2026  |  Technijian, Inc.", font: FONT, size: 20, color: "999999" })] }),
        pb(),
    ]},

    // ═══ BODY ═══
    { properties: { page: { size: { width: PAGE_W, height: PAGE_H }, margin: { top: MARGIN, right: MARGIN, bottom: MARGIN, left: MARGIN } } },
      headers: { default: new Header({ children: [new Paragraph({ alignment: AlignmentType.RIGHT, children: [new TextRun({ text: "GSD V4.1 Developer Guide", font: FONT, size: 16, color: "999999", italics: true })] })] }) },
      footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER, children: [new TextRun({ text: "Page ", font: FONT, size: 16, color: "999999" }), new TextRun({ children: [PageNumber.CURRENT], font: FONT, size: 16, color: "999999" })] })] }) },
      children: [
        h1("Table of Contents"),
        new TableOfContents("TOC", { hyperlink: true, headingStyleRange: "1-3" }),
        pb(),

        // ═══ 1. WHAT CHANGED ═══
        h1("1. What Changed: CLI Pipeline to Autonomous Agents"),
        p("GSD V4.1 replaces the manual multi-command CLI pipeline with a single autonomous pipeline that runs all stages without human intervention. This is the core transformation."),

        h2("1.1 The Old Workflow (V2/V3/V4.0)"),
        p("Before V4.1, building a project from Figma to deployment required 5-7 manual commands with human decision gates between each:"),
        tbl(["Step", "Command", "Time", "Human Decision Required"],
          [
            ["1. Assess", "gsd-assess", "2 min", "Read report, decide converge vs blueprint"],
            ["2. Converge", "gsd-converge", "15-45 min", "Monitor iterations, restart on stall"],
            ["3. Blueprint", "gsd-blueprint", "15-60 min", "Alternative to converge for greenfield"],
            ["4. Build gate", "(automatic in V4)", "1-3 min", "Fix errors if build fails"],
            ["5. Review", "Manual git diff + audit", "10-30 min", "Decide if code is production-ready"],
            ["6. Deploy", "Manual SSH + publish", "10-20 min", "Run commands, verify health"],
            ["7. Validate", "Manual smoke test", "10-15 min", "Check in browser"],
          ]),
        pRuns(b("Total: "), r("1-3 hours per project. 5-7 manual gates where a human must decide and act.")),

        h2("1.2 The New Workflow (V4.1)"),
        p("One command. Zero manual gates. The orchestrator makes all routing decisions and logs the rationale to the vault."),
        code("npx ts-node src/index.ts pipeline run --trigger manual"),
        p(""),
        tbl(["What Happens", "Agent", "Time", "Human Decision"],
          [
            ["Read specs, detect drift", "BlueprintAnalysisAgent", "30s", "None"],
            ["Review code quality", "CodeReviewAgent", "1-2 min", "None"],
            ["Fix issues (if any)", "RemediationAgent (loop 3x)", "2-5 min", "None"],
            ["Run build + tests + security", "QualityGateAgent", "1-2 min", "None"],
            ["E2E validation (API, pages, auth, mock data)", "E2EValidationAgent", "2-5 min", "None"],
            ["Deploy with rollback", "DeployAgent", "2-5 min", "None"],
            ["Post-deploy checks (SPA cache, DI, 500s)", "PostDeployValidationAgent", "1-2 min", "None"],
          ]),
        pRuns(b("Total: "), r("10-15 minutes per project. 0 manual gates. Full audit trail in vault.")),

        h2("1.3 Command Mapping"),
        tbl(["Old Command", "New Equivalent", "What Changed"],
          [
            ["gsd-assess", "(implicit in pipeline run)", "Analysis is the first agent, not a separate command"],
            ["gsd-converge", "pipeline run --trigger manual", "Convergence loop is now agent routing"],
            ["gsd-blueprint", "pipeline run --trigger manual", "Unified with converge; orchestrator decides"],
            ["gsd-deploy-prep (stub)", "pipeline run (includes deploy)", "Actual deployment with rollback, not a stub"],
            ["Manual code review", "CodeReviewAgent (automatic)", "Multi-model review, auto-fix, no human gate"],
            ["Manual deployment", "DeployAgent (automatic)", "Cross-platform deploy + mandatory rollback"],
          ]),
        pb(),

        // ═══ 2. ARCHITECTURE ═══
        h1("2. System Architecture"),
        p("The system has two layers that share the same vault for configuration:"),
        bulletBold("PowerShell Engine (still available):", "The original 54-script convergence engine. Use gsd-converge and gsd-blueprint directly if you prefer the old workflow."),
        bulletBold("TypeScript Harness (new):", "6 typed agents coordinated by an orchestrator with rate-limited scheduling, vault memory, and deploy automation."),

        h2("2.1 Agent Pipeline"),
        code("CLI (src/index.ts)"),
        code("  +-- Orchestrator"),
        code("      +-- RateLimiter (enforces RPM per subscription CLI)"),
        code("      +-- BlueprintAnalysisAgent  -> ConvergenceReport"),
        code("      +-- CodeReviewAgent         -> ReviewResult"),
        code("      +-- RemediationAgent        -> PatchSet  (loop 3x max)"),
        code("      +-- QualityGateAgent        -> GateResult (THROWS on fail)"),
        code("      +-- DeployAgent             -> DeployRecord (rollback on fail)"),
        code(""),
        code("Vault (memory/)"),
        code("  +-- agents/      <- system prompts, tool permissions, retry config"),
        code("  +-- knowledge/   <- quality gates, deploy config, rollback procedures"),
        code("  +-- sessions/    <- append-only run logs (auto-created per run)"),
        code("  +-- decisions/   <- orchestrator reasoning trail"),

        h2("2.2 Pipeline Flow"),
        tbl(["Step", "Agent", "On Success", "On Failure"],
          [
            ["1. Blueprint", "BlueprintAnalysisAgent", "Step 2", "Retry 3x, then HALT"],
            ["2. Review", "CodeReviewAgent", "If passed: Step 4; If failed: Step 3", "Retry 3x, then HALT"],
            ["3. Remediate", "RemediationAgent", "Step 4", "Retry 2x, then HALT"],
            ["4. Quality Gate", "QualityGateAgent", "If passed: Step 5; If failed: Step 3 (max 3 loops)", "Retry 2x, then HALT"],
            ["5. E2E Validation", "E2EValidationAgent", "If passed: Step 6; If failed: Step 3", "Retry 2x, then HALT"],
            ["6. Deploy", "DeployAgent", "Step 7", "Rollback, then HALT"],
            ["7. Post-Deploy", "PostDeployValidationAgent", "COMPLETE", "Log failures, recommend rollback"],
          ]),
        p("The task graph is read from memory/architecture/agent-system-design.md at startup. To change the pipeline flow, edit the vault note."),

        h2("2.3 Key Safety Rules"),
        bullet("DeployAgent REFUSES to run unless QualityGateAgent returned passed=true (runtime assertion)"),
        bullet("Rollback procedure must exist in the vault BEFORE any deploy step executes"),
        bullet("Rollback stops on first failed command and escalates (no blind execution)"),
        bullet("Every orchestrator routing decision is logged to memory/decisions/ with rationale"),
        bullet("Pipeline state is saved after each stage for --from-stage resume"),
        pb(),

        // ═══ 3. LLM MODEL STRATEGY ═══
        h1("3. LLM Model Strategy"),
        p("V4.1 runs on 3 Max/Ultra subscription CLIs. The target is $0 marginal token cost for all pipeline operations. API models are emergency-only fallbacks."),

        h2("3.1 Your Subscriptions"),
        tbl(["Model", "CLI", "Subscription", "Cost/mo", "RPM", "Best For"],
          [
            ["Claude", "claude", "Claude Max", "$100-200", "10", "Review, plan, blueprint (judgment)"],
            ["Codex", "codex", "ChatGPT Max", "$200", "10", "Execute / bulk code generation"],
            ["Gemini", "gemini", "Gemini Ultra", "$20", "15", "Research, bulk review (1M context)"],
          ]),
        pRuns(b("Total subscription: $320-420/mo fixed. Variable token cost: $0.")),

        h2("3.2 Emergency API Fallbacks"),
        tbl(["Model", "Cost/M tokens", "RPM", "When Used"],
          [
            ["DeepSeek", "$0.28/$0.42", "60", "Only when ALL 3 subscription CLIs are on cooldown"],
            ["MiniMax", "$0.29/$1.20", "30", "Only when DeepSeek is also exhausted"],
          ]),
        p("Target API spend: $0/month. These are insurance, not primary agents."),

        h2("3.3 How Rate Limits Are Managed"),
        p("The rate limiter enforces RPM proactively (before calls, not reactively on 429 errors):"),
        num("Before each LLM call: waitForSlot() checks the 60-second sliding window at 80% safety factor"),
        num("After each call: recordCall() logs the timestamp for window tracking"),
        num("Between pipeline stages: 30-second throttle prevents burst exhaustion"),
        num("On quota hit: agent enters 5-minute cooldown; next agent in priority list takes over"),
        num("If all 3 CLIs busy: falls back to DeepSeek API (cheapest)"),
        p(""),
        p("Phase-to-agent routing (first available wins):"),
        tbl(["Phase", "Priority 1", "Priority 2", "Priority 3"],
          [
            ["Blueprint/Review", "Claude", "Gemini", "Codex"],
            ["Plan", "Claude", "Codex", "Gemini"],
            ["Execute", "Codex", "Claude", "Gemini"],
            ["Remediate", "Claude", "Codex", "Gemini"],
          ]),

        h2("3.4 Avoiding Limit Hits"),
        bullet("Do not run multiple pipelines simultaneously (each expects exclusive CLI access)"),
        bullet("Keep batch sizes at 8-14 items (fewer large calls > many small calls)"),
        bullet("Run long convergence sessions overnight when subscription windows reset"),
        bullet("Use --dry-run for testing (skips deploy, saves rate limit budget)"),
        bullet("Set GSD_LLM_MODE=sdk only when you need guaranteed JSON schema compliance (costs per token)"),
        pb(),

        // ═══ 4. VAULT MEMORY ═══
        h1("4. Vault Memory System"),
        p("The vault is the single source of truth for all configuration. Nothing is hardcoded in the TypeScript source. The vault is Obsidian-compatible: you can browse and edit it in Obsidian alongside your development work."),

        h2("4.1 Directory Structure"),
        code("memory/"),
        code("  agents/                     System prompts + configs (read at agent init)"),
        code("    orchestrator.md           Orchestrator routing rules"),
        code("    blueprint-analysis-agent.md"),
        code("    code-review-agent.md"),
        code("    remediation-agent.md"),
        code("    quality-gate-agent.md"),
        code("    deploy-agent.md"),
        code("  knowledge/                  Pipeline configs (read by agents at runtime)"),
        code("    model-strategy.md         LLM routing and cost plan"),
        code("    quality-gates.md          Pass/fail thresholds (coverage %, security)"),
        code("    deploy-config.md          Server, paths, health endpoints"),
        code("    rollback-procedures.md    Step-by-step rollback commands"),
        code("  architecture/               Design docs"),
        code("    agent-system-design.md    Task graph table (orchestrator reads this)"),
        code("  sessions/                   Append-only run logs (auto-created)"),
        code("  decisions/                  Orchestrator decision records"),
        code("  evals/                      Test cases and results"),

        h2("4.2 How Agents Use the Vault"),
        bullet("On startup: each agent reads its vault note (memory/agents/{id}.md) for model, tools, retries, timeout, and system prompt"),
        bullet("During execution: agents read knowledge/ notes for thresholds and configs"),
        bullet("After each stage: orchestrator saves PipelineState to sessions/ for resume"),
        bullet("On every decision: orchestrator appends to decisions/ with action + reason + evidence"),
        bullet("On deploy: immutable audit trail written to sessions/deploy-audit.md"),

        h2("4.3 Editing the Vault"),
        p("To change agent behavior, edit the vault note, not the TypeScript code:"),
        bulletBold("Change quality thresholds:", "Edit memory/knowledge/quality-gates.md"),
        bulletBold("Change deploy target:", "Edit memory/knowledge/deploy-config.md"),
        bulletBold("Change agent model:", "Edit the model: field in memory/agents/{id}.md"),
        bulletBold("Change pipeline flow:", "Edit the task graph table in memory/architecture/agent-system-design.md"),
        bulletBold("Change retry count:", "Edit max_retries: in the agent's vault note frontmatter"),
        pb(),

        // ═══ 5. GETTING STARTED ═══
        h1("5. Getting Started"),
        h2("5.1 Prerequisites"),
        bullet("Node.js 20+ and npm"),
        bullet("Claude CLI (claude) with Claude Max subscription active"),
        bullet("Codex CLI (codex) with ChatGPT Max subscription active"),
        bullet("Gemini CLI (gemini) with Gemini Ultra subscription active"),
        bullet("Git (for deploy tagging and state tracking)"),
        bullet("Optional: .NET 8 SDK and npm for target project build/test"),

        h2("5.2 Installation"),
        code("cd gsd-autonomous-dev"),
        code("npm install"),
        code("npx tsc --noEmit   # verify clean compilation (0 errors)"),

        h2("5.3 Your First Pipeline Run"),
        p("Dry run (runs all agents, skips actual deployment):"),
        code("npx ts-node src/index.ts pipeline run --trigger manual --dry-run"),
        p(""),
        p("Full autonomous run (deploys if gate passes):"),
        code("npx ts-node src/index.ts pipeline run --trigger manual"),
        p(""),
        p("Resume a failed run from where it stopped:"),
        code("npx ts-node src/index.ts pipeline run --from-stage gate"),
        p(""),
        p("Run the eval suite (validates agent behavior):"),
        code("npx ts-node src/evals/runner.ts"),

        h2("5.4 CLI Reference"),
        tbl(["Flag", "Default", "Description"],
          [
            ["--trigger", "manual", "Trigger type: manual, schedule, or webhook"],
            ["--from-stage", "(start)", "Resume from: blueprint, review, remediate, gate, deploy"],
            ["--dry-run", "false", "Run full pipeline but skip DeployAgent"],
            ["--vault-path", "./memory", "Path to the vault directory"],
          ]),

        h2("5.5 Environment Variables"),
        tbl(["Variable", "Default", "Purpose"],
          [
            ["GSD_LLM_MODE", "cli", "LLM call mode: cli (OAuth, $0) or sdk (API, per-token)"],
            ["ANTHROPIC_API_KEY", "(none)", "Required only if GSD_LLM_MODE=sdk"],
            ["GSD_DEBUG", "false", "Enable debug logging for vault operations"],
          ]),
        pb(),

        // ═══ 6. AGENT REFERENCE ═══
        h1("6. Agent Reference"),
        h2("6.1 BlueprintAnalysisAgent"),
        p("Reads blueprint/spec files, extracts requirements, detects drift from current implementation. Returns a ConvergenceReport with aligned, drifted, missing items, and risk level."),
        tbl(["Property", "Value"],
          [["File", "src/agents/blueprint-analysis-agent.ts"], ["Vault note", "memory/agents/blueprint-analysis-agent.md"], ["Input", "{ blueprintPath, specPaths, repoRoot }"], ["Output", "ConvergenceReport { aligned[], drifted[], missing[], riskLevel }"], ["Structured output", "Yes (JSON schema via tool_use or prompt instructions)"]]),

        h2("6.2 CodeReviewAgent"),
        p("Validates code against the ConvergenceReport. Runs build commands, linters, and tests. Returns pass/fail with issue list."),
        tbl(["Property", "Value"],
          [["File", "src/agents/code-review-agent.ts"], ["Vault note", "memory/agents/code-review-agent.md"], ["Input", "{ convergenceReport, changedFiles, qualityGates }"], ["Output", "ReviewResult { passed, issues[], coveragePercent, securityFlags[] }"], ["Structured output", "Yes (JSON schema)"]]),

        h2("6.3 RemediationAgent"),
        p("Applies targeted code fixes for ReviewResult failures. Each fix is atomic, validated, and traceable. Creates backup before writing, validates LLM output is code (not explanation), and rolls back ALL patches if tests fail."),
        tbl(["Property", "Value"],
          [["File", "src/agents/remediation-agent.ts"], ["Vault note", "memory/agents/remediation-agent.md"], ["Input", "{ reviewResult, repoRoot }"], ["Output", "PatchSet { patches[], testsPassed }"], ["Safety", "Explanation guard, backup-before-write, rollback on test failure"]]),

        h2("6.4 QualityGateAgent"),
        p("Runs build, tests, coverage, and security scan. THROWS QualityGateFailure if any check fails. This prevents DeployAgent from ever running against failing code."),
        tbl(["Property", "Value"],
          [["File", "src/agents/quality-gate-agent.ts"], ["Vault note", "memory/agents/quality-gate-agent.md"], ["Input", "{ patchSet, qualityThresholds }"], ["Output", "GateResult { passed, coverage, securityScore, evidence[] }"], ["Hard rule", "Throws QualityGateFailure if passed=false"]]),

        h2("6.5 DeployAgent"),
        p("Executes deployment with mandatory rollback. Verifies rollback procedure exists before any deploy step. Stops rollback on first failure and escalates."),
        tbl(["Property", "Value"],
          [["File", "src/agents/deploy-agent.ts"], ["Vault note", "memory/agents/deploy-agent.md"], ["Input", "{ gateResult, deployConfig, commitSha }"], ["Output", "DeployRecord { success, environment, steps[], rollbackExecuted }"], ["Hard rules", "1) Throws if gate not passed  2) Rollback must exist  3) Stops on first rollback failure"]]),

        h2("6.6 E2EValidationAgent (NEW)"),
        p("Validates the application against Figma storyboards and API contracts BEFORE deployment. Catches: DTO mismatches, mock data fallbacks, missing stored procedures, broken auth, stub handlers, hardcoded user IDs. Based on 15 categories of post-deploy failure found during ChatAI v8 alpha."),
        tbl(["Property", "Value"],
          [["File", "src/agents/e2e-validation-agent.ts"], ["Vault note", "memory/agents/e2e-validation-agent.md"], ["Input", "{ repoRoot, backendUrl, frontendUrl, storyboardsPath, apiContractsPath, apiSpMapPath }"], ["Output", "E2EValidationResult { passed, totalFlows, passedFlows, categories }"], ["Test categories", "API contracts, SP existence, mock data detection, page render, auth flows"]]),

        h2("6.7 PostDeployValidationAgent (NEW)"),
        p("Runs AFTER deployment against the live environment. Validates: SPA hash freshness (catches IIS kernel cache stale SPA disease), DI registration completeness (no 500s on any endpoint), auth flow, and frontend bundle accessibility."),
        tbl(["Property", "Value"],
          [["File", "src/agents/post-deploy-validation-agent.ts"], ["Vault note", "memory/agents/post-deploy-validation-agent.md"], ["Input", "{ deployRecord, frontendUrl, apiBaseUrl, apiContractsPath }"], ["Output", "PostDeployValidationResult { passed, checks[], spExistence, authFlow }"], ["Key checks", "SPA hash freshness, health endpoint, no 500s on all endpoints, JS bundle accessible"]]),
        pb(),

        // ═══ 7. FIGMA TO PRODUCTION ═══
        h1("7. End-to-End: Figma to Production"),
        p("This is the complete developer workflow from design to deployed application."),

        h2("7.1 Step 1: Design in Figma Make"),
        p("Build your frontend prototype in Figma Make, then run the Figma Complete Generation Prompt (scripts/Figma_Complete_Generation_Prompt.md). This generates:"),
        bullet("12 analysis documents (screen inventory, component inventory, design system, navigation, data types, API contracts, hooks, mock data, storyboards, state matrix, API-to-SP map, implementation guide)"),
        bullet("5 stub files (controllers, DTOs, tables, stored procedures, seed data)"),
        p("Export to design/web/v##/src/_analysis/ and _stubs/."),

        h2("7.2 Step 2: Run the Autonomous Pipeline"),
        code("cd your-project-repo"),
        code("npx ts-node path/to/gsd/src/index.ts pipeline run --trigger manual"),
        p("The pipeline reads the Figma exports and runs all 5 stages automatically."),

        h2("7.3 Step 3: Review Results (Optional)"),
        p("Everything is in the vault:"),
        bullet("Run log: memory/sessions/{date}-run-{id}.md"),
        bullet("Decisions: memory/decisions/{date}-run-{id}.md"),
        bullet("Deploy audit: memory/sessions/deploy-audit.md"),

        h2("7.4 Step 4: Resume on Failure"),
        p("If any stage fails, the pipeline pauses and logs an alert. Resume:"),
        code("npx ts-node src/index.ts pipeline run --from-stage remediate"),
        p("The orchestrator reloads the saved PipelineState and picks up where it left off."),
        pb(),

        // ═══ 8. EXTENDING THE SYSTEM ═══
        h1("8. Extending the System"),

        h2("8.1 Adding a New Agent"),
        numBold("Design vault note first.", "Create memory/agents/your-agent.md with frontmatter (model, tools, forbidden_tools, retries, timeout) and body (Role, System prompt, I/O schemas, Failure modes)."),
        numBold("Define types.", "Add input/output interfaces to src/harness/types.ts."),
        numBold("Build the class.", "Create src/agents/your-agent.ts extending BaseAgent. Implement only run()."),
        numBold("Register in orchestrator.", "Add to agentDefs array and agentToCliModel map."),
        numBold("Update task graph.", "Edit the table in memory/architecture/agent-system-design.md."),
        numBold("Add phase routing.", "Add entry to PHASE_ROUTING constant in orchestrator.ts."),
        numBold("Write eval test case.", "Add to memory/evals/test-cases.md and/or built-in array in runner.ts."),
        numBold("Typecheck.", "npx tsc --noEmit must pass with 0 errors."),

        h2("8.2 Adding a Hook"),
        p("Register custom hooks in the orchestrator's initialize() method:"),
        code("this.hooks.register('onAfterRun', 'my-hook', async (ctx) => {"),
        code("  // ctx has: runId, agentId, input, output, state, durationMs"),
        code("  await vault.append('sessions/my-log.md', `Agent ${ctx.agentId} completed`);"),
        code("});"),

        h2("8.3 Changing Quality Thresholds"),
        p("Edit memory/knowledge/quality-gates.md. The QualityGateAgent reads these at runtime:"),
        bullet("Line coverage >= N% (parsed from the Coverage Gate table)"),
        bullet("Critical vulnerabilities = 0 (parsed from the Security Gate table)"),
        bullet("No hardcoded secrets (security scan patterns)"),
        pb(),

        // ═══ 9. HARNESS INTERNALS ═══
        h1("9. Harness Internals"),

        h2("9.1 Type System (types.ts)"),
        p("All agent I/O is typed. Key types: PipelineState, ConvergenceReport, ReviewResult, PatchSet, GateResult, DeployRecord, Decision. Error types: QualityGateFailure, HardGateViolation, AgentTimeoutError, EscalationError."),

        h2("9.2 VaultAdapter (vault-adapter.ts)"),
        p("Reads/writes Obsidian-compatible markdown. OS-level file locking via proper-lockfile prevents cross-process corruption. Follows [[wikilinks]] recursively. All writes go through append() or create() only."),

        h2("9.3 BaseAgent Lifecycle (base-agent.ts)"),
        code("execute(input)              // DO NOT override"),
        code("  1. hooks.fire('onBeforeRun')"),
        code("  2. rateLimiter.waitForSlot()  // blocks until RPM slot opens"),
        code("  3. run(input)                 // subclass implements this"),
        code("  4. rateLimiter.recordCall()   // tracks for sliding window"),
        code("  5. hooks.fire('onAfterRun')"),
        code("  on error: hooks.fire('onError')"),

        h2("9.4 JSON Extraction (extractJSON)"),
        p("All agents that receive structured LLM responses use extractJSON<T>(). Three strategies tried in order: (1) parse entire response, (2) extract from code fences, (3) find balanced braces. Throws on failure so retry logic engages."),

        h2("9.5 Rate Limiter (rate-limiter.ts)"),
        p("Sliding 60-second window with configurable safety factor. Tracks per-agent call history. Methods: waitForSlot() blocks until available, recordCall() logs timestamp, setCooldown() puts agent on timeout, pickAvailable() selects from priority list."),
        pb(),

        // ═══ 10. FILE REFERENCE ═══
        h1("10. File Reference"),
        tbl(["File", "Lines", "Purpose"],
          [
            ["src/harness/types.ts", "309", "All type definitions and error classes"],
            ["src/harness/vault-adapter.ts", "332", "Vault read/write with OS-level file locking"],
            ["src/harness/hooks.ts", "80", "Hook event system"],
            ["src/harness/default-hooks.ts", "209", "7 built-in hooks (log, cost, validate, retry, escalate, deploy)"],
            ["src/harness/base-agent.ts", "321", "Agent lifecycle, LLM call with rate limiting, JSON extraction"],
            ["src/harness/rate-limiter.ts", "144", "Sliding-window RPM enforcement per subscription CLI"],
            ["src/harness/orchestrator.ts", "698", "Task routing, decision logging, state persistence, escalation handling"],
            ["src/agents/blueprint-analysis-agent.ts", "148", "Spec drift detection with tool_use schema"],
            ["src/agents/code-review-agent.ts", "191", "Code quality validation (execFile, cross-platform)"],
            ["src/agents/remediation-agent.ts", "167", "Targeted fixes: validation guard, backup, rollback on test failure"],
            ["src/agents/quality-gate-agent.ts", "206", "Build/test/security gate (cross-platform scan)"],
            ["src/agents/e2e-validation-agent.ts", "213", "E2E validation: API contracts, SP existence, mock data, page render, auth"],
            ["src/agents/deploy-agent.ts", "246", "Deploy with rollback, http/https health check"],
            ["src/agents/post-deploy-validation-agent.ts", "143", "Post-deploy: SPA cache, DI health, no 500s, auth, JS bundle"],
            ["src/harness/powershell-bridge.ts", "130", "Bridge to call existing GSD PowerShell scripts from TypeScript"],
            ["src/evals/runner.ts", "463", "Eval framework, 6 test cases, vault parser, quality judge"],
            ["src/index.ts", "144", "CLI entry point"],
          ]),
        pRuns(b("Total: "), r("4,368 lines TypeScript. 36 vault notes. 8 test fixtures. 8 agents. 0 type errors.")),
        pb(),

        // ═══ 11. TROUBLESHOOTING ═══
        h1("11. Troubleshooting"),
        h3("Pipeline paused with escalation alert"),
        bullet("Check memory/sessions/alerts.md for error details"),
        bullet("Read the agent's vault note for known failure modes"),
        bullet("Fix the issue, then: pipeline run --from-stage <failed-stage>"),

        h3("All subscription CLIs on cooldown"),
        bullet("Pipeline falls back to DeepSeek API (costs money)"),
        bullet("Wait 5 minutes for cooldowns to expire, then resume"),
        bullet("Prevention: increase ThrottleSeconds, reduce batch sizes"),

        h3("JSON parse failure"),
        bullet("LLM returned non-JSON despite schema instructions"),
        bullet("Orchestrator retries up to max_retries times automatically"),
        bullet("If persistent: set GSD_LLM_MODE=sdk for guaranteed structured output"),

        h3("Deploy failed + rollback"),
        bullet("DeployAgent executes rollback from memory/knowledge/rollback-procedures.md"),
        bullet("Rollback STOPS on first failed command and escalates"),
        bullet("Full audit trail: memory/sessions/deploy-audit.md"),
        bullet("If rollback itself fails: manual intervention required"),

        h3("Missing vault note"),
        bullet("Agent fails to initialize if memory/agents/{id}.md is missing"),
        bullet("Deploy refuses to start if memory/knowledge/deploy-config.md is missing or has no Server/Deploy Path rows"),
        bullet("Fix: create the vault note with required frontmatter fields"),
    ]},
  ],
});

Packer.toBuffer(doc).then(buf => {
  fs.writeFileSync("docs/GSD-V4.1-Developer-Guide.docx", buf);
  console.log("Generated: docs/GSD-V4.1-Developer-Guide.docx");
});
