# Graphify Knowledge Graph — Installation Guide

## What Graphify Does

Graphify converts the GSD codebase (TypeScript + PowerShell + vault markdown) into a queryable knowledge graph using Tree-sitter AST parsing and Claude semantic extraction. This gives all pipeline agents structural navigation instead of flat file scanning, achieving up to 71x token reduction.

**GSD pipeline integration points:**
- BlueprintAnalysisAgent reads `GRAPH_REPORT.md` for architectural god nodes before drift detection
- CodeReviewAgent uses graph neighbors to trace change impact
- RemediationAgent uses shortest-path to find root causes
- Orchestrator passes compact graph context across model switches

## Prerequisites

- Python 3.10+ (`python --version`)
- pip (`pip --version`)
- Claude Code CLI installed and authenticated
- Node.js 18+ (already required by GSD v4.1)

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

## Troubleshooting

| Issue | Fix |
|---|---|
| `graphify: command not found` | Add Python Scripts to PATH (see Step 1) |
| `No graph found` | Run `/graphify .` to build initial graph |
| Graph is stale after changes | Run `/graphify . --update` or install git hooks |
| Large repo takes too long | Use `--mode fast` for AST-only (skip semantic pass) |
| Memory issues on huge repos | Use `--budget N` to cap token output |
