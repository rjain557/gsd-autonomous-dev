// ═══════════════════════════════════════════════════════════
// GSD V6 — Auto-Lock + Crash Recovery
// Creates a lock file at runtime. On startup, detects stale
// locks and produces a forensics report.
// ═══════════════════════════════════════════════════════════

import * as fs from 'fs';
import * as path from 'path';

export interface LockInfo {
  pid: number;
  startedAt: string;
  runId: string;
  hostname: string;
}

export interface StaleLockReport {
  lockPath: string;
  lock: LockInfo;
  staleMinutes: number;
  processAlive: boolean;
}

export class AutoLock {
  public readonly lockPath: string;
  private staleAfterMinutes: number;

  constructor(lockPath: string, staleAfterMinutes: number = 10) {
    this.lockPath = lockPath;
    this.staleAfterMinutes = staleAfterMinutes;
  }

  /** Acquire the lock. Throws if a non-stale lock exists. */
  acquire(runId: string): LockInfo {
    const existing = this.readLock();
    if (existing) {
      const stale = this.isStale(existing);
      if (!stale) {
        throw new Error(
          `Lock already held by pid=${existing.pid} run=${existing.runId} since ${existing.startedAt}`,
        );
      }
      // Stale lock — take over after recording
      this.clearLock();
    }
    const lock: LockInfo = {
      pid: process.pid,
      startedAt: new Date().toISOString(),
      runId,
      hostname: require('os').hostname(),
    };
    const dir = path.dirname(this.lockPath);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(this.lockPath, JSON.stringify(lock, null, 2), 'utf8');
    return lock;
  }

  /** Release the lock (only if it's ours). */
  release(): void {
    const existing = this.readLock();
    if (existing && existing.pid === process.pid) {
      this.clearLock();
    }
  }

  /** Force-clear the lock regardless of owner. Use with care. */
  forceClear(): void {
    this.clearLock();
  }

  readLock(): LockInfo | null {
    if (!fs.existsSync(this.lockPath)) return null;
    try {
      const raw = fs.readFileSync(this.lockPath, 'utf8');
      return JSON.parse(raw) as LockInfo;
    } catch {
      return null;
    }
  }

  /** Inspect for stale lock without acquiring. */
  inspect(): StaleLockReport | null {
    const lock = this.readLock();
    if (!lock) return null;
    const startedMs = new Date(lock.startedAt).getTime();
    const staleMinutes = (Date.now() - startedMs) / 60_000;
    const alive = this.isProcessAlive(lock.pid);
    return {
      lockPath: this.lockPath,
      lock,
      staleMinutes,
      processAlive: alive,
    };
  }

  private isStale(lock: LockInfo): boolean {
    const startedMs = new Date(lock.startedAt).getTime();
    const ageMin = (Date.now() - startedMs) / 60_000;
    if (ageMin < this.staleAfterMinutes) return false;
    return !this.isProcessAlive(lock.pid);
  }

  private isProcessAlive(pid: number): boolean {
    try {
      // Signal 0 tests process existence without signaling it
      process.kill(pid, 0);
      return true;
    } catch {
      return false;
    }
  }

  private clearLock(): void {
    if (fs.existsSync(this.lockPath)) {
      try { fs.unlinkSync(this.lockPath); } catch { /* non-fatal */ }
    }
  }
}
