# GSD infra — local provision / build / deploy automation

Scripts that turn this box (local **SQL Server 2025** + **IIS** + **.NET 10 SDK/ANCM/URL-Rewrite/ARR**)
into the dev host for every GSD AI-Dev project. Convention: dev at `<proj>.rjain.technijian.com`,
handover to ssingh@technijian.com as `alpha-<proj>.technijian.com` (see
[docs/GSD-Local-Dev-Infra.md](../docs/GSD-Local-Dev-Infra.md)).

| Script | What it does |
|---|---|
| `deploy-lib.ps1` | Shared helpers: `Invoke-Sql` (sqlcmd `-E -C -I -b`, temp-file input), dev-memory writers (`Write-DevLog`, `Write-BuildRun`, `Set-ComponentStatus`), IIS existence checks, dotnet resolution. Dot-sourced by the others. |
| `provision-project.ps1` | One-time per project: SQL DB `[<proj>]` + register project & 5 components in `gsd_dev_memory` + site dirs under `C:\inetpub\gsd\<proj>` + IIS app pool/site bound to `<proj>.rjain.technijian.com:80` with `/api` + `/mcp-admin` apps + `web.config` (SPA fallback, `/mcp` → `localhost:<port>` rewrite). **Idempotent.** |
| `build-project.ps1` | Per build: web `npm ci && build` → site root; API `dotnet publish` (.NET 10) → `/api`; `db/*.sql` → project DB; mcp-admin build → `/mcp-admin`; health-checks web+api via Host header; logs every phase to `BuildRuns`, flips `Components.Status`, sets project `deployed`. |
| `sql/gsd-dev-memory.sql` | Schema for the `gsd_dev_memory` AI-developer memory DB (Projects, Components, BuildRuns, DevLog, Decisions). Idempotent. |

## Usage

```powershell
# preview (no changes)
./infra/provision-project.ps1 -Project myhr -RepoPath D:\VSCode\myhr -DryRun

# provision for real (creates DB + IIS site; needs admin shell)
./infra/provision-project.ps1 -Project myhr -RepoPath D:\VSCode\myhr

# one-time host-wide: ARR proxy enable (required once for /mcp reverse-proxy)
./infra/provision-project.ps1 -Project myhr -RepoPath D:\VSCode\myhr -EnableArr

# build + deploy + verify from the repo
./infra/build-project.ps1 -Project myhr
```

## Safety notes

- Provisioning **modifies shared IIS state** (new site/binding). Run it deliberately; `-DryRun` first.
- `-EnableArr` flips **server-wide** `system.webServer/proxy` — one-time, host-wide; off by default.
- Project DBs are isolated per project; `jian_*` databases are never touched.
- Repo layout conventions discovered by `build-project.ps1`: web at `web|client|frontend|.`(package.json),
  API = first `*.csproj` using `Microsoft.NET.Sdk.Web`, SQL at `db|database|sql`, admin at `mcp-admin|admin`,
  MCP server at `mcp-server|mcp` (run as a service behind the `/mcp` rewrite; not auto-daemonized).
- PowerShell 5.1 gotcha: keep these scripts **ASCII-only inside strings** (UTF-8-no-BOM + em-dash
  decodes as a smart quote and breaks parsing).

## Memory

Everything lands in `gsd_dev_memory` on `localhost` (connect `sqlcmd -S localhost -E -C -I`):
projects, per-component status/health, build runs with durations, dev log, decisions. Query it at the
start of a session to recall state: `SELECT * FROM dbo.Projects; SELECT TOP 20 * FROM dbo.DevLog ORDER BY Id DESC;`
