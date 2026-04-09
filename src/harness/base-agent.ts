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

export abstract class BaseAgent {
  protected agentId: AgentId;
  protected vaultAdapter: VaultAdapter;
  protected hooks: HookSystem;
  protected state: PipelineState;
  protected agentConfig: VaultNoteMeta = {};
  protected systemPrompt: string = '';
  private rateLimiter: RateLimiter | null = null;
  private cliAgentId: string = 'claude'; // which CLI model this agent routes to

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

    await this.hooks.fire('onBeforeRun', {
      runId: this.state.runId,
      agentId: this.agentId,
      input,
      state: this.state,
    });

    try {
      const timeoutMs = (this.agentConfig.timeout_seconds ?? 120) * 1000;
      const output = await this.withTimeout(this.run(input), timeoutMs);

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
   */
  protected async buildSystemPrompt(extraNotes?: string[]): Promise<string> {
    const readPaths = (this.agentConfig.reads as string[] | undefined) ?? [];
    const allPaths = [...readPaths, ...(extraNotes ?? [])];

    if (allPaths.length === 0) {
      return this.systemPrompt;
    }

    const context = await this.vaultAdapter.buildContext(allPaths);
    return `${this.systemPrompt}\n\n---\n\n# Context from vault\n\n${context}`;
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

      if (mode === 'sdk' && process.env.ANTHROPIC_API_KEY) {
        result = await this.callLLMWithSDK(systemPromptText, userMessage, model, jsonSchema);
      } else if (jsonSchema) {
        const schemaInstructions = `\n\nIMPORTANT: Return ONLY valid JSON matching this schema:\n${JSON.stringify(jsonSchema, null, 2)}\n\nReturn ONLY the JSON object, no markdown, no explanation.`;
        result = await this.callLLMWithCLI(systemPromptText, userMessage + schemaInstructions, model);
      } else {
        result = await this.callLLMWithCLI(systemPromptText, userMessage, model);
      }

      return result;
    } finally {
      // Always record the call for sliding-window tracking, even on failure.
      // Prevents phantom rate limit reservations from timed-out calls.
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

  /** CLI fallback path — used when ANTHROPIC_API_KEY is not set. */
  private async callLLMWithCLI(
    systemPromptText: string,
    userMessage: string,
    model: string,
  ): Promise<string> {
    const { execFile } = await import('child_process');
    const { promisify } = await import('util');
    const execFileAsync = promisify(execFile);

    try {
      const fullPrompt = `${systemPromptText}\n\n---\n\nUser request:\n${userMessage}`;

      const { stdout } = await execFileAsync('claude', [
        '--model', model,
        '--print',
        '--output-format', 'text',
        '--max-turns', '1',
        '-p', fullPrompt,
      ], {
        timeout: ((this.agentConfig.timeout_seconds as number) ?? 120) * 1000,
        maxBuffer: 10 * 1024 * 1024,
      });

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
