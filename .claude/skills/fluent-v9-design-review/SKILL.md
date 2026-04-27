---
name: fluent-v9-design-review
description:
  Rigorous Fluent UI React v9 design-and-implementation review. Activates when
  the user asks to review, audit, critique, or check frontend code; when a
  feature is declared done; when the user says "review this", "check the code",
  "design review", or "audit"; or automatically at the end of any Phase D feature
  implementation. Assumes the fluent-v9-mastery skill is the source of truth — any
  code that violates it is a finding. Catches every violation before it ships.
metadata:
  companion-skill: fluent-v9-mastery
  slash-command: /design-review
  severity-levels: [blocker, critical, major, minor, nit]
  version: '1.0.0'
  applies-to: frontend-code-review, pre-merge-gate, phase-d-completion
---

# Fluent UI React v9 Design Review

You are performing a rigorous design and implementation review of Fluent UI
React v9 frontend code. Your job is not to be polite — it's to catch every
violation before it ships. A senior design engineer at Microsoft would catch
all of these. So will you.

This review assumes the **fluent-v9-mastery** skill/guide is the source of
truth. If any code violates it, that's a finding.

## How to Run This Review

**Step 1 — Scope.** Determine what to review:

- If the user named a feature, path, or file, review exactly that scope.
- If the user just said "review," review the most recently modified frontend
  files (use `git diff` or recent file edits).
- If reviewing a whole feature, include every file under `src/features/<feature>/`.

Report the scope back before starting:
> "Reviewing: `src/features/orders/` — 12 files, ~840 lines."

**Step 2 — Read everything in scope.** Do not skim. Read every file end to end.
Note imports, prop shapes, style definitions, state handling, and accessibility
attributes.

**Step 3 — Run all 15 review categories below.** For each, produce findings
with severity, location, evidence, and fix.

**Step 4 — Produce the Review Report** in the exact format specified at the end.

**Step 5 — If the user approves, apply fixes.** Group by severity: apply all
Blockers and Criticals automatically, propose Majors for approval, list
Minors for later.

## Severity Levels

- 🔴 **Blocker** — Ships broken, inaccessible, or violates a hard rule (v8
  imports, hex colors, no error state). Must fix before merge.
- 🟠 **Critical** — Noticeably unprofessional or degrades UX (missing loading
  state, hand-rolled table instead of `DataGrid`, form without `Field`
  wrapper). Must fix before merge.
- 🟡 **Major** — Visibly off-brand or wrong pattern (wrong typography token,
  missing hover state, raw pixel spacing). Fix this sprint.
- 🔵 **Minor** — Polish issue (copy could be tighter, icon could be Filled
  when selected, skeleton could better match layout). Fix when touching
  the file.
- ⚪ **Nit** — Subjective preference. Note but don't require.

## Review Categories

### 1. Framework Version & Imports

Check every import statement.

**Blockers:**

- Any import from `@fluentui/react` (v8)
- Any import from `@fluentui/react-northstar` (Teams v0)
- Mixing v8 and v9 packages

**Critical:**

- Importing from deep paths (`@fluentui/react-components/dist/...`) instead
  of the package root
- Importing icons from anywhere other than `@fluentui/react-icons`
- Missing `@fluentui/react-datepicker-compat` when dates are used
  (hand-rolled date input)

Verify: `grep -r "from '@fluentui/react'" src/` returns nothing.
`grep -r "from '@fluentui/react-components'" src/` returns matches.

### 2. Theming & Provider

**Blockers:**

- No `FluentProvider` at the app root
- Multiple conflicting `FluentProvider`s without intentional nesting
- Hard-coded theme reference instead of a theme switcher for dark mode

**Critical:**

- Custom brand colors defined outside `createLightTheme` / `createDarkTheme`
- CSS variables set manually on `:root` to override theme tokens

**Major:**

- No dark theme support (`webDarkTheme` never referenced)
- No high contrast support

### 3. Token Usage (The Biggest Category)

This is where most reviews find the most violations. Inspect every
`makeStyles` block and every `style={{}}` prop.

**Blockers:**

