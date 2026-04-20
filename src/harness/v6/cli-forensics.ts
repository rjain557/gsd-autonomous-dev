// ═══════════════════════════════════════════════════════════
// GSD V6 — `gsd forensics` CLI
// Bundles decisions, sessions, observability logs, git diff,
// and a SQLite snapshot for triage.
// ═══════════════════════════════════════════════════════════

import { execFile } from 'child_process';
import { promisify } from 'util';
import * as fs from 'fs';
import * as path from 'path';
import type { StateDB } from './state-db';
import type { MilestoneId } from './types';

const execFileAsync = promisify(execFile);

export interface ForensicsOptions {
  runId: string;
  milestoneId?: MilestoneId;
  vaultPath: string;
  observabilityRoot: string;
  outputDir: string;
  repoPath?: string;            // for git diff, defaults to cwd
  includeDbDump?: boolean;      // default true
}

export interface ForensicsBundleResult {
  runId: string;
  outputPath: string;
  summary: {
    decisionsMd: number;
    observabilityFiles: number;
    sessionFiles: number;
    gitDiffBytes: number;
    dbDumpPath: string | null;
  };
}

async function safeReadDir(p: string): Promise<string[]> {
  try {
    if (!fs.existsSync(p)) return [];
    return fs.readdirSync(p);
  } catch {
    return [];
  }
}

async function copyIfExists(src: string, dst: string): Promise<boolean> {
  if (!fs.existsSync(src)) return false;
  const dstDir = path.dirname(dst);
  if (!fs.existsSync(dstDir)) fs.mkdirSync(dstDir, { recursive: true });
  fs.copyFileSync(src, dst);
  return true;
}

export async function buildForensicsBundle(db: StateDB, opts: ForensicsOptions): Promise<ForensicsBundleResult> {
  const bundleDir = path.join(opts.outputDir, `forensics-${opts.runId}`);
  if (!fs.existsSync(bundleDir)) fs.mkdirSync(bundleDir, { recursive: true });

  // 1. Decisions markdown files
  const decisionsSrc = path.join(opts.vaultPath, 'decisions');
  const decisionsDst = path.join(bundleDir, 'decisions');
  if (fs.existsSync(decisionsDst)) fs.rmSync(decisionsDst, { recursive: true, force: true });
  fs.mkdirSync(decisionsDst, { recursive: true });
  const decisionFiles = (await safeReadDir(decisionsSrc)).filter((f) => f.includes(opts.runId));
  for (const f of decisionFiles) {
    await copyIfExists(path.join(decisionsSrc, f), path.join(decisionsDst, f));
  }

  // 2. Session files
  const sessionsSrc = path.join(opts.vaultPath, 'sessions');
  const sessionsDst = path.join(bundleDir, 'sessions');
  if (fs.existsSync(sessionsDst)) fs.rmSync(sessionsDst, { recursive: true, force: true });
  fs.mkdirSync(sessionsDst, { recursive: true });
  const sessionFiles = (await safeReadDir(sessionsSrc)).filter((f) => f.includes(opts.runId));
  for (const f of sessionFiles) {
    await copyIfExists(path.join(sessionsSrc, f), path.join(sessionsDst, f));
  }

  // 3. Observability files
  const obsDst = path.join(bundleDir, 'observability');
  if (fs.existsSync(obsDst)) fs.rmSync(obsDst, { recursive: true, force: true });
  fs.mkdirSync(obsDst, { recursive: true });
  let obsCount = 0;
  const obsCategories = await safeReadDir(opts.observabilityRoot);
  for (const cat of obsCategories) {
    const catDir = path.join(opts.observabilityRoot, cat);
    if (!fs.statSync(catDir).isDirectory()) continue;
    const files = (await safeReadDir(catDir)).filter((f) => f.includes(opts.runId));
    for (const f of files) {
      await copyIfExists(path.join(catDir, f), path.join(obsDst, cat, f));
      obsCount++;
    }
  }

  // 4. Git diff
  let gitDiff = '';
  const repoPath = opts.repoPath ?? process.cwd();
  try {
    const { stdout } = await execFileAsync('git', ['diff', 'HEAD'], {
      cwd: repoPath,
      maxBuffer: 50 * 1024 * 1024,
    });
    gitDiff = stdout;
  } catch {
    gitDiff = '[git diff unavailable]';
  }
  fs.writeFileSync(path.join(bundleDir, 'git-diff.patch'), gitDiff, 'utf8');

  // 5. SQLite dump (if requested and milestoneId provided)
  let dbDumpPath: string | null = null;
  if ((opts.includeDbDump ?? true) && opts.milestoneId) {
    const m = db.getMilestone(opts.milestoneId);
    const slices = db.listSlicesForMilestone(opts.milestoneId);
    const tasksBySlice: Record<string, unknown> = {};
    for (const s of slices) tasksBySlice[s.id] = db.listTasksForSlice(s.id);
    const decisions = db.listDecisionsForMilestone(opts.milestoneId);
    const snapshot = {
      exportedAt: new Date().toISOString(),
      milestone: m,
      slices,
      tasksBySlice,
      decisions,
    };
    dbDumpPath = path.join(bundleDir, 'state-snapshot.json');
    fs.writeFileSync(dbDumpPath, JSON.stringify(snapshot, null, 2), 'utf8');
  }

  // 6. Manifest
  const manifest = {
    runId: opts.runId,
    milestoneId: opts.milestoneId ?? null,
    createdAt: new Date().toISOString(),
    decisionsMd: decisionFiles.length,
    sessionFiles: sessionFiles.length,
    observabilityFiles: obsCount,
    gitDiffBytes: gitDiff.length,
    dbDumpPath,
  };
  fs.writeFileSync(path.join(bundleDir, 'MANIFEST.json'), JSON.stringify(manifest, null, 2), 'utf8');

  return {
    runId: opts.runId,
    outputPath: bundleDir,
    summary: {
      decisionsMd: decisionFiles.length,
      observabilityFiles: obsCount,
      sessionFiles: sessionFiles.length,
      gitDiffBytes: gitDiff.length,
      dbDumpPath,
    },
  };
}
