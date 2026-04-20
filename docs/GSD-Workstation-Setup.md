# GSD V6 — Complete Workstation Setup Guide

Everything needed to run the GSD autonomous development pipeline on a new Windows workstation. Total time: ~20 minutes.

## Prerequisites

| Requirement | Minimum Version | Check Command | Install |
|---|---|---|---|
| Windows 10/11 | 10.0.19041+ | `winver` | - |
| Git | 2.40+ | `git --version` | `winget install Git.Git` |
| Node.js | 18+ | `node --version` | `winget install OpenJS.NodeJS.LTS` |
| npm | 9+ | `npm --version` | Comes with Node.js |
| Python | 3.10+ | `python --version` | `winget install Python.Python.3.14` |
| pip | 23+ | `pip --version` | Comes with Python |
| Docker Desktop | 4.0+ | `docker --version` | `winget install Docker.DockerDesktop` |

Docker is optional but required for Shannon penetration testing.

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

Installs: TypeScript, Anthropic SDK, Playwright, proper-lockfile, uuid, docx.

Verify: `npx tsc --noEmit` — should print nothing (0 errors).

## Step 3: Install Playwright Browser

```bash
npx playwright install chromium
```

Downloads headless Chromium (~112 MB) for browser-level E2E testing.

## Step 4: Add Python Scripts to PATH

```powershell
# Find your Python Scripts directory
$pythonScripts = "$env:APPDATA\Python\Python314\Scripts"

# Add to PATH permanently (one-time)
$currentPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
if ($currentPath -notlike "*$pythonScripts*") {
    [System.Environment]::SetEnvironmentVariable('Path', "$currentPath;$pythonScripts", 'User')
    Write-Host "Added to PATH. RESTART YOUR TERMINAL now."
}
```

**Restart your terminal after this step.**

## Step 5: Install Python Tools

```bash
pip install graphifyy semgrep
```

Verify:

```bash
graphify --help     # Should show usage
semgrep --version   # Should show 1.157.0+
```

## Step 6: Install Global npm Tools

```bash
npm install -g gitnexus @modelcontextprotocol/server-github
```

## Step 7: Install AI CLI Tools

### Claude Code (REQUIRED)

Install the Claude Code extension in VS Code, or:

```bash
npm install -g @anthropic-ai/claude-code
claude auth
```

### Codex CLI (recommended — fallback agent)

```bash
npm install -g @openai/codex
codex auth
```

### Gemini CLI (recommended — fallback agent)

```bash
npm install -g @google/gemini-cli
gemini auth
```

## Step 8: Configure Claude Code Integrations

Run these from the project root (`gsd-autonomous-dev/gsd-autonomous-dev`):

```bash
# Graphify — knowledge graph + PreToolUse hook
graphify claude install
graphify install

# GitNexus — code intelligence + blast radius
gitnexus analyze
gitnexus setup

# Context7 — live library docs MCP
claude mcp add context7 -- npx -y @upstash/context7-mcp@latest

# OWASP Security Skill
npx -y skills add agamm/claude-code-owasp -y

# Shannon Lite — penetration testing
npx -y skills add unicodeveloper/shannon -y
```

What this step wires up:

- Graphify graph generation and the repo-local search reminder in `.claude/settings.json`.
- The GitNexus local index in `.gitnexus/` plus the repo skill pack under `.claude/skills/gitnexus/`.
- Context7 as a workstation MCP server for live library documentation.
- OWASP and Shannon as host-installed security skills, while the repository keeps reference copies under `.agents/skills/`.

## Step 9: Build Knowledge Graphs

```bash
# Graphify knowledge graph (from Claude Code)
# /graphify .
# Or from CLI:
graphify .

# GitNexus is already indexed from Step 8
```

## Step 10: Configure Secrets

### GitHub PAT

The repo already commits the GitHub MCP server configuration in `.claude/settings.json`. Supply the token through the environment instead of editing the committed file:

```powershell
[System.Environment]::SetEnvironmentVariable('GITHUB_PERSONAL_ACCESS_TOKEN', 'ghp_YOUR_TOKEN', 'User')
```

Optional variables:

- `GSD_LLM_MODE=cli` is the default and does not need to be set unless you are overriding to `sdk`.
- `ANTHROPIC_API_KEY` is only needed for SDK mode or for Shannon flows that are not using Claude Code OAuth.

## Verification Checklist

Run all checks to confirm everything works:

```bash
cd C:\vscode\gsd-autonomous-dev\gsd-autonomous-dev

# 1. TypeScript compiles
npx tsc --noEmit
# Expected: no output (0 errors)

# 2. Node dependencies load
node -e "['uuid','proper-lockfile','@anthropic-ai/sdk','playwright'].forEach(d => { try { require(d); console.log('OK:', d); } catch { console.log('FAIL:', d); } })"
# Expected: all OK

# 3. Semgrep
semgrep --version
# Expected: 1.157.0+

# 4. Playwright browser
node -e "require('playwright').chromium.launch({headless:true}).then(b => { console.log('OK: Chromium'); b.close(); })"
# Expected: OK: Chromium

# 5. Graphify
graphify --help
# Expected: Usage info

# 6. GitNexus
gitnexus --version
# Expected: 1.5.3+

# 7. Knowledge graphs exist
ls graphify-out/GRAPH_REPORT.md
ls .gitnexus/
# Expected: both exist (rebuild with /graphify . and gitnexus analyze if missing)

# 8. Repo skill packs are present
find .claude/skills -maxdepth 3 -name SKILL.md
find .agents/skills -maxdepth 2 -name SKILL.md
# Expected: GitNexus + SQL/UI skills under .claude/skills, OWASP + Shannon under .agents/skills

# 9. Repo hook + MCP config exists
rg -n "PreToolUse|mcpServers|github" .claude/settings.json
# Expected: Graphify PreToolUse reminder and GitHub MCP config

# 10. GSD pipeline dry run (requires Claude CLI)
npx ts-node src/index.ts run full --help
# Expected: shows milestone list

# 11. GSD status
npx ts-node src/index.ts status
# Expected: shows project status or "No SDLC state found"
```

