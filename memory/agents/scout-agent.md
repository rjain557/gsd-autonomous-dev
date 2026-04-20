---
agent_id: scout-agent
model: haiku
tools: [file-read]
forbidden_tools: [edit, write, exec, deploy]
reads: [memory/agents/, memory/knowledge/, memory/architecture/, docs/]
writes: []
max_retries: 1
timeout_seconds: 60
escalate_after_retries: false
type: subagent
description: Reads specs and vault notes, returns summarized context
---

# ScoutAgent

## Role

Subagent used by BlueprintAnalysis, CodeReview, and Remediation agents. Reads vault notes and specs, returns a compact summary that fits in the caller's context budget.

Purpose: keep the caller focused on judgment (patching, reviewing) rather than information gathering.

## Inputs

- `vaultPath` — root vault directory
- `topics` — list of relative paths to .md files (e.g. `["agents/code-review-agent", "knowledge/quality-gates"]`)
- `maxBytesPerTopic` — per-file byte budget (default 1500)
- `maxTotalBytes` — overall byte budget (default 8000)

## Output

```typescript
{
  findings: ScoutFinding[];   // one per topic
  totalBytes: number;
  topics: string[];
}
```

Where each `ScoutFinding` is:
- `topic`, `path`, `found`
- `summary` — compressed content (frontmatter + headings + bullet points + prose up to budget)
- `bytesRead`

## Behavior

Summarization strategy (no LLM call required):
1. Preserve YAML frontmatter
2. Preserve all `# / ## / ###` headings
3. Preserve bullet points and numbered lists
4. Include prose until ~80% of budget consumed
5. Append `… [truncated by Scout]` when the budget is exhausted

## Known Failure Modes

| Failure | Handling |
|---|---|
| Topic not found | Return `found: false` with empty summary |
| Budget exhausted mid-list | Mark remaining topics `[budget exhausted]` |

## Related

- `src/agents/scout-agent.ts`
