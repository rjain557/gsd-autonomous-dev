// ═══════════════════════════════════════════════════════════
// GSD V6 — Compacted Tool Execution
// Runs bash/tool commands, persists raw output to disk, and
// returns a compact summary to the agent. Agent can request
// raw output by path if needed.
// ═══════════════════════════════════════════════════════════

import { execFile } from 'child_process';
import { promisify } from 'util';
import * as fs from 'fs';
import * as path from 'path';

const execFileAsync = promisify(execFile);

export interface CompactedResult {
  summary: string;
  rawPath: string;
  rawSize: number;
  exitCode: number;
  durationMs: number;
  command: string;
  args: string[];
  cwd: string;
}

export interface CompactedExecOptions {
  cwd: string;
  outputDir: string;
  runId: string;
  maxInlineBytes?: number;     // default 2000
  timeoutMs?: number;          // default 300_000
  summarizer?: (raw: string) => Promise<string> | string;
}

/**
 * Run a command and store raw output to disk. Returns a compact summary.
 */
export async function compactedRun(
  command: string,
  args: string[],
  opts: CompactedExecOptions,
): Promise<CompactedResult> {
  const start = Date.now();
  const maxInline = opts.maxInlineBytes ?? 2000;
  const timeoutMs = opts.timeoutMs ?? 300_000;

  const rawDir = path.join(opts.outputDir, opts.runId, 'raw');
  if (!fs.existsSync(rawDir)) fs.mkdirSync(rawDir, { recursive: true });
  const filename = `${Date.now()}-${command.replace(/[^a-zA-Z0-9]/g, '_')}.txt`;
  const rawPath = path.join(rawDir, filename);

  let exitCode = 0;
  let raw: string;
  try {
    const { stdout, stderr } = await execFileAsync(command, args, {
      cwd: opts.cwd,
      timeout: timeoutMs,
      maxBuffer: 50 * 1024 * 1024,
      // shell: true on Windows so .cmd/.bat shims (pnpm, npm-installed CLIs) resolve.
      // args are supplied by agent code and are expected to be flag/value pairs, not
      // arbitrary user content — see spawnCli for the prompt-passing path that uses stdin.
      shell: process.platform === 'win32',
    });
    raw = `=== STDOUT ===\n${stdout}\n\n=== STDERR ===\n${stderr}\n`;
  } catch (e) {
    const err = e as { code?: number; stdout?: string; stderr?: string; message?: string };
    exitCode = typeof err.code === 'number' ? err.code : 1;
    raw = `=== STDOUT ===\n${err.stdout ?? ''}\n\n=== STDERR ===\n${err.stderr ?? ''}\n\n=== ERROR ===\n${err.message ?? ''}\n`;
  }

  fs.writeFileSync(rawPath, raw, 'utf8');

  let summary: string;
  if (raw.length <= maxInline) {
    summary = raw;
  } else if (opts.summarizer) {
    summary = await Promise.resolve(opts.summarizer(raw));
  } else {
    // Default summarizer: head + tail + size hint
    const head = raw.slice(0, Math.floor(maxInline / 2));
    const tail = raw.slice(-Math.floor(maxInline / 2));
    summary = `${head}\n\n… [truncated ${raw.length - maxInline} bytes; full at ${rawPath}] …\n\n${tail}`;
  }

  return {
    summary,
    rawPath,
    rawSize: raw.length,
    exitCode,
    durationMs: Date.now() - start,
    command,
    args,
    cwd: opts.cwd,
  };
}

/** Read the raw output back (agent-accessible). */
export function readRaw(rawPath: string): string {
  return fs.readFileSync(rawPath, 'utf8');
}
