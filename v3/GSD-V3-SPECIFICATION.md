# GSD V3 Specification: All-API, 2-Model Pipeline

**Version:** 3.0.0
**Date:** 2026-03-10
**Status:** DRAFT — Awaiting Review

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Architecture Overview](#2-architecture-overview)
3. [Model Selection & Justification](#3-model-selection--justification)
4. [Cost Optimization Architecture](#4-cost-optimization-architecture)
5. [Pipeline Phases](#5-pipeline-phases)
6. [Quality & Speed Optimizations](#6-quality--speed-optimizations)
7. [Pipeline Modes](#7-pipeline-modes)
8. [Multi-Interface Architecture](#8-multi-interface-architecture)
9. [Configuration Reference](#9-configuration-reference)
10. [Prompt Specifications](#10-prompt-specifications)
11. [Cost Projections](#11-cost-projections)
12. [Runtime Architecture](#12-runtime-architecture)
13. [Migration from V2](#13-migration-from-v2)
14. [Acceptance Criteria](#14-acceptance-criteria)

---

## 1. Executive Summary

### What Changed from V2

| Dimension | V2 | V3 |
|-----------|----|----|
| Models | 7 (Claude, Codex, Gemini, Kimi, DeepSeek, GLM-5, MiniMax) | **2** (Claude Sonnet 4.6 API, GPT-5.1 Codex Mini API) |
| Billing | CLI subscriptions ($100-200/mo) | **Pure API pay-per-token** |
| Cost per 100K LOC | ~$50-57 (estimated) | **~$5.12** (with all optimizations) |
| Wall clock (200 reqs) | ~12-15 hours | **~1.5 hours** |
| API keys required | 7 | **2** (Anthropic, OpenAI) |
| Coordination complexity | High (7 agents, quotas, fallbacks, rotation) | **Minimal** (2 models, deterministic routing) |

### Design Principles

1. **Two models, deterministic routing.** Sonnet reasons. Codex Mini generates code. No fallbacks, no rotation pools, no quota juggling.
2. **Three mechanical cost levers.** Prompt caching (90% input savings), Batch API (50% off non-urgent), model routing (Codex Mini at 12-60x cheaper output than Sonnet).
3. **Local validation before LLM review.** Lint, typecheck, and test locally (free) before spending tokens on Sonnet review.
4. **Speculative execution.** Start next Execute batch while current Review is in-flight. 15% waste risk for 40% speed gain.
5. **Structured JSON output everywhere.** Eliminates parsing failures and retry waste.
6. **Diff-based review.** Send diffs, not full files. Sonnet reviews better with less noise.

---

## 2. Architecture Overview

```
┌───────────────────────────────────────────────────────────────────┐
│                     GSD V3 ORCHESTRATOR                           │
│                     (PowerShell + REST API)                       │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │  CACHED PREFIX (written once per project, read every call)  │  │
│  │  ┌──────────────┐ ┌──────────────┐ ┌────────────────────┐  │  │
│  │  │ System Prompt │ │ Spec Docs    │ │ Blueprint Manifest │  │  │
│  │  │ ~2,000 tok    │ │ ~8,000 tok   │ │ ~5,000 tok         │  │  │
│  │  └──────────────┘ └──────────────┘ └────────────────────┘  │  │
│  │  Total: ~15,000 tokens                                      │  │
│  │  Cache write: $0.056 (once) | Cache read: $0.0045 (per call)│  │
│  └─────────────────────────────────────────────────────────────┘  │
│                                                                   │
│  PHASE 1: Spec Gate    → Sonnet API (Batch + Cache Write)        │
│  PHASE 2: Research     → Sonnet API (Batch + Cache Read)         │
│  PHASE 3: Plan         → Sonnet API (Batch + Cache Read)         │
│  PHASE 4: Execute      → Codex Mini API (Real-time, Parallel)    │
│  PHASE 5: Local Validate → lint + typecheck + test (FREE)        │
│  PHASE 6: Review       → Sonnet API (Batch + Cache Read, diffs)  │
│  PHASE 7: Verify       → Sonnet API (Real-time + Cache Read)     │
│  PHASE 8: Spec-Fix     → Sonnet API (Batch + Cache Read)         │
│                                                                   │
│  API Clients: Anthropic SDK (.NET/Python) + OpenAI SDK           │
│  API Keys: ANTHROPIC_API_KEY + OPENAI_API_KEY                    │
└───────────────────────────────────────────────────────────────────┘
```

### Data Flow Per Iteration

```
                    ┌─────────┐
                    │ Spec    │ (one-time, iteration 0)
                    │ Gate    │
                    └────┬────┘
                         │ spec-quality-report.json
                         │ cache prefix written
                         ▼
              ┌──────────────────────┐
              │   ITERATION LOOP     │
              │                      │
              │  ┌────────────────┐  │
              │  │ 2. Research    │◄─┼── Sonnet BATCH (cached)
              │  └───────┬────────┘  │
              │          │           │
              │  ┌───────▼────────┐  │
              │  │ 3. Plan        │◄─┼── Sonnet BATCH (cached)
              │  └───────┬────────┘  │
              │          │           │
              │  ┌───────▼────────┐  │
              │  │ 4. Execute     │◄─┼── Codex Mini REAL-TIME (15 items parallel)
              │  └───────┬────────┘  │
              │          │           │
              │  ┌───────▼────────┐  │
              │  │ 5. Local       │  │  FREE (lint + typecheck + test)
              │  │    Validate    │  │
              │  └──┬─────────┬──┘  │
              │     │         │      │
              │   PASS      FAIL     │
              │     │         │      │
              │     │  ┌──────▼───┐  │
              │     │  │6. Review │◄─┼── Sonnet BATCH (cached, diffs only)
              │     │  └──────┬───┘  │
              │     │         │      │
              │  ┌──▼─────────▼──┐   │
              │  │ 7. Verify     │◄──┼── Sonnet REAL-TIME (cached) [gates next iter]
              │  └───────┬───────┘   │
              │          │           │
              │     ┌────▼────┐      │
              │     │ health  │      │
              │     │ < 100?  │      │
              │     └──┬───┬──┘      │
              │      Y │   │ N       │
              │        │   └─────────┼──► CONVERGED
              │  ┌─────▼──────┐      │
              │  │ 8. SpecFix │◄─────┼── Sonnet BATCH (cached, if conflicts detected)
              │  │ (optional) │      │
              │  └─────┬──────┘      │
              │        │             │
              │        └─────────────┼──► NEXT ITERATION
              │                      │
              └──────────────────────┘
```

---

## 3. Model Selection & Justification

### Selected Models

| Model | API Pricing (per M tokens) | Cache Read | SWE-bench | Role |
|-------|:-:|:-:|:-:|------|
| **Claude Sonnet 4.6** | $3.00 in / $15.00 out | $0.30 in | 79.6% | All reasoning: spec, research, plan, review, verify, spec-fix |
| **GPT-5.1 Codex Mini** | $0.25 in / $2.00 out | N/A | N/A | All code generation |

### Why Not Other Models

| Model | Why Excluded |
|-------|-------------|
| **Claude Opus 4.6** ($5/$25) | 1.2 points above Sonnet on SWE-bench. 67% more expensive. Quality delta doesn't justify cost for spec-driven work where the spec constrains the output. |
| **GPT-5.3 Codex** ($1.75/$14) | 7x more expensive than Codex Mini for output tokens. When the plan is detailed and well-specified (because Sonnet wrote it), Codex Mini generates equivalent code. |
| **DeepSeek V3.2** ($0.28/$0.42) | 70.2% SWE-bench vs Codex Mini's higher code quality. Saves pennies, costs rework cycles. No prompt caching. No Batch API. |
| **Gemini 3.1 Pro** ($2/$12) | Overlaps with Sonnet's role. Adding a third model adds coordination complexity for marginal savings. 1M context not needed when caching is used. |
| **Haiku 4.5** ($1/$5) | Cheaper reasoning but lower quality. One extra rework cycle ($0.50-1.00) exceeds savings across 10+ calls. |
| **Kimi, GLM-5, MiniMax** | Coordination overhead of managing 4+ extra API keys, endpoints, error handling, and fallback logic exceeds any per-token savings at our scale. |

### When to Override (Escape Hatches)

The orchestrator supports model overrides via `supervisor/agent-override.json` for edge cases:

- **Opus 4.6**: If a specific requirement consistently fails Verify after 3+ rework cycles, escalate that single item's Plan + Review phases to Opus.
- **Codex 5.3**: If a requirement involves complex multi-file refactoring where Codex Mini produces incomplete output, route that item's Execute to Codex 5.3.
- **DeepSeek V3.2**: For projects with 500+ requirements where budget is the primary constraint and 70% SWE-bench quality is acceptable.

These are per-item overrides, not pipeline-level changes.

---

## 4. Cost Optimization Architecture

### Lever 1: Prompt Caching (90% Input Savings)

#### Cacheable Prefix Structure

Every Sonnet API call shares a common prefix. This prefix is written to cache once and read on every subsequent call.

```
┌──────────────────────────────────────────────────────┐
│  CACHE BLOCK 1: System Prompt + Conventions          │
│  ~2,000 tokens                                       │
│  Content: Role definition, coding standards,         │
│  compliance rules, output format requirements        │
│  Stability: Static for entire project                │
├──────────────────────────────────────────────────────┤
│  CACHE BLOCK 2: Specification Documents              │
│  ~8,000 tokens (varies by project)                   │
│  Content: Requirements matrix, spec quality report,  │
│  dependency graph, acceptance criteria               │
│  Stability: Changes only on spec-fix (rare)          │
├──────────────────────────────────────────────────────┤
│  CACHE BLOCK 3: Blueprint Manifest                   │
│  ~5,000 tokens (varies by project)                   │
│  Content: Architecture manifest, file map,           │
│  interface inventory, tech decisions                  │
│  Stability: Changes only on major architectural      │
│  decisions (very rare)                               │
└──────────────────────────────────────────────────────┘
Total cached prefix: ~15,000 tokens
```

#### Cache Economics

| Metric | Value |
|--------|:-----:|
| Cache write cost (once) | $0.056 (15K × $3.75/M) |
| Cache read cost (per call) | $0.0045 (15K × $0.30/M) |
| Uncached equivalent cost (per call) | $0.045 (15K × $3.00/M) |
| **Savings per call** | **$0.0405 (90%)** |
| Breakeven | **2 calls** |
| Calls per project (~200 reqs) | ~115 Sonnet calls |
| **Total cache savings** | **~$4.60** |

#### Cache Lifetime Management

- Use **5-minute cache TTL** (default, cheapest write at 1.25x).
- The convergence loop fires Sonnet calls frequently enough (every 10-30 seconds) that the 5-minute cache stays warm naturally.
- If the pipeline pauses >5 minutes (e.g., waiting for Execute), the next Sonnet call auto-refreshes the cache. Cost: one $0.056 write. Negligible.
- **Do NOT use 1-hour cache** ($0.112 write at 2x). The 5-minute cache with natural refresh is cheaper for our access pattern.

#### Cache Invalidation

The cache prefix must be rewritten when:
1. **Spec-Fix phase modifies the specification** → Invalidate block 2, rewrite.
2. **Blueprint changes** (rare, only if architecture is revised) → Invalidate block 3, rewrite.
3. **System prompt changes** (never during a run) → Invalidate block 1, rewrite.

Implementation: The orchestrator tracks a `cache_version` counter. Each cache block has a hash. If the hash changes, the orchestrator sets `cache_control: {"type": "ephemeral"}` on the updated block to trigger a rewrite.

### Lever 2: Batch API (50% Discount on Non-Urgent Phases)

#### Batch-Eligible Phases

| Phase | Real-time Required? | Batch Eligible? | Effective Prices (per M) |
|-------|:---:|:---:|:---:|
| 1. Spec Gate | No (runs once at start) | **Yes** | $1.50 in / $7.50 out |
| 2. Research | No (prep work) | **Yes** | $1.50 in / $7.50 out |
| 3. Plan | No (prep before execute) | **Yes** | $1.50 in / $7.50 out |
| 4. Execute | Yes (iterative, parallel) | No | $0.25 in / $2.00 out |
| 5. Local Validate | N/A (local) | N/A | $0.00 |
| 6. Review | No (runs after execute) | **Yes** | $1.50 in / $7.50 out |
| 7. Verify | **Yes (gates next iteration)** | **No** | $3.00 in / $15.00 out |
| 8. Spec-Fix | No (occasional) | **Yes** | $1.50 in / $7.50 out |

**5 of 7 API phases (71%) are batch-eligible.**

#### Batch API Implementation

```
Orchestrator submits batch request:
POST /v1/messages/batches
{
  "requests": [
    { "custom_id": "research-iter-5-req-042", "params": { ... } },
    { "custom_id": "research-iter-5-req-043", "params": { ... } },
    ...
  ]
}

Response: { "id": "batch_abc123", "processing_status": "in_progress" }

Poll: GET /v1/messages/batches/batch_abc123
Until: processing_status == "ended"
Typical latency: 5-30 minutes (vs <1 second real-time)
```

#### Batch + Cache Combined Pricing

When combining Batch API (50% off) with prompt caching (90% off input reads), the effective per-call cost for cached-prefix Sonnet calls is:

| Component | Calculation | Cost |
|-----------|:-:|:-:|
| 15K cached input (batch + cache read) | 15K × $0.30/M × 0.5 | $0.00225 |
| 10K new input (batch) | 10K × $1.50/M | $0.015 |
| 4K output (batch) | 4K × $7.50/M | $0.030 |
| **Per-call total** | | **$0.047** |

Compare uncached, non-batch: 25K × $3.00/M + 4K × $15.00/M = **$0.135** per call. **65% savings.**

### Lever 3: Model Routing (Codex Mini for All Code Generation)

| Metric | Sonnet 4.6 (if used for code gen) | Codex Mini | Savings |
|--------|:-:|:-:|:-:|
| Output price per M tokens | $15.00 | $2.00 | **87%** |
| Input price per M tokens | $3.00 | $0.25 | **92%** |
| Avg output per Execute call | 52,500 tokens | 52,500 tokens | — |
| Cost per Execute call | $0.80 | $0.116 | **85%** |
| Execute phase total (23 iters) | $18.40 | $2.67 | **-$15.73** |

The key insight: **Codex Mini generates excellent code when given a detailed plan.** Sonnet writes the plan; Codex Mini follows it. This separation of concerns lets each model do what it's best at, at the optimal price point.

---

## 5. Pipeline Phases

### Phase 0: Cache Warm (One-time, Pre-pipeline)

**Purpose:** Write the cached prefix to ensure all subsequent calls get cache hits.
**Model:** Sonnet 4.6 (API, real-time)
**When:** Before iteration 1 begins.
**Implementation:** Send a minimal Sonnet call with the full prefix marked as `cache_control: {"type": "ephemeral"}`. The response can be discarded — the purpose is purely to populate the cache.

```json
{
  "model": "claude-sonnet-4-6-20260310",
  "system": [
    { "type": "text", "text": "{{SYSTEM_PROMPT}}", "cache_control": {"type": "ephemeral"} },
    { "type": "text", "text": "{{SPEC_DOCUMENT}}", "cache_control": {"type": "ephemeral"} },
    { "type": "text", "text": "{{BLUEPRINT_MANIFEST}}", "cache_control": {"type": "ephemeral"} }
  ],
  "messages": [
    { "role": "user", "content": "Acknowledge context loaded. Respond with: {\"status\": \"ready\"}" }
  ],
  "max_tokens": 20
}
```

**Cost:** ~$0.056 (cache write) + negligible output.
**Tokens:** 15,000 input (write), ~10 output.

### Phase 1: Spec Gate (One-time, Batched)

**Purpose:** Validate specification quality before any generation begins. Detect contradictions, ambiguities, gaps across all artifacts.
**Model:** Sonnet 4.6 (API, Batch)
**Frequency:** Once per pipeline run (re-run if specs change).
**Inputs:** All SDLC docs (Phase A-E), Figma analysis deliverables, existing codebase structure.
**Cached input:** Full 15K prefix (cache read).
**New input:** ~35,000 tokens (spec artifacts beyond the cached prefix).
**Output:** ~3,000 tokens.

**Output Schema (enforced via JSON mode):**
```json
{
  "$schema": "gsd-v3/spec-gate-output",
  "timestamp": "ISO-8601",
  "overall_status": "pass | warn | block",
  "clarity_score": 0-100,
  "conflicts": [
    {
      "id": "CONFLICT-001",
      "type": "data_type | api_contract | business_rule | navigation | database | missing_ref",
      "severity": "critical | high | medium",
      "description": "string",
      "source_a": { "artifact": "string", "section": "string", "value": "string" },
      "source_b": { "artifact": "string", "section": "string", "value": "string" },
      "recommendation": "string"
    }
  ],
  "ambiguities": [
    {
      "id": "AMBIG-001",
      "artifact": "string",
      "section": "string",
      "issue": "string",
      "impact": "string"
    }
  ],
  "requirements_derived": [
    {
      "id": "REQ-001",
      "name": "string",
      "category": "string",
      "complexity": "small | medium | large",
      "priority": "critical | high | medium | low",
      "acceptance_criteria": ["string"],
      "dependencies": ["REQ-xxx"]
    }
  ],
  "summary": {
    "total_conflicts": 0,
    "critical_conflicts": 0,
    "total_ambiguities": 0,
    "total_requirements": 0,
    "artifacts_checked": ["string"]
  }
}
```

**Gate Rules:**
- `block` if ANY critical conflicts found → pipeline halts, human intervention required.
- `warn` if clarity_score < 85 → proceed with warnings logged.
- `block` if clarity_score < 70 → pipeline halts.

**Cost per call:**
- Cached input: 15K × $0.15/M (batch cache read) = $0.00225
- New input: 35K × $1.50/M (batch) = $0.0525
- Output: 3K × $7.50/M (batch) = $0.0225
- **Total: $0.077**

### Phase 2: Research (Per-Iteration, Batched)

**Purpose:** Analyze existing code patterns, discover dependencies, identify technical decisions needed for the current batch of requirements.
**Model:** Sonnet 4.6 (API, Batch)
**Frequency:** Once per iteration.
**Inputs:** Requirements for current batch, existing source code snippets, file map.
**Cached input:** Full 15K prefix (cache read).
**New input:** ~10,000 tokens (batch requirements + relevant source excerpts).
**Output:** ~6,000 tokens.

**Output Schema:**
```json
{
  "$schema": "gsd-v3/research-output",
  "iteration": 0,
  "batch_requirements": ["REQ-xxx"],
  "findings": [
    {
      "req_id": "REQ-xxx",
      "existing_patterns": ["description of relevant existing code"],
      "dependencies_discovered": ["file paths or REQ IDs"],
      "tech_decisions": ["decision description"],
      "risk_factors": ["risk description"]
    }
  ],
  "shared_patterns": {
    "reusable_components": ["component descriptions"],
    "common_interfaces": ["interface descriptions"],
    "naming_conventions_observed": ["pattern descriptions"]
  },
  "file_context_needed": {
    "files_to_read": ["paths needed for Plan phase"],
    "files_to_modify": ["paths that will be changed"]
  }
}
```

**Cost per call:** $0.062 (see Lever 2 calculation above)
**Total (23 iterations):** $1.25

### Phase 3: Plan (Per-Iteration, Batched)

**Purpose:** Create detailed, actionable generation plans for each requirement in the current batch. These plans are consumed directly by Codex Mini in the Execute phase.
**Model:** Sonnet 4.6 (API, Batch)
**Frequency:** Once per iteration.
**Inputs:** Research findings, requirements, relevant source code context.
**Cached input:** Full 15K prefix (cache read).
**New input:** ~8,000 tokens (research output + file context).
**Output:** ~4,000 tokens.

**Output Schema:**
```json
{
  "$schema": "gsd-v3/plan-output",
  "iteration": 0,
  "plans": [
    {
      "req_id": "REQ-xxx",
      "complexity": "small | medium | large",
      "confidence": 0.0-1.0,
      "implementation_order": [
        {
          "step": 1,
          "action": "create | modify",
          "file_path": "string",
          "description": "Detailed description of what to create/change",
          "preserve": ["list of existing code elements to preserve"],
          "dependencies": ["other steps or files"]
        }
      ],
      "files_to_create": [
        {
          "path": "string",
          "type": "controller | service | repository | dto | component | hook | migration | sp | test",
          "estimated_tokens": 0,
          "description": "Purpose and key interfaces"
        }
      ],
      "files_to_modify": [
        {
          "path": "string",
          "changes": "Description of specific changes",
          "preserve": ["Elements that must not be modified"]
        }
      ],
      "acceptance_tests": [
        {
          "type": "file_exists | pattern_match | build_check | dotnet_test | npm_test",
          "target": "string",
          "expected": "string"
        }
      ]
    }
  ],
  "batch_summary": {
    "total_files_to_create": 0,
    "total_files_to_modify": 0,
    "estimated_total_output_tokens": 0,
    "parallel_safe": true
  }
}
```

**The plan's `confidence` field drives the confidence-gated review optimization (see Phase 6).**

**Cost per call:** $0.040
**Total (23 iterations):** $0.86

### Phase 4: Execute (Per-Iteration, Real-Time, Parallel)

**Purpose:** Generate production-ready code for all requirements in the current batch.
**Model:** GPT-5.1 Codex Mini (API, Real-Time)
**Frequency:** Once per iteration, with up to 15 items fired in parallel.
**Inputs:** Plan output for each requirement, relevant existing source code.
**New input:** ~42,500 tokens per batch (15 items × 300 tok plan + 30K file map + 8K context).
**Output:** ~52,500 tokens per batch (15 items × 3,500 avg output).

**Parallelism Strategy:**

Each requirement in the batch gets its own Codex Mini API call, fired concurrently:

```
Batch of 15 requirements:
  ├── REQ-042 → Codex Mini call #1  ┐
  ├── REQ-043 → Codex Mini call #2  │
  ├── REQ-044 → Codex Mini call #3  │
  │   ...                           ├── All concurrent
  ├── REQ-055 → Codex Mini call #14 │
  └── REQ-056 → Codex Mini call #15 ┘

  Wall time: ~20 seconds (longest single call)
  vs sequential: ~5 minutes (15 × 20 seconds)
```

**Input per item:**
```json
{
  "model": "gpt-5.1-codex-mini",
  "messages": [
    {
      "role": "system",
      "content": "{{CODING_CONVENTIONS}}\n{{SECURITY_STANDARDS}}"
    },
    {
      "role": "user",
      "content": "Generate code for requirement {{REQ_ID}}.\n\nPLAN:\n{{PLAN_JSON}}\n\nEXISTING FILES:\n{{RELEVANT_SOURCE}}\n\nGenerate COMPLETE, PRODUCTION-READY code. No stubs, no placeholders. Follow the plan exactly."
    }
  ],
  "response_format": { "type": "text" },
  "max_tokens": 16384
}
```

**Output:** Raw code files with clear file-path markers.

**Cost per call (single item):** 2,833 input × $0.25/M + 3,500 output × $2.00/M = $0.0078
**Cost per batch (15 items):** $0.116
**Total (23 iterations):** $2.67

### Phase 5: Local Validate (Per-Item, Free)

**Purpose:** Catch compilation errors, lint violations, type errors, and test failures locally before spending tokens on LLM review.
**Model:** None (local tooling only).
**Frequency:** Once per item after Execute.
**Cost:** $0.00.

**Validation Pipeline:**

```powershell
foreach ($item in $ExecutedItems) {
    $result = @{ req_id = $item.ReqId; passed = $true; failures = @() }

    # 1. File existence check
    foreach ($file in $item.FilesCreated) {
        if (-not (Test-Path $file)) {
            $result.passed = $false
            $result.failures += @{ type = "file_missing"; file = $file }
        }
    }

    # 2. Lint check (language-specific)
    # C#: dotnet build --no-restore (syntax/type check)
    # TypeScript: npx tsc --noEmit
    # SQL: sqlcmd -i $file -b (syntax check)

    # 3. Test execution (if tests exist for this requirement)
    # dotnet test --filter "Category=$item.ReqId"
    # npm test -- --testPathPattern=$item.TestPattern

    # 4. Pattern match (acceptance criteria from Plan)
    foreach ($test in $item.AcceptanceTests) {
        # file_exists, pattern_match, build_check checks
    }
}
```

**Output Classification:**
- **PASS** → Skip Review phase for this item. Go directly to Verify.
- **FAIL** → Send failure output + generated code diff to Review phase.

**Expected pass rate:** ~60-70% of items (based on well-specified plans).
**Cost impact:** Skipping Review for 60% of items saves ~$1.20 per project.

### Phase 6: Review (Conditional, Batched, Diff-Based)

**Purpose:** Analyze items that failed local validation. Provide targeted fix instructions.
**Model:** Sonnet 4.6 (API, Batch)
**Frequency:** Once per iteration, but only for items that FAILED local validation.
**Inputs:** Diff of generated code + local validation failure output.
**Cached input:** Full 15K prefix (cache read).
**New input:** ~12,000 tokens (diffs + error output, NOT full files).
**Output:** ~3,000 tokens.

**Key optimization: Diff-based review, not full-file review.**

Previously (V2): Review sent 55K tokens of full generated files.
Now (V3): Review sends only:
1. The **diff** (what changed vs the plan's expectation)
2. The **local validation failure output** (compiler errors, test failures)
3. The **acceptance criteria** that aren't met

This gives Sonnet focused context, improving review accuracy while reducing token count by ~75%.

**Confidence-Gated Skip:**

Items with `plan.confidence >= 0.9` (from Phase 3) AND local validation PASS skip Review entirely. This catches trivial items (CRUD, config, DTOs) that don't need LLM review.

```
Execute output for item
    │
    ├── Local validate PASS + plan confidence ≥ 0.9 → SKIP Review → Verify
    ├── Local validate PASS + plan confidence < 0.9 → Review (brief, diff-based)
    └── Local validate FAIL → Review (full, with error context)
```

**Output Schema:**
```json
{
  "$schema": "gsd-v3/review-output",
  "iteration": 0,
  "reviews": [
    {
      "req_id": "REQ-xxx",
      "status": "pass | needs_rework | critical_issue",
      "issues": [
        {
          "severity": "critical | high | medium | low",
          "file": "string",
          "line_range": "string",
          "issue": "string",
          "fix_instruction": "Specific instruction for next Execute cycle"
        }
      ],
      "rework_plan": {
        "files_to_modify": ["paths"],
        "specific_changes": ["change descriptions"],
        "estimated_tokens": 0
      }
    }
  ],
  "summary": {
    "total_reviewed": 0,
    "passed": 0,
    "needs_rework": 0,
    "critical_issues": 0
  }
}
```

**Cost per call:** ~$0.060 (reduced from $0.108 with diff-based approach)
**Effective cost (60% items skip):** ~$0.024 average per item
**Total (23 iterations, ~40% of items):** $1.10

### Phase 7: Verify (Per-Iteration, Real-Time, Cached)

**Purpose:** Update health scores, track requirement satisfaction, detect drift, gate next iteration.
**Model:** Sonnet 4.6 (API, Real-Time — must be real-time because it gates the next iteration).
**Frequency:** Once per iteration.
**Inputs:** Execution results, review results, current health state.
**Cached input:** Full 15K prefix (cache read).
**New input:** ~30,000 tokens (execution log + review output + health state).
**Output:** ~2,500 tokens.

**Output Schema:**
```json
{
  "$schema": "gsd-v3/verify-output",
  "iteration": 0,
  "health_score": 0-100,
  "health_delta": -100 to +100,
  "requirements_status": [
    {
      "req_id": "REQ-xxx",
      "status": "not_started | partial | satisfied",
      "satisfaction_pct": 0-100,
      "blocking_issues": ["string"]
    }
  ],
  "drift_detected": [
    {
      "type": "file_modified_outside_plan | dependency_broken | spec_mismatch",
      "description": "string",
      "affected_requirements": ["REQ-xxx"]
    }
  ],
  "next_iteration": {
    "recommended_batch_size": 0,
    "priority_requirements": ["REQ-xxx"],
    "rework_requirements": ["REQ-xxx"],
    "skip_research": false,
    "escalate_to_opus": ["REQ-xxx"],
    "spec_fix_needed": false,
    "spec_conflicts": ["CONFLICT-xxx"]
  },
  "convergence": {
    "converged": false,
    "stall_detected": false,
    "stall_reason": "string",
    "iterations_remaining_estimate": 0
  }
}
```

**Gate Rules:**
- If `converged == true` (health_score >= target_health) → Pipeline ends.
- If `stall_detected == true` (3+ iterations with health_delta <= 0) → Trigger spec-fix or halt.
- If `escalate_to_opus` is non-empty → Those items use Opus 4.6 for next Plan + Review.
- If `spec_fix_needed == true` → Run Phase 8 before next iteration.

**Cost per call:** $0.132
**Total (23 iterations):** $1.09 (this phase cannot be batched — it's the critical path)

### Phase 8: Spec-Fix (Occasional, Batched)

**Purpose:** Resolve specification conflicts and ambiguities discovered during execution.
**Model:** Sonnet 4.6 (API, Batch)
**Frequency:** ~5 times per project (triggered by Verify when spec issues found).
**Inputs:** Conflicts from Verify, original spec artifacts, execution context.
**Cached input:** Full 15K prefix (cache read) — **note: cache block 2 must be rewritten after spec-fix**.
**New input:** ~12,000 tokens.
**Output:** ~4,000 tokens.

**Output Schema:**
```json
{
  "$schema": "gsd-v3/spec-fix-output",
  "iteration": 0,
  "resolutions": [
    {
      "conflict_id": "CONFLICT-xxx",
      "resolution": "Description of how the conflict was resolved",
      "spec_changes": [
        {
          "artifact": "file path",
          "section": "section name",
          "old_value": "string",
          "new_value": "string"
        }
      ],
      "affected_requirements": ["REQ-xxx"],
      "requires_rework": ["REQ-xxx"]
    }
  ],
  "cache_invalidation": {
    "spec_block_changed": true,
    "new_spec_hash": "sha256"
  }
}
```

**After spec-fix:** The orchestrator rewrites cache block 2 (spec documents) with the updated content. Cost: one additional $0.030 cache write.

**Cost per call:** $0.050
**Total (~5 calls):** $0.25

---

## 6. Quality & Speed Optimizations

### Optimization 1: Local Validation Before LLM Review

**Impact:** -$1.20 cost, +10% speed, better quality (test-informed review)

Items that pass local validation (lint + typecheck + test) skip the Review phase entirely. This eliminates ~60% of Review calls while improving quality for the remaining 40% — because Review receives the specific failure output rather than raw code.

**Implementation:**
- After Execute, run local validation pipeline (Phase 5) for every item.
- Items with PASS status proceed directly to Verify.
- Items with FAIL status enter Review with error context attached.

### Optimization 2: Structured JSON Output

**Impact:** -$0.75 cost (fewer retries), +10% speed, better reliability

All Sonnet API calls use `response_format: { "type": "json_object" }` with the schemas defined above. This eliminates parsing failures that cause retry loops.

**Implementation:**
- Every phase prompt includes the exact JSON schema.
- The orchestrator validates output against schema before proceeding.
- If schema validation fails (should be rare with JSON mode), retry once with a repair prompt.

### Optimization 3: Confidence-Gated Review Skip

**Impact:** -$0.90 cost, +15% speed, neutral quality

The Plan phase assigns a `confidence` score (0.0-1.0) to each requirement:
- `>= 0.9`: Trivial item (CRUD, DTO, config, simple SP, seed data). Skip Review if local validation passes.
- `0.7-0.89`: Standard item. Normal Review if local validation fails.
- `< 0.7`: Complex item. Always Review regardless of local validation.

**Confidence criteria (for Plan phase prompt):**
- Complexity: `small` → +0.3, `medium` → +0.1, `large` → -0.1
- Category match: `crud | config | dto | seed_data` → +0.3
- Dependencies: 0 deps → +0.2, 1-2 deps → +0.1, 3+ deps → -0.1
- Prior rework: 0 reworks → +0.1, 1+ reworks → -0.2

### Optimization 4: Speculative Execution

**Impact:** $0.00 cost, +40% speed, neutral quality

Start the next iteration's Research + Plan while the current iteration's Review is still in-flight (batched).

```
Timeline WITHOUT speculative execution:
  Iter N:  [Execute 20s] [LocalVal 10s] [Review 20min batch] [Verify 8s]
  Iter N+1:                                                   [Research...

Timeline WITH speculative execution:
  Iter N:    [Execute 20s] [LocalVal 10s] [Review 20min batch]──────────[Verify 8s]
  Iter N+1:                                [Research 10min] [Plan 10min] [Execute 20s]...
```

**Risk:** If Review rejects items and changes the queue, some of N+1's Research/Plan work may be wasted. At 15% rejection rate, the expected waste is ~$0.009 per iteration (15% × $0.062). Acceptable.

**Guard rails:**
- Speculative execution only starts if current iteration's health_delta > 0 (pipeline is making progress).
- If the previous Verify detected a stall, disable speculative execution for the next iteration.
- Maximum 1 iteration of speculative lookahead (don't pipeline deeper than N+1).

### Optimization 5: Diff-Based Review

**Impact:** -$1.35 cost, +5% speed, better quality

Review receives only diffs and error output instead of full generated files.

**Before (V2):** 55K tokens of full generated files per Review call.
**After (V3):** ~12K tokens of diffs + error context per Review call.

Sonnet is better at reviewing diffs because:
1. Less noise — only the relevant changes are visible.
2. Error context — the specific failure tells Sonnet exactly what to focus on.
3. Smaller context — Sonnet's attention is more focused.

### Optimization 6: Two-Stage Execute (Skeleton → Fill)

**Impact:** +$0.50 cost, -5% speed, significantly better structural correctness

Split Execute into two Codex Mini passes:

**Pass 1 — Skeleton (30% of output tokens):**
Generate type signatures, interfaces, function stubs, class structure, imports, namespace declarations. No implementation bodies.

**Pass 2 — Fill (70% of output tokens):**
Receive the skeleton as input. Fill in all implementation bodies, referencing the skeleton's type signatures and interfaces.

**Why this improves quality:**
- Structural errors (wrong interface, missing method, mismatched types) are caught between passes.
- The skeleton provides a contract that constrains the fill pass.
- Each pass has smaller, more focused context.

**Cost increase:** ~$0.50 total (extra Codex Mini calls for skeleton pass). Well worth it for the quality improvement.

**Implementation:**
```
For each requirement in batch:
  Pass 1: Codex Mini → generates skeleton (types, interfaces, stubs)
  Validate skeleton: check type signatures match plan
  Pass 2: Codex Mini → fills implementations using skeleton + plan
```

### Optimization 7: Cache-Warming Pre-flight

**Impact:** +$0.06 cost, +2% speed (eliminates cold-start)

Before the first real iteration, fire a throwaway Sonnet call to populate the cache (Phase 0). This ensures every productive call gets a cache hit.

---

## 7. Pipeline Modes

The V3 pipeline operates in three modes. All modes use the same 2-model architecture, prompt caching, and batch API — but with different phase configurations, batch sizes, and iteration limits.

### Mode 1: Greenfield (`gsd-blueprint`)

**When:** Building a new project from spec (pre-1.0). Full pipeline, all phases active.

| Parameter | Value |
|-----------|:-----:|
| Max iterations | 25 |
| Batch size | 15 |
| Phases active | All 8 (cache-warm through spec-fix) |
| Research | Full (every iteration) |
| Spec Gate | Required (blocks on clarity < 70) |
| Speculative execution | Enabled |
| Budget cap | $50.00 |

This is the default mode described in Sections 2-6. All optimizations apply.

### Mode 2: Bug Fix (`gsd-fix`)

**When:** Post-launch. Fixing specific bugs reported via CLI, file, or bug directory.

```
gsd-fix "Login fails when email contains + character"
gsd-fix -File bugs.md
gsd-fix -BugDir ./bugs/login-issue/
```

| Parameter | Value |
|-----------|:-----:|
| Max iterations | 5 |
| Batch size | 3 |
| Phases active | Plan → Execute → Local Validate → Review → Verify |
| Research | **Skipped** (bug context is self-contained) |
| Spec Gate | **Skipped** (spec already validated at 1.0) |
| Speculative execution | **Disabled** (too few iterations to benefit) |
| Two-stage execute | **Optional** (disabled for small fixes, enabled for multi-file bugs) |
| Budget cap | $5.00 |
| Scope filter | `source:bug_report` or `id:BUG-001,BUG-002` |

#### Bug Fix Data Flow

```
Bug Report (CLI / file / directory)
    │
    ├── Parse bug → create BUG-xxx entry in requirements-matrix.json
    │   status: "not_started", priority: "critical", source: "bug_report"
    │
    ├── Copy artifacts → .gsd/supervisor/bug-artifacts/BUG-xxx/
    │   Screenshots, logs, repro files
    │
    ├── Write error-context.md → .gsd/supervisor/error-context.md
    │   Bug description + inlined log snippets (first 20 lines)
    │
    └── Run scoped convergence loop:
        │
        ├── Plan (Sonnet BATCH, cached)
        │   Input: bug context + error-context.md + relevant source files
        │   Scope filter: only BUG-xxx requirements
        │
        ├── Execute (Codex Mini, real-time)
        │   Fix only the files identified in plan
        │
        ├── Local Validate (FREE)
        │   Must pass: existing tests + new regression test
        │
        ├── Review (Sonnet BATCH, cached)
        │   Diff-based: only the fix diff + test output
        │   Focus: regression risk, does fix address root cause
        │
        └── Verify (Sonnet real-time, cached)
            Update BUG-xxx status, check for side effects
```

#### Bug Fix Cost Estimate

| Phase | Iterations | Cost |
|-------|:----------:|:----:|
| Plan | 3 | $0.12 |
| Execute | 3 | $0.035 |
| Local Validate | 3 | $0.00 |
| Review | ~2 (skip if local passes) | $0.12 |
| Verify | 3 | $0.040 |
| **Total per bug** | | **~$0.32** |

For a typical month with 20 bugs: **~$6.40/month**.

#### Bug Fix Requirements Matrix Entry

```json
{
    "req_id": "BUG-001",
    "source": "bug_report",
    "sdlc_phase": "Phase-D-Implementation",
    "description": "Login fails when email contains + character",
    "status": "not_started",
    "depends_on": [],
    "priority": "critical",
    "spec_version": "fix",
    "interface": "web",
    "bug_artifacts": {
        "screenshots": [".gsd/supervisor/bug-artifacts/BUG-001/error-screenshot.png"],
        "logs": [".gsd/supervisor/bug-artifacts/BUG-001/server.log"],
        "repro_steps": "1. Enter email with + char\n2. Click login\n3. 500 error"
    },
    "regression_test_required": true
}
```

### Mode 3: Feature Update (`gsd-update`)

**When:** Post-launch. Adding new features from updated specs (v02, v03, etc.) without touching satisfied requirements.

```
gsd-update
gsd-update -Scope "source:v02_spec"
gsd-update -Scope "id:REQ-201,REQ-202,REQ-203"
```

| Parameter | Value |
|-----------|:-----:|
| Max iterations | 20 |
| Batch size | 10 |
| Phases active | All 8 (same as greenfield, but incremental) |
| Research | Full (new features need pattern discovery) |
| Spec Gate | **Incremental** (validate only new/changed spec sections) |
| Speculative execution | Enabled |
| Two-stage execute | Enabled |
| Budget cap | $25.00 |
| Scope filter | `source:v02_spec` or specific requirement IDs |

#### Feature Update Data Flow

```
Updated Specs (v02 docs, new Figma designs, etc.)
    │
    ├── Incremental Spec Gate (Sonnet BATCH, cached)
    │   Only validate NEW spec sections against existing spec
    │   Detect conflicts between new features and existing code
    │   Do NOT re-validate already-satisfied requirements
    │
    ├── Incremental Create-Phases (Sonnet BATCH, cached)
    │   READ existing requirements-matrix.json
    │   PRESERVE all existing entries (status unchanged)
    │   APPEND new requirements with spec_version: "v02"
    │   Recalculate health score with new total
    │
    └── Run scoped convergence loop (same as greenfield, but filtered):
        │
        ├── Research → only new requirements
        ├── Plan → only new requirements (respect existing dep graph)
        ├── Execute → only new requirement files
        ├── Local Validate → new files + regression suite
        ├── Review → only new/changed code
        └── Verify → full health check (new + existing)
                     Regression detection: flag if existing satisfied
                     requirements regressed to partial/not_started
```

#### Feature Update Preservation Rules

1. **NEVER modify** files owned by satisfied requirements unless the plan explicitly identifies a shared dependency.
2. **ALWAYS run full regression** (all existing tests) during Local Validate, not just new requirement tests.
3. **TAG** new requirements with `spec_version: "v02"` for traceability.
4. **DETECT regression**: If Verify finds a previously-satisfied requirement regressed, halt and flag for human review.
5. **Cache prefix update**: New spec content is appended to cache block 2. Cache rewrite triggered.

#### Feature Update Cost Estimate (50 new requirements, ~25K new LOC)

| Phase | Iterations | Cost |
|-------|:----------:|:----:|
| Incremental Spec Gate | 1 | $0.08 |
| Incremental Create-Phases | 1 | $0.05 |
| Research | 7 | $0.43 |
| Plan | 7 | $0.28 |
| Execute (skeleton + fill) | 7 | $0.95 |
| Local Validate | 7 | $0.00 |
| Review | ~3 | $0.18 |
| Verify | 7 | $0.33 |
| **Total per feature update** | | **~$2.30** |

### Mode Comparison

| Dimension | Greenfield | Bug Fix | Feature Update |
|-----------|:----------:|:-------:|:--------------:|
| Command | `gsd-blueprint` | `gsd-fix` | `gsd-update` |
| Max iterations | 25 | 5 | 20 |
| Batch size | 15 | 3 | 10 |
| Research | Full | Skip | Full (scoped) |
| Spec Gate | Full | Skip | Incremental |
| Scope filter | None (all) | `source:bug_report` | `source:v02_spec` |
| Preserve existing | N/A | Yes | Yes |
| Regression test | N/A | Required | Required |
| Two-stage execute | Yes | Optional | Yes |
| Speculative execution | Yes | No | Yes |
| Budget cap | $50 | $5 | $25 |
| Typical cost | $7.30/100K LOC | $0.32/bug | $2.30/50 reqs |

---

## 8. Multi-Interface Architecture

### Supported Interface Types

The V3 pipeline generates code for 5 interface types simultaneously. Each interface has its own design artifacts, conventions, and generation patterns.

| Interface | Key | Description | Frontend Stack | Design Source |
|-----------|:---:|-------------|---------------|---------------|
| **Web Application** | `web` | Primary SPA for end users | React 18 + TypeScript | Figma → `design/web/v{N}/_analysis/` |
| **MCP Admin Portal** | `mcp-admin` | Model Context Protocol admin dashboard | React 18 + TypeScript | Figma → `design/mcp-admin/v{N}/_analysis/` |
| **Browser Extension** | `browser` | Chrome/Firefox/Edge extension | React 18 (popup/options) + Background Service Worker | Figma → `design/browser/v{N}/_analysis/` |
| **Mobile App** | `mobile` | iOS/Android native app | React Native or .NET MAUI | Figma → `design/mobile/v{N}/_analysis/` |
| **Remote Agent** | `agent` | Headless autonomous agent | Node.js/Python CLI, no UI | Spec docs (no Figma) |

### Design Folder Structure

```
design/
├── web/
│   └── v1/
│       ├── _analysis/                    ← Figma Make deliverables
│       │   ├── 01-screen-inventory.md
│       │   ├── 02-component-inventory.md
│       │   ├── 03-design-system.md
│       │   ├── 04-navigation-routing.md
│       │   ├── 05-data-types.md
│       │   ├── 06-api-contracts.md
│       │   ├── 07-hooks-state.md
│       │   ├── 08-mock-data-catalog.md
│       │   ├── 09-storyboards.md
│       │   ├── 10-screen-state-matrix.md
│       │   ├── 11-api-to-sp-map.md
│       │   └── 12-implementation-guide.md
│       └── _stubs/                       ← Code stubs
│           ├── backend/Controllers/*.cs
│           ├── backend/Models/*.cs
│           ├── database/01-tables.sql
│           ├── database/02-stored-procedures.sql
│           └── database/03-seed-data.sql
├── mcp-admin/
│   └── v1/
│       ├── _analysis/                    ← Same 12-deliverable structure
│       └── _stubs/
├── browser/
│   └── v1/
│       ├── _analysis/
│       └── _stubs/
├── mobile/
│   └── v1/
│       ├── _analysis/
│       └── _stubs/
└── agent/
    └── v1/
        └── spec/                         ← No Figma, spec-only
            ├── agent-capabilities.md
            ├── agent-protocols.md
            └── agent-api-contracts.md
```

### Interface Detection

The orchestrator auto-detects interfaces at pipeline start using `Find-ProjectInterfaces()`:

```powershell
# Auto-detection scans design/ for interface folders matching types in config
# Returns: Interfaces array with metadata per interface

$interfaces = Find-ProjectInterfaces
# Result:
# [
#   { Key: "web",     Version: "v1", HasAnalysis: true,  AnalysisFileCount: 12 },
#   { Key: "mcp",     Version: "v1", HasAnalysis: true,  AnalysisFileCount: 12 },
#   { Key: "browser", Version: "v1", HasAnalysis: true,  AnalysisFileCount: 8 },
#   { Key: "mobile",  Version: "v1", HasAnalysis: false, AnalysisFileCount: 0 },
#   { Key: "agent",   Version: "v1", HasAnalysis: false, AnalysisFileCount: 0 }
# ]
```

**Interface map saved to:** `.gsd/blueprint/interface-map.json`

### Interface-Specific Conventions

Each interface type has distinct code generation patterns injected into Execute prompts:

#### Web Application (`web`)

```
Frontend: React 18 + TypeScript + Vite
Routing: React Router v7
State: React Query for server state, Zustand for client state
Styling: Tailwind CSS with design tokens from Figma 03-design-system.md
Testing: Vitest + React Testing Library
Build: Vite → dist/
Output dir: src/web/
```

#### MCP Admin Portal (`mcp`)

```
Frontend: React 18 + TypeScript + Vite
Routing: React Router v7
State: React Query + Zustand
Styling: Tailwind CSS (admin-specific design system)
MCP SDK: @anthropic-ai/mcp-sdk for server/tool management
Features: Server configuration, tool management, log viewer, metrics dashboard
Testing: Vitest + React Testing Library
Build: Vite → dist/
Output dir: src/mcp-admin/
Unique patterns:
  - MCP server connection management (SSE/stdio)
  - Tool registry CRUD
  - Real-time log streaming
  - Server health monitoring
```

#### Browser Extension (`browser`)

```
Framework: React 18 + TypeScript (popup, options, side panel)
Background: Service Worker (Manifest V3)
Content Scripts: Vanilla TypeScript (injected into pages)
Storage: chrome.storage.sync / chrome.storage.local
Messaging: chrome.runtime.sendMessage / chrome.runtime.onMessage
Permissions: Minimal required, declared in manifest.json
Testing: Vitest + JSDOM (no real browser APIs in tests)
Build: Vite + CRXJS or custom Vite plugin → dist/
Output structure:
  src/browser/
    ├── manifest.json
    ├── background/service-worker.ts
    ├── content/content-script.ts
    ├── popup/App.tsx
    ├── options/App.tsx
    ├── sidepanel/App.tsx (optional)
    └── shared/storage.ts, messaging.ts
Unique patterns:
  - Manifest V3 permissions model
  - Content script ↔ background messaging
  - chrome.storage wrapper with type safety
  - Cross-origin request handling via background
  - Extension-specific CSP constraints
```

#### Mobile App (`mobile`)

```
Option A — React Native:
  Framework: React Native 0.76+ with Expo
  Navigation: React Navigation v7
  State: React Query + Zustand (shared patterns with web)
  Styling: NativeWind (Tailwind for React Native)
  Testing: Jest + React Native Testing Library
  Build: Expo EAS Build
  Output dir: src/mobile/

Option B — .NET MAUI:
  Framework: .NET 8 MAUI
  Navigation: Shell navigation
  State: MVVM with CommunityToolkit.Mvvm
  Styling: XAML resources + design tokens
  Testing: xUnit + MAUI test framework
  Build: dotnet publish
  Output dir: src/mobile-maui/

Unique patterns:
  - Platform-specific code (iOS/Android)
  - Offline-first data sync
  - Push notification registration
  - Biometric authentication
  - Deep linking / universal links
  - App store compliance (privacy labels, permissions)
```

#### Remote Agent (`agent`)

```
Runtime: Node.js 22+ or Python 3.12+
Protocol: MCP client (connects to MCP servers)
Communication: stdio / SSE / WebSocket
Auth: API key + OAuth2 for service-to-service
Scheduling: Cron or event-driven (webhook triggers)
Testing: Vitest (Node) or pytest (Python)
Build: Docker container
Output dir: src/agent/
Unique patterns:
  - No UI — headless CLI or daemon
  - MCP tool invocation and result handling
  - Autonomous task loop with human-in-the-loop checkpoints
  - Structured logging (JSON)
  - Rate limiting and backoff
  - State persistence between runs
  - Health check endpoint (HTTP /health)
```

### Interface-Aware Pipeline Behavior

#### Spec Gate: Cross-Interface Consistency

The Spec Gate phase validates consistency across ALL detected interfaces:

```json
{
  "cross_interface_checks": [
    {
      "check": "shared_api_contracts",
      "description": "All interfaces hitting the same API must agree on endpoint shapes",
      "sources": ["web/06-api-contracts.md", "mcp-admin/06-api-contracts.md", "mobile/06-api-contracts.md"]
    },
    {
      "check": "shared_data_types",
      "description": "TypeScript interfaces must match across web, MCP, browser, mobile",
      "sources": ["*/05-data-types.md"]
    },
    {
      "check": "shared_design_tokens",
      "description": "Core design tokens (colors, spacing) should be consistent across web + MCP",
      "sources": ["*/03-design-system.md"]
    },
    {
      "check": "auth_consistency",
      "description": "Auth flows must be compatible across all interfaces",
      "sources": ["*/06-api-contracts.md", "agent/agent-api-contracts.md"]
    }
  ]
}
```

#### Requirements: Interface Tagging

Every requirement is tagged with its target interface(s):

```json
{
  "req_id": "REQ-042",
  "name": "Patient search",
  "interfaces": ["web", "mobile"],
  "interface_specific": {
    "web": { "screen": "PatientSearch.tsx", "route": "/patients/search" },
    "mobile": { "screen": "PatientSearchScreen.tsx", "route": "PatientSearch" }
  }
}
```

Requirements can target multiple interfaces (shared features) or a single interface (platform-specific).

#### Plan: Interface-Specific File Routing

The Plan phase generates files routed to the correct output directories:

```json
{
  "req_id": "REQ-042",
  "files_to_create": [
    { "path": "src/web/pages/PatientSearch.tsx", "interface": "web" },
    { "path": "src/mobile/screens/PatientSearchScreen.tsx", "interface": "mobile" },
    { "path": "src/shared/hooks/usePatientSearch.ts", "interface": "shared" },
    { "path": "src/shared/types/patient.ts", "interface": "shared" },
    { "path": "backend/Controllers/PatientController.cs", "interface": "backend" },
    { "path": "database/stored-procedures/usp_Patient_Search.sql", "interface": "backend" }
  ]
}
```

#### Execute: Interface-Specific Conventions Injection

Each Codex Mini call receives the conventions for its target interface:

```
For web file → inject web conventions (React 18 + Tailwind + design tokens)
For mobile file → inject mobile conventions (React Native + NativeWind)
For browser file → inject browser conventions (Manifest V3 + chrome APIs)
For MCP file → inject MCP conventions (MCP SDK + admin patterns)
For agent file → inject agent conventions (headless + MCP client)
For shared file → inject shared conventions (pure TypeScript, no platform APIs)
For backend file → inject backend conventions (.NET 8 + Dapper)
```

This keeps each Codex Mini call focused on one set of conventions, improving code quality.

#### Execute: Cross-Interface Parallelism

When a requirement targets multiple interfaces, the Execute calls for different interfaces run in parallel:

```
REQ-042 (web + mobile):
  ├── Codex Mini: web/PatientSearch.tsx          ┐
  ├── Codex Mini: mobile/PatientSearchScreen.tsx  ├── All parallel
  ├── Codex Mini: shared/usePatientSearch.ts      │
  └── Codex Mini: backend/PatientController.cs    ┘
```

Shared files (hooks, types) are generated first if they're dependencies, otherwise all files fire concurrently.

#### Local Validate: Per-Interface Tooling

| Interface | Build Check | Type Check | Lint | Test |
|-----------|------------|------------|------|------|
| Web | `vite build` | `tsc --noEmit` | `eslint` | `vitest` |
| MCP | `vite build` | `tsc --noEmit` | `eslint` | `vitest` |
| Browser | `vite build` (CRXJS) | `tsc --noEmit` | `eslint` | `vitest` |
| Mobile (RN) | `expo prebuild --check` | `tsc --noEmit` | `eslint` | `jest` |
| Mobile (MAUI) | `dotnet build` | N/A (compiled) | N/A | `dotnet test` |
| Agent (Node) | `tsc` | `tsc --noEmit` | `eslint` | `vitest` |
| Agent (Python) | N/A | `mypy` | `ruff` | `pytest` |
| Backend | `dotnet build --no-restore` | N/A (compiled) | N/A | `dotnet test` |
| Database | `sqlcmd -i {file} -b` | N/A | N/A | N/A |

### Shared Code Strategy

Maximize code reuse across interfaces:

```
src/
├── shared/                          ← Used by ALL frontends
│   ├── types/                       ← TypeScript interfaces (from Figma 05-data-types.md)
│   ├── hooks/                       ← Data fetching hooks (React Query)
│   ├── utils/                       ← Pure functions, formatters, validators
│   ├── api/                         ← API client (fetch wrapper, typed endpoints)
│   └── constants/                   ← Shared constants, enums
├── web/                             ← Web-only components and pages
├── mcp-admin/                       ← MCP admin-only components
├── browser/                         ← Extension-specific code
├── mobile/                          ← Mobile-specific screens and navigation
├── agent/                           ← Agent-specific logic
└── backend/                         ← .NET 8 API (shared across all interfaces)
```

**Rules for shared code:**
1. `shared/` must contain NO platform-specific imports (no `react-native`, no `chrome.*`, no `expo-*`).
2. `shared/types/` is the single source of truth for all TypeScript interfaces.
3. `shared/hooks/` uses React Query — compatible with React 18 (web, MCP, browser popup) and React Native.
4. `shared/api/` uses `fetch` — available in all runtimes.

### Interface-Specific Cost Impact

Adding interfaces increases requirements but shares the cached prefix and backend code:

| Interfaces | Est. Requirements | Est. LOC | Greenfield Cost | Notes |
|:---:|:---:|:---:|:---:|------|
| Web only | 200 | 100K | $7.30 | Baseline |
| Web + MCP | 280 | 140K | $10.00 | MCP shares 60% of backend |
| Web + MCP + Browser | 340 | 165K | $12.00 | Browser is lightweight |
| Web + MCP + Browser + Mobile | 450 | 220K | $15.80 | Mobile adds platform-specific code |
| All 5 (+ Agent) | 500 | 250K | $17.50 | Agent is headless, few UI requirements |

Cost scales sub-linearly because:
- Backend API is shared across all interfaces (generated once).
- `shared/` types, hooks, and utils are generated once.
- Cached prefix is the same for all interfaces (one cache write).
- Additional interfaces mostly add frontend-specific requirements.

### Bug Fix and Feature Update with Multiple Interfaces

#### Bug Fix: Interface-Scoped

Bugs are tagged with their interface. The fix pipeline only touches that interface's code:

```
gsd-fix -Interface web "Login button unresponsive on Safari"
gsd-fix -Interface browser "Extension popup doesn't open on Firefox"
gsd-fix -Interface mobile "Crash on Android 14 when rotating screen"
```

The scope filter becomes: `source:bug_report AND interface:web`

Local validation runs only the affected interface's test suite, plus shared regression tests.

#### Feature Update: Cross-Interface

New features may span multiple interfaces:

```
gsd-update -Scope "source:v02_spec"
# v02 spec adds "patient messaging" feature for web + mobile + agent
```

The incremental create-phases phase:
1. Reads existing matrix (preserves all satisfied requirements).
2. Discovers new requirements from v02 specs.
3. Tags new requirements with their target interfaces.
4. Plans shared code first, then interface-specific code.

---

## 9. Configuration Reference

### v3/config/global-config.json

See `v3/config/global-config.json` for the complete configuration file. Key changes from V2:

| Setting | V2 Value | V3 Value | Reason |
|---------|----------|----------|--------|
| `phase_order` | 5 phases | 8 phases (incl. local-validate, cache-warm) | New optimization phases |
| `batch_size_max` | 14 | 15 | Codex Mini handles larger batches |
| `models` | 7 agents | 2 models | Simplified routing |
| `prompt_caching.enabled` | false | true | 90% input savings |
| `batch_api.enabled` | false | true | 50% off non-urgent phases |
| `local_validation.enabled` | false | true | Free quality gate |
| `speculative_execution.enabled` | false | true | 40% speed boost |
| `diff_based_review.enabled` | false | true | Better + cheaper review |
| `two_stage_execute.enabled` | false | true | Structural correctness |
| `confidence_gated_review.threshold` | N/A | 0.9 | Skip review for trivial items |
| `council_requirements.enabled` | true | **false** | Replaced by 2-model deterministic routing |
| `partitioned_code_review.enabled` | true | **false** | Replaced by diff-based review |
| `parallel_research.enabled` | true | **false** | Single model, batch API instead |
| `complexity_routing.enabled` | true | **false** | All code gen → Codex Mini, all reasoning → Sonnet |

### v3/config/model-registry.json

See `v3/config/model-registry.json` for the complete configuration file.

### v3/config/agent-map.json

See `v3/config/agent-map.json` for the complete configuration file.

---

## 10. Prompt Specifications

### Shared Prompts (Injected into All Sonnet Calls via Cache)

- `v3/prompts/shared/system-prompt.md` — Role definition, output format rules, JSON schema enforcement
- `v3/prompts/shared/coding-conventions.md` — Carried from V2, injected into Execute calls for Codex Mini
- `v3/prompts/shared/security-standards.md` — Carried from V2, injected into Execute calls for Codex Mini

### Phase Prompts

| Phase | Prompt File | Model | Notes |
|-------|------------|-------|-------|
| 1. Spec Gate | `v3/prompts/sonnet/01-spec-gate.md` | Sonnet | Adapted from V2 `01-spec-quality-gate.md`, adds JSON schema |
| 2. Research | `v3/prompts/sonnet/02-research.md` | Sonnet | Replaces Gemini research; uses batch + cache |
| 3. Plan | `v3/prompts/sonnet/03-plan.md` | Sonnet | Adds confidence scoring, two-stage plan output |
| 4a. Execute (Skeleton) | `v3/prompts/codex-mini/04a-execute-skeleton.md` | Codex Mini | New: generates types/interfaces/stubs only |
| 4b. Execute (Fill) | `v3/prompts/codex-mini/04b-execute-fill.md` | Codex Mini | New: fills implementations from skeleton |
| 6. Review | `v3/prompts/sonnet/06-review.md` | Sonnet | Diff-based, receives error context from local validate |
| 7. Verify | `v3/prompts/sonnet/07-verify.md` | Sonnet | Adapted from V2, adds convergence detection + escalation |
| 8. Spec-Fix | `v3/prompts/sonnet/08-spec-fix.md` | Sonnet | Replaces Gemini spec-fix; adds cache invalidation |

---

## 11. Cost Projections

### Reference Project: 200 Requirements, ~100,000 LOC

**Pipeline parameters:**
- Batch size: 15
- Batch efficiency: 70% → 10.5 effective items/iteration
- Base iterations: ceil(200 / 10.5) = 20
- Retry iterations: 3 (15% rework rate reduced to ~8% with optimizations)
- Total iterations: **23**
- Spec-fix frequency: ~5 times

### Phase-by-Phase Cost

| Phase | Model | Batch? | Cached? | Iterations | Input Tok/Call | Output Tok/Call | Cost/Call | Total Cost |
|-------|-------|:------:|:-------:|:----------:|:-:|:-:|:-:|:-:|
| 0. Cache Warm | Sonnet | No | Write | 1 | 15,000 | 10 | $0.056 | **$0.06** |
| 1. Spec Gate | Sonnet | Yes | Read | 1 | 50,000 | 3,000 | $0.077 | **$0.08** |
| 2. Research | Sonnet | Yes | Read | 23 | 25,000 | 6,000 | $0.062 | **$1.25** |
| 3. Plan | Sonnet | Yes | Read | 23 | 23,000 | 4,000 | $0.040 | **$0.86** |
| 4. Execute | Codex Mini | No | No | 23 | 42,500 | 52,500 | $0.116 | **$2.67** |
| 4b. Skeleton pass | Codex Mini | No | No | 23 | 20,000 | 15,750 | $0.037 | **$0.50** |
| 5. Local Validate | None | — | — | 23 | 0 | 0 | $0.00 | **$0.00** |
| 6. Review (40%) | Sonnet | Yes | Read | ~9 | 27,000 | 3,000 | $0.060 | **$0.54** |
| 7. Verify | Sonnet | No | Read | 23 | 45,000 | 2,500 | $0.132 | **$1.09** |
| 8. Spec-Fix | Sonnet | Yes | Read | 5 | 27,000 | 4,000 | $0.050 | **$0.25** |
| **TOTAL** | | | | | | | | **$7.30** |

### Cost Comparison Across Versions

| Version | Models | Total Cost | $/1K LOC | Wall Clock | API Keys |
|---------|:------:|:---------:|:--------:|:----------:|:--------:|
| V2 (7 models, CLI subscriptions) | 7 | ~$50-57 | $0.50-0.57 | 12-15 hrs | 7 |
| V3 Naive (2 models, no optimization) | 2 | ~$22.00 | $0.22 | 4-5 hrs | 2 |
| V3 + Cache only | 2 | ~$13.50 | $0.14 | 4-5 hrs | 2 |
| V3 + Cache + Batch | 2 | ~$9.00 | $0.09 | 3-4 hrs | 2 |
| **V3 Full (all optimizations)** | **2** | **$7.30** | **$0.073** | **~1.5 hrs** | **2** |

### Scaling Projections

| Project Size | Requirements | Est. LOC | Iterations | Total Cost | $/1K LOC |
|:---:|:---:|:---:|:---:|:---:|:---:|
| Small | 50 | 25,000 | 7 | $2.10 | $0.084 |
| Medium | 100 | 50,000 | 12 | $3.80 | $0.076 |
| **Reference** | **200** | **100,000** | **23** | **$7.30** | **$0.073** |
| Large | 500 | 250,000 | 55 | $17.50 | $0.070 |
| Enterprise | 1,000 | 500,000 | 105 | $33.00 | $0.066 |

Cost per LOC decreases with scale because the cache write cost and spec gate are amortized over more items.

---

## 12. Runtime Architecture

### API Client Configuration

```json
{
  "anthropic": {
    "api_key_env": "ANTHROPIC_API_KEY",
    "base_url": "https://api.anthropic.com",
    "api_version": "2024-01-01",
    "default_model": "claude-sonnet-4-6-20260310",
    "max_retries": 3,
    "retry_backoff": [2, 4, 8],
    "timeout_seconds": 120,
    "batch_endpoint": "/v1/messages/batches",
    "batch_poll_interval_seconds": 30,
    "batch_max_wait_minutes": 60
  },
  "openai": {
    "api_key_env": "OPENAI_API_KEY",
    "base_url": "https://api.openai.com/v1",
    "default_model": "gpt-5.1-codex-mini",
    "max_retries": 3,
    "retry_backoff": [2, 4, 8],
    "timeout_seconds": 120,
    "max_concurrent_requests": 15
  }
}
```

### Rate Limits

| Model | RPM | TPM | Concurrent | Notes |
|-------|:---:|:---:|:----------:|-------|
| Sonnet 4.6 (Tier 2) | 1,000 | 160,000 | 50 | Well within limits for our usage |
| Sonnet 4.6 (Tier 3) | 2,000 | 320,000 | 100 | Achievable after ~$100 spend |
| Codex Mini | 3,500 | 10,000,000 | 100 | Effectively unlimited for our usage |

At 23 iterations with ~6 Sonnet calls per iteration = ~138 total Sonnet calls. At ~10 seconds between iterations, peak RPM is ~6. Nowhere near rate limits.

### Error Handling

```
API Error → Retry with exponential backoff (2s, 4s, 8s)
  │
  ├── 429 (Rate Limit) → Wait for retry-after header, then retry
  ├── 500/502/503 → Retry up to 3 times
  ├── 400 (Bad Request) → Log error, skip item, flag for human review
  ├── Timeout → Retry once with 2x timeout
  └── All retries exhausted → Mark item as failed, continue pipeline
```

### Checkpoint & Recovery

```json
{
  "checkpoint": {
    "pipeline": "v3-convergence",
    "iteration": 5,
    "phase": "execute",
    "batch_items": ["REQ-042", "REQ-043", "REQ-044"],
    "completed_items": ["REQ-001", "REQ-002", "..."],
    "health_score": 42,
    "cache_version": 1,
    "cache_block_hashes": {
      "system_prompt": "sha256:abc...",
      "spec_documents": "sha256:def...",
      "blueprint": "sha256:ghi..."
    },
    "cost_so_far": {
      "sonnet_input_tokens": 450000,
      "sonnet_output_tokens": 85000,
      "codex_mini_input_tokens": 212500,
      "codex_mini_output_tokens": 262500,
      "total_usd": 3.15
    },
    "last_updated": "ISO-8601"
  }
}
```

### Notification Events

All existing notification events from V2 are preserved:
- `iteration_complete` — Per-iteration summary with cost delta
- `converged` — Pipeline finished successfully
- `stalled` — Health not improving for 3+ iterations
- `quota_exhausted` — Replaced with `budget_threshold` (alert at 80% of budget cap)
- `error` — Unrecoverable error

New V3 events:
- `cache_invalidated` — Cache prefix was rewritten (after spec-fix)
- `opus_escalation` — Item escalated to Opus 4.6 for complex reasoning
- `batch_completed` — Batch API request finished processing
- `speculative_waste` — Speculative execution was invalidated by Review results

---

## 13. Migration from V2

### What's Removed

| V2 Feature | V3 Replacement |
|-----------|---------------|
| 7-agent rotation pool | 2-model deterministic routing |
| CLI-based agent invocation | Direct API calls (Anthropic SDK + OpenAI SDK) |
| Council requirements (multi-agent consensus) | Single Sonnet review + local validation |
| Partitioned code review (5 agents) | Diff-based Sonnet review |
| Parallel research (3 agents) | Single Sonnet research (batched) |
| Complexity routing (low/med/high → different agents) | All reasoning → Sonnet, all code → Codex Mini |
| Chunked review (rate-limit-aware) | Batch API handles throughput |
| Agent warm-start cache | API prompt caching replaces this |
| DeepSeek/GLM-5/MiniMax/Kimi agents | Removed (2-model strategy) |
| Gemini research/spec-fix | Sonnet handles both (batched) |

### What's Preserved

- All quality gates (database completeness, security compliance, spec quality, API contract validation, visual validation, design token enforcement, compliance engine)
- Acceptance test framework (file_exists, pattern_match, build_check, dotnet_test, npm_test)
- Runtime smoke test
- LOC tracking and cost-per-line metrics
- Health scoring system
- Requirements matrix format
- Stall detection
- Checkpoint/recovery
- Notification system
- Supervisor context injection
- `.gsd/` directory structure
- All prompt content (adapted for JSON output)

### What's New

- Prompt caching with cache block management
- Batch API integration
- Local validation phase
- Confidence-gated review skip
- Speculative execution
- Diff-based review
- Two-stage execute (skeleton → fill)
- Per-item Opus escalation (escape hatch)
- Structured JSON output on all phases

### Migration Steps

1. **Install API dependencies:** Anthropic SDK, OpenAI SDK
2. **Set environment variables:** `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`
3. **Replace config files:** `agent-map.json`, `model-registry.json`, `global-config.json` with V3 versions
4. **Update prompts:** Copy V3 prompts to project, adapt any project-specific customizations
5. **Update orchestrator:** Replace CLI agent invocation with API client calls
6. **Remove unused API keys:** Gemini, Kimi, DeepSeek, GLM-5, MiniMax
7. **Test:** Run against a small project (50 requirements) to validate

---

## 14. Acceptance Criteria

### Functional Requirements

- [ ] Pipeline completes 200-requirement reference project without manual intervention
- [ ] All 8 phases execute in correct order with correct model routing
- [ ] Prompt caching achieves >85% cache hit rate after warm-up
- [ ] Batch API is used for phases 1, 2, 3, 6, 8
- [ ] Real-time API is used for phases 4, 7
- [ ] Local validation catches >50% of issues before LLM review
- [ ] Confidence-gated skip eliminates >30% of Review calls
- [ ] Structured JSON output parses without errors on >99% of calls
- [ ] Speculative execution overlaps Research/Plan with Review
- [ ] Two-stage execute generates valid skeletons before fill
- [ ] Checkpoint/recovery resumes from any phase
- [ ] All existing quality gates pass

### Cost Requirements

- [ ] Total cost for reference project (200 reqs, 100K LOC) < $10.00
- [ ] Cost per 1,000 LOC < $0.10
- [ ] Cache write overhead < $0.10 per project
- [ ] No Sonnet calls without cache prefix (except Phase 0)

### Speed Requirements

- [ ] Wall clock time for reference project < 3 hours
- [ ] Execute phase parallelism: 15 concurrent Codex Mini calls
- [ ] Batch API response time < 30 minutes per batch
- [ ] No idle time between iterations (speculative execution fills gaps)

### Quality Requirements

- [ ] Health score reaches 100 within 25 iterations for reference project
- [ ] Rework rate < 12% (down from V2's ~15%)
- [ ] All generated code passes local validation (lint + typecheck) after rework
- [ ] No regression in quality gate pass rates vs V2

### Pipeline Mode Requirements

- [ ] `gsd-fix` completes a single bug fix in ≤5 iterations, ≤$1.00
- [ ] `gsd-fix` creates BUG-xxx entries with proper metadata (source, interface, artifacts)
- [ ] `gsd-fix` skips Research and Spec Gate phases
- [ ] `gsd-fix` scope filter restricts plan/execute to bug-report requirements only
- [ ] `gsd-fix` requires regression test generation for every fix
- [ ] `gsd-update` preserves all previously-satisfied requirements (zero regression)
- [ ] `gsd-update` runs incremental Spec Gate (validates only new/changed sections)
- [ ] `gsd-update` tags new requirements with spec_version field
- [ ] `gsd-update` detects and halts on regression of satisfied requirements
- [ ] `gsd-update` correctly scopes to `source:v02_spec` or specific requirement IDs
- [ ] All three modes (greenfield, fix, update) share the same cached prefix
- [ ] Mode switching does not require reconfiguration — mode is selected by command

### Multi-Interface Requirements

- [ ] Interface auto-detection discovers all 5 types (web, mcp, browser, mobile, agent)
- [ ] Interface map written to `.gsd/blueprint/interface-map.json` at pipeline start
- [ ] Spec Gate validates cross-interface consistency (shared API contracts, data types, auth)
- [ ] Requirements tagged with target interface(s)
- [ ] Plan generates files routed to correct output directories per interface
- [ ] Execute injects interface-specific conventions per Codex Mini call
- [ ] Cross-interface files for same requirement execute in parallel
- [ ] Local Validate runs correct toolchain per interface (vite/expo/dotnet/tsc/mypy)
- [ ] Shared code (`src/shared/`) contains no platform-specific imports
- [ ] `gsd-fix -Interface X` scopes to that interface only
- [ ] Cost scales sub-linearly with additional interfaces (shared backend amortized)
- [ ] All 12 Figma Make deliverables supported per interface that has `_analysis/`
- [ ] Agent interface works without Figma (spec-only)

---

## Appendix A: Token Budget Summary

### Per-Iteration Token Usage

| Phase | Model | Input Tokens | Output Tokens | Notes |
|-------|-------|:-:|:-:|------|
| Research | Sonnet | 25,000 (15K cached) | 6,000 | Batch |
| Plan | Sonnet | 23,000 (15K cached) | 4,000 | Batch |
| Execute (skeleton) | Codex Mini | 20,000 | 15,750 | Real-time, parallel |
| Execute (fill) | Codex Mini | 42,500 | 52,500 | Real-time, parallel |
| Local Validate | — | 0 | 0 | Free |
| Review (40% of items) | Sonnet | 27,000 (15K cached) | 3,000 | Batch, diff-based |
| Verify | Sonnet | 45,000 (15K cached) | 2,500 | Real-time |
| **Per-Iteration Total** | | **182,500** | **83,750** | |

### Per-Project Token Usage (23 Iterations)

| Model | Total Input | Total Output | Total Tokens |
|-------|:-:|:-:|:-:|
| Sonnet 4.6 | ~2.2M (1.6M cached reads) | ~350K | ~2.55M |
| Codex Mini | ~1.4M | ~1.6M | ~3.0M |
| **Combined** | **~3.6M** | **~1.95M** | **~5.55M** |

---

## Appendix B: Escape Hatch Decision Matrix

| Condition | Action | Cost Impact |
|-----------|--------|:-:|
| Item fails Verify 3+ times | Escalate Plan + Review to Opus 4.6 | +$0.25/item |
| Codex Mini output incomplete (>10K expected, <3K generated) | Route to Codex 5.3 for that item | +$0.40/item |
| Stall detected (3+ iterations, health_delta ≤ 0) | Run comprehensive Opus analysis | +$0.50 one-time |
| Budget >80% consumed, health <60% | Alert human, suggest spec revision | $0.00 |
| Spec clarity_score drops below 70 after spec-fix | Halt pipeline, require human spec revision | $0.00 |

---

*End of specification.*
