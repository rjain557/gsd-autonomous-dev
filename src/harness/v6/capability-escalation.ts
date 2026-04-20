// ═══════════════════════════════════════════════════════════
// GSD V6 — Depth-First Capability Escalation
// When any agent returns a CapabilityGap, the orchestrator
// pauses the current slice, records the gap to SQLite, and
// either:
//   - creates a new "capability-fill" slice to build the missing
//     capability, then resumes; OR
//   - halts with a clear gap description for the operator.
// ═══════════════════════════════════════════════════════════

import type { StateDB } from './state-db';
import type { CapabilityGap, MilestoneId, SliceId, Slice } from './types';
import type { ObservabilityLogger } from './observability-logger';

export type EscalationResolution = 'halt' | 'inline-fix' | 'new-slice' | 'skip';

export interface EscalationPolicy {
  /** Keyword → resolution map; first match wins. Default: 'halt' */
  rules: Array<{ matches: RegExp; resolution: EscalationResolution; reason: string }>;
  defaultResolution: EscalationResolution;
}

export const DEFAULT_ESCALATION_POLICY: EscalationPolicy = {
  rules: [
    { matches: /semgrep rule/i,       resolution: 'new-slice', reason: 'Author the missing Semgrep rule in a dedicated capability slice.' },
    { matches: /vault note/i,         resolution: 'new-slice', reason: 'Author the missing agent/knowledge note.' },
    { matches: /deploy target/i,      resolution: 'halt',      reason: 'Deploy target config missing — operator must fix memory/knowledge/deploy-config.md.' },
    { matches: /tool not installed/i, resolution: 'halt',      reason: 'External tool missing — operator must install.' },
  ],
  defaultResolution: 'halt',
};

export interface EscalationOutcome {
  resolution: EscalationResolution;
  reason: string;
  newSliceId?: SliceId;
}

export class CapabilityEscalator {
  private db: StateDB;
  private milestoneId: MilestoneId;
  private policy: EscalationPolicy;
  private obs: ObservabilityLogger | null;

  constructor(db: StateDB, milestoneId: MilestoneId, obs: ObservabilityLogger | null = null, policy: EscalationPolicy = DEFAULT_ESCALATION_POLICY) {
    this.db = db;
    this.milestoneId = milestoneId;
    this.policy = policy;
    this.obs = obs;
  }

  /** Decide how to resolve a gap based on policy. */
  resolve(gap: CapabilityGap): EscalationOutcome {
    for (const rule of this.policy.rules) {
      if (rule.matches.test(gap.missing) || rule.matches.test(gap.suggestedFix)) {
        return { resolution: rule.resolution, reason: rule.reason };
      }
    }
    return { resolution: this.policy.defaultResolution, reason: 'No matching policy rule; default applied.' };
  }

  /**
   * Handle a gap — persist it as a decision and, if policy says so, create a
   * new capability-fill slice to address it.
   */
  handle(gap: CapabilityGap, currentSliceId: SliceId): EscalationOutcome {
    const outcome = this.resolve(gap);
    const now = new Date().toISOString();

    this.db.recordDecision({
      milestoneId: this.milestoneId,
      sliceId: currentSliceId,
      timestamp: now,
      action: `capability-gap:${outcome.resolution}`,
      reason: gap.missing,
      evidence: JSON.stringify({ gap, outcome }),
    });
    this.obs?.log('router-decisions', 'capability-gap', { gap, outcome });

    if (outcome.resolution === 'new-slice') {
      const existingSlices = this.db.listSlicesForMilestone(this.milestoneId);
      const nextNum = existingSlices.length + 1;
      const newSliceId: SliceId = `S${String(nextNum).padStart(2, '0')}-cap`;
      const slice: Slice = {
        id: newSliceId,
        milestoneId: this.milestoneId,
        name: `capability-fill: ${gap.missing.slice(0, 60)}`,
        description: `Blocker from slice ${currentSliceId}. Fix: ${gap.suggestedFix}`,
        status: 'pending',
        dependsOnSliceIds: [],
        startedAt: null,
        completedAt: null,
      };
      this.db.createSlice(slice);
      outcome.newSliceId = newSliceId;
    }

    return outcome;
  }
}

/** Type guard for agent outputs that carry a capability gap. */
export function isCapabilityGap(output: unknown): output is CapabilityGap {
  return (
    typeof output === 'object' &&
    output !== null &&
    (output as Record<string, unknown>).kind === 'capability-gap' &&
    typeof (output as CapabilityGap).missing === 'string'
  );
}
