---
description: Rigorous Fluent UI React v9 design review — runs the fluent-v9-design-review skill against a named scope
---

Run a full Fluent UI React v9 design review using the `fluent-v9-design-review` skill as the source of truth.

## Scope resolution

The user's argument determines what gets reviewed:

1. **If the user named a feature, path, or file** (e.g. `/design-review src/features/orders`), review exactly that scope.
2. **If the user passed no argument**, review the most recently modified frontend files — use `git diff --name-only HEAD~1 HEAD` and filter for `.tsx` / `.ts` files under `src/` that touch UI code.
3. **If reviewing a whole feature**, include every file under `src/features/<feature>/`.

Report the scope back in one line before starting:

> "Reviewing: `src/features/orders/` — 12 files, ~840 lines."

## Execution

Invoke the `fluent-v9-design-review` skill. It will:

1. Read every file end to end (imports, prop shapes, style definitions, state, a11y).
2. Run all 15 review categories (framework imports, theming, tokens, Griffel, typography, layout, primitives, four states, forms, server state, a11y, motion, responsive, code quality, polish & copy).
3. Produce the Review Report in the exact format the skill specifies, including severity-classified findings, strengths, recommended fix order, and the 8-dimension metrics scorecard (Overall design quality score: X/80).

## After the review

If the user says "apply fixes" / "fix them" / "yes":

- Apply all 🔴 Blockers and 🟠 Criticals automatically.
- Re-run `npm run typecheck` and `npm run lint` after fixes.
- Report what was changed and what remains.
- Recommend a re-review if more than 10 fixes were applied.

If the user asks about a specific finding, cite the mastery-guide part number (e.g. "Violates Part 3: Griffel requires `shorthands.padding()` for shorthand properties").

## Companion skill

This command pairs with the `fluent-v9-mastery` skill (the source of truth that the review enforces). Keep both installed. If only one must remain, keep mastery; if both are present, their value compounds.
