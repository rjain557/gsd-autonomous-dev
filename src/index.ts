// ═══════════════════════════════════════════════════════════
// GSD V6 — Unified CLI Entry Point
// Milestone → Slice → Task hierarchy with SQLite state, worktree
// isolation, budget routing, forensics, observability.
// Legacy `pipeline run` and `sdlc run` preserved for slice-level access.
// ═══════════════════════════════════════════════════════════

import { Orchestrator } from './harness/orchestrator';
import { SdlcOrchestrator } from './harness/sdlc-orchestrator';
import type { PipelineStage, TriggerType } from './harness/types';
import type { SdlcPhase } from './harness/sdlc-types';

import { MilestoneOrchestrator } from './harness/v6/milestone-orchestrator';
import { StateDB } from './harness/v6/state-db';
import { WorktreeManager } from './harness/v6/worktree-manager';
import { runQuery, runQueryAsync, formatQueryResult, type QuerySubject } from './harness/v6/cli-query';
import { buildForensicsBundle } from './harness/v6/cli-forensics';
import { validateStackLeaks, formatStackLeakReport } from './harness/v6/stack-leak-validator';
import { getProjectStackContext } from './harness/project-stack-context';
import { worktreeStatus, worktreePrune, worktreeTeardown, formatWorktreeStatus } from './harness/v6/cli-worktree';
import { runDocGardener, formatDocGardenReport } from './harness/v6/doc-gardener';
import { runKnowledgeHarvest } from './harness/v6/knowledge-harvester';
import { migrateV5ToV6 } from './harness/v6/migrate-v5-to-v6';

import { execFileSync } from 'child_process';
import { existsSync } from 'fs';
import { join } from 'path';

// ── Preflight validation ────────────────────────────────────

interface PreflightResult {
  ok: boolean;
  warnings: string[];
  errors: string[];
}

function preflight(vaultPath: string): PreflightResult {
  const warnings: string[] = [];
  const errors: string[] = [];

  // 1. Vault path exists with expected structure
  if (!existsSync(vaultPath)) {
    errors.push(`Vault path not found: ${vaultPath}`);
  } else if (!existsSync(join(vaultPath, 'agents'))) {
    errors.push(`Vault path missing agents/ subdirectory: ${vaultPath}/agents`);
  }

  // 2. Validate GSD_LLM_MODE
  const llmMode = process.env.GSD_LLM_MODE;
  if (llmMode && llmMode !== 'cli' && llmMode !== 'sdk') {
    errors.push(`GSD_LLM_MODE must be "cli" or "sdk", got: "${llmMode}"`);
  }

  // 3. If SDK mode, check for API key
  if (llmMode === 'sdk' && !process.env.ANTHROPIC_API_KEY) {
    errors.push('GSD_LLM_MODE=sdk requires ANTHROPIC_API_KEY environment variable');
  }

  // 4. Check primary CLI availability (claude is required minimum)
  const cliChecks: Array<{ name: string; required: boolean }> = [
    { name: 'claude', required: true },
    { name: 'codex', required: false },
    { name: 'gemini', required: false },
  ];

  for (const cli of cliChecks) {
    try {
      // shell: true so Windows resolves .cmd/.bat shims (e.g., npm-installed `claude`)
      execFileSync(cli.name, ['--version'], { timeout: 10_000, stdio: 'pipe', shell: true });
    } catch {
      const msg = `CLI "${cli.name}" not found on PATH. Install and authenticate before running the pipeline.`;
      if (cli.required) {
        errors.push(msg);
      } else {
        warnings.push(msg + ' (fallback agents will be used)');
      }
    }
  }

  // 5. Check Semgrep availability (non-blocking — falls back to regex)
  // shell: true so Windows resolves .cmd/.bat shims and `python` aliases.
  let semgrepFound = false;
  try {
    execFileSync('semgrep', ['--version'], { timeout: 10_000, stdio: 'pipe', shell: true });
    semgrepFound = true;
  } catch {
    // Try python module invocation (Windows PATH workaround)
    try {
      execFileSync('python', ['-m', 'semgrep', '--version'], { timeout: 10_000, stdio: 'pipe', shell: true });
      semgrepFound = true;
    } catch {
      try {
        execFileSync('python3', ['-m', 'semgrep', '--version'], { timeout: 10_000, stdio: 'pipe', shell: true });
        semgrepFound = true;
      } catch { /* not installed */ }
    }
  }
  if (!semgrepFound) {
    warnings.push('Semgrep SAST not found (pip install semgrep). Security scanning will use regex-only fallback.');
  }

  return { ok: errors.length === 0, warnings, errors };
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);

  if (args.length === 0 || args[0] === 'help' || args[0] === '--help') {
    printUsage();
    return;
  }

  // Route to the correct command
  switch (args[0]) {
    case 'run':
      await handleGsd(args.slice(1));
      break;
    case 'status':
      await handleStatus();
      break;
    case 'pipeline':
      await handlePipeline(args.slice(1));
      break;
    case 'sdlc':
      await handleSdlc(args.slice(1));
      break;
    case 'query':
      await handleQuery(args.slice(1));
      break;
    case 'forensics':
      await handleForensics(args.slice(1));
      break;
    case 'worktree':
      await handleWorktree(args.slice(1));
      break;
    case 'doc-garden':
      await handleDocGarden(args.slice(1));
      break;
    case 'harvest':
      await handleHarvest(args.slice(1));
      break;
    case 'migrate':
      await handleMigrate(args.slice(1));
      break;
    case 'validate-stack':
      await handleValidateStack(args.slice(1));
      break;
    default:
      console.error(`Unknown command: ${args[0]}`);
      printUsage();
      process.exit(1);
  }
}

