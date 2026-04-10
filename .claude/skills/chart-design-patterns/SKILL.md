---
name: chart-design-patterns
description:
  Data visualization patterns for enterprise dashboards. Use when building
  charts, sparklines, KPI cards, funnels, or any data viz component. Covers
  chart type selection, accessible color palettes, responsive sizing, tooltips,
  drill-down, and loading/empty states for charts.
metadata:
  stack: React 18, recharts or @fluentui/react-charting, Fluent UI v9
  version: '1.0.0'
---

# Chart & Data Visualization Patterns

Enterprise-grade chart patterns for commodity trading dashboards, financial
reporting, operational monitoring, and executive KPIs.

## When to Activate

- Building a dashboard with charts or KPI cards
- "Add a chart showing trends over time"
- "Create a margin analysis visualization"
- "Build a pipeline funnel"
- "Add sparklines to the grid"
- Reviewing chart accessibility or responsiveness

## Chart Type Selection Rules

| Data Shape | Chart Type | When to Use |
|---|---|---|
| Trend over time | Line chart | Margin %, revenue, price index (continuous) |
| Trend over time (volume) | Area chart | Scale volume, dispatch count (emphasize magnitude) |
| Comparison across categories | Horizontal bar chart | Top 10 accounts, material breakdown |
| Comparison across categories | Vertical bar chart | Monthly revenue, weekly dispatch count |
| Part-of-whole | Donut chart (NOT pie) | Margin contribution by material, tenant distribution |
| Distribution | Histogram | Weight distribution, delivery time distribution |
| Pipeline / funnel | Funnel / trapezoid | Order status progression (Draft→Invoiced) |
| Single KPI | KPI card with sparkline | Revenue MTD, margin %, orders this week |
| Inline trend | Sparkline (60x20px) | Grid cells, KPI card secondary indicator |
| Progress | Progress bar / gauge | ETL progress, quota attainment, count completion |
| Relationship | Scatter plot | Supplier risk (volume vs variance) |

## Color Palette (Accessible)

### Primary Chart Colors (ordered by usage priority)
```
#0078D4  Fluent Blue (primary series)
#106EBE  Dark Blue (secondary series)
#2E7D32  Green (positive/OCC)
#E65100  Orange (cautionary/Aluminum)
#7B1FA2  Purple (tertiary/HDPE)
#BF360C  Brown (Copper)
#1565C0  Royal Blue (Mixed Paper)
#00838F  Teal (supplementary)
```

### Status Colors for Charts
```
Success/Positive: #107C10
Warning/Caution:  #FFB900
Error/Negative:   #D13438
Neutral/Baseline: #A19F9D
```

### Color-Blind Accessibility
- Never rely on color alone to convey meaning
- Use patterns/textures in addition to color: diagonal lines, dots, crosshatch
- Use labels directly on chart segments (not just legend)
- Test with Deuteranopia simulation
- Minimum 3:1 contrast between adjacent chart segments

## Material Grade Colors (Consistent Across All Charts)

| Material | Color | Hex |
|---|---|---|
| OCC | Green | #2E7D32 |
| Mixed Paper | Royal Blue | #1565C0 |
| SOP | Teal | #00838F |
| DLK | Amber | #F57C00 |
| ONP | Gray | #616161 |
| HDPE | Purple | #7B1FA2 |
| PET | Cyan | #0097A7 |
| Aluminum | Orange | #E65100 |
| Copper | Brown | #BF360C |

## Chart Sizing

| Context | Min Height | Recommended | Max Width |
|---|---|---|---|
| KPI sparkline (inline) | 20px | 20x60px | 80px |
| Grid cell sparkline | 24px | 24x100px | 120px |
| Dashboard card chart | 160px | 200px | Card width |
| Section chart | 240px | 280px | 100% |
| Hero chart (full-width) | 300px | 360px | 1440px |
| Full-page report chart | 400px | 480px | 100% |

### Responsive Rules
- Charts reflow to fill container width (never fixed pixel width)
- Below 600px: hide legend, show only on tap/hover
- Below 400px: reduce to sparkline representation
- Maintain aspect ratio on resize (use `responsiveContainer`)

## Interactive Behaviors

### Tooltips
- Hover data point: show tooltip with formatted value
- Tooltip format: `{label}: {value} ({change}%)` — e.g., "Apr 2026: $2.4M (+18%)"
- Tooltip has subtle shadow and arrow pointer
- Multi-series: tooltip shows all series values at that x-position
- Mobile: long-press to show tooltip (no hover)

### Drill-Down
- Click chart segment/bar: navigate to filtered detail view
- Click funnel stage: show DataGrid of items in that stage
- Click pie/donut segment: expand to show sub-categories
- Breadcrumb trail for drill-down path: "Revenue > By Material > OCC > By Account"

### Time Period Selector
- Segmented control above chart: "7D" / "30D" / "90D" / "1Y" / "Custom"
- Custom: date range picker
- Selected period persists across charts on same dashboard

### Zoom/Pan (large datasets)
- Time-series with >365 data points: enable horizontal scroll/zoom
- Brush selector at bottom for range selection
- "Reset Zoom" button when zoomed in

## KPI Cards

```
┌─────────────────────────────┐
│  Revenue MTD                │ ← Label: 13sp, secondary color
│  $2.4M                     │ ← Value: 32sp bold, primary color
│  ▲ +18% vs last month      │ ← Change: 14sp, green/red/gray
│  ~~~~~~~~ sparkline ~~~~~~~ │ ← Sparkline: 20px height, last 30 days
└─────────────────────────────┘
```

- Card: 280px min-width, 120px height, 16px padding
- Value: `font-variant-numeric: tabular-nums` for stable width
- Change indicator: up arrow green, down arrow red, sideways arrow gray
- Sparkline: no axis labels, no grid, just the line with area fill

## Chart States (5-State Rule Applied)

| State | Implementation |
|---|---|
| Loading | Skeleton matching chart dimensions. Show axis labels/ticks as skeleton. Shimmer animation. |
| Error | Chart area shows `MessageBar intent="error"` centered. "Failed to load chart data" + Retry. |
| Empty | Axis lines visible, no data points. Centered: "No data for this period" + adjust period CTA. |
| Populated | Normal chart render with animations. |
| Stale | Chart renders but shows amber badge: "Data from 3h ago" with refresh icon. |

## Animation

- Initial render: data points/bars animate in from baseline (500ms ease-out)
- Value change: smooth transition to new position (300ms)
- Hover: data point enlarges slightly (scale 1.2)
- Segment selection: selected segment slightly separates (donut) or brightens (bar)
- Sparkline: draw animation left-to-right on first render (400ms)

## Print / Export

- "Export Chart" button: PNG (screenshot), SVG (vector), CSV (raw data)
- Print: chart renders at full width, dark colors on white background, legend always visible
- PDF reports: charts embedded as vector SVG for crisp rendering at any zoom
