// ═══════════════════════════════════════════════════════════
// GSD V6 — Budget-Pressure Model Router
// Downgrades model selection at 50/75/90% budget thresholds.
// ═══════════════════════════════════════════════════════════

import type { BudgetStatus, BudgetTier } from './types';

export type ModelTier = 'premium' | 'standard' | 'cheap' | 'emergency';

/** Mapping from model tier to actual model ID. Caller may override. */
export const DEFAULT_TIER_MODELS: Record<ModelTier, string> = {
  premium: 'claude',     // CLI: claude (Sonnet)
  standard: 'codex',     // CLI: codex
  cheap: 'gemini',       // CLI: gemini (Ultra — $0 marginal, cheapest)
  emergency: 'deepseek', // API: deepseek-chat ($0.27/$1.10 per M)
};

export interface BudgetRouterOptions {
  budgetUsd: number;
  spentUsd: number;
  tierModels?: Partial<Record<ModelTier, string>>;
}

export class BudgetRouter {
  private budgetUsd: number;
  private spentUsd: number;
  private tierModels: Record<ModelTier, string>;

  constructor(opts: BudgetRouterOptions) {
    this.budgetUsd = opts.budgetUsd;
    this.spentUsd = opts.spentUsd;
    this.tierModels = { ...DEFAULT_TIER_MODELS, ...opts.tierModels };
  }

  get status(): BudgetStatus {
    const percentUsed = this.budgetUsd > 0 ? (this.spentUsd / this.budgetUsd) * 100 : 0;
    let tier: BudgetTier;
    if (percentUsed >= 90) tier = 'emergency';
    else if (percentUsed >= 75) tier = 'downgrade-hard';
    else if (percentUsed >= 50) tier = 'downgrade-soft';
    else tier = 'normal';
    return { spentUsd: this.spentUsd, budgetUsd: this.budgetUsd, percentUsed, tier };
  }

  /**
   * Pick a model for a given preferred tier, possibly downgraded by budget.
   * Returns the actual model CLI/ID to invoke.
   */
  pickModel(preferred: ModelTier = 'premium'): { model: string; tier: ModelTier; reason: string } {
    const s = this.status;
    let effective = preferred;
    let reason = `budget ${s.percentUsed.toFixed(1)}% — no downgrade`;

    if (s.tier === 'emergency') {
      effective = 'emergency';
      reason = `budget >= 90% — forced emergency tier (${this.tierModels.emergency})`;
    } else if (s.tier === 'downgrade-hard' && preferred !== 'cheap' && preferred !== 'emergency') {
      effective = 'cheap';
      reason = `budget >= 75% — downgraded ${preferred} -> cheap`;
    } else if (s.tier === 'downgrade-soft' && preferred === 'premium') {
      effective = 'standard';
      reason = `budget >= 50% — downgraded premium -> standard`;
    }

    return { model: this.tierModels[effective], tier: effective, reason };
  }

  updateSpend(newSpentUsd: number): void {
    this.spentUsd = newSpentUsd;
  }
}
