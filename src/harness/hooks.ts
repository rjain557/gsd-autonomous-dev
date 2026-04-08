// ═══════════════════════════════════════════════════════════
// GSD Agent System — Hook System
// Register, fire, and manage hooks for agent lifecycle events.
// ═══════════════════════════════════════════════════════════

import type { HookEvent, HookHandler, HookContext } from './types';

interface RegisteredHook {
  name: string;
  handler: HookHandler;
}

export class HookSystem {
  private hooks = new Map<HookEvent, RegisteredHook[]>();

  /** Register a named handler for a hook event. */
  register(event: HookEvent, name: string, handler: HookHandler): void {
    if (!this.hooks.has(event)) {
      this.hooks.set(event, []);
    }

    const existing = this.hooks.get(event)!;

    // Prevent duplicate registration
    const idx = existing.findIndex(h => h.name === name);
    if (idx !== -1) {
      existing[idx] = { name, handler };
    } else {
      existing.push({ name, handler });
    }
  }

  /**
   * Fire all handlers for an event in registration order.
   * If any handler throws, log the error and continue — don't halt the pipeline.
   */
  async fire(event: HookEvent, context: HookContext): Promise<void> {
    const handlers = this.hooks.get(event) ?? [];

    for (const { name, handler } of handlers) {
      try {
        await handler(context);
      } catch (err) {
        console.error(`[HOOK ERROR] ${event}/${name}: ${err instanceof Error ? err.message : String(err)}`);

        // Validation hooks are critical — their failures must propagate
        if (name === 'result-validator') {
          throw err;
        }

        // For other hooks: fire onError to log, but don't halt the pipeline
        if (event !== 'onError') {
          try {
            await this.fire('onError', {
              ...context,
              error: err instanceof Error ? err : new Error(String(err)),
            });
          } catch {
            // Swallow errors in error handlers to prevent infinite recursion
          }
        }
      }
    }
  }

  /** Remove a named handler from an event. */
  deregister(event: HookEvent, name: string): void {
    const handlers = this.hooks.get(event);
    if (!handlers) return;

    const idx = handlers.findIndex(h => h.name === name);
    if (idx !== -1) {
      handlers.splice(idx, 1);
    }
  }

  /** List all registered hooks (for debugging). */
  listHooks(): Map<HookEvent, string[]> {
    const result = new Map<HookEvent, string[]>();
    for (const [event, handlers] of this.hooks) {
      result.set(event, handlers.map(h => h.name));
    }
    return result;
  }
}
