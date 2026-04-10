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

## Documentation & Security

### Context7 MCP (Live Library Docs)

- **What**: Real-time, version-specific documentation for 1000+ libraries (.NET, React, Dapper, etc.)
- **Install**: `claude mcp add context7 -- npx -y @upstash/context7-mcp@latest`
- **Tools**: `resolve-library-id`, `query-docs`
- **Cost**: Free (1000 requests/month)
- **Used by**: All agents that generate code (Architecture, Remediation, Contract Freeze)

### OWASP Security Skill

- **What**: OWASP Top 10:2025, ASVS 5.0, Agentic AI security, C#/TS-specific patterns
- **Install**: `npx skills add agamm/claude-code-owasp`
- **Location**: `.claude/skills/owasp-security/SKILL.md`
- **Cost**: Free (MIT), ~1500 tokens context
- **Used by**: QualityGate (preventive), CodeReview (detection)

### Shannon Lite (Penetration Testing)

- **What**: White-box AI pentester, 96% exploit success rate, 50+ vulnerability types
- **Install**: `npx skills add unicodeveloper/shannon`
- **Location**: `.claude/skills/shannon/SKILL.md`
- **Trigger**: `/shannon` in Claude Code
- **Cost**: ~$50/pentest (Docker + LLM, 1-1.5 hours)
- **Used by**: Release readiness (Phase G), on-demand security audits

## Which Agent Uses Which Tool

| Agent | Graphify | GitNexus | Semgrep | Playwright | Context7 | OWASP | GitHub MCP |
|---|---|---|---|---|---|---|---|
| Orchestrator | - | - | - | - | - | - | PR/issues |
| BlueprintAnalysis | GRAPH_REPORT | query, context | - | - | - | - | - |
| CodeReview | GRAPH_REPORT | impact, detect_changes | - | - | - | patterns | - |
| Remediation | GRAPH_REPORT | impact, context | - | - | docs | patterns | - |
| QualityGate | - | - | Full SAST | - | - | patterns | - |
| E2EValidation | - | query | - | Browser tests | - | - | - |
| Deploy | - | - | - | - | - | - | - |
| PostDeploy | - | - | - | - | - | - | - |
| RequirementsAgent | - | - | - | - | - | - | - |
| ArchitectureAgent | - | - | - | - | docs | - | - |
| FigmaIntegration | - | - | - | - | - | - | - |
| PhaseReconcile | - | - | - | - | - | - | - |
| BlueprintFreeze | - | - | - | - | - | - | - |
| ContractFreeze | - | - | - | - | docs | - | - |