/**
 * Unified GSD command — one entry point, tell it where you are.
 *
 * Milestones map to SDLC phases:
 *   requirements     → Phase A (requirements) + Phase B (architecture)
 *   figma-prompts    → Phase B output → generates Figma Make prompts per interface
 *   figma-uploaded   → Phase C (validate 12/12 deliverables) + Phase AB-Reconcile
 *   contracts        → Phase D (blueprint freeze) + Phase E (contract freeze / SCG1)
 *   blueprint        → Pipeline: blueprint → review → remediate → gate → e2e
 *   deploy           → Pipeline: deploy → post-deploy
 *   full             → Everything A through deployment
 */
const MILESTONE_TO_PHASES: Record<string, { sdlcFrom?: SdlcPhase; sdlcTo?: SdlcPhase; pipelineFrom?: PipelineStage; pipelineTo?: PipelineStage; description: string }> = {
  'requirements':  { sdlcFrom: 'phase-a', sdlcTo: 'phase-b', description: 'Gather requirements + generate architecture' },
  'figma-prompts': { sdlcFrom: 'phase-b', sdlcTo: 'phase-b', description: 'Generate Figma Make prompts from architecture' },
  'figma-uploaded': { sdlcFrom: 'phase-c', sdlcTo: 'phase-ab-reconcile', description: 'Validate Figma deliverables + reconcile with requirements' },
  'contracts':     { sdlcFrom: 'phase-d', sdlcTo: 'phase-e', description: 'Freeze blueprint + generate contracts (SCG1)' },
  'blueprint':     { pipelineFrom: 'blueprint', description: 'Run GSD pipeline: blueprint → review → gate → e2e' },
  'deploy':        { pipelineFrom: 'deploy', description: 'Deploy to alpha + post-deploy validation' },
  'full':          { sdlcFrom: 'phase-a', description: 'Full lifecycle: requirements → deploy' },
};

