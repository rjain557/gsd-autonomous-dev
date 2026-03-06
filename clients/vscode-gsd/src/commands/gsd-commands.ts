import * as vscode from 'vscode';
import * as path from 'path';
import { GsdDataService } from '../parsers/gsd-data-service';
import { DashboardPanel } from '../webview/dashboard-panel';
import { RequirementsProvider } from '../providers/requirements-provider';

/**
 * Registers all GSD commands:
 * - gsd.openDashboard
 * - gsd.startConverge / stopConverge
 * - gsd.runAssess / runBlueprint
 * - gsd.showCosts
 * - gsd.refreshAll
 * - gsd.openRequirement
 * - gsd.filterRequirements
 */
export function registerCommands(
  context: vscode.ExtensionContext,
  dataService: GsdDataService,
  requirementsProvider: RequirementsProvider,
): void {
  const workspaceRoot = dataService.getWorkspaceRoot();

  // Find scripts path
  const scriptsPath = resolveScriptsPath(workspaceRoot);
  const outputChannel = vscode.window.createOutputChannel('GSD Engine');

  // Dashboard
  context.subscriptions.push(
    vscode.commands.registerCommand('gsd.openDashboard', () => {
      DashboardPanel.createOrShow(context.extensionUri, dataService);
    })
  );

  // Start convergence
  context.subscriptions.push(
    vscode.commands.registerCommand('gsd.startConverge', async () => {
      const options = await vscode.window.showQuickPick([
        { label: 'Full Convergence', description: 'Run complete convergence loop', args: '' },
        { label: 'Skip Research', description: 'Skip Gemini/Codex research phase', args: '-SkipResearch' },
        { label: 'Dry Run', description: 'Preview without executing', args: '-DryRun' },
        { label: 'Incremental', description: 'Add new requirements from updated specs', args: '-Incremental' },
        { label: 'Force Code Review', description: 'Force review even at 100%', args: '-ForceCodeReview' },
      ], { placeHolder: 'Select convergence mode' });

      if (!options) { return; }

      runGsdScript(outputChannel, scriptsPath, 'convergence-loop.ps1', options.args);
    })
  );

  // Stop convergence
  context.subscriptions.push(
    vscode.commands.registerCommand('gsd.stopConverge', async () => {
      const confirm = await vscode.window.showWarningMessage(
        'Stop the convergence loop?',
        { modal: true },
        'Stop'
      );
      if (confirm === 'Stop') {
        const engine = dataService.getSnapshot().engine;
        if (engine?.pid) {
          const terminal = vscode.window.createTerminal('GSD Stop');
          // Cross-platform process kill
          terminal.sendText(
            process.platform === 'win32'
              ? `Stop-Process -Id ${engine.pid} -Force`
              : `kill ${engine.pid}`
          );
          terminal.show();
        } else {
          vscode.window.showInformationMessage('No running engine process found.');
        }
      }
    })
  );

  // Assess
  context.subscriptions.push(
    vscode.commands.registerCommand('gsd.runAssess', () => {
      runGsdScript(outputChannel, scriptsPath, 'gsd-profile-functions.ps1', 'gsd-assess');
    })
  );

  // Blueprint
  context.subscriptions.push(
    vscode.commands.registerCommand('gsd.runBlueprint', () => {
      runGsdScript(outputChannel, scriptsPath, 'install-gsd-blueprint.ps1', '');
    })
  );

  // Show costs
  context.subscriptions.push(
    vscode.commands.registerCommand('gsd.showCosts', () => {
      const costs = dataService.getSnapshot().costs;
      if (!costs) {
        vscode.window.showInformationMessage('No cost data available yet.');
        return;
      }

      outputChannel.clear();
      outputChannel.appendLine('=== GSD Cost Summary ===');
      outputChannel.appendLine(`Total: $${costs.total_cost_usd.toFixed(2)} (${costs.total_calls} calls)`);
      outputChannel.appendLine('');

      // By agent
      const byAgent = new Map<string, number>();
      for (const run of costs.runs) {
        for (const d of run.details) {
          byAgent.set(d.agent, (byAgent.get(d.agent) || 0) + d.cost_usd);
        }
      }
      for (const [agent, cost] of byAgent) {
        outputChannel.appendLine(`  ${agent}: $${cost.toFixed(2)}`);
      }
      outputChannel.show();
    })
  );

  // Refresh
  context.subscriptions.push(
    vscode.commands.registerCommand('gsd.refreshAll', () => {
      dataService.refresh();
      vscode.window.showInformationMessage('GSD data refreshed.');
    })
  );

  // Open requirement
  context.subscriptions.push(
    vscode.commands.registerCommand('gsd.openRequirement', async () => {
      const matrix = dataService.getSnapshot().matrix;
      if (!matrix) {
        vscode.window.showInformationMessage('No requirements data.');
        return;
      }

      const items = matrix.requirements.map(r => ({
        label: `${r.id}: ${r.description}`,
        description: `${r.status} · ${r.priority} · ${r.pattern}`,
        detail: r.satisfied_by.length > 0 ? `Files: ${r.satisfied_by.join(', ')}` : `Spec: ${r.spec_doc}`,
        requirement: r,
      }));

      const picked = await vscode.window.showQuickPick(items, {
        placeHolder: 'Search requirements...',
        matchOnDescription: true,
        matchOnDetail: true,
      });

      if (picked) {
        const r = picked.requirement;
        const target = r.satisfied_by.length > 0 ? r.satisfied_by[0] : r.spec_doc;
        if (target) {
          const uri = vscode.Uri.file(path.join(workspaceRoot, target));
          vscode.window.showTextDocument(uri);
        }
      }
    })
  );

  // Filter requirements
  context.subscriptions.push(
    vscode.commands.registerCommand('gsd.filterRequirements', async () => {
      const filter = await vscode.window.showQuickPick([
        { label: 'All', value: 'all' as const },
        { label: 'Satisfied', value: 'satisfied' as const },
        { label: 'Partial', value: 'partial' as const },
        { label: 'Not Started', value: 'not_started' as const },
      ], { placeHolder: 'Filter requirements by status' });

      if (filter) {
        requirementsProvider.setFilter(filter.value);
      }
    })
  );
}

