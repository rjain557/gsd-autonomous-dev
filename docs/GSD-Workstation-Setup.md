# GSD v4.1 — New Workstation Setup Guide

Complete instructions to set up a fully functional GSD autonomous development environment on a new Windows workstation. Total time: ~15 minutes.

## Prerequisites

| Requirement | Minimum Version | Check Command |
|---|---|---|
| Windows 10/11 | 10.0.19041+ | `winver` |
| Git | 2.40+ | `git --version` |
| Node.js | 18+ | `node --version` |
| npm | 9+ | `npm --version` |
| Python | 3.10+ | `python --version` |
| pip | 23+ | `pip --version` |

## Step 1: Clone the Repository

```bash
cd C:\vscode
git clone https://github.com/rjain557/gsd-autonomous-dev.git
cd gsd-autonomous-dev\gsd-autonomous-dev
```

## Step 2: Install Node.js Dependencies

```bash
npm install
```

This installs: TypeScript, Anthropic SDK, Playwright, proper-lockfile, uuid, docx.

Verify: `npx tsc --noEmit` should print nothing (0 errors).

## Step 3: Install Playwright Browser

```bash
npx playwright install chromium
```

Downloads headless Chromium (~112 MB) for browser-level E2E testing.

## Step 4: Install Python Tools

### Add Python Scripts to PATH (one-time)

```powershell
# Check current PATH
[System.Environment]::GetEnvironmentVariable('Path', 'User')

# Add Python Scripts directory (adjust version number if different)
$pythonScripts = "$env:APPDATA\Python\Python314\Scripts"
if (Test-Path $pythonScripts) {
    $currentPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    if ($currentPath -notlike "*$pythonScripts*") {
        [System.Environment]::SetEnvironmentVariable('Path', "$currentPath;$pythonScripts", 'User')
        Write-Host "Added $pythonScripts to PATH. Restart terminal to take effect."
    }
}
```

**Restart your terminal** after adding to PATH.

### Install Graphify (Knowledge Graph)

```bash
pip install graphifyy
```

Verify: `graphify --help` should show usage info.

### Install Semgrep (SAST Security Scanner)

```bash
pip install semgrep
```

Verify: `semgrep --version` should print version (1.157.0+).

## Step 5: Install Claude Code Integration

### Graphify Hook

```bash
cd C:\vscode\gsd-autonomous-dev\gsd-autonomous-dev
graphify claude install
graphify install
```

This adds:
- `## graphify` section to `CLAUDE.md`
- PreToolUse hook in `.claude/settings.json` that redirects file searches to the knowledge graph

### Build the Knowledge Graph

From within Claude Code, run:

```
/graphify .
```

Or from the command line:

```bash
graphify .
```

This generates `graphify-out/GRAPH_REPORT.md`, `graph.json`, and `graph.html`.

## Step 5b: Install GitNexus (Code Intelligence Engine)

GitNexus provides blast radius analysis, execution flow tracing, and impact scoring. Runs alongside Graphify — they serve complementary purposes.

```bash
npm install -g gitnexus
```

### Index the Repository

```bash
cd C:\vscode\gsd-autonomous-dev\gsd-autonomous-dev
gitnexus analyze
```

This creates `.gitnexus/` with the indexed graph (830+ nodes, 1600+ edges, 47 execution flows).

### Configure MCP + Hooks

```bash
gitnexus setup
```

This auto-configures:
- MCP server in global Claude Code settings
- PreToolUse hook (enriches searches with graph context)
- PostToolUse hook (auto-reindex after git commits)
- 7 skills in `~/.claude/skills/gitnexus/`

### Verify

```bash
gitnexus --version
# Expected: 1.5.3+
```

The `.gitnexus/` directory is gitignored (regenerated per-workstation).

## Step 6: Install GitHub MCP Server

```bash
npm install -g @modelcontextprotocol/server-github
```

### Configure Token

1. Get your GitHub PAT from the keys file:
   `C:\Users\rjain\OneDrive - Technijian, Inc\Documents\VSCODE\keys\github-mcp.md`

2. Set it in `.claude/settings.json` (already configured in the repo):
   ```json
   {
     "mcpServers": {
       "github": {
         "env": {
           "GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_YOUR_TOKEN"
         }
       }
     }
   }
   ```

3. Or set as system environment variable:
   ```powershell
   [System.Environment]::SetEnvironmentVariable('GITHUB_PERSONAL_ACCESS_TOKEN', 'ghp_YOUR_TOKEN', 'User')
   ```

