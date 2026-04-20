// ═══════════════════════════════════════════════════════════
// GSD V6 — `gsd worktree` CLI
// Status, list, prune commands for milestone worktrees.
// ═══════════════════════════════════════════════════════════

import type { WorktreeManager } from './worktree-manager';
import type { StateDB } from './state-db';
import type { MilestoneId } from './types';

export interface WorktreeStatusReport {
  activeMilestones: Array<{
    milestoneId: MilestoneId;
    name: string;
    status: string;
    worktreePath: string | null;
    exists: boolean;
    gitTracked: boolean;
    head: string | null;
  }>;
  allGitWorktrees: Array<{ path: string; branch: string; head: string }>;
}

export async function worktreeStatus(
  db: StateDB,
  manager: WorktreeManager,
): Promise<WorktreeStatusReport> {
  const milestones = db.listMilestones();
  const active: WorktreeStatusReport['activeMilestones'] = [];

  for (const m of milestones) {
    const status = await manager.status(m.id);
    const head = await manager.getHead(m.id);
    active.push({
      milestoneId: m.id,
      name: m.name,
      status: m.status,
      worktreePath: m.worktreePath,
      exists: status.exists,
      gitTracked: status.gitTracked,
      head,
    });
  }

  const allGitWorktrees = await manager.listAll();

  return { activeMilestones: active, allGitWorktrees };
}

export async function worktreePrune(manager: WorktreeManager): Promise<string> {
  return manager.prune();
}

export async function worktreeTeardown(
  manager: WorktreeManager,
  milestoneId: MilestoneId,
  opts: { deleteBranch?: boolean; force?: boolean } = {},
): Promise<void> {
  await manager.teardown(milestoneId, opts);
}

export function formatWorktreeStatus(report: WorktreeStatusReport): string {
  const lines: string[] = [];
  lines.push('=== Active Milestones ===');
  if (report.activeMilestones.length === 0) {
    lines.push('  (none)');
  } else {
    for (const m of report.activeMilestones) {
      lines.push(`  ${m.milestoneId} [${m.status}] ${m.name}`);
      lines.push(`    worktree: ${m.worktreePath ?? '(none)'} exists=${m.exists} gitTracked=${m.gitTracked}`);
      if (m.head) lines.push(`    HEAD: ${m.head}`);
    }
  }
  lines.push('');
  lines.push('=== All Git Worktrees ===');
  if (report.allGitWorktrees.length === 0) {
    lines.push('  (none)');
  } else {
    for (const wt of report.allGitWorktrees) {
      lines.push(`  ${wt.path} [${wt.branch}] ${wt.head.slice(0, 8)}`);
    }
  }
  return lines.join('\n');
}
