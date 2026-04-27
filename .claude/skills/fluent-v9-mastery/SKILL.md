---
name: fluent-v9-mastery
description:
  Production-grade Fluent UI React v9 design and implementation discipline.
  Activates whenever the user requests frontend work, React components, Fluent
  UI, UI/UX design, screen implementation, form building, or any visual polish
  pass on generated projects. Output must feel like it was built by a senior
  product designer + senior frontend engineer at Microsoft — not an AI-generated
  admin panel. Covers token system, Griffel styling, theming, layout, component
  selection, forms, the four states rule, accessibility, polish details, code
  quality standards, forbidden anti-patterns, and a pre/post-coding checklist.
metadata:
  stack: "@fluentui/react-components v9, Griffel, React 18, TypeScript strict, React Hook Form, Zod, TanStack Query v5"
  related-skills: [react-ui-design-patterns, composition-patterns, web-design-guidelines]
  version: '1.0.0'
  applies-to: frontend-code-generation, ui-review, visual-polish
---

# Fluent UI React v9 — Design & Implementation Mastery

You are designing and building a production-grade, professionally designed
frontend using Microsoft Fluent UI React v9 (`@fluentui/react-components`).
Your output must feel like it was built by a senior product designer and
senior frontend engineer working together at Microsoft — not like a generic
AI-generated admin panel.

Internalize everything below before writing a single line of code. When in
doubt, re-read the relevant section.

## Part 1 — Design Philosophy

Fluent is not Material, not Ant, not Chakra. It has a specific visual language
rooted in five principles, and every decision you make must serve them:

1. **Light.** Interfaces feel weightless. Use generous whitespace, subtle
   elevation, and restrained color. Heavy borders, drop shadows on everything,
   and dense layouts violate this principle.
2. **Depth.** Hierarchy comes from layered surfaces
   (`colorNeutralBackground1` → `2` → `3` → `4`), not from borders. Elevation
   tokens (`shadow2`, `shadow4`, `shadow8`, `shadow16`, `shadow28`, `shadow64`)
   communicate stacking order. A `Dialog` sits at `shadow64`; a `Card` rests
   at `shadow4`.
3. **Motion.** Movement has meaning. Use Fluent's motion tokens
   (`durationFaster`, `durationNormal`, `durationSlow` +
   `curveAccelerateMid`, `curveDecelerateMid`, `curveEasyEase`) to reinforce
   cause and effect. A `Drawer` slides in; a `Dialog` fades + scales; a
   `Toast` enters from an edge. Never animate for decoration.
4. **Material.** Surfaces have honest properties — acrylic, solid, subtle.
   Use `colorNeutralBackgroundAlpha` variants for translucent surfaces over
   imagery. Don't fake glassmorphism with hand-rolled CSS.
5. **Scale.** The same design system serves a phone and a 4K monitor. Think
   in tokens, not pixels. Think in components, not divs.

## Part 2 — The Token System (Learn This Cold)

You are forbidden from using hex codes, named colors, or arbitrary pixel
values. Everything routes through tokens from `@fluentui/react-components`.

**Color tokens** come in semantic families:

- `colorNeutralBackground1..6` — surface layers, ascending elevation
- `colorNeutralForeground1..4` — text, descending emphasis (1 is primary text, 4 is disabled)
- `colorNeutralStroke1..3` — borders, dividers
- `colorBrandBackground`, `colorBrandForeground1/2`, `colorBrandStroke1/2` — brand accent
- `colorStatusSuccess*`, `colorStatusWarning*`, `colorStatusDanger*`, `colorPaletteRed*` etc. — semantic status

Use semantic tokens first (`colorStatusDangerBackground1`), palette tokens
only when semantics don't fit.

**Spacing tokens** are a 4px grid: `spacingHorizontalXXS` (2px) →
`spacingHorizontalXXXL` (32px). Vertical variants mirror these. No raw 8px
or 12px ever appears in your styles.

**Typography tokens** are compound — they bundle font-family, size,
line-height, and weight:

- `typographyStyles.caption2`, `caption1` — metadata, timestamps
- `typographyStyles.body1`, `body1Strong`, `body2` — content
- `typographyStyles.subtitle2`, `subtitle1` — section headers
- `typographyStyles.title3`, `title2`, `title1` — page and card titles
- `typographyStyles.largeTitle`, `display` — hero moments

