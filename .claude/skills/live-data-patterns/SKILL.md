---
name: live-data-patterns
description:
  Real-time and live data UI patterns for SignalR streaming, WebSocket feeds,
  and notification-driven interfaces. Use when building screens that display
  live-updating data — scale weight streaming, dispatch board updates, HITL
  notifications, GPS tracking, accounting sync status, or price tickers.
metadata:
  stack: React 18, @microsoft/signalr, @fluentui/react-components
  version: '1.0.0'
---

# Live Data & Real-Time UI Patterns

Patterns for interfaces that display continuously updating data via SignalR,
WebSocket, or SSE. Covers connection management, value change animation,
staleness detection, notification stacking, and reconnection UX.

## When to Activate

- Building a screen with SignalR or WebSocket data
- "Show live weight from the scale"
- "Real-time updates on the dispatch board"
- "HITL notification queue"
- "Live GPS fleet tracking"
- "Streaming price ticker"
- Reviewing connection handling or staleness UX

## Connection Status Indicator

Always show connection state in the toolbar or status bar:

```
┌─────────────────────────────────────────┐
│  ● Connected          (green dot)       │ Normal operation
│  ◐ Reconnecting...    (amber spinner)   │ Connection lost, auto-retrying
│  ○ Disconnected       (red dot)         │ All retries failed
│  ● Connected (read-only) (blue dot)     │ Connected but stale/degraded
└─────────────────────────────────────────┘
```

- Green dot: `colorStatusSuccessForeground1` — pulsing subtly (1s cycle)
- Amber spinner: `Spinner size="tiny"` + "Reconnecting..." text
- Red dot: `colorStatusDangerForeground1` + "Disconnected" + "Retry" link
- Position: top-right toolbar area, always visible, never hidden by scroll

## Reconnection Behavior

```tsx
const connection = new HubConnectionBuilder()
  .withUrl('/hubs/scale')
  .withAutomaticReconnect([0, 2000, 5000, 10000, 30000]) // immediate, 2s, 5s, 10s, 30s
  .build();

connection.onreconnecting(() => setStatus('reconnecting'));
connection.onreconnected(() => {
  setStatus('connected');
  showToast('Connection restored', 'success');
});
connection.onclose(() => setStatus('disconnected'));
```

### UX During Reconnection
- Data on screen: keep displaying last-known data (do NOT clear)
- Amber overlay bar at top: "Connection lost — reconnecting..."
- After reconnect: green toast "Connection restored" + refetch latest data
- After max retries fail: red `MessageBar` with "Manual retry" button
- Never show empty/error state just because connection dropped — show stale data with indicator

## Data Freshness Badge

For data that updates periodically (not streaming):

```
┌──────────────────────────────────────┐
│  Updated 3s ago  ●                   │ Fresh (green, < 30s)
│  Updated 2m ago  ●                   │ OK (green, < 5m)
│  Updated 15m ago ●                   │ Stale (amber, > 5m)
│  Updated 1h ago  ●                   │ Very stale (red, > 30m)
│  Last update failed ●  [Retry]       │ Error (red, with retry)
└──────────────────────────────────────┘
```

- Auto-increment timer: updates every second when < 60s, every minute when > 60s
- Threshold configurable per data type:
  - Scale weight: stale > 5 seconds (critical operational data)
  - Dispatch board: stale > 30 seconds
  - KPI dashboards: stale > 5 minutes
  - Price indexes: stale > 1 hour

## Value Change Animation

### Numeric Counter Roll (Scale Weight)
The most critical live element — scale weight display:

```
┌─────────────────────────────────────┐
│                                     │
│        45,280                       │ ← 120sp bold, monospace
│         lbs                         │ ← 24sp, secondary color
│                                     │
│  ● Stable    ○ Unstable             │ ← Stability indicator
└─────────────────────────────────────┘
```

