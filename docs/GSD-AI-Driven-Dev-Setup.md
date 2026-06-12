# GSD AI-Driven Development — Agent / Harness / Skill / Workflow Setup

> Deep-research synthesis + prioritized gap-closure plan for supporting autonomous AI-driven
> development per the Technijian SDLC (GSD V6 lifecycle, Phases A–G).
> Authored 2026-06-11. Evidence base: the three knowledge sources registered in
> `memory/knowledge/knowledge-sources.md` (esp. the Cortex `Inbox/` research corpus).

## 1. Where the system already is (~70% of an autonomous SDLC)

Mature and in production:

- **20 typed agents** (`src/agents/`) covering every SDLC phase A–G, each with a vault contract in
  `memory/agents/*.md`.
- **Harness** (`src/harness/` + `src/harness/v6/`, ~38 files): orchestrator, SDLC orchestrator,
  base-agent lifecycle/hooks, execution-graph scheduler, milestone/slice/task hierarchy, SQLite
  state DB, stuck-detector + mechanical-fix, budget-router + capability-router/escalation,
  timeout-hierarchy, worktree-manager + git-txn, knowledge-harvester, observability-logger.
- **Routing**: dual-auth (CLI OAuth primary $0 → API backup), 3 CLI + 2 API model families in
  `config/model-registry.json`; complexity-based routing in `config/global-config.json`.
- **Gates**: SCG1, build, security (0 critical), coverage ≥80%, E2E ≥95%, deploy hard-block.
- **Skills**: 98 reference skills in `.agents/skills/` + project UI/SQL skills in `.claude/skills/`.
- **Memory + intelligence**: hybrid Obsidian vault + SQLite; GitNexus + Graphify; 6 lifecycle hooks.

## 2. What the research corpus says matters most (Cortex `Inbox/` synthesis)

1. **Harness > model.** Same model + better harness moved a benchmark rank 30→5. Invest in
   scaffolding (prompts, tool contracts, context policy, feedback loops) before chasing models.
2. **Hybrid memory (vector + BM25 + RRF).** Pure-semantic recall misses exact matches; combine.
3. **Durable state machines for long-running agents.** Checkpoint explicit state; don't grow chat
   history. Enables pause/resume across idle time without context pollution.
4. **Close feedback loops *inside* the agent loop.** Local typecheck/lint/test is necessary but
   insufficient for distributed systems — need fast ephemeral envs; post-PR CI arrives too late.
5. **Decision-tree pattern selection, not default complexity.** Start single-agent+ReAct; add
   Planning / Reflection / Multi-agent only when a specific bottleneck justifies it.
6. **Delegate to focused sub-agents.** Packing all tools into one prompt degrades reasoning.
7. **Webhook-driven resume + scale-to-zero** for idle waits (signoffs, deploys, hardware).
8. **Explicit tool contracts + context compaction.** Recall "why" via memory tools, not raw chat.

## 3. Gap analysis (mapped to research + SDLC)

| # | Gap | SDLC impact | Research backing | Effort |
|---|-----|-------------|------------------|--------|
| G1 | **Knowledge-source wiring** — vaults/keys not registered for every session | Sessions re-discover paths; creds risk | #8 (tool contracts) | **DONE** (this change) |
| G2 | **Skill forging** — no automated skill generation from harvested patterns (SkillForge stub disabled) | Manual skill upkeep; patterns don't compound | #1, #8 | M |
| G3 | **Tighter in-loop feedback** — F4/F5 rely on local + post-hoc checks; no fast ephemeral env per slice | Slow remediation loops; late failure discovery | #4 | M–L |
| G4 | **Durable resume on human-gated waits** (compliance attestation, contract execution, Apple MDM, breach escalation) — no webhook/checkpoint resume | v6.2 domain agents block synchronously | #3, #7 | M |
| G5 | **Hybrid retrieval** — vault retrieval is keyword/topic only; no vector+RRF over Cortex corpus | Weaker recall of prior diseases/research | #2 | M |
| G6 | **Central workflow registry** — workflows live per-skill; no composition engine across the A–G pipeline | Hard to compose/observe end-to-end | #5 | M |
| G7 | **Real-time observability** — decisions logged but no metrics export/dashboards/alerts | Hard to supervise long autonomous runs | (ops) | M |
| G8 | **Model-catalog drift** — registry vs Cortex `model_catalog` (weekly) can diverge | Stale routing/pricing | #1 | S |

Effort: S ≤ ½ day · M ≈ 1–3 days · L > 3 days.

## 4. Recommended sequence

**Track 1 — Foundation (do first, low risk, high leverage)**
- G1 ✅ knowledge sources registered (CLAUDE.md + `memory/knowledge/knowledge-sources.md` + file memory).
- G8: a small sync check reconciling `config/model-registry.json` against Cortex `model_catalog` /
  `litellm_gateway`, run by the existing feature-check schedule.

**Track 2 — Harness depth (highest research-backed ROI: "harness > model")**
- G3: per-slice ephemeral validation env so F2→F4 feedback closes in-loop.
- G4: checkpoint + webhook resume for human-gated waits in the v6.2 domain agents.

**Track 3 — Compounding intelligence**
- G2: SkillForge — promote harvested patterns (knowledge-harvester) into `.claude/skills/` candidates.
- G5: hybrid (vector+BM25+RRF) retrieval over the GSD vault + Cortex corpus.

**Track 4 — Supervision**
- G6 central workflow registry/composition over A–G; G7 metrics export + dashboards.

## 5. Guardrails (from the GSD vault `07-Feedback/index.md` — binding)

- **No pipeline auto-start** — never auto-restart a run; manage notifications only.
- **Requirements from specs only** — never infer requirements from code.
- **Spec-alignment guard before any run.** **Proactive, not reactive** — fix root causes.
- **Never print/commit secrets** from the key vault; load creds from env or the LiteLLM gateway.

## 6. Status

Track-1 foundation is complete. Tracks 2–4 are scoped but not built — they are multi-day efforts
that change agent/harness behavior and should be prioritized by the owner before implementation.