- Any hex color (`#0078d4`, `#fff`, `#000`)
- Any named color (`color: 'red'`, `background: 'white'`)
- Any `rgb()` / `rgba()` / `hsl()` (except for transparent overlays where
  a token doesn't exist, with a comment)
- Raw px spacing (`padding: '16px'`, `margin: '8px 0'`)
- Raw px font sizes (`fontSize: '14px'`)
- Hand-written font-family strings (`fontFamily: 'Segoe UI, ...'`) — should
  use `typographyStyles`

**Critical:**

- Raw border widths (`borderWidth: '1px'`) instead of `strokeWidthThin`
- Raw border radii (`borderRadius: '4px'`) instead of `borderRadiusMedium`
- Raw durations (`transition: '200ms ease'`) instead of `durationNormal`
  + curve tokens
- Shadow values written out (`boxShadow: '0 2px 4px ...'`) instead of
  `shadow4` etc.

**Major:**

- Wrong semantic token (using `colorBrandBackground` for a destructive
  action instead of `colorStatusDangerBackground3`)
- Using palette tokens (`colorPaletteRedBackground1`) when a semantic
  token exists (`colorStatusDangerBackground1`)

For every violation, show the offending line and the correct replacement:

```text
❌ src/features/orders/OrderCard.tsx:42
   padding: '16px 24px',
✅ Fix:
   ...shorthands.padding(tokens.spacingVerticalL, tokens.spacingHorizontalXL),
```

### 4. Griffel & makeStyles Correctness

**Blockers:**

- Any `styled-components`, `@emotion/styled`, or `@emotion/react` imports
- CSS modules or `.css` / `.scss` files for component styling (global
  resets and font imports are fine — flag, don't block)
- Inline `style={{}}` for static values

**Critical:**

- Shorthand properties written as shorthand (`padding: '8px 16px'`,
  `border: '1px solid ...'`) instead of `shorthands.padding(...)`,
  `shorthands.border(...)`
- `makeStyles` defined in a separate file instead of co-located at the
  bottom of the component file
- Template-string concatenation of class names instead of `mergeClasses()`

**Major:**

- `makeStyles` defined inside the component function body (should be
  module-level)
- Conditional classes applied with ternary string concat instead of
  `mergeClasses(styles.base, condition && styles.active)`

### 5. Typography

**Blockers:**

- Raw `fontSize` / `fontWeight` / `lineHeight` set manually

**Critical:**

- Not using `typographyStyles` spread (`...typographyStyles.body1`)
- Heading hierarchy inverted (`h1` smaller than `h2`, or `largeTitle`
  inside a card section)

**Major:**

- Using `body1` where `subtitle2` is warranted (section headers)
- Using `caption1` for primary content
- Multiple competing type scales on the same screen

### 6. Layout & Spacing Rhythm

**Critical:**

- No consistent spacing rhythm — values jump between XS, XXL, M randomly
  on the same screen
- Dense content without breathing room (cards with `spacingVerticalXS`
  padding)
- Max-width not set on reading or dashboard content (stretches to 2560px)

**Major:**

- Not using `Card` / `CardHeader` / `CardPreview` where a card pattern
  is clearly used
- Hand-built page shells instead of composing with Fluent primitives
  where possible
- Missing section backgrounds to create visual hierarchy (everything on
  one flat surface)

**Minor:**

- Odd gap sizes between unrelated elements
- Header not sticky on long-scroll pages

### 7. Component Primitive Selection

This is where "works" vs "feels designed" diverges most. For each UI
element, verify the correct primitive was used.

**Blockers:**

- Hand-rolled `<table>` / `<tr>` / `<td>` instead of `DataGrid`
- Hand-rolled modal with `position: fixed` instead of `Dialog`
- Native `<select>` instead of `Dropdown` / `Combobox`
- Native `<input type="checkbox">` instead of `Checkbox` / `Switch`
- Hand-rolled tooltip with CSS instead of `Tooltip`

**Critical:**

Wrong primitive for the job:

- `Tooltip` used for critical info (should be `Popover` or inline)
- `Dropdown` used for searchable multi-select (should be `Combobox` or `TagPicker`)
- `Button appearance="link"` used for actual navigation (should be `Link`)
- `Dialog` used for side-panel detail (should be `Drawer`)
- `MessageBar` used for transient notifications (should be `Toast`)
- `Toast` used for critical blocking info (should be `MessageBar` or `Dialog`)

**Major:**

- Icon-only buttons without `Tooltip` wrapper
- Multiple primary buttons on the same screen (should be one)
- `Spinner` used where `Skeleton` would be more appropriate (predictable
  content shape)

### 8. The Four States

For every screen that fetches or mutates data, verify all four:

**Blockers:**

- No error state (errors swallowed or cause app crash)
- No loading state (blank screen while fetching)

**Critical:**

- No empty state (empty table shown with just a header)
- Loading state is a full-page spinner when `Skeleton` would work
- Error state is a generic "Something went wrong" with no retry action
- Success state renders before loading resolves (flash of wrong content)

**Major:**

- Empty state is text-only (no illustration/icon, no CTA)
- Error message exposes stack traces or technical details to end users
- Skeleton shape doesn't match final layout (generic gray rectangle for
  a card with avatar + two lines)

### 9. Forms & Validation

**Blockers:**

- Input not wrapped in `Field`
- No validation on submit (form can post empty required fields)
- `useState` + manual validation instead of React Hook Form

**Critical:**

- `Field` missing `label` (placeholder used as label)
- `validationState` / `validationMessage` not wired to errors
- Schema not defined with Zod (or equivalent runtime validator)
- Submit button not disabled during `isSubmitting`
- No loading indicator on submit button during mutation

**Major:**

- `Controller` not used for Fluent controlled inputs (`Dropdown`, `Combobox`,
  `DatePicker`, `Switch`, `Slider`) — will cause uncontrolled behavior
- Required fields not marked visually (`required` prop on `Field`)
- Validation fires on every keystroke instead of on blur/submit (noisy)
- No `hint` prop on non-obvious fields

**Minor:**

- Default values not set in `useForm`
- Form doesn't preserve state across navigation when it should

### 10. Server State & Data Fetching

**Blockers:**

- `useEffect(() => { fetch(...) }, [])` pattern anywhere
- Direct `fetch` / `axios` calls bypassing the generated Swagger client
- Mutations without error handling
- Query keys that aren't arrays or don't include variable dependencies

**Critical:**

- Not using TanStack Query (`useQuery` / `useMutation`)
- Query without explicit `enabled` gate when it depends on conditional data
- Mutation without `onSuccess` cache invalidation (stale data after save)
- Not handling `isPending`, `isError`, `error`, `data` explicitly

**Major:**

- No optimistic update where the pattern clearly warrants one (toggles,
  favorites)
- Missing rollback on mutation error
- Query keys inconsistent across the feature (`['orders']` in one place,
  `['orders', 'list']` in another)

### 11. Accessibility

**Blockers:**

- Icon-only button without `aria-label`
- Form input without associated label
- `outline: none` on focusable elements without a replacement focus indicator
- Color used as the only signal (red text with no icon for error)
- Keyboard trap in a modal or menu
- Elements with `onClick` on non-interactive tags (`<div onClick>`) without
  `role` + `tabIndex` + keyboard handler

**Critical:**

- Tab order doesn't match visual order
- `Esc` doesn't close overlays
- Focus not returned to trigger after overlay closes
- Missing `aria-live` region for dynamic content (toasts, validation)
- Images/icons without `alt` or `aria-hidden`
- `prefers-reduced-motion` not respected on any non-trivial animation

**Major:**

- Tap targets smaller than 44×44px
- Contrast below 4.5:1 for text or 3:1 for UI (usually from custom colors
  that should have been tokens)
- Zoom to 200% breaks layout
- Screen reader announces meaningless labels ("button button") or missing
  landmarks

**Minor:**

- Overuse of `aria-label` where visible text would serve
- Missing `<nav>`, `<main>`, `<section>` semantic landmarks under Fluent
  components

### 12. Motion & Micro-interactions

**Critical:**

- Hard-coded transition durations (`transition: 'all 300ms'`)
- Animation on page load for every element (noisy)
- No hover state on interactive elements
- No pressed/active state on buttons

**Major:**

- Using wrong curve (decelerate on exit, accelerate on enter)
- Transitioning `all` instead of specific properties (performance)
- No transition on state changes where one would reinforce the change

**Minor:**

- Animation duration feels slow (>400ms for small elements) or too fast
  (<100ms)

### 13. Responsive & Cross-Device

**Blockers:**

- Horizontal scrolling on 375px viewport (content doesn't fit)
- Fixed widths (`width: 1200px`) that break small screens

**Critical:**

- No mobile layout (just a shrunken desktop)
- Touch targets <44×44px on mobile
- Hover-only affordances (no tap equivalent)
- Tables that don't adapt to narrow viewports (no horizontal scroll
  container, no responsive collapse)

**Major:**

- No container queries or media queries for meaningful breakpoints
- Inconsistent breakpoints across the feature (640 in one component,
  768 in another)
- Dense content not reflowing on tablet

### 14. Code Quality & Architecture

**Critical:**

- `any` types or `@ts-ignore` without justification comment
- Components >300 lines without decomposition
- Feature not following `src/features/<feature>/{components,hooks,api,types}`
  structure
- Barrel exports leaking internals
- Props interface not named `<Component>Props`

**Major:**

- Render blocks >80 lines not extracted to subcomponents
- Business logic in components instead of hooks
- API wrappers duplicated across components instead of lifted to
  `features/*/api/`
- Magic strings repeated (status values, role names) instead of const
  enums or unions

**Minor:**

- Inconsistent naming (`handleClick` vs `onClickHandler`)
- Unused imports
- Props not destructured in signature

### 15. Polish & Copy

**Major:**

- Button labels that aren't verbs (`Submit` instead of `Save changes`,
  `OK` instead of `Create order`)
