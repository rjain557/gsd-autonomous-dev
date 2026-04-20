---
agent_id: researcher-agent
model: gemini
tools: [gitnexus, graphify, semgrep, context7]
forbidden_tools: [edit, write, deploy]
reads: [.gitnexus/, graphify-out/]
writes: []
max_retries: 1
timeout_seconds: 180
escalate_after_retries: false
type: subagent
description: Runs GitNexus / Graphify / Semgrep / Context7 queries, returns synthesized findings
---

# ResearcherAgent

## Role

Subagent used by Remediation and E2E agents when they need deep research across code graphs, static analysis, or library documentation. Runs the external tools via their CLIs/MCPs and synthesizes the outputs into a compact narrative.

## Inputs

- `cwd` — where to run the tools (usually the milestone worktree)
- `query` — concept or symbol name
- `sources` — which backends to query: `gitnexus | graphify | semgrep | context7`
- `timeoutMs` — per-source timeout (default 60000)

## Output

```typescript
{
  query: string;
  findings: ResearchFinding[];
  synthesizedSummary: string;   // multi-source narrative
}
```

Each finding: `source, success, content, error?`.

## Behavior

- `gitnexus`: runs `npx gitnexus query "<concept>"` — returns execution flows
- `graphify`: runs `npx graphify query "<concept>"` — returns community/neighborhood
- `semgrep`: runs `semgrep --lang=generic -e <pattern> .` — simplified surface
- `context7`: returns a pointer — caller must invoke via MCP (not from this agent)

Failures are non-fatal; other sources still contribute.

## Known Failure Modes

| Failure | Handling |
|---|---|
| Tool not installed | `success: false` with error text, other sources continue |
| Tool timeout | `success: false`, partial stdout captured |
| Context7 called directly | Returns `success: false` with instruction to use MCP |

## Related

- `src/agents/researcher-agent.ts`
- Context7 MCP: `claude mcp add context7 -- npx -y @upstash/context7-mcp@latest`
