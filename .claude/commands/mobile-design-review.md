---
description: Rigorous React Native + Expo mobile design review — runs the react-native-design-review skill against a named scope, checking iOS and Android parity
---

Run a full React Native + Expo mobile design review using the `react-native-design-review` skill as the source of truth.

## Scope resolution

The user's argument determines what gets reviewed:

1. **If the user named a feature, path, or file** (e.g. `/mobile-design-review src/features/orders`), review exactly that scope.
2. **If the user passed no argument**, review the most recently modified mobile files — use `git diff --name-only HEAD~1 HEAD` and filter for `.tsx` / `.ts` files under `src/` that touch mobile UI code.
3. **If reviewing a whole feature**, include every file under `src/features/<feature>/`.

Report the scope back in one line before starting:

> "Reviewing: `src/features/orders/` — 14 files, ~1,120 lines. Target platforms: iOS + Android."

## Execution

Invoke the `react-native-design-review` skill. It will:

1. Read every file end to end (imports, prop shapes, style definitions, state, a11y, platform handling).
2. Run all 17 review categories (platform handling, stack compliance, tokens, typography, safe areas, navigation, primitives, lists, forms, five states, data/offline/sync, motion/haptics, a11y, images, code quality, platform polish, copy).
3. Produce the Review Report in the exact format the skill specifies, including severity-classified findings, the **Platform Parity Check** table (iOS vs Android per concern), strengths, recommended fix order, and the 10-dimension metrics scorecard (Overall mobile design quality score: X/100).

## After the review

If the user says "apply fixes" / "fix them" / "yes":

- Apply all 🔴 Blockers and 🟠 Criticals automatically.
- Re-run `npm run typecheck` and `npm run lint` after fixes.
- Report what was changed and what remains.
- Recommend a re-review if more than 10 fixes were applied.
- Offer to also run on the other platform's simulator if platform-specific fixes were made.

If the user asks about a specific finding, cite the mastery-guide part number (e.g. "Violates Part 8: FlashList requires `estimatedItemSize` for virtualization to work").

## Companion skill

This command pairs with the `react-native-mastery` skill (the source of truth that the review enforces). Keep both installed. If only one must remain, keep mastery; if both are present, their value compounds.

## Symmetry with web

This is the mobile counterpart to `/design-review` (which runs `fluent-v9-design-review`). Because the mobile app and web frontend hit the same Swagger backend and share feature-folder structure, running both reviews on a cross-platform feature catches inconsistencies before they ship.
