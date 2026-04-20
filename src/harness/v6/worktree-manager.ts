// ═══════════════════════════════════════════════════════════
// GSD V6 — Worktree Manager
// Creates, tracks, and tears down git worktrees per milestone.
// Uses execFile (not shell) to avoid injection.
// ═══════════════════════════════════════════════════════════

import { execFile } from 'child_process';
import { promisify } from 'util';
import * as fs from 'fs';
import * as path from 'path';
import type { StateDB } from './state-db';
import type { MilestoneId } from './types';

const execFileAsync = promisify(execFile);

export interface WorktreeInfo {
  milestoneId: MilestoneId;
  path: string;
  branch: string;
  exists: boolean;
  gitTracked: boolean;
}

export interface WorktreeManagerOptions {
  parentRepoPath: string;
  worktreeRoot?: string;       // default: <parentRepoPath>/.gsd-worktrees
  branchPrefix?: string;       // default: "gsd/v6/milestone/"
}

export class WorktreeManager {
  private parentRepoPath: string;
  private worktreeRoot: string;
  private branchPrefix: string;
  private stateDB: StateDB;

  constructor(stateDB: StateDB, opts: WorktreeManagerOptions) {
    this.stateDB = stateDB;
    this.parentRepoPath = path.resolve(opts.parentRepoPath);
    this.worktreeRoot = opts.worktreeRoot ?? path.join(this.parentRepoPath, '.gsd-worktrees');
    this.branchPrefix = opts.branchPrefix ?? 'gsd/v6/milestone/';
  }

  private getWorktreePath(milestoneId: MilestoneId): string {
    return path.join(this.worktreeRoot, milestoneId);
  }

  private getBranchName(milestoneId: MilestoneId): string {
    return `${this.branchPrefix}${milestoneId.toLowerCase()}`;
  }

  /** Runs a git command in the parent repo. */
  private async git(args: string[]): Promise<{ stdout: string; stderr: string }> {
    return execFileAsync('git', args, { cwd: this.parentRepoPath, maxBuffer: 10 * 1024 * 1024 });
  }

  /** Runs a git command in a specific working directory. */
  private async gitIn(cwd: string, args: string[]): Promise<{ stdout: string; stderr: string }> {
    return execFileAsync('git', args, { cwd, maxBuffer: 10 * 1024 * 1024 });
  }

  async isParentRepo(): Promise<boolean> {
    try {
      await this.git(['rev-parse', '--is-inside-work-tree']);
      return true;
    } catch {
      return false;
    }
  }

  async create(milestoneId: MilestoneId, baseBranch: string = 'main'): Promise<WorktreeInfo> {
    if (!(await this.isParentRepo())) {
      throw new Error(`Parent path is not a git repo: ${this.parentRepoPath}`);
    }

    const wtPath = this.getWorktreePath(milestoneId);
    const branch = this.getBranchName(milestoneId);

    if (fs.existsSync(wtPath)) {
      // Already exists — verify git tracks it
      try {
        await this.gitIn(wtPath, ['rev-parse', '--is-inside-work-tree']);
        this.stateDB.setMilestoneWorktreePath(milestoneId, wtPath);
        return { milestoneId, path: wtPath, branch, exists: true, gitTracked: true };
      } catch {
        // Path exists but not a worktree — unsafe to proceed automatically
        throw new Error(`Worktree path exists but is not a git worktree: ${wtPath}`);
      }
    }

    if (!fs.existsSync(this.worktreeRoot)) {
      fs.mkdirSync(this.worktreeRoot, { recursive: true });
    }

    // Check if branch already exists
    let branchExists = false;
    try {
      await this.git(['rev-parse', '--verify', `refs/heads/${branch}`]);
      branchExists = true;
    } catch {
      branchExists = false;
    }

    if (branchExists) {
      await this.git(['worktree', 'add', wtPath, branch]);
    } else {
      await this.git(['worktree', 'add', '-b', branch, wtPath, baseBranch]);
    }

    this.stateDB.setMilestoneWorktreePath(milestoneId, wtPath);
    return { milestoneId, path: wtPath, branch, exists: true, gitTracked: true };
  }

  async teardown(milestoneId: MilestoneId, opts: { deleteBranch?: boolean; force?: boolean } = {}): Promise<void> {
    const wtPath = this.getWorktreePath(milestoneId);
    if (!fs.existsSync(wtPath)) {
      this.stateDB.setMilestoneWorktreePath(milestoneId, null);
      return;
    }
    const args = ['worktree', 'remove'];
    if (opts.force) args.push('--force');
    args.push(wtPath);
    await this.git(args);

    if (opts.deleteBranch) {
      try {
        const branch = this.getBranchName(milestoneId);
        await this.git(['branch', '-D', branch]);
      } catch {
        // Branch may not exist or still checked out elsewhere — non-fatal
      }
    }
    this.stateDB.setMilestoneWorktreePath(milestoneId, null);
  }

  async status(milestoneId: MilestoneId): Promise<WorktreeInfo> {
    const wtPath = this.getWorktreePath(milestoneId);
    const branch = this.getBranchName(milestoneId);
    const exists = fs.existsSync(wtPath);
    let gitTracked = false;
    if (exists) {
      try {
        await this.gitIn(wtPath, ['rev-parse', '--is-inside-work-tree']);
        gitTracked = true;
      } catch {
        gitTracked = false;
      }
    }
    return { milestoneId, path: wtPath, branch, exists, gitTracked };
  }

  async listAll(): Promise<Array<{ path: string; branch: string; head: string }>> {
    if (!(await this.isParentRepo())) return [];
    const { stdout } = await this.git(['worktree', 'list', '--porcelain']);
    const out: Array<{ path: string; branch: string; head: string }> = [];
    let current: { path?: string; branch?: string; head?: string } = {};
    for (const line of stdout.split('\n')) {
      if (line.startsWith('worktree ')) {
        if (current.path) out.push({ path: current.path, branch: current.branch ?? '', head: current.head ?? '' });
        current = { path: line.slice('worktree '.length).trim() };
      } else if (line.startsWith('HEAD ')) {
        current.head = line.slice('HEAD '.length).trim();
      } else if (line.startsWith('branch ')) {
        current.branch = line.slice('branch '.length).trim();
      }
    }
    if (current.path) out.push({ path: current.path, branch: current.branch ?? '', head: current.head ?? '' });
    return out;
  }

  /** Removes stale/pruned worktrees from git metadata. */
  async prune(): Promise<string> {
    try {
      const { stdout } = await this.git(['worktree', 'prune', '-v']);
      return stdout;
    } catch (e) {
      return `prune failed: ${(e as Error).message}`;
    }
  }

  /** Get the HEAD SHA of a milestone worktree. */
  async getHead(milestoneId: MilestoneId): Promise<string | null> {
    const wtPath = this.getWorktreePath(milestoneId);
    if (!fs.existsSync(wtPath)) return null;
    try {
      const { stdout } = await this.gitIn(wtPath, ['rev-parse', 'HEAD']);
      return stdout.trim();
    } catch {
      return null;
    }
  }
}
