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

### Skills Marketplace Scan

- [ ] Check github.com/vercel-labs/skills for new official skills
- [ ] Check github.com/agentskillexchange/skills for new security-scanned skills
- [ ] Check github.com/trailofbits/skills for new security research skills
- [ ] Check github.com/anthropics/skills for new Anthropic-published skills
- [ ] Check github.com/AgentSecOps/SecOpsAgentKit for new security ops skills
- [ ] Run `npx skills add <repo> --list` to see what's new before installing
- [ ] Check for caveman updates (token reduction improvements)
- [ ] Check for new .NET / React / SQL Server specific skills
- [ ] Verify installed skills still work after CLI version updates

### Cost Optimization

- [ ] Any subscription price changes?
- [ ] Any new free tiers or credits?
- [ ] API pricing changes for DeepSeek/MiniMax?
- [ ] Can any paid feature replace a custom implementation?
- [ ] Is caveman actually reducing token usage? Check session logs.

## Verification-First Process

NEVER implement a feature based on assumptions or training data. Every feature must be verified before adoption.

### Step 1: Discover
- Read the provider's official changelog and documentation
- Search for the feature name in official docs (not blog posts or community speculation)
- If the feature has a CLI flag, run it locally and confirm it works

### Step 2: Verify
- Run a minimal test: create a throwaway project and test the feature in isolation
- Confirm: does it actually do what the docs say? On your OS? With your subscription tier?
- Document: exact command, exact output, exact behavior observed
- If the feature doesn't work as documented, mark it as "unverified" and move on

### Step 3: Evaluate
- Does it replace custom code? If yes, how many lines does it save?
- Does it reduce cost? Run both paths and compare actual token/dollar costs
- Does it improve quality? Run the same task with and without, compare outputs
- Does it improve speed? Time both paths with the same input
- Is it Claude-only? If yes, keep the TypeScript harness for multi-LLM; use native for orchestration only
- Is it stable? If experimental, add to "watching" table. If GA, proceed to Step 4

### Step 4: Implement
- Create a branch, implement the change, test the full pipeline
- Verify no regressions in existing agents
- Update the developer guide Section 10.11 (move from "not yet confirmed" to "in use")
- Update the change log at the bottom of Section 10.11
- Commit with a clear message explaining what was adopted and why

### Step 5: Monitor
- After 1 week: check vault session logs for any errors related to the new feature
- After 30 days: evaluate whether the feature delivered the expected benefit
- If not: revert and document why in the change log

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
