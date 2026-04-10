---
name: enterprise-form-patterns
description:
  Complex form design patterns for enterprise ERP applications. Use when building
  multi-section forms, conditional fields, formula editors, array fields, or any
  form with more than 5 inputs. Covers validation, auto-save, computed fields,
  stepper wizards, and draft persistence.
metadata:
  stack: React 18, @fluentui/react-components, react-hook-form or native
  version: '1.0.0'
---

# Enterprise Form Design Patterns

Complex form patterns for commodity trading worksheets, pricing configurations,
rental agreements, booking forms, commission rules, and ETL configuration.

## When to Activate

- Building a form with more than 5 input fields
- "Add a multi-section form"
- "Build a formula editor / expression builder"
- "Add conditional fields that show/hide based on selection"
- "Add line items (add/remove rows)"
- "Add auto-calculation to the form"
- Reviewing form validation or UX

## Form Layout Rules

### Section Organization
- Group related fields into collapsible sections with `Accordion` or `Card` containers
- Section header: Semibold 16sp + optional description in secondary text
- Fields within section: vertical stack with 16px gap
- Between sections: 24px gap with subtle divider

### Field Layout
- Labels: above input (Fluent `Field` component), never inline/beside
- Required fields: red asterisk after label text
- Optional fields: "(optional)" suffix in secondary text
- Help text: below input in 12sp secondary color
- Error text: below input in red, replaces help text when invalid
- Two-column layout for short fields (e.g., City + State) using CSS Grid `grid-template-columns: 1fr 1fr`
- Full-width for text areas, dropdowns, and complex inputs

### Field Sizing
| Input Type | Width | Height |
|---|---|---|
| Short text (name, code) | 280px or 50% | 32px |
| Long text (description) | 100% | 32px |
| Textarea (notes) | 100% | 80-120px (3-5 rows) |
| Number (quantity, weight) | 160px | 32px |
| Currency | 200px (with $ prefix) | 32px |
| Date | 200px | 32px |
| Dropdown/Combobox | 280px or 50% | 32px |
| Large numeric (scale weight) | 100% | 64px (48sp font) |

## Validation Patterns

### Validate on Blur (not on every keystroke)
```tsx
<Field
  label="Order Number"
  validationState={errors.orderNumber ? 'error' : 'none'}
  validationMessage={errors.orderNumber?.message}
>
  <Input onBlur={() => trigger('orderNumber')} />
</Field>
```

### Validation Timing
| Event | Validation |
|---|---|
| Field blur | Validate that field only |
| Form submit | Validate all fields, scroll to first error |
| Field change (after first blur error) | Re-validate to clear error immediately |
| Section advance (stepper) | Validate current section fields only |

### Error Display
- Inline: red text below field, field border turns red
- Section-level: red `MessageBar` at top of section summarizing errors
- Form-level: red `MessageBar` at top of form: "Please fix 3 errors before submitting"
- Scroll to first error on submit with smooth scroll + focus on the errored input

### Common Validators
| Field | Rule | Message |
|---|---|---|
| Required | Not empty/null | "{Field} is required" |
| Min/Max length | String length bounds | "{Field} must be 3-100 characters" |
| Numeric range | Min/max value | "Weight must be between 0 and 100,000 lbs" |
| Pattern | Regex match | "Order number must match format SO-YYYY-NNNN" |
| Sum constraint | Array items sum to total | "Split weights must equal net weight (±0.5 lb)" |
| Date range | Start before end | "Start date must be before end date" |
| Conditional | Required when toggle on | "Formula expression is required when pricing type is Formula" |

## Conditional Fields (Show/Hide)

```tsx
// Toggle controls visibility of dependent section
<Switch
  label="Consume Bulk Material"
  checked={consumeBulk}
  onChange={(_, data) => setConsumeBulk(data.checked)}
/>

{consumeBulk && (
  <Card>
    <Field label="Bulk Material Source">
      <Combobox>{bulkSources.map(...)}</Combobox>
    </Field>
    <Text>Available: 12,400 lbs</Text>
    <Text weight="semibold">Yield: {yieldPct}%</Text>
  </Card>
)}
```

- Animate show/hide: 200ms slide-down with opacity fade
- When hidden fields have values: clear on hide, OR warn "Hiding this section will clear your entries"
- Conditional required: fields only required when their section is visible

## Auto-Calculated Fields

- Computed fields: read-only `Input` with gray background showing calculated value
- Label includes calculator icon and "(calculated)" suffix
- Recalculate on any input change that affects the formula
- Show calculation breakdown on hover/click: "Material: $120 + Freight: $45 + Processing: $18 = $183"
- Loading state while calculating: small `Spinner` replaces value briefly

