// ═══════════════════════════════════════════════════════════
// GSD Agent System — CLI Entry Point
// Preserves existing CLI commands, adds `pipeline` command.
// ═══════════════════════════════════════════════════════════

import { Orchestrator } from './harness/orchestrator';
import { SdlcOrchestrator } from './harness/sdlc-orchestrator';
import type { PipelineStage, TriggerType } from './harness/types';
import type { SdlcPhase } from './harness/sdlc-types';
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
      execFileSync(cli.name, ['--version'], { timeout: 10_000, stdio: 'pipe' });
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
  let semgrepFound = false;
  try {
    execFileSync('semgrep', ['--version'], { timeout: 10_000, stdio: 'pipe' });
    semgrepFound = true;
  } catch {
    // Try python module invocation (Windows PATH workaround)
    try {
      execFileSync('python', ['-m', 'semgrep', '--version'], { timeout: 10_000, stdio: 'pipe' });
      semgrepFound = true;
    } catch {
      try {
        execFileSync('python3', ['-m', 'semgrep', '--version'], { timeout: 10_000, stdio: 'pipe' });
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
  console.log('  GSD Project Status');
  console.log('═══════════════════════════════════════════════');

  // Try to load SDLC state
  try {
    const { VaultAdapter } = await import('./harness/vault-adapter');
    const vault = new VaultAdapter(vaultPath);
    const note = await vault.read('sessions/sdlc-state-latest.json');
    const state = JSON.parse(note.body);

    const milestoneMap: Record<string, string> = {
      'phase-a': 'requirements', 'phase-b': 'requirements',
      'phase-c': 'figma-uploaded', 'phase-ab-reconcile': 'figma-uploaded',
      'phase-d': 'contracts', 'phase-e': 'contracts',
      'pipeline': 'blueprint/deploy',
    };

    console.log(`  Run ID:     ${state.sdlcRunId}`);
    console.log(`  Status:     ${state.status}`);
    console.log(`  Phase:      ${state.currentPhase}`);
    console.log(`  Milestone:  ${milestoneMap[state.currentPhase] ?? 'unknown'}`);
    console.log('');
    console.log('  Completed:');
    if (state.intakePack) console.log('    ✓ Phase A — Requirements (Intake Pack)');
    if (state.architecturePack) console.log('    ✓ Phase B — Architecture Pack');
    if (state.figmaDeliverables) console.log(`    ✓ Phase C — Figma (${state.figmaDeliverables.completeness ?? '?'}/12 deliverables)`);
    if (state.reconciliationReport) console.log(`    ✓ Phase A/B Reconcile (alignment: ${state.reconciliationReport.alignmentScore ?? '?'}%)`);
    if (state.frozenBlueprint) console.log(`    ✓ Phase D — Blueprint Frozen (${state.frozenBlueprint.frozenAt ?? ''})`);
    if (state.contractArtifacts) console.log(`    ✓ Phase E — SCG1 ${state.contractArtifacts.scg1Passed ? 'PASSED' : 'FAILED'} (${state.contractArtifacts.endpoints ?? '?'} endpoints, ${state.contractArtifacts.storedProcedures ?? '?'} SPs)`);
    console.log('');

    // Suggest next step
    const nextMilestone: Record<string, string> = {
      'phase-a': 'gsd run requirements', 'phase-b': 'gsd run figma-prompts',
      'phase-c': 'gsd run figma-uploaded', 'phase-ab-reconcile': 'gsd run contracts',
      'phase-d': 'gsd run contracts', 'phase-e': 'gsd run blueprint',
      'pipeline': 'gsd run deploy',
    };
    if (state.status === 'complete') {
      console.log('  All phases complete!');
    } else {
      console.log(`  Next: ${nextMilestone[state.currentPhase] ?? 'gsd run full'}`);
    }
  } catch {
    console.log('  No SDLC state found. Start with:');
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

  // Run SDLC phases if needed
  if (config.sdlcFrom) {
    const sdlcOrchestrator = new SdlcOrchestrator(vaultPath);
    await sdlcOrchestrator.initialize();

    const sdlcResult = await sdlcOrchestrator.run({
      trigger: 'manual',
      fromPhase: config.sdlcFrom,
      projectName: options['project'] ?? 'Untitled',
      projectDescription: options['description'] ?? '',
      designPath: options['design-path'],
      vaultPath,
    });

    console.log(`[GSD] SDLC phases: ${sdlcResult.status}`);

    if (sdlcResult.status === 'failed') {
      console.error(`\nSDLC failed at phase: ${sdlcResult.currentPhase}`);
      console.log(`Resume: gsd run ${milestone} --from-phase ${sdlcResult.currentPhase}`);
      process.exit(1);
    }

    // If milestone stops before pipeline, we're done
    if (config.sdlcTo && !config.pipelineFrom && milestone !== 'full') {
      console.log('\n  SDLC phases complete. Next milestone ready.');
      return;
    }
  }

  // Run pipeline if needed
  if (config.pipelineFrom || milestone === 'full') {
    const pipelineOrchestrator = new Orchestrator(vaultPath);
    await pipelineOrchestrator.initialize();

    const pipelineResult = await pipelineOrchestrator.run({
      trigger: 'manual',
      fromStage: config.pipelineFrom,
      dryRun,
      vaultPath,
    });

    console.log('');
    console.log('═══════════════════════════════════════════════');
    console.log(`  GSD ${pipelineResult.status.toUpperCase()}`);
    console.log('═══════════════════════════════════════════════');
    console.log(`  Status:     ${pipelineResult.status}`);
    console.log(`  Stage:      ${pipelineResult.currentStage}`);
    console.log(`  Decisions:  ${pipelineResult.decisions.length}`);
    console.log(`  Cost:       $${pipelineResult.costAccumulator.reduce((s, e) => s + e.estimatedCostUsd, 0).toFixed(2)}`);
    console.log('═══════════════════════════════════════════════');

    if (pipelineResult.status === 'failed' || pipelineResult.status === 'paused') {
      console.log(`\nResume: gsd run blueprint --from-stage ${pipelineResult.currentStage}`);
      process.exit(1);
    }
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

  const orchestrator = new Orchestrator(vaultPath);
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

  const orchestrator = new SdlcOrchestrator(vaultPath);
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
GSD Agent System — Goal Spec Done

Usage:
  npx ts-node src/index.ts run <milestone> [options]

Milestones (tell it where you are):
  requirements      Phase A+B: gather requirements + architecture
  figma-prompts     Generate Figma Make prompts for interfaces
  figma-uploaded    Phase C: validate Figma deliverables + reconcile
  contracts         Phase D+E: freeze blueprint + SCG1 contracts
  blueprint         Phase F: code pipeline (review, gate, e2e)
  deploy            Phase G: alpha deploy + post-deploy validation
  full              Everything: requirements → alpha deploy

Options:
  --project <name>          Project name
  --description <text>      Project description
  --design-path <path>      Path to Figma Make output
  --vault-path <path>       Vault directory (default: ./memory)
  --dry-run                 Skip deployment

Examples:
  # New project — start with requirements
  gsd run requirements --project "ClientPortal" --description "Multi-tenant SaaS"

  # Figma designs done — validate and reconcile
  gsd run figma-uploaded --design-path design/web/v1/src/

  # Generate contracts
  gsd run contracts

  # Run code pipeline
  gsd run blueprint

  # Deploy to alpha
  gsd run deploy

  # Full end-to-end
  gsd run full --project "ClientPortal" --description "Multi-tenant SaaS"

Legacy commands:
  pipeline run [options]    Direct pipeline access (Phase F-G only)
  sdlc run [options]        Direct SDLC orchestrator access
`);
}

main().catch((err) => {
  console.error('Fatal error:', err instanceof Error ? err.message : String(err));
  process.exit(1);
});
