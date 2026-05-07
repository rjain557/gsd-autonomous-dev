---
type: managed-agent
id: goose-patterns-import-agent
status: Proposed
source_url: https://goose-docs.ai/
source_access: fetched-2026-04-27
owned_upgrade: v7.0-skillforge-and-dag
activation: feature-check, skillforge-design-review
---

# Goose Patterns Import Agent

## Purpose

Track Goose patterns that can improve GSD without replacing the TypeScript harness: recipes, subrecipes, MCP extension catalogs, ACP interoperability, subagents, and adversary review.

## V7 Additions

- Add a V8 candidate for `GsdRecipe`: portable YAML workflow definitions inspired by Goose recipes/subrecipes.
- Add an ACP watch item for connecting GSD-managed agents to editors or external coding agents when the protocol stabilizes.
- Add an adversary-reviewer pattern to the ReviewAuditor backlog for unsafe tool/action detection.
- Compare Goose MCP extension catalog growth against GSD's Context7/GitNexus/Graphify/MCP stack during monthly feature checks.

## Operating Contract

1. Monitor Goose docs for stable recipe, ACP, and security APIs.
2. Propose interop only when it preserves GSD's existing vault, SQLite, worktree, and multi-model routing model.
3. Do not introduce Goose as a replacement orchestrator in V7.

## Acceptance Criteria

- V7 keeps the current harness while capturing portable workflow and security ideas for V8.
- Any Goose-inspired import is represented as an additive bridge or recipe format.

