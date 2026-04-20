// ═══════════════════════════════════════════════════════════
// GSD Agent System — BaseAgent
// Abstract base class for all pipeline agents. Handles the
// run lifecycle (hooks, timing, error handling) so subclasses
// only implement pure domain logic in run().
// ═══════════════════════════════════════════════════════════

import Anthropic from '@anthropic-ai/sdk';
import type {
  AgentId,
  AgentInput,
  AgentOutput,
  PipelineState,
  VaultNoteMeta,
} from './types';
import { AgentTimeoutError } from './types';
import type { VaultAdapter } from './vault-adapter';
import type { HookSystem } from './hooks';
import type { RateLimiter } from './rate-limiter';
import { runWithTimeouts } from './v6/timeout-hierarchy';
import type { TaskTimeouts } from './v6/types';
import type { ObservabilityLogger, ObservabilityCategory } from './v6/observability-logger';
import type { BudgetRouter, ModelTier } from './v6/budget-router';
import { compactedRun, type CompactedResult } from './v6/compacted-exec';
import { spawnCli } from './v6/spawn-cli';
import type { SubagentRegistry } from './v6/subagent-registry';
import type { ProjectStackContext } from './project-stack-context';
import { DEFAULT_STACK_CONTEXT, renderStackContextBlock } from './project-stack-context';

export abstract class BaseAgent {
  protected agentId: AgentId;
  protected vaultAdapter: VaultAdapter;
  protected hooks: HookSystem;
  protected state: PipelineState;
  protected agentConfig: VaultNoteMeta = {};
  protected systemPrompt: string = '';
  private rateLimiter: RateLimiter | null = null;
  private cliAgentId: string = 'claude'; // which CLI model this agent routes to
  // V6: milestone context (optional — null for standalone slice/phase runs)
  protected observability: ObservabilityLogger | null = null;
  protected budgetRouter: BudgetRouter | null = null;
  protected milestoneRunId: string | null = null;
  protected compactedOutputDir: string | null = null;
  protected _subagents: SubagentRegistry | null = null;
  // v6.1.0: per-project stack context (defaults to .NET 8 when no override declared)
  protected projectStackContext: ProjectStackContext = DEFAULT_STACK_CONTEXT;

  constructor(
    agentId: AgentId,
    vault: VaultAdapter,
    hooks: HookSystem,
    state: PipelineState,
  ) {
    this.agentId = agentId;
    this.vaultAdapter = vault;
    this.hooks = hooks;
    this.state = state;
  }

  /** Attach rate limiter for RPM enforcement during LLM calls. */
  setRateLimiter(limiter: RateLimiter, cliAgentId: string): void {
    this.rateLimiter = limiter;
    this.cliAgentId = cliAgentId;
  }

  /** V6: attach milestone context so the agent can log observability + route budget. */
  setMilestoneContext(ctx: {
    observability?: ObservabilityLogger | null;
    budgetRouter?: BudgetRouter | null;
    runId?: string | null;
    compactedOutputDir?: string | null;
  }): void {
    if (ctx.observability !== undefined) this.observability = ctx.observability;
    if (ctx.budgetRouter !== undefined) this.budgetRouter = ctx.budgetRouter;
    if (ctx.runId !== undefined) this.milestoneRunId = ctx.runId;
    if (ctx.compactedOutputDir !== undefined) this.compactedOutputDir = ctx.compactedOutputDir;
  }

  /**
   * v6.1.0: attach per-project stack context. Defaults to .NET 8 when no
   * override is declared. Agents must honor this context when generating
   * artifacts (csproj TargetFramework, SDK references, architecture prose).
   */
  setProjectStackContext(ctx: ProjectStackContext): void {
    this.projectStackContext = ctx;
  }

  /**
   * v6.1.0: accessor for the project stack context. Subclasses use this
   * to derive runtime values (framework strings, SDK paths, etc.).
   */
  protected getProjectStackContext(): ProjectStackContext {
    return this.projectStackContext;
  }

  /**
   * V6: Fresh context per task — reset transient state fields before invoking run().
   * The PipelineState reference is preserved (it's the shared mutable slice state),
   * but the agent starts each call with a clean working slate: no accumulated
   * prompt context, no stale prior output, no carried-over retry state.
   *
   * Subclasses can override to clear subclass-specific fields.
   */
  protected resetTaskContext(): void {
    // BaseAgent has no accumulated context of its own, but the hook is here
    // so subclasses can wipe their per-task scratch. Called automatically
    // at the start of each execute().
  }

  /** V6: emit a structured observability event (no-op if no logger attached). */
  protected logObs(category: ObservabilityCategory, kind: string, data: Record<string, unknown>): void {
    if (!this.observability) return;
    this.observability.log(category, kind, { agentId: this.agentId, ...data });
  }

