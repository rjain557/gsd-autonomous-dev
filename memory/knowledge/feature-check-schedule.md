---
type: knowledge
description: 30-day feature check schedule — review Claude/OpenAI/Google for new capabilities that improve speed, quality, or cost
last_checked: 2026-04-10
next_check: 2026-05-10
---

# 30-Day Feature Check Schedule

## Purpose

Every 30 days, review the latest releases from Anthropic, OpenAI, and Google for new features that could improve the GSD pipeline's speed, quality, or cost. Update this note with findings and apply any beneficial changes.

## Check Sources

| Provider | What to Check | URL |
|---|---|---|
| Anthropic | Claude Code changelog, API changelog, pricing | claude.ai/code, docs.anthropic.com |
| OpenAI | Codex CLI updates, GPT model changes, pricing | platform.openai.com |
| Google | Gemini CLI updates, model changes, context limits | ai.google.dev |
| Claude Code | Sub-agent improvements, agent teams stability, new hooks | code.claude.com/docs/en/changelog |

## Checklist (run every 30 days)

### Claude Code Features
- [ ] Agent teams: still experimental or GA? Any breaking changes?
- [ ] Sub-agents: new capabilities? Better context sharing?
- [ ] Hooks: new hook events? New hook types?
- [ ] Cloud scheduled tasks: new triggers? Better monitoring?
- [ ] MCP: new official MCP servers? Protocol changes?

### Claude API
- [ ] New models? (check if Opus 5 / Sonnet 5 launched)
- [ ] Prompt caching changes? (TTL, cost reduction %)
- [ ] Batch API updates? (latency improvements, cost changes)
- [ ] Tool use improvements? (better JSON schema compliance)
- [ ] Extended thinking changes? (new modes, cost)
- [ ] Rate limit changes for Max plan?

### OpenAI / Codex
- [ ] Codex CLI updates? New commands, flags, approval modes?
- [ ] New models? (GPT-5.1, o3 updates, o4 launch?)
- [ ] Rate limit changes for ChatGPT Max plan? RPM/TPM changes?
- [ ] New features in full-auto mode? Better error handling?
- [ ] Codex agent/sub-agent capabilities? Can Codex spawn sub-tasks?
- [ ] Codex structured output? JSON mode improvements?
- [ ] Codex tool use? Can it call external tools like Claude Code?
- [ ] Codex file editing improvements? Better diff handling?
- [ ] Multi-file generation? Can Codex create multiple files atomically?
- [ ] Codex hooks or extensions? Equivalent of Claude Code hooks?

### Google / Gemini
- [ ] Gemini CLI updates? New commands, approval modes?
- [ ] New models? Context window beyond 1M? Gemini 2.5 Pro updates?
- [ ] Rate limit changes for Ultra plan?
- [ ] Gemini Code Assist features? Inline suggestions, multi-file edits?
- [ ] Gemini agent capabilities? Sub-agent spawning?
- [ ] Gemini tool use? MCP support? External tool calling?
- [ ] Gemini structured output? JSON schema enforcement?
- [ ] Gemini grounding? Can it search code repos natively?
- [ ] Gemini Batch API? Cost reduction for bulk calls?
- [ ] Gemini multimodal for Figma? Can it analyze Figma screenshots directly?

### Cost Optimization
- [ ] Any subscription price changes?
- [ ] Any new free tiers or credits?
- [ ] API pricing changes for DeepSeek/MiniMax?
- [ ] Can any paid feature replace a custom implementation?

## Decision Framework

When evaluating a new feature:

1. **Does it replace custom code?** If yes, migrate (less code to maintain)
2. **Does it reduce cost?** If yes, adopt (prompt caching, batch API)
3. **Does it improve quality?** If yes, evaluate (extended thinking, better models)
4. **Does it improve speed?** If yes, adopt (parallelism, caching)
5. **Is it stable?** If experimental, wait. If GA, adopt.

## Auth Mode Strategy

The pipeline supports dual auth for Claude:

| Mode | Auth | Cost | When Used |
|---|---|---|---|
| CLI (default) | OAuth via `claude auth login` | $0 (Max subscription) | Normal operation |
| SDK (backup) | `ANTHROPIC_API_KEY` env var | Pay-per-token | When CLI hits rate limit |

The pipeline auto-switches: CLI fails → 5-min cooldown → SDK takes over → cooldown expires → back to CLI. Set `ANTHROPIC_API_KEY` in environment to enable the backup.

## Change Log

### 2026-04-10 (Initial)
- Established 30-day check schedule
- V5.0: Hybrid architecture (TypeScript harness + Claude Code native features)
- Dual auth: CLI OAuth primary, API key backup with auto-switch
- Agent teams: experimental, monitoring for GA
- Prompt caching: not yet applied (TODO for next check)
- Batch API: not yet applied (TODO for bulk reviews)

### Next Check: 2026-05-10
- Check if agent teams reached GA
- Evaluate prompt caching for system prompts
- Evaluate batch API for bulk code reviews
- Check for Claude Opus 5 / Sonnet 5 availability