- Error messages that describe the problem without a fix (`Invalid input`
  vs `Enter an email like name@example.com`)
- Empty state copy that's generic (`No items` instead of
  `You haven't created any orders yet. Start by creating your first order.`)
- Numbers not formatted (`1234567.89` instead of `$1,234,567.89`)
- Dates not formatted via `Intl.DateTimeFormat` or not localized
- Absolute timestamps where relative would be clearer
  (`2025-04-23T14:32:00Z` instead of `2m ago`)
- No thousands separators
- Mixing `&` and `and`, `OK` and `Okay`, sentence case and Title Case
  within the same screen

**Minor:**

- Icon not used where a high-frequency action would benefit
- Regular icon used in selected/active state (should be Filled)
- Missing `Tooltip` on icon-only controls

## Review Report Format

Produce the report in exactly this structure:

````markdown
# Design Review: <feature or scope>

**Reviewed:** <file count> files, <line count> lines
**Date:** <date>
**Overall verdict:** ✅ Ship it | ⚠️ Ship after fixes | ❌ Not ready

## Summary

<2–3 sentence executive summary. Lead with what's good, then the headline issues.>

## Findings by Severity

### 🔴 Blockers (<count>)

1. **<Short title>** — `src/path/to/file.tsx:LINE`
   - **Evidence:** <code snippet or description>
   - **Why it matters:** <1 sentence>
   - **Fix:** <code snippet or concrete action>