function resolveScriptsPath(workspaceRoot: string): string {
  // Check configured path first
  const configured = vscode.workspace.getConfiguration('gsd').get<string>('scriptsPath', '');
  if (configured) { return configured; }

  // Auto-detect: look for scripts/ in workspace root or parent
  const candidates = [
    path.join(workspaceRoot, 'scripts'),
    path.join(workspaceRoot, '..', 'gsd-autonomous-dev', 'scripts'),
  ];

  for (const candidate of candidates) {
    try {
      const fs = require('fs');
      if (fs.existsSync(path.join(candidate, 'convergence-loop.ps1'))) {
        return candidate;
      }
    } catch {
      // continue
    }
  }

  return path.join(workspaceRoot, 'scripts');
}

function runGsdScript(outputChannel: vscode.OutputChannel, scriptsPath: string, script: string, args: string): void {
  const terminal = vscode.window.createTerminal({
    name: `GSD: ${script}`,
    cwd: path.dirname(scriptsPath),
  });

  const scriptPath = path.join(scriptsPath, script);
  const isWindows = process.platform === 'win32';

  if (isWindows) {
    terminal.sendText(`powershell -ExecutionPolicy Bypass -File "${scriptPath}" ${args}`.trim());
  } else {
    terminal.sendText(`pwsh -File "${scriptPath}" ${args}`.trim());
  }

  terminal.show();
  outputChannel.appendLine(`[${new Date().toLocaleTimeString()}] Started: ${script} ${args}`);
}
