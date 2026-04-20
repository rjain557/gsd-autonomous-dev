// ═══════════════════════════════════════════════════════════
// GSD V6 — Capability-Aware Router
// Scores agents against task metadata and picks the best
// available agent for a given task.
// ═══════════════════════════════════════════════════════════

import type { AgentCapability } from './types';

export interface TaskDescriptor {
  languages: string[];
  domains: string[];
  tokenSize: number;
  stage?: string;
}

export interface RoutingDecision {
  agentId: string;
  score: number;
  breakdown: {
    languageMatch: number;
    domainMatch: number;
    contextHeadroom: number;
    quality: number;
    availability: number;
  };
  reason: string;
}

export class CapabilityRouter {
  private agents: AgentCapability[];

  constructor(agents: AgentCapability[]) {
    this.agents = agents;
  }

  score(agent: AgentCapability, task: TaskDescriptor): RoutingDecision {
    const langMatches = agent.languages.filter((l) => task.languages.includes(l)).length;
    const languageMatch = task.languages.length > 0 ? langMatches / task.languages.length : 1;

    const domainMatches = agent.domains.filter((d) => task.domains.includes(d)).length;
    const domainMatch = task.domains.length > 0 ? domainMatches / task.domains.length : 1;

    const contextHeadroom = task.tokenSize > 0
      ? Math.min(1, Math.max(0, 1 - task.tokenSize / agent.maxContextTokens))
      : 1;

    const quality = agent.qualityScore;
    const availability = agent.availabilityScore;

    const score =
      0.25 * languageMatch +
      0.20 * domainMatch +
      0.15 * contextHeadroom +
      0.20 * quality +
      0.20 * availability;

    return {
      agentId: agent.agentId,
      score,
      breakdown: { languageMatch, domainMatch, contextHeadroom, quality, availability },
      reason: `score=${score.toFixed(3)} lang=${languageMatch.toFixed(2)} domain=${domainMatch.toFixed(2)} ctx=${contextHeadroom.toFixed(2)} q=${quality.toFixed(2)} avail=${availability.toFixed(2)}`,
    };
  }

  pick(task: TaskDescriptor): RoutingDecision | null {
    if (this.agents.length === 0) return null;
    const scored = this.agents.map((a) => this.score(a, task));
    scored.sort((a, b) => b.score - a.score);
    return scored[0];
  }

  rank(task: TaskDescriptor): RoutingDecision[] {
    return this.agents.map((a) => this.score(a, task)).sort((a, b) => b.score - a.score);
  }

  updateAvailability(agentId: string, availabilityScore: number): void {
    const idx = this.agents.findIndex((a) => a.agentId === agentId);
    if (idx >= 0) this.agents[idx] = { ...this.agents[idx], availabilityScore };
  }
}