### 🟠 Critical (<count>)
<same format>

### 🟡 Major (<count>)
<same format>

### 🔵 Minor (<count>)
<condensed — one line each with file:line>

### ⚪ Nits (<count>)
<one line each>

## Strengths

<3–5 bullets on what was done well. Be specific. This keeps the review balanced and reinforces good patterns.>

## Recommended Fix Order

1. <Blocker items grouped logically>
2. <Critical items>
3. <Major items as a follow-up PR>

## Metrics

- Token discipline: <X>/10 (hex colors, raw px, wrong tokens)
- Component primitive fit: <X>/10 (right Fluent primitive for the job)
- State coverage: <X>/10 (loading / empty / error / success)
- Accessibility: <X>/10
- Forms & validation: <X>/10
- Responsive: <X>/10
- Code quality: <X>/10
- Polish & copy: <X>/10

**Overall design quality score: <X>/80**

## Next Steps

<One paragraph. What the developer should do next. Offer to apply Blocker + Critical fixes automatically.>
````

## Review Principles

- **Be specific.** Every finding cites a file and line number. No
  "consider improving the styling."
- **Show the fix.** For every Blocker and Critical, show the corrected
  code — don't just point at the problem.
- **Be proportional.** If the code is 95% excellent, say so in the summary
  before listing the 5%. A review that only lists flaws demoralizes
  without informing.
- **Don't invent problems.** If the code follows a pattern that isn't in
  the mastery guide but is defensible, note it as "⚪ Consideration" not
  a finding.
- **Separate taste from rules.** Token violations are rules. "I'd use
  Filled icons for the selected tab" is taste — mark as Minor or Nit.
- **Check what the mastery guide requires.** Reference the specific part:
  "Violates Part 3: Griffel requires `shorthands.padding()` for shorthand
  properties." This teaches while reviewing.
- **Verify, don't assume.** If you're unsure whether a component is
  correct (e.g., whether `Combobox` or `Dropdown` fits), read the
  surrounding code to understand the use case before declaring a finding.
- **Propose the fix order.** A good review ends with a clear path forward:
  fix these five things, merge, handle the rest as follow-ups.

## When There's Nothing to Review

If the scope is empty (no frontend files changed) or the code is trivial
(<20 lines, clearly correct):

> "Nothing substantive to review in <scope>. Code is minimal and follows
> conventions. Approved."

Don't pad a review with minor findings to justify running it.

## After the Review

If the user responds "apply fixes" / "fix them" / "yes":

- Apply all Blockers and Criticals automatically
- Re-run typecheck and lint after fixes
- Report what was changed and what remains
- Recommend a re-review if >10 fixes were applied

If the user responds with questions about specific findings, explain the
reasoning and reference the mastery guide part number.

## Integration Notes

- **Pair with the mastery skill.** This review assumes the
  `fluent-v9-mastery` skill exists and references it (e.g.,
  "Violates Part 3"). They're designed as a set.
- **Run three ways:**
  1. As a slash command: `/design-review src/features/orders`
  2. As an auto-trigger at end of feature implementation (add to your
     Phase D skill: "After declaring a feature done, automatically run
     the design review skill")
  3. As a pre-merge gate in CI
- **The metrics section is the secret weapon.** Over time, if you track
  scores across features, you'll see exactly where your team's quality
  is trending. Token discipline scores usually improve fastest;
  accessibility and polish scores are the long tail.
- **For client-visible work, run twice.** Once after implementation, then
  again after fixes. The second pass catches the regressions fixes
  sometimes introduce.

When asked to review frontend code, run this entire review by default.
Don't shortcut categories. Don't be lenient. The mastery guide is the bar.
