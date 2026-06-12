---
type: knowledge
description: LiteLLM gateway wiring — full-gateway mode routes every LLM call through the proxy with this repo's virtual key for per-project cost tracking
last_updated: 2026-06-11
---

# LiteLLM Gateway — full-gateway routing & per-project cost tracking

> Policy (owner decision 2026-06-11): **full gateway** — every LLM call routes through the
> central LiteLLM proxy as pay-per-token, attributed to this repo's virtual key, so spend is
> tracked per project. The $0 subscription-CLI path is no longer the default. Live gateway facts
> are re-verified weekly in the Cortex topic `litellm_gateway` (see `knowledge-sources.md`).

## Gateway

- **Endpoint**: `http://10.100.254.102:4000` (host `TE-DC-LITELLM`, OpenAI- + Anthropic-compatible).
- **This repo's virtual key**: `sk-tj-gsd-autonomouse-dev` — value lives in the key vault
  (`keys/litellm-virtual-keys.md`). **Never** hardcode, print, log, or commit it.
- Spend is attributed by virtual key (per repo) and, more granularly, by `x-litellm-tags`.

## Environment contract (read by `src/harness/base-agent.ts`)

| Env var | Purpose | Example |
|---|---|---|
| `LITELLM_BASE_URL` | gateway base URL — its presence flips the default mode to `gateway` | `http://10.100.254.102:4000` |
| `LITELLM_VIRTUAL_KEY` | this repo's `sk-tj-…` key (loaded from the key vault at launch) | `sk-tj-gsd-autonomouse-dev` |
| `GSD_LLM_MODE` | optional explicit override: `gateway` \| `sdk` \| `cli` | `gateway` |
| `GSD_PROJECT` | repo tag for cost attribution (default `gsd-autonomouse-dev`) | `gsd-autonomouse-dev` |

Mode resolution: `GSD_LLM_MODE` if set, else `gateway` when `LITELLM_BASE_URL` is present, else
`cli`. In `gateway` mode the harness builds the Anthropic SDK client against `LITELLM_BASE_URL`
with `LITELLM_VIRTUAL_KEY` and tags each request `x-litellm-tags: repo:<project>,agent:<id>,run:<id>`.

## How calls are routed

The harness LLM path is the Anthropic Messages API (`base-agent.ts → callLLMWithSDK`). LiteLLM's
Anthropic-compatible endpoint accepts it and routes to whatever the request `model` names — a
canonical model id (`claude-sonnet-4-6`) or a gateway alias. Each agent's `model:` (vault-note
frontmatter / `config/model-registry.json`) should be set to the right tier per
`docs/GSD-Model-Cost-Optimization.md`. Gateway aliases (verified 2026-05-27, re-verified weekly):

| Tier | Alias | Backing model |
|---|---|---|
| triage | `triage-deepseek-flash` / `triage-haiku` / `triage-gemini-flash` | deepseek-v4-flash / claude-haiku-4-5 / gemini-2.5-flash-lite |
| decision | `decision-sonnet` / `decision-gpt` / `decision-codex-deepseek` / `decision-kimi` | claude-sonnet-4-6 / gpt-5.4 / deepseek-v4-pro / kimi-k2.6 |
| escalate | `escalate-opus` / `escalate-gpt` / `decision-gemini-pro` | claude-opus-4-8 / gpt-5.5 / gemini-3.1-pro |

New aliases (add to `infrastructure/litellm/config.yaml`, then `docker compose up -d --force-recreate litellm`).

## Operational gotchas (from Cortex `litellm_gateway`)

- Models defined in `config.yaml` are authoritative — edit the YAML, don't `/model/update` them.
- `docker compose up -d litellm` does NOT reload config — use `--force-recreate`.
- GLM: use `api.z.ai` (intl). MiniMax: `api.minimax.io`, **account currently unfunded** (insufficient balance) — keep out until funded.
- Per-request usage lands in Postgres `LiteLLM_SpendLogs` (the daily cost report reads it; ClickHouse/OTEL is not capturing).

## Fallback / resilience

If a gateway call fails and `GSD_LLM_MODE` is unset, the harness can still fall back to the CLI
($0) path. To force pure gateway with no $0 fallback, set `GSD_LLM_MODE=gateway` explicitly.

See also: [model-strategy.md](model-strategy.md), [knowledge-sources.md](knowledge-sources.md),
`docs/GSD-Model-Cost-Optimization.md`.
