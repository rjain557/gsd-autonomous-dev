// ═══════════════════════════════════════════════════════════
// GSD V5 → V6 State Migration
// Scans `memory/sessions/pipeline-state-*.json` and
// `memory/sessions/sdlc-state-*.json` from V5 runs and imports
// them into the V6 SQLite state DB as synthetic milestones with
// a single legacy slice containing each prior stage as a task.
// ═══════════════════════════════════════════════════════════

import * as fs from 'fs';
import * as path from 'path';
import { StateDB } from './state-db';
import type { Milestone, Slice, Task } from './types';
import type { PipelineState } from '../types';

export interface MigrationReport {
  scannedSessionFiles: number;
  importedMilestones: number;
  skipped: Array<{ file: string; reason: string }>;
  createdMilestoneIds: string[];
}

export interface MigrationOptions {
  vaultPath: string;           // default: ./memory
  dryRun?: boolean;            // default: false
  onlyRunIds?: string[];       // if provided, only migrate these runs
}

export async function migrateV5ToV6(opts: MigrationOptions): Promise<MigrationReport> {
  const vaultPath = opts.vaultPath;
  const sessionsDir = path.join(vaultPath, 'sessions');
  const report: MigrationReport = {
    scannedSessionFiles: 0,
    importedMilestones: 0,
    skipped: [],
    createdMilestoneIds: [],
  };

  if (!fs.existsSync(sessionsDir)) {
    report.skipped.push({ file: sessionsDir, reason: 'sessions directory does not exist' });
    return report;
  }

  const dbPath = path.join(vaultPath, 'state.db');
  const db = opts.dryRun ? null : new StateDB(dbPath);

  const files = fs.readdirSync(sessionsDir).filter((f) =>
    (f.startsWith('pipeline-state-') && f.endsWith('.json') && !f.includes('latest'))
    || (f.startsWith('sdlc-state-') && f.endsWith('.json') && !f.includes('latest')),
  );

  for (const file of files) {
    report.scannedSessionFiles++;
    const full = path.join(sessionsDir, file);
    let raw: string;
    try {
      raw = fs.readFileSync(full, 'utf8');
    } catch (e) {
      report.skipped.push({ file, reason: `read failed: ${(e as Error).message}` });
      continue;
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch (e) {
      report.skipped.push({ file, reason: `parse failed: ${(e as Error).message}` });
      continue;
    }

    // Accept pipeline-state (flat PipelineState JSON) OR VaultNote-wrapped JSON
    const state = (parsed as { body?: string }).body
      ? safeParse((parsed as { body: string }).body)
      : parsed;

    if (!state || typeof state !== 'object') {
      report.skipped.push({ file, reason: 'no usable state payload' });
      continue;
    }

    const ps = state as Partial<PipelineState>;
    const runId = ps.runId;
    if (!runId) {
      report.skipped.push({ file, reason: 'no runId on state' });
      continue;
    }
    if (opts.onlyRunIds && !opts.onlyRunIds.includes(runId)) continue;

    // Synthesize a V6 milestone from this V5 run
    const milestoneId = `MV5-${runId.slice(0, 8).toUpperCase()}`;
    const sliceId = `S01`;
    const startedAt = ps.startedAt ?? new Date().toISOString();
    const completedAt = ps.completedAt ?? null;
    const status = ps.status === 'complete' ? 'complete' : ps.status === 'failed' ? 'failed' : 'complete';

    const milestone: Milestone = {
      id: milestoneId,
      name: `Migrated V5 run ${runId}`,
      description: `Imported from sessions/${file}`,
      status,
      startedAt,
      completedAt,
      budgetUsd: 0,
      spentUsd: (ps.costAccumulator ?? []).reduce((s, e) => s + (e.estimatedCostUsd ?? 0), 0),
      worktreePath: null,
      parentRepoPath: process.cwd(),
    };

    const slice: Slice = {
      id: sliceId,
      milestoneId,
      name: 'legacy-v5-run',
      description: `Originally ran as a V5 pipeline in session ${runId}`,
      status,
      dependsOnSliceIds: [],
      startedAt,
      completedAt,
    };

    // Tasks: one per recorded decision/stage
    const tasks: Task[] = (ps.decisions ?? []).map((d, idx) => ({
      id: `T${String(idx + 1).padStart(3, '0')}`,
      sliceId,
      agentId: d.agentId,
      stage: d.stage,
      status: 'complete',
      dependsOnTaskIds: [],
      startedAt: d.timestamp,
      completedAt: d.timestamp,
      costUsd: 0,
      tokensIn: 0,
      tokensOut: 0,
      outputHash: null,
      attempt: 1,
      maxAttempts: 1,
    }));

    if (db) {
      try {
        db.createMilestone(milestone);
        db.createSlice(slice);
        for (const t of tasks) db.createTask(t);
        for (const d of ps.decisions ?? []) {
          db.recordDecision({
            milestoneId,
            sliceId,
            timestamp: d.timestamp,
            action: d.action,
            reason: d.reason,
            evidence: d.evidence,
          });
        }
        report.importedMilestones++;
        report.createdMilestoneIds.push(milestoneId);
      } catch (e) {
        report.skipped.push({ file, reason: `db insert failed: ${(e as Error).message}` });
      }
    } else {
      // dry run: just account for it
      report.importedMilestones++;
      report.createdMilestoneIds.push(milestoneId);
    }
  }

  if (db) db.close();
  return report;
}

function safeParse(raw: string): unknown {
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}
