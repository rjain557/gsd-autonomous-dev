import * as vscode from 'vscode';
import { GsdDataService } from '../parsers/gsd-data-service';
import { EngineStatus, HealthData } from '../types';

export class EngineStatusProvider implements vscode.TreeDataProvider<StatusItem> {
  private readonly _onDidChangeTreeData = new vscode.EventEmitter<StatusItem | undefined>();
  readonly onDidChangeTreeData = this._onDidChangeTreeData.event;

  constructor(private dataService: GsdDataService) {
    dataService.onDidChange(() => this._onDidChangeTreeData.fire(undefined));
  }

  getTreeItem(element: StatusItem): vscode.TreeItem {
    return element;
  }

  getChildren(): StatusItem[] {
    const snap = this.dataService.getSnapshot();

    if (!this.dataService.isInitialized()) {
      return [new StatusItem('No .gsd directory found', '', 'warning')];
    }

    const items: StatusItem[] = [];
    const health = snap.health;
    const engine = snap.engine;

    // Health score with color-coded icon
    if (health) {
      const icon = health.health_score >= 90 ? 'pass' :
                   health.health_score >= 50 ? 'warning' : 'error';
      items.push(new StatusItem(
        `Health: ${health.health_score.toFixed(1)}%`,
        `${health.satisfied}/${health.total_requirements} requirements satisfied`,
        icon
      ));
      items.push(new StatusItem(
        `Requirements`,
        `${health.satisfied} done · ${health.partial} partial · ${health.not_started} pending`,
        'list-tree'
      ));
      items.push(new StatusItem(
        `Iteration: ${health.iteration}`,
        '',
        'symbol-number'
      ));
    } else {
      items.push(new StatusItem('Health data not available', 'Run gsd-converge to start', 'info'));
    }

    // Engine state
    if (engine) {
      const stateIcon = this.stateIcon(engine.state);
      items.push(new StatusItem(
        `Engine: ${engine.state.toUpperCase()}`,
        engine.phase ? `Phase: ${engine.phase} · Agent: ${engine.agent}` : '',
        stateIcon
      ));

      if (engine.elapsed_minutes > 0) {
        items.push(new StatusItem(
          `Elapsed: ${engine.elapsed_minutes}m`,
          `Started: ${this.formatTime(engine.started_at)}`,
          'clock'
        ));
      }

      if (engine.sleep_until) {
        items.push(new StatusItem(
          `Sleeping until ${this.formatTime(engine.sleep_until)}`,
          engine.sleep_reason || '',
          'debug-pause'
        ));
      }

      if (engine.last_error) {
        items.push(new StatusItem(
          `Last Error`,
          engine.last_error,
          'error'
        ));
      }

      if (engine.errors_this_iteration > 0) {
        items.push(new StatusItem(
          `Errors this iteration: ${engine.errors_this_iteration}`,
          engine.recovered_from_error ? 'Recovered' : 'Not recovered',
          'bug'
        ));
      }
    }

    // Costs summary
    const costs = snap.costs;
    if (costs) {
      items.push(new StatusItem(
        `Cost: $${costs.total_cost_usd.toFixed(2)}`,
        `${costs.total_calls} API calls`,
        'credit-card'
      ));
    }

    return items;
  }

  private stateIcon(state: string): string {
    const map: Record<string, string> = {
      starting: 'loading~spin',
      running: 'play',
      sleeping: 'debug-pause',
      stalled: 'warning',
      completed: 'check',
      converged: 'pass-filled',
    };
    return map[state] || 'circle-outline';
  }

  private formatTime(iso: string): string {
    try {
      return new Date(iso).toLocaleTimeString();
    } catch {
      return iso;
    }
  }
}

export class StatusItem extends vscode.TreeItem {
  constructor(label: string, detail: string, icon: string) {
    super(label, vscode.TreeItemCollapsibleState.None);
    this.description = detail;
    this.iconPath = new vscode.ThemeIcon(icon);
    this.tooltip = detail || label;
  }
}