Spread them: `...typographyStyles.body1`. Never set `fontSize` manually.

**Border radius:** `borderRadiusNone`, `Small` (2px), `Medium` (4px — the
default), `Large` (6px), `XLarge` (8px), `Circular`. Cards use `Medium`,
avatars use `Circular`, pills use `Large`.

**Stroke width:** `strokeWidthThin` (1px), `Thick` (2px), `Thicker` (3px),
`Thickest` (4px). Focus indicators use `Thick`.

**Shadow tokens:** `shadow2` (resting card) → `shadow64` (modal). Pair with
the right surface color for believable depth.

**Motion tokens:** always pair a duration with a curve. Entering elements
use decelerate curves; exiting elements use accelerate curves; elements
moving in place use easy-ease.

## Part 3 — Styling: Griffel & makeStyles

Fluent v9 uses **Griffel**, an atomic CSS-in-JS engine. It is not Emotion.
Syntax differs in important ways.

```tsx
import { makeStyles, shorthands, tokens, typographyStyles } from '@fluentui/react-components';

const useStyles = makeStyles({
  root: {
    display: 'flex',
    flexDirection: 'column',
    rowGap: tokens.spacingVerticalM,
    ...shorthands.padding(tokens.spacingVerticalL, tokens.spacingHorizontalL),
    ...shorthands.border(tokens.strokeWidthThin, 'solid', tokens.colorNeutralStroke2),
    borderRadius: tokens.borderRadiusMedium,
    backgroundColor: tokens.colorNeutralBackground1,
    ':hover': {
      backgroundColor: tokens.colorNeutralBackground1Hover,
    },
  },
  title: {
    ...typographyStyles.subtitle1,
    color: tokens.colorNeutralForeground1,
  },
});
```

Rules:

- Use `shorthands.padding`, `shorthands.margin`, `shorthands.border`,
  `shorthands.borderColor`, `shorthands.overflow` — Griffel requires these
  for shorthand properties.
- Gap properties (`rowGap`, `columnGap`) work natively — no shorthand needed.
- Media queries use the `'@media (min-width: 640px)': {...}` key syntax.
- Pseudo-selectors (`:hover`, `:focus-visible`, `:disabled`) are keys on the
  same object.
- Define `useStyles` at the bottom of the component file, not in a separate
  file (co-location).
- Use `mergeClasses(styles.a, styles.b, condition && styles.c)` to combine
  class names — never template-string concatenate.

## Part 4 — Theming & FluentProvider

Wrap the app root once:

```tsx
<FluentProvider theme={webLightTheme}>
  <App />
</FluentProvider>
```

Available themes: `webLightTheme`, `webDarkTheme`, `webHighContrastTheme`,
and brand variants via `createLightTheme` / `createDarkTheme` using a
`BrandVariants` ramp.

For a custom brand, generate the ramp with the Fluent UI Theme Designer,
export the `BrandVariants` object, then:

```tsx
const brand: BrandVariants = { /* 16 shades, 10 to 160 */ };
const lightTheme = createLightTheme(brand);
const darkTheme = createDarkTheme(brand);
```

For dark mode, detect user preference and toggle the `theme` prop on
`FluentProvider`. Nested `FluentProvider`s let you theme a subtree
differently (e.g., a dark hero on a light page).

Never override theme via CSS variables directly. Never write
`:root { --color-primary: ... }`.

## Part 5 — Layout & Composition

Fluent v9 does not ship a grid component. Layouts are built from flex/grid
via `makeStyles`. The conventions:

- **Page shell:** Header (sticky, `shadow4`, `colorNeutralBackground1`) →
  Nav (side drawer or top bar) → Main (scrolling region,
  `colorNeutralBackground2`) → optional Aside.
- **Content density:** default to comfortable spacing (`spacingVerticalL`
  between sections, `spacingVerticalM` within sections). Use compact
  spacing only in data-dense views (DataGrid rows, toolbars).
- **Card-based layouts:** wrap logical units in `Card` with `CardHeader`
  (title + description + action) and `CardPreview` (media). Don't hand-roll
  cards with divs.
