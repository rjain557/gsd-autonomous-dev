# Graphify and Augmentation Stack — Installation Guide

This guide started as the Graphify setup doc. Under V6 it covers the wider augmentation layer that ships alongside Graphify: GitNexus, Semgrep, Playwright, MCP servers, and security skills.

## What Graphify Does

Graphify converts the GSD codebase (TypeScript + PowerShell + vault markdown) into a queryable knowledge graph using Tree-sitter AST parsing and Claude semantic extraction. This gives all pipeline agents structural navigation instead of flat file scanning, achieving up to 71x token reduction.

In the V6 stack, Graphify works alongside GitNexus:

- Graphify explains community structure, god nodes, and graph-level neighborhood.
- GitNexus explains symbol context, execution flows, and blast radius before edits.

**GSD pipeline integration points:**
- BlueprintAnalysisAgent reads `GRAPH_REPORT.md` for architectural god nodes before drift detection
- CodeReviewAgent uses graph neighbors to trace change impact
- RemediationAgent uses shortest-path to find root causes
- Orchestrator passes compact graph context across model switches

## Prerequisites

- Python 3.10+ (`python --version`)
- pip (`pip --version`)
- Claude Code CLI installed and authenticated
- Node.js 18+ (already required by GSD V6)
- Docker Desktop 4.0+ if you plan to use Shannon pentesting

## Installation (New Workstation)

### Step 1: Install Graphify

```bash
pip install graphifyy
```

If the script directory is not on PATH, add it:

**Windows (PowerShell):**
```powershell
$env:PATH += ";$env:APPDATA\Python\Python314\Scripts"
# To make permanent, add to System Environment Variables:
# Settings > System > About > Advanced system settings > Environment Variables > Path > Edit > New
# Add: %APPDATA%\Python\Python314\Scripts
```

**macOS/Linux:**
```bash
# Usually already on PATH, but if not:
export PATH="$PATH:$HOME/.local/bin"
echo 'export PATH="$PATH:$HOME/.local/bin"' >> ~/.bashrc
```

### Step 2: Install Claude Code Integration

```bash
cd /path/to/gsd-autonomous-dev
graphify claude install
graphify install
```

This does two things:
1. Adds a `## graphify` section to `CLAUDE.md` with rules for graph-first navigation
2. Registers a `PreToolUse` hook in `.claude/settings.json` that intercepts Glob/Grep and redirects Claude to the knowledge graph

### Step 3: Build the Knowledge Graph

```bash
cd /path/to/gsd-autonomous-dev
# From within Claude Code:
/graphify .
```

Or from the command line:
```bash
graphify .
```

This generates:
- `graphify-out/GRAPH_REPORT.md` — god nodes, communities, structural summary
- `graphify-out/graph.json` — queryable graph data
- `graphify-out/graph.html` — interactive visualization
- `graphify-out/cache/` — SHA256 cache for incremental updates

### Step 4: Install Git Hooks (Optional)

Auto-rebuild the graph on git commits/checkouts:

```bash
graphify hook install
```

## Updating the Graph

After making code changes:

```bash
# Incremental update (only changed files):
/graphify . --update

# Full rebuild:
/graphify .

# Watch mode (auto-sync on file changes):
/graphify . --watch
```

## Querying the Graph

```bash
# Find connections between components:
graphify query "what connects Orchestrator to DeployAgent?"

# With specific graph file:
graphify query "what are the god nodes?" --graph graphify-out/graph.json
```

## MCP Server (Advanced)

Expose the graph as an MCP server for programmatic tool access:

```bash
python -m graphify.serve graphify-out/graph.json
```

This provides tools: `query_graph`, `get_node`, `get_neighbors`, `shortest_path`.

## Uninstallation

```bash
graphify claude uninstall    # Remove CLAUDE.md section + hook
graphify hook uninstall      # Remove git hooks
pip uninstall graphifyy      # Remove package
rm -rf graphify-out/         # Remove generated graph
```

## GitNexus Code Intelligence

Install:

```bash
npm install -g gitnexus
gitnexus analyze
gitnexus setup
```

What it adds:

- Symbol-aware context and execution-flow tracing from `.gitnexus/`
- Blast radius checks before edits
- Safe rename workflow instead of text search and replace