## Step 7: Install AI CLI Tools

### Claude Code (Required)

Install Claude Code extension in VS Code, or install the CLI:

```bash
npm install -g @anthropic-ai/claude-code
```

Authenticate: `claude auth`

### Codex CLI (Optional — fallback agent)

```bash
npm install -g @openai/codex
codex auth
```

### Gemini CLI (Optional — fallback agent)

```bash
npm install -g @google/gemini-cli
gemini auth
```

## Step 8: Install Legacy PowerShell Engine (Optional)

Only needed if running the v1.5/v2/v3 PowerShell pipelines:

```powershell
cd C:\vscode\gsd-autonomous-dev\gsd-autonomous-dev
powershell -ExecutionPolicy Bypass -File scripts\install-gsd-all.ps1
```

## Verification Checklist

Run these checks to confirm everything works:

```bash
cd C:\vscode\gsd-autonomous-dev\gsd-autonomous-dev

# 1. TypeScript compiles
npx tsc --noEmit
# Expected: no output (0 errors)

# 2. Dependencies load
node -e "['uuid','proper-lockfile','@anthropic-ai/sdk','playwright'].forEach(d => { try { require(d); console.log('OK:', d); } catch { console.log('FAIL:', d); } })"
# Expected: all OK

# 3. Semgrep works
semgrep --version
# Expected: 1.157.0 or higher

# 4. Playwright browser
node -e "require('playwright').chromium.launch({headless:true}).then(b => { console.log('OK: Chromium'); b.close(); })"
# Expected: OK: Chromium

# 5. Graphify
graphify --help
# Expected: Usage info

# 6. Graphify knowledge graph exists
ls graphify-out/GRAPH_REPORT.md
# Expected: file exists (run /graphify . if missing)

# 7. GitNexus index exists
gitnexus --version
ls .gitnexus/
# Expected: version 1.5.3+, .gitnexus/ directory exists (run gitnexus analyze if missing)

# 8. Pipeline dry run (requires Claude CLI)
npx ts-node src/index.ts pipeline run --trigger manual --dry-run
# Expected: preflight passes, pipeline initializes
```

## Quick Reference Card

| Task | Command |
|---|---|
| Run pipeline | `npx ts-node src/index.ts pipeline run --trigger manual` |
| Dry run (no deploy) | `npx ts-node src/index.ts pipeline run --dry-run` |
| Resume from stage | `npx ts-node src/index.ts pipeline run --from-stage gate` |
| Type check | `npx tsc --noEmit` |
| Run tests | `npm test` |
| Run evals | `npm run evals` |
| Build knowledge graph | `/graphify .` (in Claude Code) |
| Update graph | `/graphify . --update` |
| Query graph | `graphify query "what connects X to Y?"` |

## Directory Structure (What You Get)

```
gsd-autonomous-dev/
  src/                    # V4.1 TypeScript harness (orchestrator, 7 agents, evals)
  memory/                 # Obsidian vault (agent configs, knowledge, architecture)
  graphify-out/           # Knowledge graph (GRAPH_REPORT.md, graph.json, graph.html)
  .claude/settings.json   # Graphify hook + GitHub MCP config
  v2/                     # Legacy V2 pipeline (PowerShell)
  v3/                     # Legacy V3 pipeline (PowerShell)
  scripts/                # Legacy install + patch scripts
  docs/                   # All documentation
  test-fixtures/          # Eval test data
  node_modules/           # (generated by npm install)
```

## Troubleshooting

| Problem | Solution |
|---|---|
| `semgrep: command not found` | Restart terminal after adding Python Scripts to PATH |
| `pysemgrep not found` | Same fix — PATH must include Python Scripts dir |
| `graphify: command not found` | Same fix — Python Scripts dir on PATH |
| `tsc: command not found` | Use `npx tsc` or `./node_modules/.bin/tsc` |
| `ENOENT: claude` in preflight | Install Claude Code CLI and authenticate |
| `Chromium not found` | Run `npx playwright install chromium` |
| Graphify graph missing | Run `/graphify .` from Claude Code |
| GitHub MCP not connecting | Set `GITHUB_PERSONAL_ACCESS_TOKEN` env var |
| TypeScript errors after pull | Run `npm install` (new dependencies may have been added) |
| Pipeline paused | Check `memory/sessions/alerts.md`, resume with `--from-stage` |
