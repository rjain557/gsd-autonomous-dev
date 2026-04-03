---
name: web-design-guidelines
description: Review UI code for Web Interface Guidelines compliance. Use when asked to "review my UI", "check accessibility", "audit design", "review UX", or "check my site against best practices".
metadata:
  author: vercel
  version: "1.0.0"
  argument-hint: <file-or-pattern>
---

# Web Interface Guidelines

Review files for compliance with Web Interface Guidelines.

## How It Works

1. Fetch the latest guidelines from the source URL below
2. Read the specified files (or prompt user for files/pattern)
3. Check against all rules in the fetched guidelines
4. Output findings in the terse `file:line` format

## Guidelines Source

Fetch fresh guidelines before each review:

```
https://raw.githubusercontent.com/vercel-labs/web-interface-guidelines/main/command.md
```

Use WebFetch to retrieve the latest rules. The fetched content contains all the rules and output format instructions.

## Usage

When a user provides a file or pattern argument:
1. Fetch guidelines from the source URL above
2. Read the specified files
3. Apply all rules from the fetched guidelines
4. Output findings using the format specified in the guidelines

If no files specified, ask the user which files to review.

## Fluent UI v9 Accessibility Checklist

When reviewing Fluent UI v9 components, additionally verify:

| Rule | Check |
|---|---|
| ARIA-01 | All interactive elements have `aria-label` or visible label |
| ARIA-02 | `role` attributes match element semantics |
| ARIA-03 | Focus order follows visual order (no `tabIndex > 0`) |
| ARIA-04 | Color contrast ≥ 4.5:1 for text, ≥ 3:1 for UI components |
| ARIA-05 | All form inputs paired with `<Label>` from `@fluentui/react-components` |
| ARIA-06 | Dialog/Drawer has `aria-labelledby` pointing to title |
| ARIA-07 | Toast/Alert uses `role="alert"` for errors, `role="status"` for info |
| ARIA-08 | Images have meaningful `alt` text (empty `alt=""` for decorative) |
| ARIA-09 | Keyboard-navigable: all actions reachable via Tab + Enter/Space |
| ARIA-10 | No keyboard traps outside of Modal/Dialog (managed by Fluent internally) |
