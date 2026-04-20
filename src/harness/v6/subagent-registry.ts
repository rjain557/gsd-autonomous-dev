// ═══════════════════════════════════════════════════════════
// GSD V6 — Subagent Registry
// Allows top-level agents (Blueprint, Review, Remediation, E2E)
// to delegate narrow tasks to Scout (vault summaries) and
// Researcher (GitNexus/Graphify/Semgrep queries).
// ═══════════════════════════════════════════════════════════

import type { VaultAdapter } from '../vault-adapter';
import type { HookSystem } from '../hooks';
import type { PipelineState } from '../types';
import { ScoutAgent } from '../../agents/scout-agent';
import { ResearcherAgent } from '../../agents/researcher-agent';
import type { ScoutInput, ScoutOutput } from '../../agents/scout-agent';
import type { ResearcherInput, ResearcherOutput } from '../../agents/researcher-agent';

export class SubagentRegistry {
  private scout: ScoutAgent | null = null;
  private researcher: ResearcherAgent | null = null;

  private vault: VaultAdapter;
  private hooks: HookSystem;
  private state: PipelineState;

  constructor(vault: VaultAdapter, hooks: HookSystem, state: PipelineState) {
    this.vault = vault;
    this.hooks = hooks;
    this.state = state;
  }

  private async getScout(): Promise<ScoutAgent> {
    if (!this.scout) {
      this.scout = new ScoutAgent('scout-agent', this.vault, this.hooks, this.state);
      await this.scout.initialize();
    }
    return this.scout;
  }

  private async getResearcher(): Promise<ResearcherAgent> {
    if (!this.researcher) {
      this.researcher = new ResearcherAgent('researcher-agent', this.vault, this.hooks, this.state);
      await this.researcher.initialize();
    }
    return this.researcher;
  }

  /** Delegate a vault-summary lookup to Scout. */
  async scoutVault(input: ScoutInput): Promise<ScoutOutput> {
    const agent = await this.getScout();
    return (await agent.execute(input)) as ScoutOutput;
  }

  /** Delegate a code-graph or tool query to Researcher. */
  async researchCode(input: ResearcherInput): Promise<ResearcherOutput> {
    const agent = await this.getResearcher();
    return (await agent.execute(input)) as ResearcherOutput;
  }
}
