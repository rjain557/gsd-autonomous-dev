# GSD Maintenance Flow (Phase U) — Updating Existing Applications

> **v6.3, built 2026-06-12.** Completes the Technijian SDLC for the brownfield case: a client
> reports an issue against a deployed application → the system triages it, localizes the fault,
> freezes a change specification, and the **unchanged** pipeline (F1–G) implements, gates, and
> deploys the update. This document is the canonical reference for the Developer Guide.

## 1. Why Phase U exists

Phases A–G drive a project from description to alpha (greenfield). What was missing: the loop for
**existing** applications — bug reports, change requests, incremental features. Research consensus
(Agentless, LocAgent, SWE-bench dissections, OpenSpec/Kiro SDD wave, Cortex deep-research):

- **Spec before code** — implementing against a frozen change spec beats implementing against raw
  issue text (prevents drift, makes the fix reviewable and reproducible).
- **Reproduce first** — a confirmed failing reproduction is the single best signal; pipelines gate
  on red→green, not on plausibility.
- **Hierarchical, graph-guided localization** — file → symbol → line using the code graph
  (+10.5% localization accuracy vs ungrounded search; GitNexus is our graph).
- **Risk-routed approval** — low-risk changes flow autonomously; high-risk (auth/tenant/PHI/payment
  or contract-breaking) pause for SecurityAgent + human signoff.

## 2. The flow

```
Client issue ──► U1 triage ──► U2 update-spec ──► F1 blueprint ──► F2 review ──► F3 remediate
                  │                  │              (existing pipeline, unchanged)   ⮡ loop
                  │ not actionable   │ requiresHumanApproval                F4 gate → audit →
                  ▼                  ▼                                      F5 e2e → F6 deploy →
                PAUSED (questions    PAUSED (review change spec,            G post-deploy
                surfaced to human)   resume --from-stage blueprint)
```

Run it: `npx ts-node src/index.ts run maintenance --issue "<client issue text>" [--project-root <app repo>]`
Greenfield runs are unaffected: stages `triage`/`update-spec` auto-skip when no issue context exists.

## 3. New components

### Agents (vault contract first, per Memory Rule 5)

| Agent | Stage | Vault note | Code | Job |
|---|---|---|---|---|
| **IssueTriageAgent** | `triage` (U1) | `memory/agents/issue-triage-agent.md` | `src/agents/issue-triage-agent.ts` | Classify (bug/feature/change-request/question + severity) → reproduce (bugs: failing test sketch; no repro = not actionable) → localize hierarchically (harness pre-ranks candidate files by keyword/path — the Agentless pattern — LLM narrows to suspects with **cited rationales**, confidence floor 0.4) → blast radius + risk |
| **UpdateSpecAgent** | `update-spec` (U2) | `memory/agents/update-spec-agent.md` | `src/agents/update-spec-agent.ts` | TriageResult → frozen **change spec**: proposal (root cause/approach/alternative/non-goals), **delta specs only**, **EARS acceptance criteria** (repro flip = #1), ordered tasks for RemediationAgent, test plan. Persists to vault `changes/CH-{runId}/change-spec.md` |

**Hard gates** (runtime assertions, mirroring Rule 8):
- UpdateSpecAgent **throws** if a bug's `reproStatus !== 'confirmed'` — no repro, no spec, no auto-fix.
- Bug specs without EARS criteria throw.
- `riskLevel high` ⇒ `requiresHumanApproval = true` (enforced in code, not just prompted).

### Knowledge notes (configs live in vault, per Rule 4)

- `memory/knowledge/triage-rules.md` — classification table, reproduction discipline, localization
  discipline (hierarchical, graph-first, attribution-over-confidence, 0.4 floor), risk triggers.
- `memory/knowledge/spec-update-guidelines.md` — delta-only principle, EARS format, small-task
  sizing, scope ceiling (≥3 specs rewritten ⇒ recommend re-running the `contracts` milestone),
  change-spec layout, risk routing table.

### Skill

- `.claude/skills/issue-triage/SKILL.md` — interactive counterpart for Claude Code sessions:
  same discipline but uses **GitNexus** (`gitnexus_query`/`gitnexus_context`/`gitnexus_impact`)
  for localization instead of the harness's keyword ranking.

## 4. Pipeline/state changes (for the Developer Guide)

| Surface | Change |
|---|---|
| `PipelineStage` | + `'triage'`, `'update-spec'` (lead the stage order; skipped on greenfield) |
| `AgentId` | + `'issue-triage-agent'`, `'update-spec-agent'` |
| `PipelineState` | + `triageContext`, `triageResult`, `specUpdateResult` (null on greenfield) |
| `PipelineTrigger` / `MilestoneRunInput` | + `issueDescription?` — its presence flips the run into Phase U |
| Orchestrator | new stage cases; run-loop honors stage-set `status='paused'` (needs-info / approval); `PHASE_ROUTING` rows for both stages; decisions logged for every routing choice (Rule 7) |
| CLI | new milestone `maintenance` (`pipelineFrom: 'triage'`); `--issue` required (≥10 chars); resume after approval: `pipeline run --from-stage blueprint` |
| Types of record | `TriageResult` (incl. `reproStatus`, `clarifyingQuestions`, `suspects[]` with confidence+rationale), `SpecUpdateResult` (incl. `deltaSpecs[]`, `earsCriteria[]`, `requiresHumanApproval`), `SuspectLocation`, `DeltaSpec` — all in `src/harness/types.ts` |

## 5. Updated stage map (supersedes the 7-step table for maintenance runs)

| Step | Stage | Agent | On success | On halt |
|---|---|---|---|---|
| U1 | triage | IssueTriageAgent | U2 | not actionable → PAUSED + clarifying questions |
| U2 | update-spec | UpdateSpecAgent | F1 (spec persisted to `changes/`) | human approval needed → PAUSED |
| F1–G | blueprint → … → post-deploy | (existing agents, unchanged) | per existing stage map | per existing stage map |

QualityGate addition (spec'd in the test plan, enforced at F4): the **repro test must have failed
before the patch and pass after** (red→green), alongside the existing build/security/coverage gates.

## 6. Verification of this build

- `npx tsc --noEmit` clean; **31/31 v6 tests pass** (one stale assertion updated for the .NET 10
  default; `better-sqlite3` upgraded 11.10 → **12.10** for Node-24 prebuilt bindings — this also
  fixed the previously-failing StateDB/StuckDetector tests on this workstation).
- Greenfield safety: `triage` stage logs `skip` and continues when no `issueDescription` is present.

## 7. Future enhancements (not built)

- GitNexus-powered localization inside the harness agent (today: deterministic keyword ranking in
  the harness, GitNexus in interactive sessions; LocAgent evidence says graph > keyword).
- GitHub intake: `claude-code-action` issue-opened trigger (pin ≥ v1.0.94; never `allowed_non_write_users:"*"` — June 2026 CVE) feeding `gsd run maintenance`.
- F4 automation of the red→green repro check as a first-class QualityGate step.
