---
type: knowledge
description: V6 golden-rules-as-code — Semgrep and ESLint rules generated from CLAUDE.md conventions
version: 6.0.0
---

# Golden Rules as Code

QualityGateAgent runs every `.yml` rule in this directory alongside the standard Semgrep ruleset. Rules encode CLAUDE.md conventions (T-SQL naming, tenant isolation, Fluent UI patterns, etc.) as executable checks.

## Structure

- `*.yml` — Semgrep rules
- `*.eslint.js` — ESLint rule stubs (future)
- `meta.yml` — rule registry metadata (severity, enabled, owner)

## Severity Semantics

- `ERROR` — fails the quality gate
- `WARNING` — reported but does not fail the gate
- `INFO` — logged only

## Authoring a New Rule

1. Write a `.yml` file with Semgrep syntax
2. Test with `semgrep --config=memory/knowledge/rules/my-rule.yml <path>`
3. Add metadata entry to `meta.yml`
4. Commit

## Current Rules

| File | Category | Severity | What it catches |
|------|----------|----------|-----------------|
| `tsql-naming.yml` | Backend | WARNING | Stored procs not following `usp_Entity_Action` convention |
| `tsql-no-select-star.yml` | Backend | ERROR | `SELECT *` in stored procs |
| `tsql-tenant-filter.yml` | Backend | ERROR | Queries on tenant-scoped tables without `WHERE TenantId` filter |
| `tsql-nvarchar-max.yml` | Backend | WARNING | `NVARCHAR(MAX)` parameters (prefer explicit length) |
| `react-no-tabindex-positive.yml` | Frontend | ERROR | `tabIndex > 0` on React components |