async function handleStatus(): Promise<void> {
  const vaultPath = './memory';

  console.log('');
  console.log('═══════════════════════════════════════════════');
  console.log('  GSD V6 Project Status');
  console.log('═══════════════════════════════════════════════');

  // ── V6 milestone state (SQLite) ────────────────────────
  const dbPath = join(vaultPath, 'state.db');
  if (existsSync(dbPath)) {
    try {
      const db = new StateDB(dbPath);
      try {
        const milestones = db.listMilestones();
        if (milestones.length === 0) {
          console.log('  V6 milestones:  (none in state.db)');
        } else {
          const active = milestones.filter((m) => m.status === 'running' || m.status === 'paused');
          const recent = milestones.slice(0, 5);
          console.log(`  V6 milestones:  ${milestones.length} total, ${active.length} active`);
          console.log('');
          console.log('  Recent:');
          for (const m of recent) {
            const slices = db.listSlicesForMilestone(m.id);
            const completeSlices = slices.filter((s) => s.status === 'complete').length;
            console.log(`    ${m.id}  [${m.status.padEnd(9)}]  ${m.name}`);
            console.log(`       slices: ${completeSlices}/${slices.length}  spent: $${m.spentUsd.toFixed(4)} / budget $${m.budgetUsd}`);
            if (m.worktreePath) console.log(`       worktree: ${m.worktreePath}`);
          }
          console.log('');
          if (active.length > 0) {
            console.log(`  Inspect: gsd query milestone ${active[0].id}`);
          }
        }
      } finally {
        db.close();
      }
    } catch (e) {
      console.log(`  V6 state.db: unreadable — ${(e as Error).message}`);
    }
  } else {
    console.log('  V6 milestones:  (no state.db yet — will be created on first `gsd run`)');
  }

  // ── Legacy SDLC state (for mid-V5 migrations) ──────────
  console.log('');
  console.log('  ──── Legacy SDLC state ────');
  try {
    const { VaultAdapter } = await import('./harness/vault-adapter');
    const vault = new VaultAdapter(vaultPath);
    const note = await vault.read('sessions/sdlc-state-latest.json');
    const state = JSON.parse(note.body);

    console.log(`  Run ID:     ${state.sdlcRunId}`);
    console.log(`  Status:     ${state.status}`);
    console.log(`  Phase:      ${state.currentPhase}`);
    console.log('  Completed:');
    if (state.intakePack) console.log('    ✓ Phase A — Requirements (Intake Pack)');
    if (state.architecturePack) console.log('    ✓ Phase B — Architecture Pack');
    if (state.figmaDeliverables) console.log(`    ✓ Phase C — Figma (${state.figmaDeliverables.completeness ?? '?'}/12 deliverables)`);
    if (state.reconciliationReport) console.log(`    ✓ Phase A/B Reconcile (alignment: ${state.reconciliationReport.alignmentScore ?? '?'}%)`);
    if (state.frozenBlueprint) console.log(`    ✓ Phase D — Blueprint Frozen (${state.frozenBlueprint.frozenAt ?? ''})`);
    if (state.contractArtifacts) console.log(`    ✓ Phase E — SCG1 ${state.contractArtifacts.scg1Passed ? 'PASSED' : 'FAILED'} (${state.contractArtifacts.endpoints ?? '?'} endpoints, ${state.contractArtifacts.storedProcedures ?? '?'} SPs)`);

    const nextMilestone: Record<string, string> = {
      'phase-a': 'gsd run requirements', 'phase-b': 'gsd run figma-prompts',
      'phase-c': 'gsd run figma-uploaded', 'phase-ab-reconcile': 'gsd run contracts',
      'phase-d': 'gsd run contracts', 'phase-e': 'gsd run blueprint',
      'pipeline': 'gsd run deploy',
    };
    if (state.status !== 'complete') {
      console.log(`  Next: ${nextMilestone[state.currentPhase] ?? 'gsd run full'}`);
    }
  } catch {
    console.log('  No legacy SDLC state. New project? Start with:');
    console.log('    gsd run requirements --project "MyProject" --description "..."');
  }
  console.log('═══════════════════════════════════════════════');
  console.log('');
}