- **Section rhythm:** alternating `colorNeutralBackground1` and
  `colorNeutralBackground2` creates visual sections without borders.
- **Max content width:** 1280px for dashboards, 720px for reading-focused
  pages. Center with `marginInline: 'auto'`.
- **Responsive:** mobile-first. Use container queries (`@container`) or
  `useMediaQuery` from `@fluentui/react-components`. Breakpoints: 480
  (phone), 640 (large phone), 1024 (tablet), 1366 (desktop), 1920 (large
  desktop).

## Part 6 — Component Mastery

Use the right primitive for the job. Common mistakes and corrections:

**Buttons.** `Button` has `appearance`: `secondary` (default), `primary`
(one per view, for the main CTA), `outline`, `subtle` (toolbar actions),
`transparent` (inline), `link`. Pair with `icon` prop and `iconPosition`.
For dangerous actions, don't color buttons red — use a confirmation
`Dialog`. `ToggleButton` for pressed/unpressed state. `MenuButton` when it
opens a menu. `SplitButton` for a default action + dropdown.

**Inputs & Forms.** Every input lives inside a `Field`:

```tsx
<Field label="Email" required validationState={errors.email ? 'error' : 'none'} validationMessage={errors.email?.message} hint="We'll never share this.">
  <Input {...register('email')} />
</Field>
```

Use `Input` for short text, `Textarea` for long, `SpinButton` for numbers,
`Slider` for ranges, `Switch` for binary settings, `Checkbox` for
multi-select, `Radio` + `RadioGroup` for single-select from a small set,
`Dropdown` for single-select from a medium set, `Combobox` for searchable
single or multi-select, `TagPicker` for multi-select with chips,
`DatePicker` (from `@fluentui/react-datepicker-compat`) for dates.

**Data display.** `DataGrid` for tabular data — it supports sortable
columns, row selection, resizable columns, and virtualization. Configure
columns with `createTableColumn<T>()`. Never hand-build a `<table>`.
`List` for simple vertical lists. `Tree` for hierarchy.

**Overlays.** `Dialog` for confirmations and focused tasks (modal,
centered). `Drawer`/`OverlayDrawer`/`InlineDrawer` for side panels with
detail or secondary actions. `Popover` for contextual info anchored to an
element. `Tooltip` for label-only hover help (never for critical info).
`Menu`/`MenuList`/`MenuItem` for action menus.

**Feedback.** `Spinner` for indeterminate waits >400ms. `Skeleton` (with
`SkeletonItem`) for content-shaped loading placeholders — always prefer
over spinners when layout is predictable. `ProgressBar` for determinate
progress. `MessageBar` (with `intent: info | success | warning | error`)
for inline page-level messages. `Toast` (via `useToastController` +
`Toaster`) for transient notifications.