## Quick Reference Card

| Task | Command |
|---|---|
| **SDLC lifecycle** | `gsd run full --project "X" --description "Y"` |
| Requirements only | `gsd run requirements --project "X" --description "Y"` |
| After Figma upload | `gsd run figma-uploaded --design-path design/web/v1/src/` |
| Generate contracts | `gsd run contracts` |
| Code pipeline | `gsd run blueprint` |
| Deploy to alpha | `gsd run deploy` |
| Check progress | `gsd status` |
| With review gates | `gsd run requirements --review` |
| Pipeline only | `npx ts-node src/index.ts pipeline run --trigger manual` |
| Dry run | `npx ts-node src/index.ts pipeline run --dry-run` |
| Type check | `npx tsc --noEmit` |
| Run tests | `npm test` |
| Build knowledge graph | `/graphify .` (in Claude Code) |
| Reindex GitNexus | `gitnexus analyze` |
| Security pentest | `/shannon` (in Claude Code, needs Docker) |

## Complete Tool Inventory

| Tool | Type | Purpose | Cost |
|---|---|---|---|
| Claude Code | AI CLI | Primary reasoning agent | $200/mo subscription ($0 marginal) |
| Codex CLI | AI CLI | Code generation fallback | $200/mo subscription ($0 marginal) |
| Gemini CLI | AI CLI | Research/synthesis fallback | $20/mo subscription ($0 marginal) |
| Graphify | Knowledge graph | Codebase structure, community detection | Free (MIT) |
| GitNexus | Code intelligence | Blast radius, execution flows, impact | Free (PolyForm NC) |
| Context7 | MCP server | Live library docs (.NET, React, etc.) | Free (1000 req/mo) |
| Semgrep | SAST scanner | 2000+ security rules | Free (OSS) |
| Playwright | Browser testing | Headless Chromium E2E | Free (Apache 2.0) |
| OWASP Skill | Security patterns | OWASP Top 10, ASVS 5.0 | Free (MIT) |
| Shannon Lite | Pentesting | White-box vuln testing, 96% success | Free (runs on your LLM subscription) |
| GitHub MCP | Automation | PR creation, issue tracking | Free (needs PAT) |

**Total monthly cost: ~$420 (3 subscriptions). Per-run marginal cost: $0.**

## Repo-Bundled Skill Packs

These live in the repository after clone and help explain why the 4.2 setup is larger than "just the vault":

| Location | Contents |
|---|---|
| `.claude/skills/` | GitNexus skill pack plus `sql-expert`, `sql-performance-optimizer`, `react-ui-design-patterns`, `composition-patterns`, and `web-design-guidelines` |
| `.agents/skills/` | `owasp-security` and `shannon` reference skills used by the security workflow |

Some workstations also mirror the `.agents/skills/` entries into `.claude/skills/` through local symlinks. The repository source of truth remains the paths above.

## Directory Structure

```
gsd-autonomous-dev/
  src/                    # V6 TypeScript harness
    harness/              #   Orchestrators, types, hooks, vault adapter
    agents/               #   14 agents (8 pipeline + 6 SDLC)
    evals/                #   Test framework
  memory/                 # Obsidian vault
    agents/               #   14 agent vault notes
    knowledge/            #   Quality gates, deploy config, tools reference
    architecture/         #   Task graph, state schema, hook registry
  .claude/skills/         # Project skill pack (gitnexus, SQL, React UI, composition, web design)
  .agents/skills/         # Shared/security skills (OWASP, Shannon)
  .claude/settings.json   # Graphify hook + GitHub MCP config
  graphify-out/           # Knowledge graph output (per-machine)
  .gitnexus/              # GitNexus index (per-machine)
  docs/                   # Documentation
  test-fixtures/          # Eval test data
  v2/, v3/                # Legacy pipelines
  scripts/                # Legacy PowerShell scripts
```

## Troubleshooting

| Problem | Solution |
|---|---|
| `semgrep: command not found` | Restart terminal after Step 4 (PATH update) |
| `pysemgrep not found` | Same — Python Scripts not on PATH |
| `graphify: command not found` | Same — Python Scripts not on PATH |
| `tsc: command not found` | Use `npx tsc` instead |
| `ENOENT: claude` in preflight | Install Claude Code CLI: `npm install -g @anthropic-ai/claude-code` |
| `Chromium not found` | Run `npx playwright install chromium` |
| Graphify graph missing | Run `/graphify .` from Claude Code |
| GitNexus stale | Run `gitnexus analyze` |
| GitHub MCP not connecting | Set `GITHUB_PERSONAL_ACCESS_TOKEN` env var |
| TypeScript errors after pull | Run `npm install` |
| Shannon won't run | Install Docker Desktop: `winget install Docker.DockerDesktop` |
| Pipeline paused | Run `gsd status` to see where you are, then resume |
| Context7 rate limited | Free tier: 1000 req/month, 60 req/hour |