async function handleGsd(args: string[]): Promise<void> {
  const milestone = args[0];

  if (!milestone || milestone === 'help' || milestone === '--help') {
    console.log(`
GSD — One Command, Tell It Where You Are

Usage:
  gsd run <milestone> [options]

Milestones (in order):
  requirements      Gather requirements + generate architecture spec
  figma-prompts     Generate Figma Make prompts for each interface
  figma-uploaded    Validate Figma deliverables + update requirements
  contracts         Freeze blueprint + generate SCG1 contracts
  blueprint         Run code pipeline (review, gate, e2e validation)
  deploy            Deploy to alpha + post-deploy checks
  full              Run everything from requirements to deploy

Options:
  --project <name>          Project name
  --description <text>      Project description (for requirements phase)
  --design-path <path>      Path to Figma output (default: auto-detect)
  --vault-path <path>       Vault directory (default: ./memory)
  --dry-run                 Skip actual deployment

Examples:
  # Starting a new project — gather requirements
  gsd run requirements --project "ClientPortal" --description "Multi-tenant SaaS portal"

  # Figma designs are done, uploaded deliverables
  gsd run figma-uploaded --design-path design/web/v1/src/

  # Generate contracts from frozen blueprint
  gsd run contracts

  # Run code pipeline through to validation
  gsd run blueprint

  # Deploy to alpha
  gsd run deploy

  # Full lifecycle end-to-end
  gsd run full --project "ClientPortal" --description "Multi-tenant SaaS portal"
`);
    return;
  }

  const config = MILESTONE_TO_PHASES[milestone];
  if (!config) {
    console.error(`Unknown milestone: "${milestone}"`);
    console.error(`Valid milestones: ${Object.keys(MILESTONE_TO_PHASES).join(', ')}`);
    process.exit(1);
  }

  const options = parseOptions(args.slice(1));
  const vaultPath = options['vault-path'] ?? './memory';
  const dryRun = options['dry-run'] === 'true' || options['dry-run'] === '';

  // Preflight
  const check = preflight(vaultPath);
  for (const w of check.warnings) console.warn(`  [WARN] ${w}`);
  if (!check.ok) {
    console.error('\n  Preflight failed:');
    for (const e of check.errors) console.error(`    ✗ ${e}`);
    process.exit(1);
  }

  console.log('');
  console.log('═══════════════════════════════════════════════');
  console.log('  GSD — Goal Spec Done');
  console.log('═══════════════════════════════════════════════');
  console.log(`  Milestone:  ${milestone} — ${config.description}`);
  if (options['project']) console.log(`  Project:    ${options['project']}`);
  console.log(`  Vault:      ${vaultPath}`);
  console.log('═══════════════════════════════════════════════');
  console.log('');

  // Milestone prerequisite validation — check prior state exists
  const prereqs: Record<string, { needs: string; check: string }> = {
    'figma-prompts': { needs: 'requirements', check: 'docs/sdlc/phase-b-architecture-pack.json' },
    'figma-uploaded': { needs: 'figma-prompts (Figma Make export)', check: '' },  // No file check — design path validated by agent
    'contracts':     { needs: 'figma-uploaded', check: 'docs/sdlc/phase-ab-reconciliation-report.json' },
    'blueprint':     { needs: 'contracts', check: 'docs/sdlc/phase-e-contract-artifacts.json' },
    'deploy':        { needs: 'blueprint', check: '' },  // Pipeline state checked by orchestrator
  };
  const prereq = prereqs[milestone];
  if (prereq?.check) {
    try {
      const { existsSync } = await import('fs');
      if (!existsSync(prereq.check)) {
        console.error(`  Cannot run '${milestone}' — prerequisite '${prereq.needs}' not yet complete.`);
        console.error(`  Expected: ${prereq.check}`);
        console.error(`  Run: gsd run ${prereq.needs}`);
        process.exit(1);
      }
    } catch { /* fs check failed, proceed anyway */ }
  }

  // V6: run everything inside a Milestone (SQLite state, worktree, budget, auto-lock)
  const useWorktree = options['worktree'] === 'true' || options['worktree'] === '';
  const budgetUsd = options['budget'] ? parseFloat(options['budget']) : 10;
  const review = options['review'] === 'true' || options['review'] === '';
  // v6.1.0: target project root for per-project stack-overrides.md resolution
  const projectRoot = options['project-root'] ?? process.cwd();

  const milestoneOrchestrator = new MilestoneOrchestrator({
    vaultPath,
    parentRepoPath: projectRoot,
    budgetUsd,
    useWorktree,
    baseBranch: options['base-branch'] ?? 'main',
  });

  try {
    const result = await milestoneOrchestrator.run(
      {
        milestoneName: options['project'] ?? milestone,
        description: options['description'] ?? config.description,
        trigger: 'manual',
        sdlcFromPhase: config.sdlcFrom,
        sdlcToPhase: config.sdlcTo,
        projectName: options['project'] ?? 'Untitled',
        projectDescription: options['description'] ?? '',
        designPath: options['design-path'],
        review,
        pipelineFromStage: config.pipelineFrom ?? (milestone === 'full' ? 'blueprint' : undefined),
        dryRun,
      },
      () => new SdlcOrchestrator(vaultPath, projectRoot),
      () => new Orchestrator(vaultPath, projectRoot),
    );

    console.log('');
    console.log('═══════════════════════════════════════════════');
    console.log(`  V6 Milestone ${result.status.toUpperCase()}`);
    console.log('═══════════════════════════════════════════════');
    console.log(`  Milestone:  ${result.milestoneId}`);
    console.log(`  Run ID:     ${result.runId}`);
    console.log(`  Status:     ${result.status}`);
    console.log(`  Slices:     ${result.sliceResults.map((s) => `${s.sliceId}=${s.status}`).join(', ')}`);
    console.log(`  Cost:       $${result.totalCostUsd.toFixed(4)}`);
    console.log(`  Duration:   ${(result.durationMs / 1000).toFixed(1)}s`);
    if (result.error) console.log(`  Error:      ${result.error}`);
    console.log('═══════════════════════════════════════════════');
    console.log('');
    console.log(`  Inspect: gsd query milestone ${result.milestoneId}`);
    if (result.status === 'failed') {
      console.log(`  Triage: gsd forensics --run ${result.runId} --milestone ${result.milestoneId}`);
      process.exit(1);
    }
  } finally {
    milestoneOrchestrator.close();
  }
}