Operational rule of thumb:

- Use Graphify to understand architecture and neighborhood.
- Use GitNexus to understand caller impact and flow-level consequences.

## Troubleshooting

| Issue | Fix |
|---|---|
| `graphify: command not found` | Add Python Scripts to PATH (see Step 1) |
| `No graph found` | Run `/graphify .` to build initial graph |
| Graph is stale after changes | Run `/graphify . --update` or install git hooks |
| Large repo takes too long | Use `--mode fast` for AST-only (skip semantic pass) |
| Memory issues on huge repos | Use `--budget N` to cap token output |

---

# Additional Quality Tools

## Semgrep SAST Scanner

Semgrep provides 2000+ security rules for .NET, TypeScript, and SQL. QualityGateAgent runs it automatically during the gate stage.

### Install

```bash
pip install semgrep
```

Verify: `semgrep --version`

If the Python Scripts directory is not on PATH, add it (same as Graphify — see Step 1 above).

### How it integrates

QualityGateAgent calls `semgrep --config auto --json .` during security scanning. If Semgrep is not installed, it falls back to the built-in 11 regex patterns. The preflight check warns at pipeline startup if Semgrep is missing.

### Rules

The `--config auto` flag loads Semgrep's curated ruleset which includes:
- SQL injection (parameterized query violations)
- XSS (dangerouslySetInnerHTML in React)
- Hardcoded secrets (API keys, tokens, passwords)
- OWASP Top 10 patterns
- .NET-specific security rules

## Playwright Browser Testing

Playwright enables headless Chromium testing for real browser-level E2E validation.

### Install

```bash
npm install playwright
npx playwright install chromium
```

### How it integrates

E2EValidationAgent automatically detects Playwright at runtime via dynamic `import('playwright')`. If available, it:
1. Launches headless Chromium
2. Navigates to the frontend root — verifies page renders with real content (not blank)
3. Checks for console.error messages on page load
4. Tests login page accessibility

If Playwright is not installed, the agent falls back to HTTP status code checks (existing behavior).

## Context7 MCP

Context7 is the live-library documentation MCP used by architecture, contract-freeze, and remediation workflows.

### Install

```bash
claude mcp add context7 -- npx -y @upstash/context7-mcp@latest
```

Use it when the agent needs version-aware docs for .NET, React, Fluent UI, Dapper, or other external libraries.

## GitHub MCP Server

The GitHub MCP server enables autonomous PR creation, issue management, and review comments.

### Configuration

Already configured in `.claude/settings.json`:

```json
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": ""
      }
    }
  }
}
```

### Setup

1. Create a GitHub Personal Access Token at https://github.com/settings/tokens
2. Keep the committed `.claude/settings.json` file unchanged
3. Set environment variable: `export GITHUB_PERSONAL_ACCESS_TOKEN=ghp_...` or the Windows equivalent

### Capabilities

Once configured, Claude Code can:
- Create PRs with summaries from pipeline output
- Read and link GitHub issues to requirements
- Post code review findings as PR comments
- Update deployment status on PRs

## Security Skills

### OWASP Security Skill

Install:

```bash
npx -y skills add agamm/claude-code-owasp -y
```

What it adds:

- OWASP Top 10:2025 review guidance
- ASVS 5.0 checks
- Agentic AI security patterns for tool use, memory, and privilege boundaries

Repository reference copy:

- `.agents/skills/owasp-security/SKILL.md`

### Shannon Lite

Install:

```bash
npx -y skills add unicodeveloper/shannon -y
```

What it adds:

- Docker-based white-box pentesting
- Real exploit verification before a finding is reported
- Optional release-readiness validation beyond static scanning

Requirements:

- Docker Desktop
- Authorization to test the target
- Non-production scope

Repository reference copy:

- `.agents/skills/shannon/SKILL.md`

## Repo-Bundled Skills and Wiring

The repository also carries local skill content and committed config that operators should know about:

- `.claude/skills/` contains the GitNexus skill pack plus SQL, React UI, composition, and web design skills.
- `.agents/skills/` contains the OWASP and Shannon reference skills.
- `.claude/settings.json` commits the Graphify `PreToolUse` reminder and the GitHub MCP server configuration.
