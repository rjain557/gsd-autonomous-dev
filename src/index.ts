// ═══════════════════════════════════════════════════════════
// GSD Agent System — CLI Entry Point
// Preserves existing CLI commands, adds `pipeline` command.
// ═══════════════════════════════════════════════════════════

import { Orchestrator } from './harness/orchestrator';
import type { PipelineStage, TriggerType } from './harness/types';

async function main(): Promise<void> {
  const args = process.argv.slice(2);

  if (args.length === 0 || args[0] === 'help' || args[0] === '--help') {
    printUsage();
    return;
  }

  // Route to the correct command
  switch (args[0]) {
    case 'pipeline':
      await handlePipeline(args.slice(1));
      break;
    default:
      console.error(`Unknown command: ${args[0]}`);
      printUsage();
      process.exit(1);
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
GSD Agent System — CLI

Usage:
  npx ts-node src/index.ts pipeline run [options]

Options:
  --trigger <manual|schedule|webhook>   Pipeline trigger type (default: manual)
  --from-stage <stage>                  Resume from stage: blueprint|review|remediate|gate|e2e|deploy|post-deploy
  --dry-run                             Run full pipeline but skip deploy
  --vault-path <path>                   Path to vault/memory directory (default: ./memory)

Examples:
  # Full pipeline run
  npx ts-node src/index.ts pipeline run --trigger manual

  # Dry run (no deploy)
  npx ts-node src/index.ts pipeline run --trigger manual --dry-run

  # Resume from failed stage
  npx ts-node src/index.ts pipeline run --from-stage gate

  # Custom vault path
  npx ts-node src/index.ts pipeline run --vault-path ./my-vault
`);
}

main().catch((err) => {
  console.error('Fatal error:', err instanceof Error ? err.message : String(err));
  process.exit(1);
});