// ── V6 CLI: gsd query ──────────────────────────────────────
async function handleQuery(args: string[]): Promise<void> {
  if (args.length === 0 || args[0] === 'help' || args[0] === '--help') {
    console.log(`
gsd query — V6 headless state API

Usage:
  gsd query milestones                        List all milestones
  gsd query milestone <id>                    Milestone detail + slices
  gsd query slice <id>                        Slice detail + tasks
  gsd query task <id>                         Task detail
  gsd query cost [--since <ISO>]              Cost rollup
  gsd query stuck [--min <N>]                 Stuck-loop patterns
  gsd query decisions <milestoneId>           Decision log for a milestone
  gsd query stack [--project-root <path>]     v6.1.0 — resolved stack context

Options:
  --vault-path <path>    Vault directory (default: ./memory)
  --project-root <path>  Target project for stack (default: cwd)
  --pretty               Pretty JSON (default on)
  --compact              Compact JSON
`);
    return;
  }

  const subject = args[0] as QuerySubject;
  const id = args[1] && !args[1].startsWith('--') ? args[1] : undefined;
  const options = parseOptions(args.slice(id ? 2 : 1));
  const vaultPath = options['vault-path'] ?? './memory';
  const pretty = options['compact'] !== 'true' && options['compact'] !== '';

  // v6.1.0: `stack` subject reads target project root — does not need state.db
  if (subject === 'stack') {
    const result = await runQueryAsync('stack', {
      projectRoot: options['project-root'] ?? process.cwd(),
    });
    console.log(formatQueryResult(result, pretty));
    if (!result.ok) process.exit(1);
    return;
  }

  const dbPath = join(vaultPath, 'state.db');
  if (!existsSync(dbPath)) {
    console.error(JSON.stringify({ subject, ok: false, error: `no state.db at ${dbPath}`, data: null }, null, 2));
    process.exit(1);
  }

  const db = new StateDB(dbPath);
  try {
    const result = runQuery(db, subject, id, {
      since: options['since'],
      minOccurrences: options['min'] ? parseInt(options['min'], 10) : undefined,
    });
    console.log(formatQueryResult(result, pretty));
    if (!result.ok) process.exit(1);
  } finally {
    db.close();
  }
}

// ── V6.1.0 CLI: gsd validate-stack ─────────────────────────
async function handleValidateStack(args: string[]): Promise<void> {
  if (args.length > 0 && (args[0] === 'help' || args[0] === '--help')) {
    console.log(`
gsd validate-stack — scan target project for stack-context leaks

Usage:
  gsd validate-stack [--project-root <path>] [--json] [--fail-on-findings]

Scans every .csproj / .json / .md / .yaml / .xml file under <project-root>
(respecting typical ignore dirs) for .NET framework values that contradict
the resolved PROJECT STACK CONTEXT. For example: if the project declares
net9.0 but a generated artifact contains "net8.0", the validator flags it.

Options:
  --project-root <path>    Target project root (default: cwd)
  --json                   Emit JSON report instead of markdown
  --fail-on-findings       Exit 1 if any findings detected (CI hook)
`);
    return;
  }
  const options = parseOptions(args);
  const projectRoot = options['project-root'] ?? process.cwd();
  const emitJson = options['json'] === 'true' || options['json'] === '';
  const failOnFindings = options['fail-on-findings'] === 'true' || options['fail-on-findings'] === '';

  const context = await getProjectStackContext(projectRoot);
  const report = await validateStackLeaks({ projectRoot, context });

  if (emitJson) {
    console.log(JSON.stringify(report, null, 2));
  } else {
    console.log(formatStackLeakReport(report));
  }

  if (failOnFindings && report.findings.length > 0) {
    process.exit(1);
  }
}

// ── V6 CLI: gsd forensics ──────────────────────────────────
async function handleForensics(args: string[]): Promise<void> {
  if (args.length === 0 || args[0] === 'help' || args[0] === '--help') {
    console.log(`
gsd forensics — V6 triage bundle builder

Usage:
  gsd forensics --run <runId> [--milestone <milestoneId>] [--out <dir>]

Options:
  --run <runId>              (required) Run identifier to bundle
  --milestone <id>           Milestone to snapshot from state.db
  --out <dir>                Output dir (default: ./forensics)
  --vault-path <path>        Vault directory (default: ./memory)
  --obs-root <path>          Observability root (default: <vault>/observability)
`);
    return;
  }

  const options = parseOptions(args);
  const runId = options['run'];
  if (!runId) {
    console.error('--run <runId> is required');
    process.exit(1);
  }
  const vaultPath = options['vault-path'] ?? './memory';
  const obsRoot = options['obs-root'] ?? join(vaultPath, 'observability');
  const outDir = options['out'] ?? './forensics';
  const milestoneId = options['milestone'];

  const dbPath = join(vaultPath, 'state.db');
  const db = existsSync(dbPath) ? new StateDB(dbPath) : null;
  if (!db) {
    console.error(`no state.db at ${dbPath}`);
    process.exit(1);
  }

  try {
    const bundle = await buildForensicsBundle(db, {
      runId,
      milestoneId,
      vaultPath,
      observabilityRoot: obsRoot,
      outputDir: outDir,
      repoPath: process.cwd(),
    });
    console.log('');
    console.log('═══════════════════════════════════════════════');
    console.log('  Forensics Bundle Built');
    console.log('═══════════════════════════════════════════════');
    console.log(`  Run ID:              ${bundle.runId}`);
    console.log(`  Output:              ${bundle.outputPath}`);
    console.log(`  Decision markdown:   ${bundle.summary.decisionsMd}`);
    console.log(`  Session files:       ${bundle.summary.sessionFiles}`);
    console.log(`  Observability files: ${bundle.summary.observabilityFiles}`);
    console.log(`  Git diff bytes:      ${bundle.summary.gitDiffBytes}`);
    console.log(`  DB snapshot:         ${bundle.summary.dbDumpPath ?? '(none)'}`);
    console.log('═══════════════════════════════════════════════');
  } finally {
    db.close();
  }
}

