# States + accessibility — non-negotiable

## Five states for every data-driven screen

Design ALL five before a screen is complete — empty/error get the same care as the happy path:

1. **Loading** — `Skeleton`/`SkeletonItem` shaped like the final layout (not a centered spinner).
2. **Empty** — centered large icon or illustration + headline (`subtitle1`) + supporting text
   (`body1`, `colorNeutralForeground2`) + primary CTA. Never an empty table with just headers.
3. **Error** — `MessageBar intent="error"` with a human message + Retry button. Never swallowed.
4. **Populated** — the happy path.
5. **Optimistic** — during mutations: disabled UI + local cache update, rollback on error.

## Accessibility (WAI-ARIA)

- Every icon-only button has `aria-label`; every input has a visible `Field` label.
- Never remove focus indicators (`outline: none` is forbidden).
- `Dialog`/`Drawer` use `aria-labelledby` pointing at the title element.
- Error toasts/alerts: `role="alert"`; informational: `role="status"`.
- Color contrast ≥ 4.5:1 for text, ≥ 3:1 for UI elements; state is never communicated by color
  alone (pair icon + text).
- Logical tab order; no `tabIndex > 0`. Keyboard path for every mouse path.
