import * as vscode from 'vscode';
import { GsdDataService } from './parsers/gsd-data-service';
import { EngineStatusProvider } from './providers/engine-status-provider';
import { RequirementsProvider } from './providers/requirements-provider';
import { AgentsProvider } from './providers/agents-provider';
import { CostsProvider } from './providers/costs-provider';
import { StatusBarProvider } from './providers/status-bar-provider';
import { registerCommands } from './commands/gsd-commands';

export function activate(context: vscode.ExtensionContext): void {
  const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
  if (!workspaceFolder) {
    vscode.window.showWarningMessage('GSD: No workspace folder open.');
    return;
  }

  const workspaceRoot = workspaceFolder.uri.fsPath;

  // Core data service — watches .gsd/ and provides typed snapshots
  const dataService = new GsdDataService(workspaceRoot);
  context.subscriptions.push(dataService);
  dataService.start();

  // Sidebar tree views
  const engineStatusProvider = new EngineStatusProvider(dataService);
  const requirementsProvider = new RequirementsProvider(dataService);
  const agentsProvider = new AgentsProvider(dataService);
  const costsProvider = new CostsProvider(dataService);

  context.subscriptions.push(
    vscode.window.registerTreeDataProvider('gsd-engine-status', engineStatusProvider),
    vscode.window.registerTreeDataProvider('gsd-requirements', requirementsProvider),
    vscode.window.registerTreeDataProvider('gsd-agents', agentsProvider),
    vscode.window.registerTreeDataProvider('gsd-costs', costsProvider),
  );

  // Status bar
  const statusBar = new StatusBarProvider(dataService);
  context.subscriptions.push(statusBar);

  // Commands
  registerCommands(context, dataService, requirementsProvider);

  // Auto-open dashboard if configured
  if (vscode.workspace.getConfiguration('gsd').get<boolean>('autoOpenDashboard', false)) {
    vscode.commands.executeCommand('gsd.openDashboard');
  }

  // Log activation
  const outputChannel = vscode.window.createOutputChannel('GSD Engine');
  outputChannel.appendLine(`GSD extension activated. Workspace: ${workspaceRoot}`);
  outputChannel.appendLine(`Watching: ${dataService.getGsdRoot()}`);

  if (!dataService.isInitialized()) {
    vscode.window.showInformationMessage(
      'GSD: No .gsd directory found. Run gsd-converge to initialize.',
      'Run Assessment'
    ).then(action => {
      if (action === 'Run Assessment') {
        vscode.commands.executeCommand('gsd.runAssess');
      }
    });
  }
}

export function deactivate(): void {
  // Cleanup handled by disposables
}
