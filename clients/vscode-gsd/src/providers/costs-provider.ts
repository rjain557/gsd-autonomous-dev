import * as vscode from 'vscode';
import { GsdDataService } from '../parsers/gsd-data-service';
import { CostDetail, CostRun } from '../types';

type TreeNode = CostRunItem | CostDetailItem;

/** Shows token cost breakdown by run and agent */
export class CostsProvider implements vscode.TreeDataProvider<TreeNode> {
  private readonly _onDidChangeTreeData = new vscode.EventEmitter<TreeNode | undefined>();
  readonly onDidChangeTreeData = this._onDidChangeTreeData.event;

  constructor(private dataService: GsdDataService) {
    dataService.onDidChange(() => this._onDidChangeTreeData.fire(undefined));
  }

  getTreeItem(element: TreeNode): vscode.TreeItem {
    return element;
  }

  getChildren(element?: TreeNode): TreeNode[] {
    const costs = this.dataService.getSnapshot().costs;

    if (!costs) {
      return [new CostRunItem(null, 0)];
    }

    if (!element) {
      // Show summary at top, then each run
      const items: TreeNode[] = [];

      // Aggregate by agent
      const byAgent = new Map<string, { tokens_in: number; tokens_out: number; cost: number; calls: number }>();
      for (const run of costs.runs) {
        for (const d of run.details) {
          const agg = byAgent.get(d.agent) || { tokens_in: 0, tokens_out: 0, cost: 0, calls: 0 };
          agg.tokens_in += d.tokens_in;
          agg.tokens_out += d.tokens_out;
          agg.cost += d.cost_usd;
          agg.calls += 1;
          byAgent.set(d.agent, agg);
        }
      }

      // Agent summaries
      for (const [agent, agg] of byAgent) {
        const item = new vscode.TreeItem(
          `${agent}: $${agg.cost.toFixed(2)}`,
          vscode.TreeItemCollapsibleState.None
        );
        item.description = `${this.formatTokens(agg.tokens_in)} in · ${this.formatTokens(agg.tokens_out)} out · ${agg.calls} calls`;
        item.iconPath = new vscode.ThemeIcon('credit-card');
        items.push(item as TreeNode);
      }

      // Total
      const totalItem = new vscode.TreeItem(
        `Total: $${costs.total_cost_usd.toFixed(2)}`,
        vscode.TreeItemCollapsibleState.None
      );
      totalItem.description = `${costs.total_calls} API calls across ${costs.runs.length} runs`;
      totalItem.iconPath = new vscode.ThemeIcon('graph');
      items.unshift(totalItem as TreeNode);

      // Individual runs (collapsible)
      for (let i = costs.runs.length - 1; i >= 0; i--) {
        items.push(new CostRunItem(costs.runs[i], i + 1));
      }

      return items;
    }

    if (element instanceof CostRunItem && element.run) {
      return element.run.details.map(d => new CostDetailItem(d));
    }

    return [];
  }

  private formatTokens(n: number): string {
    if (n >= 1_000_000) { return `${(n / 1_000_000).toFixed(1)}M`; }
    if (n >= 1_000) { return `${(n / 1_000).toFixed(1)}K`; }
    return `${n}`;
  }
}

class CostRunItem extends vscode.TreeItem {
  run: CostRun | null;

  constructor(run: CostRun | null, index: number) {
    if (!run) {
      super('No cost data available', vscode.TreeItemCollapsibleState.None);
      this.iconPath = new vscode.ThemeIcon('info');
      this.run = null;
      return;
    }

    super(`Run #${index}: $${run.cost_usd.toFixed(2)}`, vscode.TreeItemCollapsibleState.Collapsed);
    this.run = run;
    this.description = `${run.calls} calls`;
    this.iconPath = new vscode.ThemeIcon('history');

    try {
      const start = new Date(run.started).toLocaleTimeString();
      const end = new Date(run.ended).toLocaleTimeString();
      this.tooltip = `${start} — ${end}`;
    } catch {
      // ignore
    }
  }
}

class CostDetailItem extends vscode.TreeItem {
  constructor(detail: CostDetail) {
    super(
      `${detail.agent} · ${detail.phase} · Iter ${detail.iteration}`,
      vscode.TreeItemCollapsibleState.None
    );
    this.description = `$${detail.cost_usd.toFixed(3)} · ${detail.tokens_in}→${detail.tokens_out}`;
    this.iconPath = new vscode.ThemeIcon('symbol-event');
  }
}
