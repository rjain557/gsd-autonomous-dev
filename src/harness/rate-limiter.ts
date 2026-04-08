// ═══════════════════════════════════════════════════════════
// GSD Agent System — Rate Limiter
// Sliding-window rate limiter that tracks per-agent call
// history and enforces RPM limits proactively (before calls,
// not reactively on 429 errors).
// ═══════════════════════════════════════════════════════════

export interface AgentLimits {
  rpm: number;           // requests per minute
  cooldownMs: number;    // cooldown period after hitting limit
  safetyFactor: number;  // fraction of RPM to actually use (0.8 = 80%)
}

interface CallRecord {
  timestamp: number;
}

export class RateLimiter {
  private callHistory = new Map<string, CallRecord[]>();
  private cooldowns = new Map<string, number>(); // agentId → cooldown-until timestamp
  private limits: Map<string, AgentLimits>;
  private defaultSafetyFactor: number;

  constructor(defaultSafetyFactor: number = 0.8) {
    this.defaultSafetyFactor = defaultSafetyFactor;
    this.limits = new Map();
  }

  /** Register an agent's rate limits. */
  registerAgent(agentId: string, limits: AgentLimits): void {
    this.limits.set(agentId, limits);
    if (!this.callHistory.has(agentId)) {
      this.callHistory.set(agentId, []);
    }
  }

  /**
   * Wait until a slot is available for this agent.
   * Returns immediately if under limit, sleeps if at capacity.
   */
  async waitForSlot(agentId: string): Promise<void> {
    const limits = this.limits.get(agentId);
    if (!limits) return; // No limits registered — proceed immediately

    // Check cooldown first
    const cooldownUntil = this.cooldowns.get(agentId) ?? 0;
    const now = Date.now();
    if (now < cooldownUntil) {
      const waitMs = cooldownUntil - now;
      console.log(`[RATE] ${agentId} on cooldown — waiting ${Math.ceil(waitMs / 1000)}s`);
      await this.sleep(waitMs);
    }

    // Sliding window: prune calls older than 60s
    const history = this.callHistory.get(agentId) ?? [];
    const windowStart = Date.now() - 60_000;
    const recent = history.filter(c => c.timestamp > windowStart);
    this.callHistory.set(agentId, recent);

    // Check if at effective RPM limit
    const effectiveRpm = Math.floor(limits.rpm * (limits.safetyFactor ?? this.defaultSafetyFactor));
    if (recent.length >= effectiveRpm) {
      // Wait until the oldest call in the window expires
      const oldestInWindow = recent[0].timestamp;
      const waitMs = (oldestInWindow + 60_000) - Date.now() + 100; // +100ms buffer
      if (waitMs > 0) {
        console.log(`[RATE] ${agentId} at ${recent.length}/${effectiveRpm} RPM — waiting ${Math.ceil(waitMs / 1000)}s`);
        await this.sleep(waitMs);
      }
    }
  }

  /** Record a call for rate tracking. */
  recordCall(agentId: string): void {
    const history = this.callHistory.get(agentId) ?? [];
    history.push({ timestamp: Date.now() });
    this.callHistory.set(agentId, history);
  }

  /** Put an agent on cooldown (e.g., after hitting a 429). */
  setCooldown(agentId: string, durationMs?: number): void {
    const limits = this.limits.get(agentId);
    const cooldownMs = durationMs ?? limits?.cooldownMs ?? 30_000;
    this.cooldowns.set(agentId, Date.now() + cooldownMs);
    console.log(`[RATE] ${agentId} entering cooldown for ${Math.ceil(cooldownMs / 1000)}s`);
  }

  /** Check if an agent is available (not on cooldown, under RPM). */
  isAvailable(agentId: string): boolean {
    // Check cooldown
    const cooldownUntil = this.cooldowns.get(agentId) ?? 0;
    if (Date.now() < cooldownUntil) return false;

    // Check RPM
    const limits = this.limits.get(agentId);
    if (!limits) return true;

    const history = this.callHistory.get(agentId) ?? [];
    const windowStart = Date.now() - 60_000;
    const recent = history.filter(c => c.timestamp > windowStart);
    const effectiveRpm = Math.floor(limits.rpm * (limits.safetyFactor ?? this.defaultSafetyFactor));

    return recent.length < effectiveRpm;
  }

  /**
   * Pick the best available agent from a priority-ordered list.
   * Returns the first agent that isn't on cooldown and has RPM capacity.
   * Returns null if all agents are exhausted.
   */
  pickAvailable(agentIds: string[]): string | null {
    for (const id of agentIds) {
      if (this.isAvailable(id)) return id;
    }
    return null;
  }

  /** Get status of all registered agents. */
  getStatus(): Map<string, { available: boolean; recentCalls: number; effectiveRpm: number; cooldownRemainingSec: number }> {
    const result = new Map<string, { available: boolean; recentCalls: number; effectiveRpm: number; cooldownRemainingSec: number }>();

    for (const [agentId, limits] of this.limits) {
      const history = this.callHistory.get(agentId) ?? [];
      const windowStart = Date.now() - 60_000;
      const recent = history.filter(c => c.timestamp > windowStart);
      const effectiveRpm = Math.floor(limits.rpm * (limits.safetyFactor ?? this.defaultSafetyFactor));
      const cooldownUntil = this.cooldowns.get(agentId) ?? 0;
      const cooldownRemainingSec = Math.max(0, Math.ceil((cooldownUntil - Date.now()) / 1000));

      result.set(agentId, {
        available: this.isAvailable(agentId),
        recentCalls: recent.length,
        effectiveRpm,
        cooldownRemainingSec,
      });
    }

    return result;
  }

  private sleep(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }
}
