# Component selection — the right Fluent primitive for the job

- **Buttons:** `appearance="primary"` for THE one main CTA per view; `secondary` default; `subtle`
  for toolbar actions; `transparent` inline. Icon via `icon` prop. Dangerous actions get a
  confirmation `Dialog`, not a red button. `MenuButton` opens menus; `SplitButton` = default + menu.
- **Forms:** every input wrapped in `Field` (label, required, validationState, validationMessage,
  hint). `Input` short text · `Textarea` long · `SpinButton` numbers · `Switch` binary settings ·
  `Checkbox` multi · `RadioGroup` small single-select · `Dropdown` medium single-select ·
  `Combobox` searchable · `TagPicker` chips · `DatePicker` (datepicker-compat) dates.
- **Data:** `DataGrid` + `createTableColumn<T>()` for tables (sortable, selectable, resizable) —
  never hand-built `<table>`. `List` simple lists, `Tree` hierarchy.
- **Overlays:** `Dialog` confirmations/focused tasks · `Drawer` side panels · `Popover` anchored
  context · `Tooltip` label-only help (never critical info) · `Menu` actions.
- **Feedback:** `Skeleton`/`SkeletonItem` for loading (content-shaped, preferred) · `Spinner` only
  for indeterminate waits >400ms · `ProgressBar` determinate · `MessageBar` (intent=info/success/
  warning/error) inline · `Toast` via `useToastController` transient.
- **Navigation:** `TabList`+`Tab` in-page · `Breadcrumb` hierarchy · `Link` for navigation (a Button
  that navigates is wrong) · side nav composed from `Drawer` + `MenuList`.
- **Identity:** `Avatar` (initials fallback via `name`), `Persona`, `PresenceBadge`, `CounterBadge`.
- **Composition:** compound structure always — `Card > CardHeader/CardPreview`,
  `Drawer > DrawerHeader/DrawerBody/DrawerFooter`. Slots over wrappers
  (`contentBefore/contentAfter` on Input). **Variants over boolean props** —
  `<Button appearance="primary">`, never `<Button primary>`.
