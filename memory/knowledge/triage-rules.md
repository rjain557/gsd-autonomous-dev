---
type: knowledge
description: Classification, reproduction, and localization rules for the maintenance-flow triage stage (Phase U1)
last_updated: 2026-06-12
---

# Triage Rules (Phase U — maintenance flow)

Evidence base: Agentless (hierarchical localization beats line-jumping), LocAgent (graph-guided
localization +10.5% accuracy), Ambig-SWE (clarifying questions improve resolution), Cortex
deep-research on multi-agent triage. See `docs/GSD-Maintenance-Flow.md`.

## Classification

| Category | Definition | Needs repro? |
|---|---|---|
| bug | Existing behavior contradicts the frozen spec or obvious intent | **Yes — hard gate** |
| feature | New behavior not in the frozen spec | No — needs clear scope |
| change-request | Existing specified behavior should change | No — needs delta description |
| question | No code change implied | Triage answers and closes |

Severity: `critical` = data loss, security, tenant isolation, compliance (HIPAA/PCI), payment;
`high` = core flow broken, no workaround; `medium` = degraded with workaround; `low` = cosmetic.

## Reproduction discipline (bugs)

1. Reproduction is attempted BEFORE localization. No repro → no auto-fix path.
2. `confirmed` requires the code context to actually support the failure mode — not just plausibility.
3. The repro artifact (failing test sketch / Playwright steps / SQL state) becomes acceptance
   criterion #1 of the change spec and the red→green gate in QualityGate.
4. `needs-info` → emit 2-4 specific clarifying questions (expected vs actual, tenant/user/role,
   environment, steps). The orchestrator surfaces them and halts — never proceed on guesses.

## Localization discipline

1. **Hierarchical**: files → symbols (component/controller/SP) → lines. Never jump to lines.
2. **Graph first**: interactively, use GitNexus (`gitnexus_query` → `gitnexus_context` →
   `gitnexus_impact` upstream on suspects). In the harness, candidates come from deterministic
   keyword/path ranking (Agentless pattern) — grep beats embeddings for named-symbol reports.
3. Full-stack suspects for this stack: React component (web/), API controller + DTO (Controllers/),
   stored procedure (db/ — `usp_{Entity}_{Action}`), and the API↔SP mapping.
4. Every suspect needs a rationale **citing the code excerpt** (attribution > confidence — a
   specific-but-ungrounded diagnosis is a hallucination; do not reward it).
5. Confidence calibration: >0.8 = excerpt shows the defect; 0.4-0.8 = strong circumstantial;
   <0.4 = do not include. All suspects <0.4 → isValid=false, recommend interactive session.

## Risk

`high` automatically when any suspect touches: auth/JWT, TenantId filtering, payment, PHI/PII
columns, deploy/rollback scripts (see [security-critical-paths.md](security-critical-paths.md)).
High risk routes to SecurityAgent review + human approval before implementation.