**Navigation.** `TabList` + `Tab` for in-page sections. `Breadcrumb` for
hierarchy. `Link` for navigation (not `Button appearance="link"` unless
it's actually an action). For app-level nav, compose `Drawer` + `MenuList`
or use `@fluentui/react-nav-preview` for the vertical nav pattern.

**Identity.** `Avatar` (with fallback initials via `name` prop), `Persona`
for avatar + name + secondary text, `PresenceBadge` for status,
`CounterBadge` for numeric indicators.

**Icons.** `@fluentui/react-icons` exports every Fluent icon in Regular,
Filled, and sized variants (16, 20, 24, 28, 32, 48). Use Regular for
resting, Filled for selected/active state. Name pattern: `PersonAdd24Regular`.
Never import SVGs for things Fluent already provides.

## Part 7 — Forms, Validation, State

Forms use React Hook Form + Zod. Every form follows this pattern:

```tsx
const schema = z.object({
  email: z.string().email('Enter a valid email'),
  role: z.enum(['admin', 'user']),
});
type FormData = z.infer<typeof schema>;

const { register, handleSubmit, formState: { errors, isSubmitting }, control } = useForm<FormData>({
  resolver: zodResolver(schema),
  defaultValues: { email: '', role: 'user' },
});
```

Wire `validationState` and `validationMessage` on every `Field` from
`errors`. For controlled Fluent components (`Dropdown`, `Combobox`,
`DatePicker`, `Switch`, `Slider`), use `Controller` from RHF. Disable
submit while `isSubmitting`; show a spinner inside the submit button.

**Server state is TanStack Query v5.** No `useEffect(() => { fetch(...) }, [])`.
Every server interaction is a `useQuery` or `useMutation`. Use the generated
Swagger client as the query function. Handle `isPending`, `isError`, `error`,
`data` explicitly — no screen renders without all four states designed.

## Part 8 — The Four States Every Screen Needs

Before declaring any screen complete, verify all four states are designed
and implemented:

1. **Loading.** `Skeleton` matching final layout shape. Avoid full-page
   spinners unless the whole route is blocked.
2. **Empty.** Illustration or large icon + headline (`subtitle1`) +
   supporting text (`body1`, `colorNeutralForeground2`) + primary action
   button. Never show an empty table with just a header.
3. **Error.** `MessageBar intent="error"` with a clear message and a retry
   action. Log the error; show a friendly version. Never swallow errors
   silently.
4. **Success/content.** The happy path.

## Part 9 — Accessibility (Non-Negotiable)

Fluent components are accessible by default, but you can break them. Rules:

- Every interactive element has a visible focus indicator (Fluent provides
  this — don't override `outline: none`).
- Every icon-only button has an `aria-label`.
- Every `Field` has a `label` (not placeholder-as-label).
- Color is never the only signal — pair with icon or text.
- Keyboard navigation works for every flow (Tab order, Enter/Space to
  activate, Esc to close overlays, Arrow keys in lists/menus/grids).
- Respect `prefers-reduced-motion` — disable or shorten transitions.
- Minimum tap target 44×44px on touch.
- Contrast ratios: 4.5:1 for normal text, 3:1 for large text and UI
  components. The Fluent theme enforces this; don't override it.
- Use semantic HTML under Fluent components when composing (`<nav>`,
  `<main>`, `<section>`, `<article>`).

Test with keyboard only. Test with a screen reader (NVDA or VoiceOver).
Test at 200% zoom.

## Part 10 — Polish: The Details That Separate Good From Great

These are what make an interface feel *designed* rather than *assembled*:

- **Micro-interactions.** Buttons depress visibly. Switches animate. Menus
  fade+slide in. Hover states are always present on interactive elements.
  Transitions use motion tokens, not arbitrary ms values.
- **Density modes.** Offer a "compact" view for data-heavy users (reduced
  row height, `spacingVerticalXS`). Comfortable by default.
- **Skeletons match reality.** A skeleton for a user card shows a circle
  (avatar), two lines (name + role), not a generic gray rectangle.
- **Optimistic updates.** For mutations the user expects to succeed (toggle
  a switch, favorite an item), update UI immediately and roll back on
  error with a toast.
- **Smart defaults.** Date pickers default to today. Search boxes autofocus
  on list pages. Forms remember partial input across navigation (use
  react-hook-form's `shouldUnregister: false`).
- **Thoughtful copy.** Button labels are verbs (`Save changes`, not `Submit`).
  Error messages explain the fix, not the problem. Empty states invite
  action.
- **Icons earn their place.** Don't icon every button. Lead with text; add
  icons to high-frequency actions and toolbar buttons.
- **Numbers are formatted.** Currencies use `Intl.NumberFormat`. Dates use
  `Intl.DateTimeFormat` with user locale. Large numbers get thousands
  separators. Times show relative when recent (`2m ago`) and absolute when
  older.
- **No jank.** Images have explicit dimensions or aspect ratios to prevent
  layout shift. Skeletons occupy exact final dimensions.
- **Dark mode is first-class.** Every screen works in both themes. Test
  both before shipping.

## Part 11 — Code Quality Standards

- TypeScript strict mode. No `any`. No `@ts-ignore` without a comment
  explaining why.
- One component per file. File name matches component name in PascalCase.
- Co-locate `makeStyles` at the bottom of the component file.
- Co-locate types in the same file unless shared (then `types.ts`).
- Feature folders: `src/features/<feature>/{components,hooks,api,types,index.ts}`.
- Barrel exports (`index.ts`) only for public feature APIs.
- Props interfaces end in `Props` (`CustomerCardProps`).
- Event handlers start with `on` in props, `handle` in implementations.
- Extract any render block >80 lines into a subcomponent.
- Every async path has error handling.
- Every `useQuery` has a typed return and handles all states.

## Part 12 — Anti-Patterns (Forbidden)

Never do any of these:

- `import { ... } from '@fluentui/react'` — that's v8; we use v9 only.
- Inline `style={{...}}` props except for truly dynamic values (animated
  transforms, computed widths).
- Hex colors, `rgb()`, `hsl()`, or named colors in styles.
- Raw pixel spacing values (`padding: '16px'`).
- Custom CSS files for component styling (global resets and font imports
  are fine).
- `styled-components` or `@emotion/styled` — Griffel only.
- Hand-rolled modals, dropdowns, tooltips, or tables when Fluent provides them.
- Global z-index values — Fluent's portal system handles layering.
- `useEffect` + `fetch` — always TanStack Query.
- Native `<button>`/`<input>`/`<select>` in app code — use Fluent primitives.
- Color as the only differentiator (red error text with no icon).
- `!important` anywhere.
- Any `@fluentui/react` v8 package (`@fluentui/react-northstar` too —
  that's Teams' old stack).
- Copying code from v8 Fluent docs — API surface is different.

## Part 13 — Workflow Before Writing Code

For every new screen or feature, **before coding**:

1. Restate the user story and acceptance criteria.
2. List the screens needed and the primary user flow.
3. Identify the Fluent v9 components you'll compose (use Part 6 as the
   checklist).
4. Sketch the layout in prose: "Page shell with sticky header containing
   Breadcrumb + primary action. Main region is a Card containing a DataGrid
   above a Drawer trigger for row detail."
5. Identify the four states (loading, empty, error, success) and how each
   is rendered.
6. Identify the API endpoints (from generated Swagger client) and the
   TanStack Query keys.
7. Identify validation rules and build the Zod schema.
8. Only then write code.

**After coding:**

- Check all four states render correctly.
- Run `npm run typecheck` and `npm run lint`.
- Keyboard-test the flow.
- Toggle dark mode and verify.
- Resize to 375px and verify.
- Confirm no forbidden patterns from Part 12.

## Part 14 — When You're Unsure

If the user asks for a pattern not covered here, or a component that
doesn't obviously map to Fluent v9:

1. Check the official Fluent UI React v9 Storybook (`react.fluentui.dev`)
   for the component.
2. Check `@fluentui/react-components-preview` for unreleased primitives.
3. If no primitive exists, compose from existing primitives — don't
   hand-build from divs unless absolutely necessary.
4. If you must hand-build, follow every rule in Parts 2–3 (tokens,
   Griffel, accessibility) so the custom component is indistinguishable
   from a native Fluent one.

## Part 15 — Definition of Done

A screen is not complete until:

- All four states implemented and visually polished.
- Matches Fluent visual language (tokens, typography, spacing, motion).
- Keyboard-navigable end to end.
- Works in light and dark themes.
- Responsive from 375px to 1920px+.
- No TypeScript errors, no lint warnings.
- No forbidden patterns from Part 12.
- Traceable: linked to user story, signed-off prototype, and API endpoint.

When you finish a feature, produce a short **"What was built"** summary
listing the screens, components used, states handled, and any design
decisions that diverged from the prototype with justification.

## How This Skill Is Used

- Whenever the user requests frontend work, React components, Fluent UI,
  UI/UX design, or any screen implementation in this repo, apply
  everything above by default.
- If a request conflicts with these rules, surface the conflict before
  coding — don't silently lower the bar.
- The two highest-leverage sections are **Part 2 (tokens)** and
  **Part 12 (anti-patterns)**. Keep both intact even if other sections
  get summarized under context pressure.
- **Part 13 (workflow)** is what turns "generates plausible code" into
  "thinks like a designer first" — follow it on every non-trivial screen.

## Related Skills

- `/react-ui-design-patterns` — async states, loading skeletons,
  optimistic updates, empty states, error boundaries, data fetching
- `/composition-patterns` — React component architecture, compound
  components, context providers
- `/web-design-guidelines` — UI accessibility and design audit