// ── V6 CLI: gsd doc-garden ─────────────────────────────────
async function handleDocGarden(args: string[]): Promise<void> {
  const options = parseOptions(args);
  const vaultPath = options['vault-path'] ?? './memory';
  const skipTools = options['no-tool-check'] === 'true' || options['no-tool-check'] === '';
  console.log(`[doc-garden] scanning ${vaultPath}...`);
  const report = await runDocGardener({
    vaultPath,
    repoRoot: process.cwd(),
    checkToolAvailability: !skipTools,
  });
  console.log(formatDocGardenReport(report));
  if (report.findings.some((f) => f.severity === 'error')) process.exit(1);
}

// ── V6 CLI: gsd harvest ────────────────────────────────────
async function handleHarvest(args: string[]): Promise<void> {
  const options = parseOptions(args);
  const vaultPath = options['vault-path'] ?? './memory';
  const sinceDays = options['since-days'] ? parseInt(options['since-days'], 10) : 7;
  const dbPath = join(vaultPath, 'state.db');
  if (!existsSync(dbPath)) {
    console.error(`no state.db at ${dbPath}`);
    process.exit(1);
  }
  const { StateDB } = await import('./harness/v6/state-db');
  const db = new StateDB(dbPath);
  try {
    const report = await runKnowledgeHarvest({ vaultPath, db, sinceDays });
    console.log('');
    console.log('═══════════════════════════════════════════════');
    console.log('  Knowledge Harvest');
    console.log('═══════════════════════════════════════════════');
    console.log(`  Window:        last ${sinceDays} days`);
    console.log(`  Decisions:     ${report.decisionCount}`);
    console.log(`  Patterns:      ${report.patterns.length}`);
    console.log(`  Anti-patterns: ${report.antiPatterns.length}`);
    console.log(`  Files written:`);
    for (const f of report.outputFiles) console.log(`    - ${f}`);
    console.log('═══════════════════════════════════════════════');
  } finally {
    db.close();
  }
}

// ── V6 CLI: gsd migrate (V5 → V6) ──────────────────────────
async function handleMigrate(args: string[]): Promise<void> {
  const options = parseOptions(args);
  const vaultPath = options['vault-path'] ?? './memory';
  const dryRun = options['dry-run'] === 'true' || options['dry-run'] === '';
  console.log(`[migrate] scanning V5 session files under ${vaultPath}/sessions/ (dry-run=${dryRun})`);
  const report = await migrateV5ToV6({ vaultPath, dryRun });
  console.log('');
  console.log('═══════════════════════════════════════════════');
  console.log('  V5 → V6 Migration');
  console.log('═══════════════════════════════════════════════');
  console.log(`  Files scanned:    ${report.scannedSessionFiles}`);
  console.log(`  Milestones:       ${report.importedMilestones} ${dryRun ? '(dry-run)' : 'imported'}`);
  console.log(`  Skipped:          ${report.skipped.length}`);
  if (report.skipped.length > 0) {
    for (const s of report.skipped.slice(0, 5)) console.log(`    - ${s.file}: ${s.reason}`);
  }
  if (report.createdMilestoneIds.length > 0) {
    console.log(`  IDs:              ${report.createdMilestoneIds.slice(0, 10).join(', ')}${report.createdMilestoneIds.length > 10 ? '...' : ''}`);
  }
  console.log('═══════════════════════════════════════════════');
}

// ── V6 CLI: gsd worktree ───────────────────────────────────
async function handleWorktree(args: string[]): Promise<void> {
  if (args.length === 0 || args[0] === 'help' || args[0] === '--help') {
    console.log(`
gsd worktree — V6 milestone worktree control

Usage:
  gsd worktree status                    Show all milestone worktrees
  gsd worktree prune                     Prune stale git worktree metadata
  gsd worktree teardown <milestoneId>    Remove a milestone worktree

Options:
  --vault-path <path>       Vault directory (default: ./memory)
  --force                   Force removal even if dirty
  --delete-branch           Also delete the milestone's git branch
`);
    return;
  }

  const sub = args[0];
  const options = parseOptions(args.slice(1));
  const vaultPath = options['vault-path'] ?? './memory';
  const dbPath = join(vaultPath, 'state.db');
  if (!existsSync(dbPath)) {
    console.error(`no state.db at ${dbPath}`);
    process.exit(1);
  }
  const db = new StateDB(dbPath);
  const manager = new WorktreeManager(db, { parentRepoPath: process.cwd() });

  try {
    switch (sub) {
      case 'status': {
        const report = await worktreeStatus(db, manager);
        console.log(formatWorktreeStatus(report));
        break;
      }
      case 'prune': {
        const out = await worktreePrune(manager);
        console.log(out || '(nothing to prune)');
        break;
      }
      case 'teardown': {
        const milestoneId = args[1];
        if (!milestoneId || milestoneId.startsWith('--')) {
          console.error('milestone id required: gsd worktree teardown <milestoneId>');
          process.exit(1);
        }
        await worktreeTeardown(manager, milestoneId, {
          force: options['force'] === 'true' || options['force'] === '',
          deleteBranch: options['delete-branch'] === 'true' || options['delete-branch'] === '',
        });
        console.log(`torn down worktree for ${milestoneId}`);
        break;
      }
      default:
        console.error(`unknown worktree subcommand: ${sub}`);
        process.exit(1);
    }
  } finally {
    db.close();
  }
}

