---
type: managed-agent
id: openmythos-depth-routing-agent
status: Proposed
source_url: https://www.marktechpost.com/2026/04/23/a-coding-tutorial-on-openmythos-on-recurrent-depth-transformers-with-depth-extrapolation-adaptive-computation-and-mixture-of-experts-routing/
source_access: fetched-2026-04-27
replaces_share_url: https://share.google/iYLeGoUJbJtQR7dzZ
owned_upgrade: v8-model-routing-research-candidate
activation: monthly-feature-check, model-architecture-watch
---

# OpenMythos Depth Routing Agent

## Purpose

Track recurrent-depth transformer ideas, adaptive computation, depth extrapolation, and MoE routing as a model-architecture watch item for future GSD routing.

## V7 Additions

- No V7 runtime change.
- Add a V8 research candidate: expose `reasoning_depth_budget` in model routing when providers make recurrent-depth/adaptive-computation controls available.
- Add a model-evaluation note: models that can spend extra inference loops without retraining may be useful for high-risk evaluator contracts and hard remediation loops.

## Operating Contract

1. Watch for production models exposing depth/loop/adaptive-computation controls through official APIs.
2. Treat OpenMythos as conceptual signal, not a dependency.
3. If a provider exposes depth control, benchmark it against GSD evaluator-contract tasks before enabling.

## Acceptance Criteria

- GSD captures the depth-extrapolation idea without adding experimental ML code to V7.
- Any future depth budget is tied to task risk and budget pressure.

