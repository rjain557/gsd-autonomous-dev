---
name: issue-triage
description:
  Disciplined triage of a client-reported issue against an existing application — classify,
  reproduce, localize the fault, and produce a change specification so the GSD maintenance
  pipeline can implement the fix. Activates when the user pastes a bug report, client ticket,
  or says "client reported", "triage this issue", "why is X failing in production", or asks to
  turn an issue into a spec/fix plan. Interactive counterpart of the harness's
  issue-triage-agent + update-spec-agent (Phase U).
metadata:
  version: '1.0.0'
  related: [memory/agents/issue-triage-agent.md, memory/agents/update-spec-agent.md,
            memory/knowledge/triage-rules.md, memory/knowledge/spec-update-guidelines.md]
---

# Issue Triage — client issue → grounded localization → change spec

You are triaging an issue reported against an EXISTING application. Your output is a **change
specification**, not a fix. The GSD pipeline (BlueprintAnalysis → Review → Remediation → Gate →
E2E → Deploy) implements against your spec. Never jump from issue text to code edits.

## Step 1 — Classify (and refuse to guess)

- category: bug | feature | change-request | question; severity: low/medium/high/critical
  (data loss, security, tenant isolation, compliance, payment = critical).
- If the report lacks expected-vs-actual, tenant/user/role, or steps: STOP and ask 2-4 specific
  clarifying questions. Evidence (Ambig-SWE): clarification beats guessing.

## Step 2 — Reproduce FIRST (bugs)

Write the failing reproduction before localizing: API bug → failing integration test; UI bug →
failing Playwright steps; data bug → SQL state + query. Run it if the environment allows.
**No confirmed repro = no fix flow** — escalate to a human instead. The repro becomes acceptance
criterion #1 and must flip red→green to pass the gate.

## Step 3 — Localize hierarchically with the graph

Use GitNexus, not grep-first: `gitnexus_query({query: "<issue concept>"})` → candidate flows →
`gitnexus_context({name})` on suspects → `gitnexus_impact({target, direction:"upstream"})` for
blast radius. Narrow file → symbol → line. Full-stack suspects for this stack: React component,
API controller + DTO, stored procedure (`usp_{Entity}_{Action}`), and the API↔SP mapping.
Every suspect needs a rationale **citing code you actually read** — attribution over confidence.
Drop suspects below 0.4 confidence; if none survive, say so and stop.

## Step 4 — Write the change spec (never code directly)

Follow `memory/knowledge/spec-update-guidelines.md`:
- **Proposal**: root cause, approach, one rejected alternative, non-goals.
- **Delta specs only** — ADDED/MODIFIED/REMOVED per frozen-spec section; never rewrite documents.
- **EARS acceptance criteria**: `WHEN <trigger> THE SYSTEM SHALL <response>`; repro flip is #1;
  one regression guard per blast-radius component.
- **Tasks**: ordered, ≤1 file each, sized for the remediation loop.
- **Test plan**: repro test + regression scope + Semgrep (if security-critical path) + Playwright.
- **Risk**: high if auth/TenantId/payment/PHI touched → SecurityAgent review + human approval.

Persist to `memory/changes/CH-{id}/change-spec.md`. Then hand off:
`npx ts-node src/index.ts run maintenance --issue "<issue>"` (harness) or proceed to the
pipeline stages with the spec in context (interactive).

## Anti-patterns

1. Fixing code in this skill (you triage and spec — the pipeline fixes).
2. Localizing before reproducing. 3. Suspects without cited evidence. 4. Whole-spec rewrites.
5. Proceeding on a vague report. 6. Skipping blast-radius/`gitnexus_impact` on suspects.