  /**
   * V6: pick the CLI model for this agent's next call based on budget pressure.
   * Returns the model ID (claude/codex/gemini/deepseek). Falls back to the
   * rate-limiter's current assignment if no budget context is attached.
   */
  protected pickModelWithBudget(preferred: ModelTier = 'premium'): string {
    if (!this.budgetRouter) return this.cliAgentId;
    const pick = this.budgetRouter.pickModel(preferred);
    this.logObs('router-decisions', 'budget-routed', {
      preferred,
      picked: pick.model,
      tier: pick.tier,
      reason: pick.reason,
    });
    return pick.model;
  }

  /** V6: lazy-initialized subagent registry. Subclasses can call this.subagents().scoutVault(...). */
  protected subagents(): SubagentRegistry {
    if (!this._subagents) {
      // Dynamic require breaks the circular dep (base-agent ↔ subagent-registry)
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      const { SubagentRegistry: Cls } = require('./v6/subagent-registry') as typeof import('./v6/subagent-registry');
      this._subagents = new Cls(this.vaultAdapter, this.hooks, this.state);
    }
    return this._subagents;
  }

  /** V6: run a shell command with raw output persisted to disk, summary returned. */
  protected async compactedExec(
    command: string,
    args: string[],
    opts: { cwd?: string; timeoutMs?: number } = {},
  ): Promise<CompactedResult> {
    const outputDir = this.compactedOutputDir ?? './memory/observability/raw-tool-output';
    const runId = this.milestoneRunId ?? this.state.runId;
    const result = await compactedRun(command, args, {
      cwd: opts.cwd ?? process.cwd(),
      outputDir,
      runId,
      timeoutMs: opts.timeoutMs,
    });
    this.logObs('build-output', 'compacted-exec', {
      command,
      args: args.slice(0, 5),
      exitCode: result.exitCode,
      rawSize: result.rawSize,
      rawPath: result.rawPath,
      durationMs: result.durationMs,
    });
    return result;
  }

