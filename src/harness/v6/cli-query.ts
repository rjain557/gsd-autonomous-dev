// ═══════════════════════════════════════════════════════════
// GSD V6 — `gsd query` CLI
// Headless JSON state API for CI, dashboards, Prom exporters.
// ═══════════════════════════════════════════════════════════

import type { StateDB } from './state-db';
import { getProjectStackContext } from '../project-stack-context';

export type QuerySubject = 'milestone' | 'milestones' | 'slice' | 'task' | 'cost' | 'stuck' | 'decisions' | 'stack';

export interface QueryResult {
  subject: QuerySubject;
  ok: boolean;
  data: unknown;
  error?: string;
}

export interface QueryOptions {
  since?: string;          // ISO date for `cost`
  minOccurrences?: number; // for `stuck`
  projectRoot?: string;    // for `stack` — v6.1.0
}

/**
 * Async variant for queries that require I/O (currently: `stack`).
 * Kept separate so synchronous queries stay synchronous for CI tooling.
 */
export async function runQueryAsync(
  subject: QuerySubject,
  opts: QueryOptions = {},
): Promise<QueryResult> {
  if (subject === 'stack') {
    const projectRoot = opts.projectRoot ?? process.cwd();
    try {
      const ctx = await getProjectStackContext(projectRoot);
      return { subject, ok: true, data: ctx };
    } catch (e) {
      return { subject, ok: false, data: null, error: (e as Error).message };
    }
  }
  return { subject, ok: false, data: null, error: `async subject not handled: ${subject}` };
}

export function runQuery(
  db: StateDB,
  subject: QuerySubject,
  id: string | undefined,
  opts: QueryOptions = {},
): QueryResult {
  try {
    switch (subject) {
      case 'milestones': {
        const rows = db.listMilestones();
        return { subject, ok: true, data: rows };
      }
      case 'milestone': {
        if (!id) return { subject, ok: false, data: null, error: 'milestone id required' };
        const m = db.getMilestone(id);
        if (!m) return { subject, ok: false, data: null, error: `not found: ${id}` };
        const slices = db.listSlicesForMilestone(id);
        return { subject, ok: true, data: { milestone: m, slices } };
      }
      case 'slice': {
        if (!id) return { subject, ok: false, data: null, error: 'slice id required' };
        const s = db.getSlice(id);
        if (!s) return { subject, ok: false, data: null, error: `not found: ${id}` };
        const tasks = db.listTasksForSlice(id);
        return { subject, ok: true, data: { slice: s, tasks } };
      }
      case 'task': {
        if (!id) return { subject, ok: false, data: null, error: 'task id required' };
        const t = db.getTask(id);
        if (!t) return { subject, ok: false, data: null, error: `not found: ${id}` };
        return { subject, ok: true, data: t };
      }
      case 'cost': {
        const since = opts.since ?? new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();
        const cost = db.getCostSince(since);
        return { subject, ok: true, data: { since, ...cost } };
      }
      case 'stuck': {
        const minOccurrences = opts.minOccurrences ?? 2;
        const patterns = db.listStuckPatterns(minOccurrences);
        return { subject, ok: true, data: patterns };
      }
      case 'decisions': {
        if (!id) return { subject, ok: false, data: null, error: 'milestone id required for decisions' };
        const decisions = db.listDecisionsForMilestone(id);
        return { subject, ok: true, data: decisions };
      }
      default:
        return { subject, ok: false, data: null, error: `unknown subject: ${subject}` };
    }
  } catch (e) {
    return { subject, ok: false, data: null, error: (e as Error).message };
  }
}

export function formatQueryResult(result: QueryResult, pretty: boolean = true): string {
  if (pretty) return JSON.stringify(result, null, 2);
  return JSON.stringify(result);
}
