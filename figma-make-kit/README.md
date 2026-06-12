# Figma Make Kit — Technijian Fluent v9 design language

Artifacts to give **Figma Make** so its generated prototypes follow the Technijian stack
(Fluent UI React v9 look + structure) instead of generic React+Tailwind. Derived from
`.claude/skills/fluent-v9-mastery/SKILL.md` — that skill is the source of truth; regenerate this kit
when it changes. See `docs/GSD-UI-Prototyping-Automation.md` for the full Phase C flow.

## How to use (per project)

1. **Make kit (preferred, official):** in Figma, create a Make kit pointing at the npm package
   `@fluentui/react-components`, and attach:
   - [`setup.md`](setup.md) → the kit's setup instructions
   - [`guidelines/`](guidelines/) → the kit's guidelines folder (Figma recommends multiple short files)
2. **Per-prompt attachments (fallback):** if no Make kit, paste `design.md` + the relevant
   `guidelines/*.md` into the Make chat alongside the GSD-generated prompt, and attach the Stitch
   layout templates (PNG/screens) produced in Phase C step 0.
3. Generate → **Publish** → paste the `*.figma.site` URL back to the pipeline for automated
   Playwright validation.

## Contents

| File | Purpose |
|---|---|
| `setup.md` | Make-kit setup: install Fluent v9, FluentProvider wrap, Griffel, no Tailwind |
| `design.md` | design.md-spec sheet: YAML design tokens + design philosophy prose |
| `guidelines/01-tokens.md` | Token rules (color/spacing/type/radius/shadow/motion) |
| `guidelines/02-components.md` | Which Fluent component for which job |
| `guidelines/03-layout.md` | Page shell, density, rhythm, breakpoints |
| `guidelines/04-states-accessibility.md` | Five-states rule + WAI-ARIA requirements |
| `guidelines/05-forbidden.md` | Anti-patterns that mark output as AI-generated |

## Expectation management

Make steers by prose — output can still drift toward Tailwind defaults. Every Make deliverable still
passes through `/fluent-v9-design-review` (Phase C Stage 2 audit). For production code, the Dev Mode
MCP + Code Connect path emits true Fluent imports; this kit is for the prototype lane.
