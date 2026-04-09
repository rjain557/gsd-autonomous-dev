// ═══════════════════════════════════════════════════════════
// GSD Agent System — PowerShell Bridge
// @deprecated Retained for legacy GSD v3 compatibility.
// Not used by the v4.1 pipeline. May be removed in v5.
// Calls existing GSD PowerShell scripts from the TypeScript
// harness, parsing their JSON output into typed results.
// ═══════════════════════════════════════════════════════════

import { execFile } from 'child_process';
import { promisify } from 'util';
import * as path from 'path';
import * as fs from 'fs/promises';

const execFileAsync = promisify(execFile);

export interface PowerShellResult {
  success: boolean;
  exitCode: number;
  stdout: string;
  stderr: string;
  jsonOutput?: Record<string, unknown>;
}

export class PowerShellBridge {
  private gsdGlobalDir: string;
  private repoRoot: string;

  constructor(repoRoot: string) {
    this.repoRoot = repoRoot;
    // Standard GSD install location
    this.gsdGlobalDir = path.join(
      process.env.USERPROFILE ?? process.env.HOME ?? '',
      '.gsd-global',
    );
  }

  /** Run a GSD PowerShell script and return its output. */
  async runScript(scriptPath: string, args: string[] = []): Promise<PowerShellResult> {
    const fullPath = path.resolve(this.gsdGlobalDir, scriptPath);

    try {
      await fs.access(fullPath);
    } catch {
      return { success: false, exitCode: -1, stdout: '', stderr: `Script not found: ${fullPath}` };
    }

    try {
      const { stdout, stderr } = await execFileAsync(
        'powershell',
        ['-ExecutionPolicy', 'Bypass', '-NoProfile', '-File', fullPath, ...args],
        { cwd: this.repoRoot, timeout: 600_000, maxBuffer: 10 * 1024 * 1024 },
      );

      // Try to parse JSON from output (many GSD scripts write JSON to .gsd/)
      let jsonOutput: Record<string, unknown> | undefined;
      try {
        const jsonMatch = stdout.match(/\{[\s\S]*\}/);
        if (jsonMatch) jsonOutput = JSON.parse(jsonMatch[0]);
      } catch { /* not JSON output */ }

      return { success: true, exitCode: 0, stdout: stdout.trim(), stderr: stderr.trim(), jsonOutput };
    } catch (err: unknown) {
      const error = err as { code?: number; stdout?: string; stderr?: string; message?: string };
      return {
        success: false,
        exitCode: error.code ?? 1,
        stdout: (error.stdout ?? '').trim(),
        stderr: (error.stderr ?? error.message ?? '').trim(),
      };
    }
  }

  /** Run the GSD build gate (dotnet build + npm build with auto-fix). */
  async runBuildGate(maxAttempts: number = 3): Promise<PowerShellResult> {
    return this.runScript('v3/scripts/gsd-build-gate.ps1', [
      '-RepoRoot', this.repoRoot,
      '-MaxAttempts', String(maxAttempts),
    ]);
  }

  /** Run the GSD 9-phase smoke test. */
  async runSmokeTest(): Promise<PowerShellResult> {
    return this.runScript('v3/scripts/gsd-smoketest.ps1', [
      '-RepoRoot', this.repoRoot,
    ]);
  }

  /** Run the GSD code review. */
  async runCodeReview(maxCycles: number = 2): Promise<PowerShellResult> {
    return this.runScript('v3/scripts/gsd-codereview.ps1', [
      '-RepoRoot', this.repoRoot,
      '-MaxCycles', String(maxCycles),
    ]);
  }

  /** Run the GSD runtime validation (starts backend + frontend, tests endpoints). */
  async runRuntimeValidation(): Promise<PowerShellResult> {
    return this.runScript('v3/scripts/gsd-runtime-validate.ps1', [
      '-RepoRoot', this.repoRoot,
    ]);
  }

  /** Read a .gsd output file as JSON. */
  async readGsdOutput(relativePath: string): Promise<Record<string, unknown> | null> {
    const fullPath = path.join(this.repoRoot, '.gsd', relativePath);
    try {
      const content = await fs.readFile(fullPath, 'utf-8');
      return JSON.parse(content);
    } catch {
      return null;
    }
  }

  /** Check if the GSD global scripts are installed. */
  async isInstalled(): Promise<boolean> {
    try {
      await fs.access(path.join(this.gsdGlobalDir, 'scripts', 'convergence-loop.ps1'));
      return true;
    } catch {
      return false;
    }
  }
}
