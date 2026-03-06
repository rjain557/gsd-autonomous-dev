import * as vscode from 'vscode';
import { GsdDataService } from '../parsers/gsd-data-service';

/**
 * Status bar item showing:  GSD: 67% | Iter 3 | Execute (codex) | $2.45
 * Click opens the dashboard.
 */
export class StatusBarProvider implements vscode.Disposable {
  private item: vscode.StatusBarItem;
  private disposables: vscode.Disposable[] = [];

  constructor(private dataService: GsdDataService) {
    this.item = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
    this.item.command = 'gsd.openDashboard';
    this.item.name = 'GSD Engine Status';

    this.disposables.push(
      dataService.onDidChange(() => this.update()),
      this.item
    );

    this.update();

    if (vscode.workspace.getConfiguration('gsd').get<boolean>('showStatusBar', true)) {
      this.item.show();
    }
  }

  private update(): void {
    const snap = this.dataService.getSnapshot();

    if (!this.dataService.isInitialized()) {
      this.item.text = '$(circle-outline) GSD: Not initialized';
      this.item.tooltip = 'No .gsd directory found. Run gsd-converge to start.';
      return;
    }

    const parts: string[] = [];
    const tooltipParts: string[] = [];

    // Health
    const health = snap.health;
    if (health) {
      const icon = health.health_score >= 90 ? '$(pass-filled)' :
                   health.health_score >= 50 ? '$(warning)' : '$(error)';
      parts.push(`${icon} ${health.health_score.toFixed(0)}%`);
      tooltipParts.push(
        `Health: ${health.health_score.toFixed(1)}%`,
        `${health.satisfied}/${health.total_requirements} satisfied`,
        `${health.partial} partial, ${health.not_started} pending`
      );
    }

    // Engine state
    const engine = snap.engine;
    if (engine) {
      const stateIcons: Record<string, string> = {
        running: '$(loading~spin)',
        sleeping: '$(debug-pause)',
        stalled: '$(alert)',
        converged: '$(check-all)',
        completed: '$(check)',
        starting: '$(loading~spin)',
      };
      const stateIcon = stateIcons[engine.state] || '$(circle-outline)';

      if (engine.state === 'running') {
        parts.push(`Iter ${engine.iteration}`);
        parts.push(`${engine.phase} (${engine.agent})`);
        tooltipParts.push(`Phase: ${engine.phase}`, `Agent: ${engine.agent}`, `Attempt: ${engine.attempt}`);
      } else if (engine.state === 'sleeping') {
        parts.push(`${stateIcon} Sleeping`);
        if (engine.sleep_reason) { tooltipParts.push(`Reason: ${engine.sleep_reason}`); }
      } else if (engine.state === 'converged') {
        parts.push('$(check-all) CONVERGED');
      } else {
        parts.push(`${stateIcon} ${engine.state}`);
      }

      if (engine.elapsed_minutes > 0) {
        tooltipParts.push(`Elapsed: ${engine.elapsed_minutes}m`);
      }

      if (engine.last_error) {
        tooltipParts.push(`Error: ${engine.last_error}`);
      }
    }

    // Costs
    const costs = snap.costs;
    if (costs && costs.total_cost_usd > 0) {
      parts.push(`$${costs.total_cost_usd.toFixed(2)}`);
      tooltipParts.push(`Total cost: $${costs.total_cost_usd.toFixed(2)} (${costs.total_calls} calls)`);
    }

    this.item.text = `GSD: ${parts.join(' | ')}`;
    this.item.tooltip = tooltipParts.join('\n');

    // Background color for critical states
    if (engine?.state === 'stalled') {
      this.item.backgroundColor = new vscode.ThemeColor('statusBarItem.errorBackground');
    } else if (engine?.state === 'converged') {
      this.item.backgroundColor = undefined;
    } else {
      this.item.backgroundColor = undefined;
    }
  }

  dispose(): void {
    this.disposables.forEach(d => d.dispose());
  }
}
