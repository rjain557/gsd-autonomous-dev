// ═══════════════════════════════════════════════════════════
// GSD V6 — Timeout Hierarchy
// Soft / idle / hard timeouts with progressive signals.
// ═══════════════════════════════════════════════════════════

import type { TaskTimeouts } from './types';
import { DEFAULT_TIMEOUTS } from './types';

export interface TimeoutHooks {
  onSoftTimeout?: () => void | Promise<void>;
  onIdleTimeout?: () => void | Promise<void>;
  onHardTimeout?: () => void | Promise<void>;
}

export interface RunWithTimeoutResult<T> {
  result: T | null;
  timedOut: boolean;
  stage: 'soft' | 'idle' | 'hard' | 'none';
  durationMs: number;
}

/**
 * Runs a promise under soft/idle/hard timeout discipline.
 * - soft fires onSoftTimeout (agent should wrap up)
 * - idle fires onIdleTimeout if no progress signal in the interval
 * - hard forcibly rejects after hardTimeout elapses
 */
export async function runWithTimeouts<T>(
  fn: (signalProgress: () => void) => Promise<T>,
  timeouts: TaskTimeouts = DEFAULT_TIMEOUTS,
  hooks: TimeoutHooks = {},
): Promise<RunWithTimeoutResult<T>> {
  const start = Date.now();
  let lastProgress = start;
  let stage: RunWithTimeoutResult<T>['stage'] = 'none';
  const signalProgress = (): void => {
    lastProgress = Date.now();
  };

  const softMs = timeouts.softTimeoutSec * 1000;
  const idleMs = timeouts.idleTimeoutSec * 1000;
  const hardMs = timeouts.hardTimeoutSec * 1000;

  let softFired = false;
  let idleFired = false;
  let hardFired = false;

  const softTimer = setTimeout(() => {
    if (!softFired && hooks.onSoftTimeout) {
      softFired = true;
      if (stage === 'none') stage = 'soft';
      void Promise.resolve(hooks.onSoftTimeout()).catch(() => undefined);
    }
  }, softMs);

  const idleTicker = setInterval(() => {
    const idle = Date.now() - lastProgress;
    if (idle > idleMs && !idleFired && hooks.onIdleTimeout) {
      idleFired = true;
      if (stage === 'none' || stage === 'soft') stage = 'idle';
      void Promise.resolve(hooks.onIdleTimeout()).catch(() => undefined);
    }
  }, Math.min(idleMs, 30_000));

  const hardPromise = new Promise<never>((_resolve, reject) => {
    setTimeout(() => {
      hardFired = true;
      stage = 'hard';
      if (hooks.onHardTimeout) void Promise.resolve(hooks.onHardTimeout()).catch(() => undefined);
      reject(new Error(`Hard timeout after ${timeouts.hardTimeoutSec}s`));
    }, hardMs);
  });

  try {
    const result = await Promise.race([fn(signalProgress), hardPromise]);
    clearTimeout(softTimer);
    clearInterval(idleTicker);
    return {
      result: result as T,
      timedOut: false,
      stage,
      durationMs: Date.now() - start,
    };
  } catch (err) {
    clearTimeout(softTimer);
    clearInterval(idleTicker);
    if (hardFired) {
      return { result: null, timedOut: true, stage: 'hard', durationMs: Date.now() - start };
    }
    throw err;
  }
}
