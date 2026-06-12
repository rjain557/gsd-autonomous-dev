---
# design.md — Technijian design language (machine-readable tokens + philosophy)
system: Fluent 2 (Microsoft Fluent UI React v9)
library: "@fluentui/react-components"
theme: webLightTheme (dark: webDarkTheme via FluentProvider prop)
color:
  surfaces: [colorNeutralBackground1, colorNeutralBackground2, colorNeutralBackground3]
  text: [colorNeutralForeground1, colorNeutralForeground2, colorNeutralForeground3]
  borders: [colorNeutralStroke1, colorNeutralStroke2]
  brand: [colorBrandBackground, colorBrandForeground1]
  status: [colorStatusSuccess*, colorStatusWarning*, colorStatusDanger*]
  rule: semantic tokens first; palette tokens only when semantics don't fit; NEVER hex/named colors
spacing:
  grid: 4px
  tokens: [spacingVerticalXXS, XS, S, M, L, XL, XXL, XXXL]  # + Horizontal variants
  rule: no raw px values; sections use L, within-section uses M
typography:
  tokens: [caption2, caption1, body1, body1Strong, body2, subtitle2, subtitle1, title3, title2, title1, largeTitle, display]
  rule: spread typographyStyles.*; never set fontSize/fontWeight manually
radius: { card: borderRadiusMedium, pill: borderRadiusLarge, avatar: borderRadiusCircular }
elevation: { restingCard: shadow4, dropdown: shadow16, dialog: shadow64 }
motion:
  durations: [durationFaster, durationNormal, durationSlow]
  curves: { enter: curveDecelerateMid, exit: curveAccelerateMid, inPlace: curveEasyEase }
  rule: never animate for decoration; movement communicates cause/effect
layout:
  maxWidth: { dashboard: 1280px, reading: 720px }
  breakpoints: [480, 640, 1024, 1366, 1920]
states_required: [loading-skeleton, empty, error-with-retry, populated, optimistic]
accessibility: { contrast: "4.5:1 text / 3:1 UI", focus: never-remove, iconButtons: aria-label required }
---

# Design philosophy — make it feel built by a senior Microsoft product team

This is **Fluent 2** — not Material, not Ant, not a generic admin panel. Five principles govern
every decision:

1. **Light.** Weightless interfaces: generous whitespace, restrained color, subtle elevation.
   Heavy borders and dense default layouts are violations.
2. **Depth.** Hierarchy comes from layered surfaces (`Background1 → 2 → 3`), not borders.
   Shadows communicate stacking order honestly (card `shadow4`, dialog `shadow64`).
3. **Motion.** Movement has meaning: drawers slide, dialogs fade+scale, toasts enter from an edge —
   always a duration token paired with the right curve. Nothing animates for decoration.
4. **Material.** Surfaces have honest properties; use alpha background tokens for translucency.
   No hand-rolled glassmorphism.
5. **Scale.** Think in tokens and components, never pixels and divs. The same system must serve a
   phone and a 4K monitor.

The fastest way to look AI-generated: equal-weight everything. Instead: one primary action per view,
clear typographic hierarchy (title → subtitle → body → caption), section rhythm via alternating
surface tokens, real empty/loading/error states designed with the same care as the happy path.
