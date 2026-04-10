---
name: data-grid-mastery
description:
  Enterprise data grid patterns for high-density, Excel-like interfaces. Use when
  building DataGrid screens for commodity trading, inventory, dispatch, settlement,
  or any master-detail list view. Covers column types, inline editing, virtual
  scrolling, grouping, selection, keyboard navigation, and print layouts.
metadata:
  stack: React 18, @fluentui/react-components DataGrid, react-window
  version: '1.0.0'
---

# Data-Dense Grid Design Patterns

Enterprise-grade DataGrid patterns for users who live in grids 8+ hours/day.
These grids are the primary interface for commodity trading, scale operations,
dispatch management, and financial reconciliation.

## When to Activate

- Building a screen with a DataGrid as the primary content
- "Add sorting, filtering, grouping to the grid"
- "Make this grid handle 10,000+ rows"
- "Add inline editing to grid cells"
- "Add bulk selection and batch actions"
- Reviewing a grid for usability or performance

## Column Type Standards

Every column must use the correct alignment, formatting, and width:

| Type | Alignment | Format | Min Width | Example |
|---|---|---|---|---|
| ID / Code | Left | Monospace `fontFamily: 'Consolas'` | 140px | `SO-2026-0001` |
| Text | Left | Proportional, ellipsis overflow with tooltip | 120px | `Pacific Coast Recyclers` |
| Numeric (qty) | Right | `tabular-nums`, thousand separators | 100px | `1,240` |
| Currency | Right | `tabular-nums`, 2 decimals, `$` prefix | 120px | `$142,500.00` |
| Percentage | Right | `tabular-nums`, 1-2 decimals, `%` suffix | 80px | `24.7%` |
| Weight | Right | `tabular-nums`, unit suffix | 100px | `1,240 lbs` |
| Date | Left | Relative < 24h, absolute > 24h | 130px | `3h ago` / `Apr 10, 2026` |
| DateTime | Left | `MMM DD, YYYY HH:MM` | 160px | `Apr 10, 2026 08:14` |
| Status Badge | Center | Fluent `Badge` with `appearance="filled"` | 100px | Colored pill |
| Boolean | Center | Fluent `Switch` or checkmark icon | 60px | Toggle / icon |
| Actions | Right | Three-dot `Menu` or icon buttons | 48-80px | Kebab menu |

## Row Density

Provide a density toggle (toolbar control):

| Density | Row Height | Padding | Use Case |
|---|---|---|---|
| Compact | 32px | 4px 8px | Power users, maximizing visible rows |
| Normal | 40px | 8px 8px | Default for most grids |
| Comfortable | 48px | 12px 8px | Touch-friendly, casual browsing |

## Virtual Scrolling (10K+ rows)

```tsx
// Fluent DataGrid with react-window for virtual rendering
<DataGrid
  items={items}
  columns={columns}
  getRowId={(item) => item.id}
  virtualized // enables virtual scrolling
  style={{ height: 'calc(100vh - 200px)' }} // fill available space
>
```

- Always set explicit height on grid container (never auto-height with 10K rows)
- Use `keepPreviousData` on page change to prevent loading flash
- Show row count in footer: "Showing 1-50 of 12,847"

## Sticky Elements

- Header row: always sticky (`position: sticky; top: 0; z-index: 2`)
- First column (ID): sticky on horizontal scroll (`position: sticky; left: 0; z-index: 1`)
- Action column: sticky right on horizontal scroll
- Toolbar: sticky above grid with filter chips and bulk actions

## Sorting

- Click column header to sort ascending, click again for descending, third click removes sort
- Sort indicator: arrow icon (up/down) in header
- Multi-column sort: Shift+click adds secondary sort. Show sort priority numbers.
- Default sort: most recent first (CreatedAt DESC) unless domain-specific order

## Filtering

- Filter chips above grid: one chip per active filter with X to remove
- Column header filter icon: click opens filter popover per column
- Text columns: contains, starts with, equals
- Numeric/currency: greater than, less than, between
- Date: preset ranges (Today, This Week, This Month, Custom Range)
- Status: multi-select checkbox list
- "Clear All Filters" link when any filter active
- Active filter count badge on filter toolbar icon

## Row Grouping

- Group by column: drag column header to grouping area, or select from menu
- Grouped rows: collapsible section headers showing group value + count
- Aggregate row: sum/avg/count per group in footer
- Nested grouping: up to 2 levels (e.g., group by Date > group by Status)
- Expand/collapse all button in toolbar

## Row Selection

- Checkbox column (first column, 40px width)
- Click row: single select (highlights row)
- Ctrl+click: toggle individual selection
- Shift+click: range select (all rows between last click and current)
- "Select All" checkbox in header (selects current page, not all pages)
- Selected count in toolbar: "3 selected" with bulk action buttons
- Bulk actions: "Settle Selected", "Export Selected", "Delete Selected"

## Inline Editing

- Double-click cell to enter edit mode
- Cell shows appropriate Fluent input: `Input` for text, `SpinButton` for numbers, `Combobox` for dropdowns, `DatePicker` for dates
- Enter: commit edit. Escape: cancel edit. Tab: commit and move to next cell.
- Modified cells: subtle left-border accent (blue) until saved
- "Save Changes" button appears in toolbar when any cell is dirty
- Discard changes: "Revert" button next to Save

## Keyboard Navigation

| Key | Action |
|---|---|
| Arrow keys | Move cell focus |
| Enter | Open detail drawer / enter edit mode |
| Space | Toggle row selection checkbox |
| Delete | Trigger delete confirmation (if permitted) |
| Ctrl+A | Select all rows on current page |
| Ctrl+C | Copy cell value to clipboard |
| Home/End | Jump to first/last column |
| Ctrl+Home/End | Jump to first/last row |
| F2 | Enter edit mode on focused cell |
| Escape | Exit edit mode / close popover |

## Master-Detail (Row Click → Drawer)

- Single click row: open detail Drawer from right (480px width)
- Drawer shows full entity detail with tabs
- Grid row stays highlighted while drawer is open
- Arrow up/down in grid while drawer open: navigates to prev/next record
- Drawer content updates without closing/reopening

## Column Management

- Right-click column header: menu with Sort, Filter, Hide, Pin Left, Pin Right
- "Columns" button in toolbar: opens panel with checkbox list of all columns + drag reorder
- Column width: resizable by dragging header border
- Column order: draggable headers to reorder
- Persist column config per user (localStorage key: `grid-{gridId}-columns`)

## Empty Grid State

- Show column headers (so user sees the grid structure)
- Centered below headers: empty state illustration + "No [items] found" + CTA button
- If filters active: "No results match your filters" + "Clear Filters" button

## Export

- "Export" button in toolbar with dropdown: "Export Current Page (CSV)", "Export All (CSV)", "Export Selected (CSV)"
- CSV: include column headers, respect current sort/filter
- Print: toolbar button opens print-optimized view (hide checkboxes, action columns, expand truncated text, add page breaks)

## Loading State

- Skeleton rows matching column layout (skeleton rectangles per column width)
- Show exact number of skeleton rows matching expected page size
- Column headers visible during loading (not skeletonized)
- Shimmer animation on skeleton rows (gradient sweep left-to-right, 1.5s)