### Examples
| Calculated Field | Formula | Trigger |
|---|---|---|
| Net Weight | Gross - Tare | Tare captured |
| Landed Cost | Material + Freight + Processing + Storage | Any component changed |
| Projected Margin | (Sell - LandedCost) / Sell * 100 | Price or cost changed |
| Yield % | (Bale Weight / Bulk Consumed) * 100 | Bale created |
| Payable Net | Net - Moisture% - Contamination | Deductions applied |
| Commission | f(GrossProfit, TierRules) | Settlement confirmed |
| Split Validation | Sum(splits) vs NetWeight | Any split changed |

## Array Fields (Line Items)

For worksheet line items, split loads, commission tiers, booking containers:

```
┌─ Line Items ──────────────────────────────────────────────────┐
│  Material       Qty        Buy Rate    Sell Rate    [Remove]  │
│  ┌──────────┐  ┌──────┐   ┌────────┐  ┌────────┐  ┌───┐    │
│  │ OCC      ▾│  │ 1240 │   │ $120.00│  │ $145.00│  │ ✕ │    │
│  └──────────┘  └──────┘   └────────┘  └────────┘  └───┘    │
│  ┌──────────┐  ┌──────┐   ┌────────┐  ┌────────┐  ┌───┐    │
│  │ Mix Paper▾│  │  800 │   │  $42.00│  │  $55.00│  │ ✕ │    │
│  └──────────┘  └──────┘   └────────┘  └────────┘  └───┘    │
│                                                               │
│  [+ Add Line Item]                          Total: $243,800   │
└───────────────────────────────────────────────────────────────┘
```

- "Add Line Item" button at bottom of list (blue outline, plus icon)
- Remove button per row (subtle, trash icon) — requires confirmation if row has data
- Maximum line items: configurable (e.g., 50 for worksheet, 10 for splits)
- Running total/summary row at bottom (calculated, read-only)
- Empty state: "No line items added. Click + to add your first item."
- Reorder: drag handle on left edge of each row

## Formula / Expression Editor

For pricing formula builder:

```
┌─ Formula Expression ─────────────────────────────────────────┐
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ ([Fastmarkets_OCC_11] * 0.85) - [Zone_4_Freight]       │ │
│  └─────────────────────────────────────────────────────────┘ │
│  Available variables: [Fastmarkets_OCC_11] [RISI_MP_42]      │
│                       [Zone_4_Freight] [Processing_Fee]      │
│  Preview: ($125.00 * 0.85) - $45.00 = $61.25                │
│  Status: ✓ Valid expression                                  │
└───────────────────────────────────────────────────────────────┘
```

- Syntax highlighting: variables in blue, operators in gray, numbers in green
- Variable autocomplete: type `[` to trigger dropdown of available variables
- Live preview: resolves variables with current values, shows result
- Validation: balanced parentheses, valid operators (+,-,*,/), known variables only
- Error: red underline on invalid portion, error message below

## Multi-Step Wizard (Stepper)

For complex multi-phase forms (ETL config, ocean booking, new tenant setup):

```
  ① Extract  ──  ② Cleanse  ──  ③ Dedup  ──  ④ Load  ──  ⑤ Verify
     ✓              ●             ○            ○            ○
```

- Step indicators: completed (green check), current (blue filled dot), future (gray outline)
- "Back" and "Next" buttons in footer
- Validate current step before allowing "Next"
- Progress bar below stepper showing overall completion
- Step summary: completed steps show condensed summary that can be expanded to edit

## Draft Auto-Save

- Auto-save form state to localStorage every 30 seconds (key: `draft-{formType}-{entityId}`)
- "Draft saved" toast notification (subtle, 1 second auto-dismiss)
- On form re-open: detect existing draft, show `Dialog`: "Resume from draft?" with "Resume" / "Discard" buttons
- Clear draft on successful submit
- Draft age indicator: "Draft from 2 hours ago" in form header

## Action Bar (Sticky Footer)

```
┌───────────────────────────────────────────────────────────────┐
│  ⚠ 2 unsaved changes          [Save Draft]  [Submit Order]   │
│                                 secondary      primary        │
└───────────────────────────────────────────────────────────────┘
```

- Sticky to bottom of viewport (64px height, white background, top border)
- Left: change indicator ("2 unsaved changes" or "All changes saved")
- Right: action buttons (secondary + primary)
- Primary disabled until form is valid
- Loading state: primary button shows `Spinner` + "Submitting..." text, all inputs disabled
