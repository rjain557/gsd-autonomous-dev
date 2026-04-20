// ═══════════════════════════════════════════════════════════
// GSD V6 — Turn-Level Git Transactions
// Wrap each task's filesystem work in a git txn:
//   - start: note HEAD
//   - on success: commit with task metadata
//   - on failure: reset --hard to pre-task HEAD
// ═══════════════════════════════════════════════════════════

import { execFile } from 'child_process';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);

export interface GitTxnOptions {
  cwd: string;
  commitAuthor?: string;
  commitEmail?: string;
}

export interface GitTxnHandle {
  beganAtSha: string;
  cwd: string;
}

export class GitTxn {
  private cwd: string;
  private commitAuthor: string;
  private commitEmail: string;

  constructor(opts: GitTxnOptions) {
    this.cwd = opts.cwd;
    this.commitAuthor = opts.commitAuthor ?? 'GSD V6';
    this.commitEmail = opts.commitEmail ?? 'gsd-v6@local';
  }

  private async git(args: string[]): Promise<{ stdout: string; stderr: string }> {
    return execFileAsync('git', args, { cwd: this.cwd, maxBuffer: 10 * 1024 * 1024 });
  }

  async begin(): Promise<GitTxnHandle> {
    const { stdout } = await this.git(['rev-parse', 'HEAD']);
    return { beganAtSha: stdout.trim(), cwd: this.cwd };
  }

  /** Commit all changes (including new files) with a message. */
  async commit(handle: GitTxnHandle, message: string): Promise<string | null> {
    // Stage all changes
    await this.git(['add', '-A']);
    // Check if there are staged changes
    try {
      await this.git(['diff', '--cached', '--quiet']);
      // No changes staged — nothing to commit
      return null;
    } catch {
      // diff --quiet returns non-zero when there ARE changes — commit them
    }
    await this.git([
      '-c', `user.name=${this.commitAuthor}`,
      '-c', `user.email=${this.commitEmail}`,
      'commit',
      '-m', message,
    ]);
    const { stdout } = await this.git(['rev-parse', 'HEAD']);
    return stdout.trim();
  }

  async rollback(handle: GitTxnHandle): Promise<void> {
    // Reset working tree and index back to pre-task state
    await this.git(['reset', '--hard', handle.beganAtSha]);
    // Remove untracked files/dirs that this task created
    await this.git(['clean', '-fd']);
  }

  async getHead(): Promise<string> {
    const { stdout } = await this.git(['rev-parse', 'HEAD']);
    return stdout.trim();
  }

  async getDiff(handle: GitTxnHandle): Promise<string> {
    const { stdout } = await this.git(['diff', `${handle.beganAtSha}..HEAD`]);
    return stdout;
  }
}