  /** Load agent config and system prompt from vault note. */
  async initialize(): Promise<void> {
    const note = await this.vaultAdapter.read(`agents/${this.agentId}.md`);
    this.agentConfig = note.meta;

    // Extract system prompt from the note body
    const promptMatch = note.body.match(/## System prompt\s*\n([\s\S]*?)(?=\n## |\n$)/);
    this.systemPrompt = promptMatch ? promptMatch[1].trim() : note.body;
  }

  /**
   * The run lifecycle — DO NOT override this in subclasses.
   * Handles hook firing, timing, error handling, and retries.
   */
  async execute(input: AgentInput): Promise<AgentOutput> {
    const startTime = Date.now();

    // V6: fresh task context — wipe any per-task scratch before hooks fire
    this.resetTaskContext();

    await this.hooks.fire('onBeforeRun', {
      runId: this.state.runId,
      agentId: this.agentId,
      input,
      state: this.state,
    });

    try {
      // V6: timeout hierarchy (soft / idle / hard)
      const hard = this.agentConfig.timeout_seconds ?? 120;
      const timeouts: TaskTimeouts = {
        softTimeoutSec: Math.max(30, Math.floor(hard * 0.4)),
        idleTimeoutSec: Math.max(60, Math.floor(hard * 0.6)),
        hardTimeoutSec: hard,
      };
      const runResult = await runWithTimeouts<AgentOutput>(
        async (_signalProgress) => this.run(input),
        timeouts,
        {
          onSoftTimeout: async () => {
            console.log(`[${this.agentId}] soft timeout (${timeouts.softTimeoutSec}s) — wrap up signal`);
          },
          onIdleTimeout: async () => {
            console.log(`[${this.agentId}] idle timeout (${timeouts.idleTimeoutSec}s) — progress probe`);
          },
          onHardTimeout: async () => {
            console.error(`[${this.agentId}] HARD timeout (${timeouts.hardTimeoutSec}s) — forensic bundle will be required`);
          },
        },
      );
      if (runResult.timedOut || runResult.result === null) {
        throw new AgentTimeoutError(this.agentId, timeouts.hardTimeoutSec * 1000);
      }
      const output = runResult.result;

      const durationMs = Date.now() - startTime;
      await this.hooks.fire('onAfterRun', {
        runId: this.state.runId,
        agentId: this.agentId,
        input,
        output,
        state: this.state,
        durationMs,
      });

      return output;
    } catch (error) {
      await this.hooks.fire('onError', {
        runId: this.state.runId,
        agentId: this.agentId,
        input,
        error: error instanceof Error ? error : new Error(String(error)),
        state: this.state,
      });
      throw error;
    }
  }

  /**
   * Subclasses implement this — pure domain logic, no hooks, no state writes.
   * This method should be deterministic for a given input (modulo LLM calls).
   */
  protected abstract run(input: AgentInput): Promise<AgentOutput>;

  /**
   * Build a context-injected system prompt from vault.
   * Reads the agent's configured "reads" notes and appends them.
   *
   * v6.1.0: every prompt receives a `PROJECT STACK CONTEXT` block so
   * agents honor the project's declared backend framework, SDK, and
   * related stack choices (default .NET 8 preserved for backward compat).
   */
  protected async buildSystemPrompt(extraNotes?: string[]): Promise<string> {
    const readPaths = (this.agentConfig.reads as string[] | undefined) ?? [];
    const allPaths = [...readPaths, ...(extraNotes ?? [])];

    const stackBlock = renderStackContextBlock(this.projectStackContext);

    if (allPaths.length === 0) {
      return `${this.systemPrompt}\n\n${stackBlock}`;
    }

    const context = await this.vaultAdapter.buildContext(allPaths);
    return `${this.systemPrompt}\n\n${stackBlock}\n\n---\n\n# Context from vault\n\n${context}`;
  }

  /**
   * Call the LLM. Strategy selection:
   * 1. CLI first (uses OAuth subscription — no per-token cost for Claude/Codex/Gemini)
   * 2. SDK fallback (uses ANTHROPIC_API_KEY — pay-per-token, but supports tool_use structured output)
   *
   * Set GSD_LLM_MODE=sdk to force SDK, or GSD_LLM_MODE=cli to force CLI.
   */
  protected async callLLM(
    systemPromptText: string,
    userMessage: string,
    jsonSchema?: Record<string, unknown>,
  ): Promise<string> {
    const model = (this.agentConfig.model as string) ?? 'claude-sonnet-4-6';
    const mode = process.env.GSD_LLM_MODE ?? 'cli';

    // Enforce rate limit BEFORE the call
    if (this.rateLimiter) {
      await this.rateLimiter.waitForSlot(this.cliAgentId);
    }

    try {
      let result: string;

      if (mode === 'sdk') {
        // SDK mode: always use API key (pay-per-token)
        result = await this.callLLMWithSDK(systemPromptText, userMessage, model, jsonSchema);
      } else {
        // CLI mode: use OAuth subscription ($0 marginal cost)
        const userMsg = jsonSchema
          ? userMessage + `\n\nIMPORTANT: Return ONLY valid JSON matching this schema:\n${JSON.stringify(jsonSchema, null, 2)}\n\nReturn ONLY the JSON object, no markdown, no explanation.`
          : userMessage;
        try {
          result = await this.callLLMWithCLI(systemPromptText, userMsg, model);
        } catch (cliErr) {
          // AUTO-FALLBACK: If CLI fails (quota exhaustion, rate limit, CLI not found)
          // and API key is available, retry with SDK (pay-per-token backup)
          if (process.env.ANTHROPIC_API_KEY) {
            console.log(`[LLM] CLI failed for ${this.agentId}, falling back to API key: ${cliErr instanceof Error ? cliErr.message.substring(0, 80) : 'unknown'}`);
            if (this.rateLimiter) {
              this.rateLimiter.setCooldown(this.cliAgentId, 5 * 60_000);
            }
            result = await this.callLLMWithSDK(systemPromptText, userMessage, model, jsonSchema);
          } else {
            throw cliErr;
          }
        }
      }

      return result;
    } finally {
      if (this.rateLimiter) {
        this.rateLimiter.recordCall(this.cliAgentId);
      }
    }
  }

  /** Anthropic SDK path — uses tool_use for structured JSON when schema provided. */
  private async callLLMWithSDK(
    systemPromptText: string,
    userMessage: string,
    model: string,
    jsonSchema?: Record<string, unknown>,
  ): Promise<string> {
    const client = new Anthropic();
    const timeout = ((this.agentConfig.timeout_seconds as number) ?? 120) * 1000;

    try {
      if (jsonSchema) {
        // Use tool_use to get structured JSON output
        const response = await client.messages.create({
          model,
          max_tokens: 8192,
          system: systemPromptText,
          messages: [{ role: 'user', content: userMessage }],
          tools: [{
            name: 'structured_output',
            description: 'Return the analysis result as structured JSON',
            input_schema: jsonSchema as Anthropic.Tool.InputSchema,
          }],
          tool_choice: { type: 'tool', name: 'structured_output' },
        }, { timeout });

        // Extract the tool_use result
        for (const block of response.content) {
          if (block.type === 'tool_use' && block.name === 'structured_output') {
            return JSON.stringify(block.input);
          }
        }
        throw new Error('No tool_use block in response');
      }

      // Plain text response (no schema)
      const response = await client.messages.create({
        model,
        max_tokens: 8192,
        system: systemPromptText,
        messages: [{ role: 'user', content: userMessage }],
      }, { timeout });

      return response.content
        .filter(b => b.type === 'text')
        .map(b => (b as Anthropic.TextBlock).text)
        .join('\n');
    } catch (error) {
      throw new Error(
        `SDK call failed for ${this.agentId}: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }

  /**
   * CLI fallback path — used when ANTHROPIC_API_KEY is not set.
   *
   * Uses spawnCli so that Windows .cmd shims resolve (via shell: true) AND
   * the prompt text flows through stdin rather than argv — which means
   * quotes, $, backticks, &, |, and other shell metacharacters in the
   * prompt are never parsed by a shell. argv contains only safe constants.
   */
  private async callLLMWithCLI(
    systemPromptText: string,
    userMessage: string,
    model: string,
  ): Promise<string> {
    const fullPrompt = `${systemPromptText}\n\n---\n\nUser request:\n${userMessage}`;
    const timeoutMs = ((this.agentConfig.timeout_seconds as number) ?? 120) * 1000;

    try {
      const { stdout, stderr, exitCode } = await spawnCli(
        'claude',
        [
          '--model', model,
          '--print',
          '--output-format', 'text',
          '--max-turns', '1',
        ],
        {
          stdin: fullPrompt,
          timeoutMs,
          maxBuffer: 10 * 1024 * 1024,
        },
      );

      if (exitCode !== 0) {
        throw new Error(
          `CLI exited ${exitCode}: ${stderr.slice(0, 500) || '(no stderr)'}`,
        );
      }

      return stdout.trim();
    } catch (error) {
      throw new Error(
        `CLI call failed for ${this.agentId}: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }

  /**
   * Extract JSON from an LLM response string. Tries multiple strategies:
   * 1. Parse entire response as JSON
   * 2. Extract from ```json code fences
   * 3. Find outermost balanced braces
   * Throws ParseError instead of silently returning fallback.
   */
  protected extractJSON<T>(response: string): T {
    // Strategy 1: entire response is JSON
    try {
      return JSON.parse(response.trim());
    } catch { /* continue */ }

    // Strategy 2: extract from ```json ... ``` code fence
    const fenceMatch = response.match(/```(?:json)?\s*\n?([\s\S]*?)\n?\s*```/);
    if (fenceMatch) {
      try {
        return JSON.parse(fenceMatch[1].trim());
      } catch { /* continue */ }
    }

    // Strategy 3: find balanced outermost braces (handles nested objects)
    const jsonStr = this.extractBalancedJSON(response);
    if (jsonStr) {
      try {
        return JSON.parse(jsonStr);
      } catch { /* continue */ }
    }

    // Strategy 4: find balanced outermost brackets (array response)
    const arrayStr = this.extractBalancedArray(response);
    if (arrayStr) {
      try {
        return JSON.parse(arrayStr);
      } catch { /* continue */ }
    }

    // Strategy 5: attempt to fix common JSON errors (trailing commas, unquoted keys)
    const cleaned = response
      .replace(/,\s*([}\]])/g, '$1')           // Remove trailing commas
      .replace(/(['"])?(\w+)(['"])?\s*:/g, '"$2":'); // Quote unquoted keys
    const cleanedJson = this.extractBalancedJSON(cleaned);
    if (cleanedJson) {
      try {
        return JSON.parse(cleanedJson);
      } catch { /* continue */ }
    }

    throw new Error(
      `Failed to extract valid JSON from LLM response (${response.length} chars). ` +
      `First 200 chars: ${response.substring(0, 200)}`
    );
  }

  /** Find the outermost balanced { } in a string. */
  private extractBalancedJSON(text: string): string | null {
    let start = -1;
    let depth = 0;

    for (let i = 0; i < text.length; i++) {
      if (text[i] === '{') {
        if (depth === 0) start = i;
        depth++;
      } else if (text[i] === '}') {
        depth--;
        if (depth === 0 && start !== -1) {
          return text.substring(start, i + 1);
        }
      }
    }

    return null;
  }

  /** Find the outermost balanced [ ] in a string. */
  private extractBalancedArray(text: string): string | null {
    let start = -1;
    let depth = 0;

    for (let i = 0; i < text.length; i++) {
      if (text[i] === '[') {
        if (depth === 0) start = i;
        depth++;
      } else if (text[i] === ']') {
        depth--;
        if (depth === 0 && start !== -1) {
          return text.substring(start, i + 1);
        }
      }
    }

    return null;
  }

  /** Wrap a promise with a timeout. */
  private async withTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
    let timer: ReturnType<typeof setTimeout>;

    const timeoutPromise = new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        reject(new AgentTimeoutError(this.agentId, timeoutMs));
      }, timeoutMs);
    });

    try {
      return await Promise.race([promise, timeoutPromise]);
    } finally {
      clearTimeout(timer!);
    }
  }
}
