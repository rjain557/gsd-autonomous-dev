// ═══════════════════════════════════════════════════════════
// GSD V6 — Observability Logger
// Agent-queryable structured logs as JSONL. Post-deploy agent
// can grep/jq these instead of just seeing pass/fail assertions.
// ═══════════════════════════════════════════════════════════

import * as fs from 'fs';
import * as path from 'path';

export type ObservabilityCategory = 'e2e-traces' | 'deploy-logs' | 'gate-results' | 'build-output' | 'router-decisions';

export interface ObservabilityEntry {
  ts: string;
  runId: string;
  category: ObservabilityCategory;
  kind: string;
  data: Record<string, unknown>;
}

export class ObservabilityLogger {
  private rootDir: string;
  private runId: string;

  constructor(rootDir: string, runId: string) {
    this.rootDir = rootDir;
    this.runId = runId;
  }

  private fileFor(category: ObservabilityCategory): string {
    const dir = path.join(this.rootDir, category);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    return path.join(dir, `${this.runId}.jsonl`);
  }

  log(category: ObservabilityCategory, kind: string, data: Record<string, unknown>): void {
    const entry: ObservabilityEntry = {
      ts: new Date().toISOString(),
      runId: this.runId,
      category,
      kind,
      data,
    };
    const filePath = this.fileFor(category);
    fs.appendFileSync(filePath, JSON.stringify(entry) + '\n', 'utf8');
  }

  /** Read all entries for a category + runId. */
  read(category: ObservabilityCategory): ObservabilityEntry[] {
    const filePath = this.fileFor(category);
    if (!fs.existsSync(filePath)) return [];
    const raw = fs.readFileSync(filePath, 'utf8');
    return raw
      .split('\n')
      .filter((l) => l.trim().length > 0)
      .map((l) => {
        try { return JSON.parse(l) as ObservabilityEntry; } catch { return null; }
      })
      .filter((e): e is ObservabilityEntry => e !== null);
  }

  /** Filter entries by a predicate. */
  query(category: ObservabilityCategory, predicate: (e: ObservabilityEntry) => boolean): ObservabilityEntry[] {
    return this.read(category).filter(predicate);
  }
}
