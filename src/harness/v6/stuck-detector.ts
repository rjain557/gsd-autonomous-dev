// ═══════════════════════════════════════════════════════════
// GSD V6 — Stuck-Loop Detector
// Hashes task outputs (e.g. PatchSet). If the same hash recurs,
// the agent is looping — escalate instead of retry.
// ═══════════════════════════════════════════════════════════

import * as crypto from 'crypto';
import type { StateDB } from './state-db';
import type { TaskId } from './types';

export interface StuckSignal {
  isStuck: boolean;
  occurrences: number;
  signatureHash: string;
}

export class StuckDetector {
  private stateDB: StateDB;
  private threshold: number;

  constructor(stateDB: StateDB, threshold: number = 2) {
    this.stateDB = stateDB;
    this.threshold = threshold;
  }

  /** Hash an arbitrary artifact (stringified JSON, diff, etc.). */
  static hashArtifact(artifact: unknown): string {
    const canonical = typeof artifact === 'string' ? artifact : JSON.stringify(artifact, Object.keys(artifact ?? {}).sort());
    return crypto.createHash('sha256').update(canonical).digest('hex');
  }

  /**
   * Record an attempt. If the same signature has occurred >= threshold times,
   * returns isStuck=true.
   */
  record(taskId: TaskId, artifact: unknown, context: string = ''): StuckSignal {
    const signatureHash = StuckDetector.hashArtifact(artifact);
    const now = new Date().toISOString();
    const pattern = this.stateDB.upsertStuckPattern(signatureHash, `${taskId}: ${context}`.slice(0, 500), now);
    return {
      isStuck: pattern.occurrences >= this.threshold,
      occurrences: pattern.occurrences,
      signatureHash,
    };
  }

  /** Test-only: does a hash already exist? */
  has(signatureHash: string): boolean {
    return this.stateDB.getStuckPattern(signatureHash) !== null;
  }
}
