# Tokens — the only way to style

Hex codes, named colors, and raw pixel values are forbidden. Everything routes through
`tokens.*` from `@fluentui/react-components`.

- **Surfaces:** `colorNeutralBackground1` (cards/header) → `2` (page background) → `3/4` (insets).
  Alternate 1/2 for section rhythm instead of borders.
- **Text:** `colorNeutralForeground1` primary → `2` secondary → `3` tertiary → `4` disabled.
- **Borders:** `colorNeutralStroke1/2` with `strokeWidthThin`. Borders are a last resort — prefer
  surface layering and spacing.
- **Brand:** `colorBrandBackground` for the one primary CTA per view; `colorBrandForeground1` for
  active/selected accents.
- **Status:** `colorStatusDanger*/Warning*/Success*` semantic families — never raw red/green.
- **Spacing:** 4px grid only — `spacingVerticalL` between sections, `M` within sections, `S/XS` for
  tight groupings. Horizontal variants mirror vertical.
- **Type:** spread compound styles — `...typographyStyles.title2` for page titles, `subtitle1` for
  card/section headers, `body1` for content, `caption1` for metadata/timestamps.
- **Radius:** `borderRadiusMedium` default (cards, inputs), `Large` pills, `Circular` avatars.
- **Shadows:** `shadow2/4` resting cards, `shadow16` flyouts, `shadow64` modals — always paired with
  the right surface color.
- **Motion:** entering = `durationNormal` + `curveDecelerateMid`; exiting = `durationFaster` +
  `curveAccelerateMid`; in-place = `curveEasyEase`.
