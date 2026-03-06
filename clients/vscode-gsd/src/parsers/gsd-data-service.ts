import * as vscode from 'vscode';
import * as fs from 'fs';
import * as path from 'path';
import {
  GsdSnapshot, HealthData, RequirementsMatrix, EngineStatus,
  QueueData, CostSummary, HandoffEntry, SupervisorState
} from '../types';

/**
 * Watches .gsd/ directory and provides parsed, typed data snapshots.
 * Fires events when any tracked file changes so views/webviews can refresh.
 */
export class GsdDataService implements vscode.Disposable {
  private readonly _onDidChange = new vscode.EventEmitter<GsdSnapshot>();
  readonly onDidChange = this._onDidChange.event;

  private watcher: vscode.FileSystemWatcher | undefined;
  private pollTimer: NodeJS.Timeout | undefined;
  private snapshot: GsdSnapshot;
  private gsdRoot: string;
  private disposables: vscode.Disposable[] = [];

  constructor(private workspaceRoot: string) {
    const config = vscode.workspace.getConfiguration('gsd');
    const rel = config.get<string>('gsdPath', '.gsd');
    this.gsdRoot = path.join(workspaceRoot, rel);
    this.snapshot = this.emptySnapshot();
    this.disposables.push(this._onDidChange);
  }

  /** Start watching .gsd/ files for changes */
  start(): void {
    // Native file watcher for instant updates
    const pattern = new vscode.RelativePattern(this.gsdRoot, '**/*.{json,jsonl,md}');
    this.watcher = vscode.workspace.createFileSystemWatcher(pattern);
    this.watcher.onDidChange(() => this.refresh());
    this.watcher.onDidCreate(() => this.refresh());
    this.watcher.onDidDelete(() => this.refresh());
    this.disposables.push(this.watcher);

    // Fallback poll for files that may not trigger FS events (e.g., written by external processes)
    const pollMs = vscode.workspace.getConfiguration('gsd').get<number>('pollIntervalMs', 2000);
    this.pollTimer = setInterval(() => this.refresh(), pollMs);

    // Initial load
    this.refresh();
  }

  /** Force a full refresh and notify listeners */
  async refresh(): Promise<GsdSnapshot> {
    this.snapshot = {
      health: this.readJson<HealthData>('health/health-current.json'),
      matrix: this.readJson<RequirementsMatrix>('health/requirements-matrix.json'),
      engine: this.readJson<EngineStatus>('health/engine-status.json'),
      queue: this.readJson<QueueData>('generation-queue/queue-current.json'),
      costs: this.readJson<CostSummary>('costs/cost-summary.json'),
      handoffs: this.readJsonl<HandoffEntry>('agent-handoff/handoff-log.jsonl'),
      supervisor: this.readJson<SupervisorState>('supervisor/supervisor-state.json'),
      timestamp: Date.now(),
    };
    this._onDidChange.fire(this.snapshot);
    return this.snapshot;
  }

  /** Get the latest cached snapshot */
  getSnapshot(): GsdSnapshot {
    return this.snapshot;
  }

  /** Check if .gsd directory exists */
  isInitialized(): boolean {
    return fs.existsSync(this.gsdRoot);
  }

  getGsdRoot(): string {
    return this.gsdRoot;
  }

  getWorkspaceRoot(): string {
    return this.workspaceRoot;
  }

  // --- Private helpers ---

  private readJson<T>(relativePath: string): T | null {
    const fullPath = path.join(this.gsdRoot, relativePath);
    try {
      if (!fs.existsSync(fullPath)) { return null; }
      const raw = fs.readFileSync(fullPath, 'utf-8');
      return JSON.parse(raw) as T;
    } catch {
      return null;
    }
  }

  private readJsonl<T>(relativePath: string): T[] {
    const fullPath = path.join(this.gsdRoot, relativePath);
    try {
      if (!fs.existsSync(fullPath)) { return []; }
      const raw = fs.readFileSync(fullPath, 'utf-8');
      return raw
        .split('\n')
        .filter(line => line.trim().length > 0)
        .map(line => JSON.parse(line) as T);
    } catch {
      return [];
    }
  }

  private emptySnapshot(): GsdSnapshot {
    return {
      health: null, matrix: null, engine: null,
      queue: null, costs: null, handoffs: [], supervisor: null,
      timestamp: Date.now(),
    };
  }

  dispose(): void {
    if (this.pollTimer) { clearInterval(this.pollTimer); }
    this.disposables.forEach(d => d.dispose());
  }
}
