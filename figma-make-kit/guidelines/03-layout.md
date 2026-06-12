# Layout — page shell, density, rhythm

- **Page shell:** sticky Header (`colorNeutralBackground1`, `shadow4`) → side or top Nav → scrolling
  Main (`colorNeutralBackground2`) → optional Aside. Fluent has no grid component — build layout
  with flex/grid in `makeStyles` (`rowGap`/`columnGap` work natively).
- **Density:** comfortable by default — `spacingVerticalL` between sections, `M` within. Compact
  spacing only in data-dense views (DataGrid rows, toolbars).
- **Cards:** wrap logical units in `Card` with `CardHeader` (title + description + action) — never
  hand-rolled divs with borders.
- **Section rhythm:** alternate `colorNeutralBackground1`/`2` to create sections without borders.
- **Width:** max 1280px for dashboards, 720px for reading pages; center with `marginInline: 'auto'`.
- **Responsive:** mobile-first; breakpoints 480 / 640 / 1024 / 1366 / 1920. Media queries as
  `'@media (min-width: 640px)'` keys inside `makeStyles`.
- **Hierarchy test:** squint at the screen — exactly one primary action should pop, headings should
  step down cleanly (title2 → subtitle1 → body1 → caption1), and nothing should compete with the CTA.