- Each digit animates independently (roll up/down like mechanical counter)
- Digit change duration: 150ms per digit
- Stable indicator: green dot when weight hasn't changed for 2 seconds, amber when fluctuating
- Background color shift: subtle green tint when stable, neutral when unstable
- Font: monospace `tabular-nums` to prevent layout shift during digit changes

### Price Change Flash
For commodity price tickers and grid cells:

- Value increases: green flash background (200ms fade in, 1s hold, 500ms fade out)
- Value decreases: red flash background (same timing)
- No change: no animation
- Flash only on actual value change, not on re-render
- Arrow indicator: ▲ green for up, ▼ red for down, ▬ gray for flat

### Status Change Morph
When a status badge changes (e.g., Dispatched → In Transit):

- Old badge: fade out (150ms)
- New badge: fade in with scale-up from 0.8 to 1.0 (200ms)
- Color transition: smooth morph between old and new badge color (300ms)

## Notification Queue (SignalR Push)

### Toast Stack
```
┌──────────────────────────────────────┐
│  ⚠ HITL: AI wants to generate       │ ← Newest (top)
│     invoice for $45K. Review now.    │
│                              [View]  │
├──────────────────────────────────────┤
│  ✓ Settlement complete: 5 worksheets │ ← Previous
│     settled for $142,500             │
├──────────────────────────────────────┤
│  + 3 more notifications             │ ← Overflow indicator
└──────────────────────────────────────┘
```

- Max 3 visible toasts stacked (bottom-right on desktop, bottom-center on mobile)
- Newest on top
- Auto-dismiss: success = 5s, info = 8s, warning = persistent, error = persistent
- HITL notifications: always persistent (never auto-dismiss)
- Sound: optional chime for HITL requests (configurable in settings)
- Overflow: "+N more" link opens notification panel/drawer

### Notification Panel (Drawer)
- Triggered by bell icon in toolbar (badge shows unread count)
- Opens Drawer from right (360px width)
- List of all notifications: icon, title, description, timestamp, read/unread dot
- Filter: All / Unread / HITL / Scale / Dispatch
- "Mark all read" button in header
- Click notification: navigates to relevant screen

## Live Grid Updates

When DataGrid rows update via SignalR (dispatch board, sync queue):

### Row Insert Animation
- New row: slides in from top with 200ms ease, brief yellow highlight (1s fade)
- Position: insert at top (most recent) or maintain sort order

### Row Update Animation
- Changed cells: brief amber flash (200ms), then settle to new value
- Status badge change: morph animation (see above)
- If row currently selected/open in drawer: update drawer content live

### Row Remove Animation
- Row fades out (200ms) then collapses height (150ms)
- If filtered out (status change): animate out instead of instant disappear

## GPS / Map Live Updates

For fleet tracking and dispatch map:

- Vehicle position: smooth marker interpolation between GPS updates (not jumpy teleport)
- Update frequency: every 10 seconds
- Stale vehicle: marker fades to 50% opacity if no update in 60 seconds
- Trail line: optional dotted line showing last 10 positions
- Geo-fence trigger: marker pulses when entering/exiting a geo-fence zone
- Cluster markers: when zoomed out, group nearby vehicles with count badge

## Streaming Data Buffer

For high-frequency data (10Hz scale streaming):

- Buffer: accumulate updates, render at max 10fps (100ms throttle)
- Display: show latest value only (not every intermediate)
- History: optional scrolling chart showing last 30 seconds of values
- Pause: "Freeze" button stops UI updates but continues buffering (for inspection)
- Resume: "Resume" button catches up to latest value instantly

## Offline → Online Transition

When device regains connectivity:

1. Connection indicator: amber spinner → green dot (200ms transition)
2. Toast: "Back online" with green checkmark
3. Auto-sync: queued data uploads begin (show progress)
4. Data refresh: stale data on screen refreshes with brief shimmer animation
5. Notification catch-up: missed notifications load into notification panel
6. Conflict indicator: if server data differs from displayed data, show amber badge on affected rows
