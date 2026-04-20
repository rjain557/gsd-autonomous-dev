// ═══════════════════════════════════════════════════════════
// GSD V6 — Mechanical Fix Band
// Between gate failure and RemediationAgent (LLM), run cheap
// mechanical fixes first: lint --fix, prettier --write, dotnet format.
// ═══════════════════════════════════════════════════════════

import { execFile } from 'child_process';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);

export interface MechanicalFixStep {
  name: string;
  command: string;
  args: string[];
  ran: boolean;
  success: boolean;
  output: string;
  durationMs: number;
}

export interface MechanicalFixResult {
  steps: MechanicalFixStep[];
  anyChange: boolean;
}

export interface MechanicalFixOptions {
  cwd: string;
  timeoutMs?: number;
  skipSteps?: string[];
}

const DEFAULT_STEPS: Array<{ name: string; command: string; args: string[] }> = [
  { name: 'eslint --fix', command: 'npx', args: ['eslint', '.', '--fix', '--quiet'] },
  { name: 'prettier --write', command: 'npx', args: ['prettier', '--write', '.'] },
  { name: 'dotnet format', command: 'dotnet', args: ['format'] },
];

export async function runMechanicalFixBand(opts: MechanicalFixOptions): Promise<MechanicalFixResult> {
  const timeout = opts.timeoutMs ?? 120_000;
  const skip = new Set(opts.skipSteps ?? []);
  const result: MechanicalFixResult = { steps: [], anyChange: false };

  for (const step of DEFAULT_STEPS) {
    if (skip.has(step.name)) {
      result.steps.push({ ...step, ran: false, success: true, output: 'skipped', durationMs: 0 });
      continue;
    }
    const start = Date.now();
    try {
      const { stdout, stderr } = await execFileAsync(step.command, step.args, {
        cwd: opts.cwd,
        timeout,
        maxBuffer: 10 * 1024 * 1024,
      });
      const output = (stdout + stderr).slice(0, 4000);
      result.steps.push({ ...step, ran: true, success: true, output, durationMs: Date.now() - start });
      if (output.length > 0) result.anyChange = true;
    } catch (e) {
      const err = e as { message?: string; stdout?: string; stderr?: string };
      const output = ((err.stdout ?? '') + (err.stderr ?? '') + (err.message ?? '')).slice(0, 4000);
      result.steps.push({ ...step, ran: true, success: false, output, durationMs: Date.now() - start });
      // Continue other steps even if one fails (lint may not be installed, etc.)
    }
  }

  return result;
}
