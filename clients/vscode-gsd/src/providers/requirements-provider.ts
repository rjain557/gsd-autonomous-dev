import * as vscode from 'vscode';
import * as path from 'path';
import { GsdDataService } from '../parsers/gsd-data-service';
import { Requirement } from '../types';

type TreeNode = PhaseGroup | RequirementItem;

/** Groups requirements by SDLC phase, color-coded by status */
export class RequirementsProvider implements vscode.TreeDataProvider<TreeNode> {
  private readonly _onDidChangeTreeData = new vscode.EventEmitter<TreeNode | undefined>();
  readonly onDidChangeTreeData = this._onDidChangeTreeData.event;

  private filter: 'all' | 'satisfied' | 'partial' | 'not_started' = 'all';

  constructor(private dataService: GsdDataService) {
    dataService.onDidChange(() => this._onDidChangeTreeData.fire(undefined));
  }

  setFilter(filter: 'all' | 'satisfied' | 'partial' | 'not_started'): void {
    this.filter = filter;
    this._onDidChangeTreeData.fire(undefined);
  }

  getTreeItem(element: TreeNode): vscode.TreeItem {
    return element;
  }

  getChildren(element?: TreeNode): TreeNode[] {
    const matrix = this.dataService.getSnapshot().matrix;
    if (!matrix) {
      return [new PhaseGroup('No requirements data', 0, 0, 0)];
    }

    if (!element) {
      // Root level: group by SDLC phase
      const phases = new Map<string, Requirement[]>();
      for (const req of matrix.requirements) {
        if (this.filter !== 'all' && req.status !== this.filter) { continue; }
        const phase = req.sdlc_phase || 'Unassigned';
        if (!phases.has(phase)) { phases.set(phase, []); }
        phases.get(phase)!.push(req);
      }

      return Array.from(phases.entries()).map(([phase, reqs]) => {
        const satisfied = reqs.filter(r => r.status === 'satisfied').length;
        const partial = reqs.filter(r => r.status === 'partial').length;
        const notStarted = reqs.filter(r => r.status === 'not_started').length;
        const group = new PhaseGroup(phase, satisfied, partial, notStarted);
        group.requirements = reqs;
        return group;
      });
    }

    if (element instanceof PhaseGroup) {
      return element.requirements.map(req =>
        new RequirementItem(req, this.dataService.getWorkspaceRoot())
      );
    }

    return [];
  }
}

class PhaseGroup extends vscode.TreeItem {
  requirements: Requirement[] = [];

  constructor(phase: string, satisfied: number, partial: number, notStarted: number) {
    const total = satisfied + partial + notStarted;
    super(phase, vscode.TreeItemCollapsibleState.Expanded);
    const pct = total > 0 ? ((satisfied / total) * 100).toFixed(0) : '0';
    this.description = `${pct}% — ${satisfied}✓ ${partial}◐ ${notStarted}○`;
    this.iconPath = new vscode.ThemeIcon('folder', this.phaseColor(satisfied, total));
  }

  private phaseColor(satisfied: number, total: number): vscode.ThemeColor {
    if (total === 0) { return new vscode.ThemeColor('disabledForeground'); }
    const pct = (satisfied / total) * 100;
    if (pct >= 90) { return new vscode.ThemeColor('testing.iconPassed'); }
    if (pct >= 50) { return new vscode.ThemeColor('editorWarning.foreground'); }
    return new vscode.ThemeColor('testing.iconFailed');
  }
}

class RequirementItem extends vscode.TreeItem {
  constructor(req: Requirement, workspaceRoot: string) {
    super(`${req.id}: ${req.description}`, vscode.TreeItemCollapsibleState.None);

    const statusIcon = req.status === 'satisfied' ? 'pass' :
                       req.status === 'partial' ? 'warning' : 'circle-outline';
    this.iconPath = new vscode.ThemeIcon(statusIcon);

    this.description = `${req.priority} · ${req.pattern}`;
    this.tooltip = new vscode.MarkdownString(this.buildTooltip(req));

    // Click to open the first implementing file
    if (req.satisfied_by.length > 0) {
      const filePath = path.join(workspaceRoot, req.satisfied_by[0]);
      this.command = {
        command: 'vscode.open',
        title: 'Open Implementation',
        arguments: [vscode.Uri.file(filePath)],
      };
    } else if (req.spec_doc) {
      const specPath = path.join(workspaceRoot, req.spec_doc);
      this.command = {
        command: 'vscode.open',
        title: 'Open Spec',
        arguments: [vscode.Uri.file(specPath)],
      };
    }

    this.contextValue = `requirement-${req.status}`;
  }

  private buildTooltip(req: Requirement): string {
    const lines = [
      `**${req.id}** — ${req.description}`,
      '',
      `| Field | Value |`,
      `|-------|-------|`,
      `| Status | ${req.status} |`,
      `| Priority | ${req.priority} |`,
      `| Source | ${req.source} |`,
      `| Pattern | ${req.pattern} |`,
      `| Confidence | ${req.confidence} |`,
      `| Spec | ${req.spec_doc} |`,
    ];
    if (req.satisfied_by.length > 0) {
      lines.push(`| Files | ${req.satisfied_by.join(', ')} |`);
    }
    if (req.depends_on.length > 0) {
      lines.push(`| Depends On | ${req.depends_on.join(', ')} |`);
    }
    return lines.join('\n');
  }
}
