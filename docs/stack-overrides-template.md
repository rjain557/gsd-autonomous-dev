# Stack Overrides Template

> **Copy this template to `docs/gsd/stack-overrides.md` in your target project**
> (not in the GSD repo). GSD v6.1.0+ will read it at the start of every SDLC /
> Pipeline run via `getProjectStackContext()` and honor the declared values.

---

## When to create this file

Create `docs/gsd/stack-overrides.md` in your target project when any of these
are true:

- The project targets a .NET version other than `.NET 8`
- The project uses `.slnx` (XML-based) solution files
- The project has a declared mobile target
- The project needs a compliance frameworks list different from GSD's defaults (`SOC 2, HIPAA, PCI, GDPR`)

If none of these apply, **you do not need this file.** GSD defaults to .NET 8 and the standard stack.

---

## Full Example (Technijian Platform / net9.0)

```markdown
# Stack Overrides — <Project Name>

| Field                  | Value                      |
|------------------------|----------------------------|
| Backend framework      | net9.0                     |
| Backend SDK            | .NET 10 SDK                |
| Solution file format   | slnx                       |
| Data access            | Dapper + stored procedures |
| Database               | SQL Server                 |
| Frontend framework     | React 18                   |
| Frontend UI library    | Fluent UI v9               |
| Frontend build tool    | Vite                       |
| Mobile framework       | React Native               |
| Mobile toolchain       | Expo managed workflow      |
| Remote agent language  | Go                         |
| Compliance             | SOC 2, HIPAA, PCI, GDPR    |
```

## Minimal Example (only override backend)

```markdown
# Stack Overrides

| Field             | Value  |
|-------------------|--------|
| Backend framework | net9.0 |
```

Every field is optional — unspecified fields inherit GSD defaults (`.NET 8`, `React 18`, `Fluent UI v9`, `Vite`, etc.). Only declare what you are overriding.

---

## Accepted values per field

| Field | Accepted values | Default |
|-------|-----------------|---------|
| Backend framework | `net8.0` / `net9.0` / `net10.0` (also tolerates `.NET 9`, `net9`, `NET9` — see `normalizeFramework`) | `net8.0` |
| Backend SDK | Free-form string, e.g. `.NET 10 SDK` | `.NET 8 SDK` |
| Solution file format | `sln` / `slnx` | `sln` |
| Data access | Free-form, e.g. `Dapper + stored procedures` | `Dapper + stored procedures` |
| Database | Free-form, e.g. `SQL Server` | `SQL Server` |
| Frontend framework | Free-form, e.g. `React 18` | `React 18` |
| Frontend UI library | Free-form, e.g. `Fluent UI v9` | `Fluent UI v9` |
| Frontend build tool | Free-form, e.g. `Vite` | `Vite` |
| Mobile framework | Free-form, or `None` | `null` |
| Mobile toolchain | Free-form, or `None` | `null` |
| Remote agent language | Free-form, or `None` | `null` |
| Compliance | Comma-separated list | `SOC 2, HIPAA, PCI, GDPR` |

---

## How GSD uses this file

1. At every `gsd run <milestone>`, the orchestrator calls `getProjectStackContext(projectRoot)`.
2. If `docs/gsd/stack-overrides.md` exists, its fields override defaults. Otherwise defaults apply and the context is marked `source: 'default'`.
3. The resolved context is attached to every agent via `BaseAgent.setProjectStackContext()`.
4. Every agent's system prompt gains a `PROJECT STACK CONTEXT` block.
5. Agents honor the declared values when generating `.csproj` `<TargetFramework>`, SDK references, architecture prose, `package.json` dependencies, and compliance requirements.
6. **Post-phase**: the stack-leak validator scans every generated artifact for framework leaks (e.g. `net8.0` appearing when the project declared `net9.0`). Findings are logged to `memory/observability/gate-results/` and as decisions in `state.db`.

---

## Verifying your override

From the GSD repo, point at your target project and inspect the resolved context:

```bash
gsd query stack --project-root ../tech-web-myitsm
```

Expected output (abbreviated):

```json
{
  "subject": "stack",
  "ok": true,
  "data": {
    "backendFramework": "net9.0",
    "backendSdk": ".NET 10 SDK",
    "solutionFileFormat": "slnx",
    "source": "override",
    "resolvedFromPath": "<absolute path to stack-overrides.md>"
  }
}
```

If `source: 'default'` appears, the file was not found at the expected path — double-check it lives at `<projectRoot>/docs/gsd/stack-overrides.md`.

---

## CI integration: the leak validator

After a GSD run produces artifacts (e.g. `docs/sdlc/phase-b-architecture-pack.json`), run the standalone validator:

```bash
gsd validate-stack --project-root . --fail-on-findings
```

Exit code 0 = no leaks. Exit code 1 = one or more generated files contain a forbidden framework value. Add this to your CI pipeline as a defense-in-depth check for LLM-generated artifacts that contradict the declared stack.

---

## Backward compatibility

Projects created on GSD v6.0.0 and earlier continue to work unchanged — no override file is required. The default stack remains `.NET 8 + React 18 + Fluent UI v9 + SQL Server + SOC 2/HIPAA/PCI/GDPR`.

To opt into v6.1.0+ behavior, just add the file. No flag, no migration, no breaking change.
