import * as vscode from 'vscode';
import * as fs from 'fs';
import * as path from 'path';

/**
 * Hot-reloading config loader. Reads pipeline.json, global-config.json,
 * agent-map.json, model-registry.json, and prompt templates on every access.
 *
 * The engine never caches config — every iteration reads fresh from disk.
 * Edit any config file and the next iteration picks it up automatically.
 */
export class ConfigLoader implements vscode.Disposable {
  private readonly _onDidChange = new vscode.EventEmitter<void>();
  readonly onDidChange = this._onDidChange.event;

  private watcher: vscode.FileSystemWatcher | undefined;
  private disposables: vscode.Disposable[] = [];

  constructor(
    private workspaceRoot: string,
    private configDir: string,
  ) {
    this.disposables.push(this._onDidChange);
  }

  /** Start watching config files for changes */
  start(): void {
    const pattern = new vscode.RelativePattern(this.configDir, '**/*.{json,md}');
    this.watcher = vscode.workspace.createFileSystemWatcher(pattern);
    this.watcher.onDidChange(() => this._onDidChange.fire());
    this.watcher.onDidCreate(() => this._onDidChange.fire());
    this.disposables.push(this.watcher);

    // Also watch prompt templates
    const promptsDir = path.join(this.workspaceRoot, 'prompts', 'engine');
    if (fs.existsSync(promptsDir)) {
      const promptPattern = new vscode.RelativePattern(promptsDir, '*.md');
      const promptWatcher = vscode.workspace.createFileSystemWatcher(promptPattern);
      promptWatcher.onDidChange(() => this._onDidChange.fire());
      this.disposables.push(promptWatcher);
    }
  }

  /** Load pipeline definition — re-reads from disk every time */
  getPipeline(): PipelineConfig {
    return this.readJson<PipelineConfig>(path.join(this.configDir, 'pipeline.json'))!;
  }

  /** Load global config */
  getGlobalConfig(): Record<string, any> {
    return this.readJson(path.join(this.configDir, 'global-config.json')) || {};
  }

  /** Load agent map */
  getAgentMap(): Record<string, any> {
    return this.readJson(path.join(this.configDir, 'agent-map.json')) || {};
  }

  /** Load model registry */
  getModelRegistry(): Record<string, any> {
    return this.readJson(path.join(this.configDir, 'model-registry.json')) || {};
  }

  /**
   * Load and interpolate a prompt template.
   * Replaces {{variable}} placeholders with values from context.
   */
  getPrompt(promptFile: string, context: Record<string, any>): string {
    const fullPath = path.join(this.workspaceRoot, promptFile);
    try {
      let template = fs.readFileSync(fullPath, 'utf-8');

      // Interpolate {{key}} and {{key.subkey}} patterns
      template = template.replace(/\{\{(\w+(?:\.\w+)*)\}\}/g, (_match, keyPath: string) => {
        const value = this.resolveKeyPath(context, keyPath);
        return value !== undefined ? String(value) : `{{${keyPath}}}`;
      });

      return template;
    } catch {
      return `[ERROR: Could not load prompt template: ${promptFile}]`;
    }
  }

  /**
   * Get the full context object for prompt interpolation.
   * Merges global config, current engine state, and runtime values.
   */
  buildPromptContext(runtimeValues: Record<string, any>): Record<string, any> {
    const global = this.getGlobalConfig();
    return {
      // From global config
      patterns: global.patterns || {},
      docs_path: global.sdlc_docs?.path || 'docs',
      figma_path: global.figma?.base_path || 'design/figma',
      gsd_dir: global.project_gsd_dir || '.gsd',
      batch_size: global.batch_size_max || 8,
      // Runtime values override
      ...runtimeValues,
      // Computed
      timestamp: new Date().toISOString(),
    };
  }

  // --- Private helpers ---

  private readJson<T = Record<string, any>>(filePath: string): T | null {
    try {
      if (!fs.existsSync(filePath)) { return null; }
      const raw = fs.readFileSync(filePath, 'utf-8');
      return JSON.parse(raw) as T;
    } catch {
      return null;
    }
  }

  private resolveKeyPath(obj: Record<string, any>, keyPath: string): any {
    const keys = keyPath.split('.');
    let current: any = obj;
    for (const key of keys) {
      if (current === null || current === undefined) { return undefined; }
      current = current[key];
    }
    // Handle arrays by joining with commas
    if (Array.isArray(current)) { return current.join(', '); }
    return current;
  }

  dispose(): void {
    this.disposables.forEach(d => d.dispose());
  }
}

// --- Pipeline Config Types ---

export interface PhaseConfig {
  id: string;
  label: string;
  agent: string;
  prompt_file: string;
  timeout_seconds: number;
  retry: {
    max_attempts: number;
    backoff_seconds: number[];
  };
  skip_when: {
    health_above: number | null;
    iteration_below: number | null;
    flag: string | null;
  };
  outputs: string[];
  on_failure: 'continue' | 'abort_iteration' | 'abort_pipeline';
}

export interface PipelineConfig {
  version: string;
  phases: PhaseConfig[];
  convergence: {
    target_health: number;
    max_iterations: number;
    stall_threshold: number;
    stall_action: string;
    cooldown_between_phases_seconds: number;
    cooldown_between_iterations_seconds: number;
  };
  agent_fallback: {
    enabled: boolean;
    rules: Array<{
      if_agent_fails: string;
      try_next: string[];
    }>;
  };
  hooks: {
    before_iteration: string | null;
    after_iteration: string | null;
    before_phase: string | null;
    after_phase: string | null;
    on_converged: string | null;
    on_stalled: string | null;
  };
}
