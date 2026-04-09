---
type: knowledge
description: Complete reference of all external tools available to pipeline agents
---

# Pipeline Tools Reference

## Code Intelligence

### Graphify (Knowledge Graph)

- **What**: Codebase knowledge graph with community detection, god nodes, structural navigation
- **Storage**: `graphify-out/` (GRAPH_REPORT.md, graph.json, graph.html)
- **Token reduction**: Up to 71x vs raw file scanning
- **Rebuild**: `/graphify .` (Claude Code) or `graphify .` (CLI)
- **Incremental**: `/graphify . --update` (only changed files)
- **Query**: `graphify query "what connects X to Y?"`

### GitNexus (Code Intelligence Engine)

- **What**: Blast radius analysis, execution flow tracing, impact scoring, safe rename
- **Storage**: `.gitnexus/` (LadybugDB embedded graph)
- **Rebuild**: `gitnexus analyze` (11s for this repo)
- **Auto-reindex**: PostToolUse hook triggers after git commits
- **Key tools**:
  - `gitnexus_query({query: "concept"})` — find execution flows
  - `gitnexus_context({name: "symbol"})` — 360-degree view of a symbol
  - `gitnexus_impact({target: "symbol", direction: "upstream"})` — blast radius
  - `gitnexus_detect_changes({scope: "staged"})` — pre-commit scope check
  - `gitnexus_rename({symbol_name: "old", new_name: "new", dry_run: true})` — safe rename

## Security

### Semgrep (SAST Scanner)

- **What**: Static Application Security Testing with 2000+ rules
- **Install**: `pip install semgrep`
- **Invocation by QualityGateAgent**: `semgrep --config auto --json .` (falls back to `python -m semgrep`)
- **Fallback**: 11 built-in regex patterns if Semgrep unavailable
- **Severity mapping**: Semgrep ERROR = critical (blocks deploy), WARNING = high

## Testing

### Playwright (Browser E2E)

- **What**: Headless Chromium for real browser-level validation
- **Install**: `npm install playwright && npx playwright install chromium`
- **Used by**: E2EValidationAgent.validateWithBrowser()
- **Tests**: Page renders with content, no console.error, login form accessible
- **Fallback**: HTTP status checks if Playwright not installed

## Automation

### GitHub MCP Server

- **What**: Autonomous PR creation, issue tracking, review comments
- **Install**: `npm install -g @modelcontextprotocol/server-github`
- **Config**: `.claude/settings.json` mcpServers section
- **Auth**: `GITHUB_PERSONAL_ACCESS_TOKEN` environment variable
- **Key stored**: `OneDrive/VSCODE/keys/github-mcp.md`

## Which Agent Uses Which Tool

| Agent | Graphify | GitNexus | Semgrep | Playwright | GitHub MCP |
|---|---|---|---|---|---|
| Orchestrator | - | - | - | - | PR/issues |
| BlueprintAnalysis | GRAPH_REPORT | query, context | - | - | - |
| CodeReview | GRAPH_REPORT | impact, detect_changes | - | - | - |
| Remediation | GRAPH_REPORT | impact, context | - | - | - |
| QualityGate | - | - | Full SAST scan | - | - |
| E2EValidation | - | query | - | Browser tests | - |
| Deploy | - | - | - | - | - |
| PostDeploy | - | - | - | - | - |
