import * as vscode from 'vscode';
import { GsdDataService } from '../parsers/gsd-data-service';
import { HandoffEntry } from '../types';

type TreeNode = AgentGroup | HandoffItem;

/** Shows agent activity timeline grouped by agent */
export class AgentsProvider implements vscode.TreeDataProvider<TreeNode> {
  private readonly _onDidChangeTreeData = new vscode.EventEmitter<TreeNode | undefined>();
  readonly onDidChangeTreeData = this._onDidChangeTreeData.event;

  constructor(private dataService: GsdDataService) {
    dataService.onDidChange(() => this._onDidChangeTreeData.fire(undefined));
  }

  getTreeItem(element: TreeNode): vscode.TreeItem {
    return element;
  }

  getChildren(element?: TreeNode): TreeNode[] {
    const snap = this.dataService.getSnapshot();

    if (!element) {
      // Group handoffs by agent
      const agents = new Map<string, HandoffEntry[]>();
      for (const h of snap.handoffs) {
        if (!agents.has(h.agent)) { agents.set(h.agent, []); }
        agents.get(h.agent)!.push(h);
      }

      // Also show the currently active agent from engine status
      const engine = snap.engine;
      const groups: AgentGroup[] = [];

      for (const [agent, entries] of agents) {
        const isActive = engine?.agent === agent && engine?.state === 'running';
        const successes = entries.filter(e => e.status === 'success').length;
        const failures = entries.filter(e => e.status === 'failed').length;
        const totalDuration = entries.reduce((s, e) => s + e.duration_seconds, 0);
        const group = new AgentGroup(agent, entries.length, successes, failures, totalDuration, isActive);
        group.entries = entries;
        groups.push(group);
      }

      if (groups.length === 0) {
        return [new AgentGroup('No agent activity yet', 0, 0, 0, 0, false)];
      }

      return groups;
    }

    if (element instanceof AgentGroup) {
      return element.entries
        .sort((a, b) => new Date(b.timestamp).getTime() - new Date(a.timestamp).getTime())
        .slice(0, 20) // Show last 20 entries per agent
        .map(entry => new HandoffItem(entry));
    }

    return [];
  }
}

class AgentGroup extends vscode.TreeItem {
  entries: HandoffEntry[] = [];

  constructor(
    agent: string, total: number, successes: number, failures: number,
    totalDurationSec: number, isActive: boolean,
  ) {
    super(agent.toUpperCase(), total > 0
      ? vscode.TreeItemCollapsibleState.Collapsed
      : vscode.TreeItemCollapsibleState.None);

    const mins = Math.round(totalDurationSec / 60);
    this.description = total > 0
      ? `${total} calls · ${successes}✓ ${failures}✗ · ${mins}m total`
      : '';

    this.iconPath = new vscode.ThemeIcon(
      isActive ? 'loading~spin' : 'vm-running',
      isActive ? new vscode.ThemeColor('testing.iconPassed') : undefined
    );
  }
}

class HandoffItem extends vscode.TreeItem {
  constructor(entry: HandoffEntry) {
    const label = `Iter ${entry.iteration} · ${entry.phase}`;
    super(label, vscode.TreeItemCollapsibleState.None);

    const statusIcon = entry.status === 'success' ? 'pass' :
                       entry.status === 'partial' ? 'warning' : 'error';
    this.iconPath = new vscode.ThemeIcon(statusIcon);

    const delta = entry.health_after - entry.health_before;
    const deltaStr = delta > 0 ? `+${delta.toFixed(1)}%` : delta < 0 ? `${delta.toFixed(1)}%` : '±0%';
    this.description = `${deltaStr} · ${entry.duration_seconds}s · ${entry.action}`;

    if (entry.error) {
      this.tooltip = `Error: ${entry.error}`;
    }
  }
}
