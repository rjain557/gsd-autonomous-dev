// ═══════════════════════════════════════════════════════════
// GSD Agent System — Default Hooks
// Built-in hook implementations for logging, cost tracking,
// vault logging, validation, retry, escalation, and deploy audit.
// ═══════════════════════════════════════════════════════════

import type { HookSystem } from './hooks';
import type { VaultAdapter } from './vault-adapter';
import type { HookContext, PipelineState, CostEntry, GateResult, DeployRecord } from './types';

// ── Cost estimation helpers ─────────────────────────────────

function estimateTokens(obj: unknown): number {
  const json = JSON.stringify(obj ?? '');
  // ~1 token per 4 characters (English text average)
  return Math.ceil(json.length / 4);
}

// Model-specific pricing per million tokens (input/output average)
// Subscription CLIs: $0 marginal cost. API models: actual per-token rates.
const MODEL_COST_PER_M: Record<string, number> = {
  claude:   0,     // Claude Max subscription — $0 marginal
  codex:    0,     // ChatGPT Max subscription — $0 marginal
  gemini:   0,     // Gemini Ultra subscription — $0 marginal
  deepseek: 0.35,  // $0.28 input + $0.42 output average
  minimax:  0.75,  // $0.29 input + $1.20 output average
};

function estimateCostUsd(tokens: number, agentId?: string): number {
  // Resolve the CLI model from the agent ID (all subscription agents = $0)
  const cliModel = agentId?.replace(/-agent$/, '').split('-')[0] ?? '';
  const costPerM = MODEL_COST_PER_M[cliModel] ?? 0;
  return (tokens / 1_000_000) * costPerM;
}

// ── Register all default hooks ──────────────────────────────

