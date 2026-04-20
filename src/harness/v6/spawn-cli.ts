// ═══════════════════════════════════════════════════════════
// GSD V6 — Cross-platform CLI invocation
// ───────────────────────────────────────────────────────────
// Node's execFile / spawn cannot directly execute Windows .cmd / .bat
// files without `shell: true`. Many of the CLIs we drive (claude, codex,
// gemini, pnpm, etc.) are installed via npm as .cmd shims on Windows.
//
// This helper wraps child_process.spawn to:
//   1. Use shell: true on Windows so .cmd shims resolve
//   2. Keep argv limited to safe constants / flag values (ingested by
//      shell but never user-controlled prompt text)
//   3. Allow arbitrary input (prompt text, large payloads) to flow
//      through stdin — which never goes through shell parsing, so
//      quotes / $ / backticks / & / | in the payload are harmless
// ═══════════════════════════════════════════════════════════

import { spawn } from 'child_process';

export interface SpawnCliOptions {
  /** Working directory for the child process. */
  cwd?: string;
  /** Milliseconds before the child is killed. */
  timeoutMs?: number;
  /** Maximum bytes of stdout+stderr to buffer; exceeding rejects. */
  maxBuffer?: number;
  /** Payload written to the child's stdin. Closes stdin after writing. */
  stdin?: string;
  /** Environment variables (merged with process.env if not provided). */
  env?: NodeJS.ProcessEnv;
}

export interface SpawnCliResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

/**
 * Cross-platform child-process invocation.
 *
 * On Windows, uses shell: true so that .cmd / .bat shims (such as the
 * npm-installed `claude`, `codex`, `gemini`, `pnpm` binaries) resolve
 * correctly. On POSIX, runs the command directly without a shell.
 *
 * To avoid shell-escaping risk on Windows, callers should pass
 * variable-length or user/agent-generated payloads through `stdin`
 * rather than through `args`. `args` should contain only fixed flags
 * and short, predictable values (model names, format names, etc.).
 *
 * Resolves with { stdout, stderr, exitCode }. Rejects only on spawn
 * error, buffer-overflow, or timeout — a non-zero exit code still
 * resolves so the caller can inspect stderr and exit code.
 */
export function spawnCli(
  command: string,
  args: string[],
  options: SpawnCliOptions = {},
): Promise<SpawnCliResult> {
  const isWindows = process.platform === 'win32';
  const maxBuffer = options.maxBuffer ?? 10 * 1024 * 1024;

  return new Promise<SpawnCliResult>((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: options.env,
      stdio: ['pipe', 'pipe', 'pipe'],
      shell: isWindows,
    });

    const stdoutChunks: Buffer[] = [];
    const stderrChunks: Buffer[] = [];
    let stdoutSize = 0;
    let stderrSize = 0;
    let settled = false;

    const settleReject = (err: Error): void => {
      if (settled) return;
      settled = true;
      if (!child.killed) child.kill();
      reject(err);
    };

    const settleResolve = (result: SpawnCliResult): void => {
      if (settled) return;
      settled = true;
      resolve(result);
    };

    let timer: NodeJS.Timeout | undefined;
    if (options.timeoutMs && options.timeoutMs > 0) {
      timer = setTimeout(() => {
        settleReject(new Error(`spawnCli: timed out after ${options.timeoutMs}ms (command=${command})`));
      }, options.timeoutMs);
    }

    child.stdout?.on('data', (chunk: Buffer) => {
      stdoutSize += chunk.length;
      if (stdoutSize > maxBuffer) {
        settleReject(new Error(`spawnCli: stdout exceeded maxBuffer (${maxBuffer} bytes)`));
        return;
      }
      stdoutChunks.push(chunk);
    });

    child.stderr?.on('data', (chunk: Buffer) => {
      stderrSize += chunk.length;
      if (stderrSize > maxBuffer) {
        settleReject(new Error(`spawnCli: stderr exceeded maxBuffer (${maxBuffer} bytes)`));
        return;
      }
      stderrChunks.push(chunk);
    });

    child.on('error', (err) => {
      if (timer) clearTimeout(timer);
      settleReject(err);
    });

    child.on('close', (code) => {
      if (timer) clearTimeout(timer);
      settleResolve({
        stdout: Buffer.concat(stdoutChunks).toString('utf8'),
        stderr: Buffer.concat(stderrChunks).toString('utf8'),
        exitCode: code ?? -1,
      });
    });

    if (child.stdin) {
      if (options.stdin !== undefined) {
        child.stdin.on('error', (err: NodeJS.ErrnoException) => {
          // EPIPE when the child exits before consuming stdin — not fatal
          if (err.code === 'EPIPE') return;
          settleReject(err);
        });
        child.stdin.write(options.stdin, 'utf8', () => {
          child.stdin?.end();
        });
      } else {
        child.stdin.end();
      }
    }
  });
}