async function handlePipeline(args: string[]): Promise<void> {
  if (args[0] !== 'run') {
    console.error(`Unknown pipeline subcommand: ${args[0]}`);
    console.log('Usage: pipeline run [options]');
    process.exit(1);
  }

  // Parse options
  const options = parseOptions(args.slice(1));

  const trigger = (options['trigger'] ?? 'manual') as TriggerType;
  const fromStage = options['from-stage'] as PipelineStage | undefined;
  const dryRun = options['dry-run'] === 'true' || options['dry-run'] === '';
  const vaultPath = options['vault-path'] ?? './memory';

  // Run preflight checks before anything else
  const check = preflight(vaultPath);
  for (const w of check.warnings) console.warn(`  [WARN] ${w}`);
  if (!check.ok) {
    console.error('');
    console.error('  Preflight failed:');
    for (const e of check.errors) console.error(`    ✗ ${e}`);
    console.error('');
    process.exit(1);
  }

  console.log('');
  console.log('═══════════════════════════════════════════════');
  console.log('  GSD Agent Pipeline');
  console.log('═══════════════════════════════════════════════');
  console.log(`  Trigger:    ${trigger}`);
  console.log(`  From stage: ${fromStage ?? '(start)'}`);
  console.log(`  Dry run:    ${dryRun}`);
  console.log(`  Vault:      ${vaultPath}`);
  console.log('═══════════════════════════════════════════════');
  console.log('');

  // v6.1.0: target project root for stack-overrides resolution
  const projectRoot = options['project-root'] ?? process.cwd();
  const orchestrator = new Orchestrator(vaultPath, projectRoot);
  await orchestrator.initialize();

  const finalState = await orchestrator.run({
    trigger,
    fromStage,
    dryRun,
    vaultPath,
  });

  // Print result
  console.log('');
  console.log('═══════════════════════════════════════════════');
  console.log(`  Pipeline ${finalState.status.toUpperCase()}`);
  console.log('═══════════════════════════════════════════════');
  console.log(`  Run ID:     ${finalState.runId}`);
  console.log(`  Status:     ${finalState.status}`);
  console.log(`  Stage:      ${finalState.currentStage}`);
  console.log(`  Decisions:  ${finalState.decisions.length}`);
  console.log(`  Cost:       $${finalState.costAccumulator.reduce((s, e) => s + e.estimatedCostUsd, 0).toFixed(2)}`);

  if (finalState.deployRecord) {
    console.log(`  Deploy:     ${finalState.deployRecord.success ? 'SUCCESS' : 'FAILED'}`);
    console.log(`  Env:        ${finalState.deployRecord.environment}`);
    if (finalState.deployRecord.rollbackExecuted) {
      console.log(`  Rollback:   EXECUTED`);
    }
  }

  console.log('═══════════════════════════════════════════════');
  console.log('');

  if (finalState.status === 'failed' || finalState.status === 'paused') {
    console.log(`Resume with: npx ts-node src/index.ts pipeline run --from-stage ${finalState.currentStage}`);
    process.exit(1);
  }
}

