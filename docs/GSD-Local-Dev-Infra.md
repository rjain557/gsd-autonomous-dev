# GSD Local Dev Infrastructure & Per-Project Build/Deploy

> This workstation (`Administrator` on `TE-DC-AI-GSDAUTO`) has a local **SQL Server 2025** and **IIS**,
> so the GSD system can take a repo → develop → build the full app stack → deploy locally → verify,
> then hand the project off for alpha. Established 2026-06-11.

## 1. Local environment (verified)

| Component | State | Notes |
|---|---|---|
| **SQL Server 2025** | running, `localhost` (default instance `MSSQLSERVER`), v17.0.1115.1 | Connect: `sqlcmd -S localhost -E -C -I`. Existing `jian_*` DBs — **do not touch**. |
| **IIS** (W3SVC) | running | Sites: Default Web Site :80, JianAgentService :8765. |
| **.NET 10 SDK** | installed 2026-06-11 (`Microsoft.DotNet.SDK.10`) | builds `net10.0` (the new default stack). |
| **ASP.NET Core 10 Hosting Bundle** | installed (`Microsoft.DotNet.HostingBundle.10`) | provides **ANCM** so IIS can host Kestrel/ASP.NET Core apps. |
| **IIS URL Rewrite + ARR** | installed (`Microsoft.IIS.URLRewrite`, `…ApplicationRequestRouting`) | SPA fallback + reverse-proxy node/.NET backends behind subdomain paths. |
| node / npm / git | v24 / 11 / 2.54 | React/Vite builds, MCP servers, repo ops. |

## 2. AI-developer memory — `gsd_dev_memory` (local SQL)

A dedicated database the AI developer uses to **remember what it is building and how** — isolated from
`jian_*`. Schema: [`infra/sql/gsd-dev-memory.sql`](../infra/sql/gsd-dev-memory.sql).

| Table | Purpose |
|---|---|
| `Projects` | one per repo/subdomain (`Name`, `RepoPath`, `Subdomain`, `Status`, computed `AlphaHost`) |
| `Components` | the 5 deliverables per project (`Kind` = web\|api\|database\|mcp-server\|mcp-admin), host/port/health |
| `BuildRuns` | restore/build/test/publish/deploy/verify outcomes |
| `DevLog` | free-form "what I did / how" log, keyed to SDLC phase |
| `Decisions` | decision + rationale (mirrors orchestrator decision discipline) |

Use it every build: log a `DevLog` row per action, a `BuildRuns` row per phase, update `Components.Status`/`HealthUrl`.

## 3. Two-stage deployment convention

| Stage | Owner | Host pattern | Where | Trigger |
|---|---|---|---|---|
| **Dev** | rjain (this box) | **`<proj>.rjain.technijian.com`** (e.g. `myhr.rjain.technijian.com`, `myjian.rjain.technijian.com`) | local IIS + local SQL Server 2025 | active development |
| **Alpha** | handover to **ssingh@technijian.com** | **`alpha-<proj>.technijian.com`** (e.g. `alpha-myhr.technijian.com`) | test-lab servers | when dev is done — move site + database + all |

Owner wires the DNS/IIS routing for `*.rjain.technijian.com`; the GSD system creates one IIS **site per
project** bound to that host header. `gsd_dev_memory.Projects.AlphaHost` precomputes the handover target.

## 3.5 Automation — `infra/` scripts (implemented 2026-06-11)

The flow below is automated: [`infra/provision-project.ps1`](../infra/provision-project.ps1) (SQL DB +
IIS site/pool + SPA/`/mcp` rewrite + dev-memory registration; `-DryRun` to preview, `-EnableArr` for the
one-time host-wide ARR proxy enable) and [`infra/build-project.ps1`](../infra/build-project.ps1)
(build web/API/db/mcp-admin → deploy → health-check → log to `gsd_dev_memory`). See
[`infra/README.md`](../infra/README.md).

## 4. Per-project build → deploy → verify (the 5 components)

For a repo `<proj>`, on this box at `<proj>.rjain.technijian.com`:

| # | Component | Build | Host on IIS | Verify |
|---|---|---|---|---|
| 1 | **Web app** (React 18 + Fluent UI v9) | `npm ci && npm run build` (Vite) | static files at site root; **URL Rewrite SPA fallback** to `index.html` | page loads, no console errors (Playwright) |
| 2 | **API website** (ASP.NET Core .NET 10, Dapper + SPs) | `dotnet publish -c Release` | **ANCM** app at `/api` (or `api.<proj>.rjain…`) | `/api/health` 200; OpenAPI served |
| 3 | **SQL Server database** | run schema/SP scripts via `sqlcmd -E -C -I` | local SQL Server 2025 DB `<proj>` | SPs exist, `GRANT EXECUTE`, seed/smoke query |
| 4 | **MCP server** (node or .NET) | build; run as a Windows service / on a localhost port | **ARR reverse-proxy** at `/mcp` | MCP handshake / tool list responds |
| 5 | **MCP admin portal** (web) | build (static or .NET) | IIS app at `/mcp-admin` (or `mcp.<proj>.rjain…`) | portal loads + talks to the MCP server |

Each step writes a `BuildRuns` row; `verify` flips `Components.Status` to `healthy`/`broken` with `HealthUrl`+`LastCheckAt`.
Honors the stack defaults: .NET 10, SQL Server 2025 (native `JSON`/`REGEXP_*`), Fluent v9 — see
[`docs/GSD-Frontend-Stack-2026.md`](GSD-Frontend-Stack-2026.md). Quality gates from the Technijian SDLC
(SCG1, build, security, ≥80% coverage, ≥95% E2E) still apply before a project is "deployed".

## 5. Handover packaging (dev → alpha)

When dev is complete: export the DB (`.bacpac` via SqlPackage), publish the API + web artifacts, capture the
IIS site config + ARR rules, and bundle for the test lab to stand up at `alpha-<proj>.technijian.com`.
Record the handover as a `Decisions` row and a `DevLog` entry; notify ssingh@technijian.com.
