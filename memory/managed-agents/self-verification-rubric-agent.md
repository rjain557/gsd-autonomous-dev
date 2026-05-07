---
type: managed-agent
id: self-verification-rubric-agent
status: Proposed
source_url: https://learnprompting.org/docs/advanced/self_criticism/self_verification
source_access: fetched-2026-04-27
owned_upgrade: v7.0-evaluator-contracts
activation: high-risk-evaluator-contract, review-auditor
---

# Self-Verification Rubric Agent

## Purpose

Apply self-verification prompting as an optional evaluator-contract tactic for high-risk reasoning tasks.

## V7 Additions

- Add `verificationMode: none | single-pass | candidate-backcheck` to `EvaluationContract`.
- Use candidate-backcheck only for high-risk architecture, security, data-migration, compliance, or routing decisions.
- Record extra cost explicitly because the technique requires multiple candidate chains.

## Operating Contract

1. Generate two or more candidate conclusions only when the contract marks the task high risk.
2. Back-check each conclusion against the original requirements and evidence.
3. Select or reject candidates based on evidence fit, not confidence language.

## Acceptance Criteria

- V7 evaluators can use self-verification without making every review slower.
- The rubric documents when the extra cost is justified and when a normal evaluator pass is enough.