async function handleSdlc(args: string[]): Promise<void> {
  if (args[0] !== 'run') {
    console.error(`Unknown sdlc subcommand: ${args[0]}`);
    console.log('Usage: sdlc run [options]');
    process.exit(1);
  }

  const options = parseOptions(args.slice(1));

  const trigger = (options['trigger'] ?? 'manual') as 'manual' | 'schedule';
  const fromPhase = options['from-phase'] as SdlcPhase | undefined;
  const vaultPath = options['vault-path'] ?? './memory';
  const projectName = options['project'] ?? 'Untitled Project';
  const projectDescription = options['description'] ?? '';
  const designPath = options['design-path'];

  // Run preflight checks
  const check = preflight(vaultPath);
  for (const w of check.warnings) console.warn(`  [WARN] ${w}`);
  if (!check.ok) {
    console.error('\n  Preflight failed:');
    for (const e of check.errors) console.error(`    ✗ ${e}`);
    process.exit(1);
  }

  console.log('');
  console.log('═══════════════════════════════════════════════');
  console.log('  GSD SDLC Lifecycle (Phases A-G)');
  console.log('═══════════════════════════════════════════════');
  console.log(`  Trigger:    ${trigger}`);
  console.log(`  From phase: ${fromPhase ?? 'phase-a (start)'}`);
  console.log(`  Project:    ${projectName}`);
  console.log(`  Design:     ${designPath ?? '(auto-detect)'}`);
  console.log(`  Vault:      ${vaultPath}`);
  console.log('═══════════════════════════════════════════════');
  console.log('');

  // v6.1.0: target project root for stack-overrides resolution
  const sdlcProjectRoot = options['project-root'] ?? process.cwd();
  const orchestrator = new SdlcOrchestrator(vaultPath, sdlcProjectRoot);
  await orchestrator.initialize();

  const finalState = await orchestrator.run({
    trigger,
    fromPhase,
    projectName,
    projectDescription,
    designPath,
    vaultPath,
  });

  console.log('');
  console.log('═══════════════════════════════════════════════');
  console.log(`  SDLC ${finalState.status.toUpperCase()}`);
  console.log('═══════════════════════════════════════════════');
  console.log(`  Run ID:     ${finalState.sdlcRunId}`);
  console.log(`  Status:     ${finalState.status}`);
  console.log(`  Phase:      ${finalState.currentPhase}`);
  console.log(`  Decisions:  ${finalState.decisions.length}`);
  console.log('═══════════════════════════════════════════════');
  console.log('');

  if (finalState.status === 'failed' || finalState.status === 'paused') {
    console.log(`Resume with: npx ts-node src/index.ts sdlc run --from-phase ${finalState.currentPhase}`);
    process.exit(1);
  }
}

function parseOptions(args: string[]): Record<string, string> {
  const options: Record<string, string> = {};

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg.startsWith('--')) {
      const key = arg.substring(2);
      const next = args[i + 1];
      if (next && !next.startsWith('--')) {
        options[key] = next;
        i++;
      } else {
        options[key] = 'true';
      }
    }
  }

  return options;
}

function printUsage(): void {
  console.log(`
GSD V6 — Goal Spec Done

Usage:
  gsd run <milestone> [options]           Run a milestone (V6 hierarchy)
  gsd query <subject> [id] [options]      Headless JSON state query
  gsd forensics --run <runId> [options]   Build triage bundle
  gsd worktree status|prune|teardown      Milestone worktree control
  gsd doc-garden [options]                Scan vault notes for drift (Tier 4.6)
  gsd harvest [--since-days N]            Mine decisions/ for patterns (Tier 5.3)
  gsd migrate [--dry-run]                 Import V5 session files into V6 state.db
  gsd validate-stack [options]            v6.1.0 — scan for stack-context leaks
  gsd status                              Current run summary
  gsd pipeline run [options]              Legacy slice-level pipeline
  gsd sdlc run [options]                  Legacy phase-level SDLC

Milestones (for \`gsd run\`):
  requirements      Phase A+B: gather requirements + architecture
  figma-prompts     Generate Figma Make prompts for interfaces
  figma-uploaded    Phase C: validate Figma deliverables + reconcile
  contracts         Phase D+E: freeze blueprint + SCG1 contracts
  blueprint         Phase F: code pipeline (review, gate, e2e)
  deploy            Phase G: alpha deploy + post-deploy validation
  full              Everything: requirements → alpha deploy

Run options:
  --project <name>          Project name (used as milestone display name)
  --description <text>      Project description
  --design-path <path>      Path to Figma Make output
  --vault-path <path>       Vault directory (default: ./memory)
  --dry-run                 Skip deployment
  --worktree                Run in an isolated git worktree per milestone
  --base-branch <branch>    Base branch for worktree (default: main)
  --budget <usd>            Milestone budget for cost routing (default: 10)
  --project-root <path>     Target project root for docs/gsd/stack-overrides.md
                            (default: current working directory). Lets GSD honor
                            per-project backend framework (net8/net9/net10).
  --review                  Include SDLC review pass

V6 subcommand help:
  gsd query --help          Query state.db
  gsd forensics --help      Bundle decisions/observability/git diff for triage
  gsd worktree --help       Inspect or clean up milestone worktrees

Examples:
  # New project — SQLite state + markdown narrative
  gsd run requirements --project "ClientPortal" --description "Multi-tenant SaaS"

  # Full run in an isolated git worktree with a $25 budget
  gsd run full --project "ClientPortal" --description "..." --worktree --budget 25

  # Inspect state
  gsd query milestones
  gsd query milestone M07XY4
  gsd query cost --since 2026-04-01

  # After a failure
  gsd forensics --run <runId> --milestone M07XY4
  gsd worktree status
`);
}

main().catch((err) => {
  console.error('Fatal error:', err instanceof Error ? err.message : String(err));
  process.exit(1);
});