export function registerDefaultHooks(
  hooks: HookSystem,
  vault: VaultAdapter,
  getState: () => PipelineState,
): void {
  // 1. Logger — onBeforeRun
  hooks.register('onBeforeRun', 'logger', async (ctx: HookContext) => {
    const state = getState();
    console.log(
      `[AGENT START] ${ctx.agentId} run=${ctx.runId} stage=${state.currentStage}`,
    );
  });

  // 2. Cost Tracker — onBeforeRun + onAfterRun
  hooks.register('onBeforeRun', 'cost-tracker', async (ctx: HookContext) => {
    // Store input token estimate in context for later
    (ctx as unknown as Record<string, unknown>)._inputTokenEstimate = estimateTokens(ctx.input);
  });

  hooks.register('onAfterRun', 'cost-tracker', async (ctx: HookContext) => {
    const state = getState();
    const inputTokens = ((ctx as unknown as Record<string, unknown>)._inputTokenEstimate as number) ?? 0;
    const outputTokens = estimateTokens(ctx.output);
    const cost: CostEntry = {
      agentId: ctx.agentId!,
      stage: state.currentStage,
      inputTokens,
      outputTokens,
      estimatedCostUsd: estimateCostUsd(inputTokens + outputTokens, ctx.agentId),
    };
    state.costAccumulator.push(cost);
  });

  // 3. Vault Run Logger — onAfterRun
  hooks.register('onAfterRun', 'vault-run-logger', async (ctx: HookContext) => {
    if (ctx.agentId && ctx.input && ctx.output) {
      await vault.logRun(
        ctx.runId,
        ctx.agentId,
        ctx.input,
        ctx.output,
        ctx.durationMs ?? 0,
      );
    }
  });

  // 4. Result Validator — onAfterRun
  hooks.register('onAfterRun', 'result-validator', async (ctx: HookContext) => {
    if (!ctx.output) {
      throw new Error(`Agent ${ctx.agentId} returned null/undefined output`);
    }

    // Type-specific validation based on stage
    const state = getState();
    switch (state.currentStage) {
      case 'blueprint': {
        const report = ctx.output as Record<string, unknown>;
        if (!Array.isArray(report.aligned) || !Array.isArray(report.drifted)) {
          throw new Error(`BlueprintAnalysisAgent output missing required fields: aligned, drifted`);
        }
        break;
      }
      case 'review': {
        const result = ctx.output as Record<string, unknown>;
        if (typeof result.passed !== 'boolean' || !Array.isArray(result.issues)) {
          throw new Error(`CodeReviewAgent output missing required fields: passed, issues`);
        }
        break;
      }
      case 'gate': {
        const gate = ctx.output as Record<string, unknown>;
        if (typeof gate.passed !== 'boolean' || !Array.isArray(gate.evidence)) {
          throw new Error(`QualityGateAgent output missing required fields: passed, evidence`);
        }
        break;
      }
      case 'deploy': {
        const deploy = ctx.output as Record<string, unknown>;
        if (typeof deploy.success !== 'boolean' || !Array.isArray(deploy.steps)) {
          throw new Error(`DeployAgent output missing required fields: success, steps`);
        }
        break;
      }
    }
  });

  // 5. Retry with Backoff — onError
  hooks.register('onError', 'retry-with-backoff', async (ctx: HookContext) => {
    const attempt = ctx.attempt ?? 0;
    const maxRetries = 3; // Default; agents override via vault config

    if (attempt < maxRetries) {
      const backoffMs = Math.pow(2, attempt) * 1000;
      console.log(
        `[RETRY] ${ctx.agentId} attempt ${attempt + 1}/${maxRetries} — waiting ${backoffMs}ms`,
      );
      await new Promise(resolve => setTimeout(resolve, backoffMs));
    }
  });

  // 6. Escalation Alert — onError (fires after retries exhausted)
  hooks.register('onError', 'escalation-alert', async (ctx: HookContext) => {
    const attempt = ctx.attempt ?? 0;
    const maxRetries = 3;

    if (attempt >= maxRetries) {
      const state = getState();
      const alertMessage = [
        `## ESCALATION ALERT`,
        '',
        `**Agent:** ${ctx.agentId}`,
        `**Stage:** ${state.currentStage}`,
        `**Error:** ${ctx.error?.message ?? 'Unknown error'}`,
        `**Attempts:** ${attempt}`,
        '',
        `### What to do next`,
        `1. Check the session log for this run: sessions/`,
        `2. Read the agent's failure modes: agents/${ctx.agentId}.md`,
        `3. Fix the underlying issue`,
        `4. Resume with: \`pipeline run --from-stage ${state.currentStage}\``,
      ].join('\n');

      await vault.append(`sessions/alerts.md`, alertMessage);
      state.status = 'paused';

      console.error(
        `\n[ESCALATION] ${ctx.agentId} failed after ${attempt} attempts.\n` +
        `  Error: ${ctx.error?.message}\n` +
        `  Action: Pipeline paused. See memory/sessions/alerts.md\n` +
        `  Resume: pipeline run --from-stage ${state.currentStage}\n`,
      );
    }
  });

  // 7. Deploy Audit — onDeployStart + onDeployComplete + onDeployRollback
  hooks.register('onDeployStart', 'deploy-audit', async (ctx: HookContext) => {
    const entry = [
      `## Deploy Started`,
      '',
      `| Field | Value |`,
      `|---|---|`,
      `| Run | ${ctx.runId} |`,
      `| Time | ${new Date().toISOString()} |`,
      `| Stage | deploy |`,
    ].join('\n');

    await vault.append(`sessions/deploy-audit.md`, entry);
  });

  hooks.register('onDeployComplete', 'deploy-audit', async (ctx: HookContext) => {
    const record = ctx.output as DeployRecord | undefined;
    const entry = [
      `## Deploy Completed`,
      '',
      `| Field | Value |`,
      `|---|---|`,
      `| Run | ${ctx.runId} |`,
      `| Time | ${new Date().toISOString()} |`,
      `| Success | ${record?.success ?? 'unknown'} |`,
      `| Environment | ${record?.environment ?? 'unknown'} |`,
      `| Commit | ${record?.commitSha ?? 'unknown'} |`,
    ].join('\n');

    await vault.append(`sessions/deploy-audit.md`, entry);
  });

  hooks.register('onDeployRollback', 'deploy-audit', async (ctx: HookContext) => {
    const record = ctx.output as DeployRecord | undefined;
    const entry = [
      `## DEPLOY ROLLBACK`,
      '',
      `| Field | Value |`,
      `|---|---|`,
      `| Run | ${ctx.runId} |`,
      `| Time | ${new Date().toISOString()} |`,
      `| Rollback executed | ${record?.rollbackExecuted ?? 'unknown'} |`,
      `| Error | ${ctx.error?.message ?? 'unknown'} |`,
      '',
      `**CRITICAL:** Rollback was triggered. Verify manually that the previous version is serving correctly.`,
    ].join('\n');

    await vault.append(`sessions/deploy-audit.md`, entry);
  });
}
