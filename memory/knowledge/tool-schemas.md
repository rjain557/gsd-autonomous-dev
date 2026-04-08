---
type: knowledge
description: All tool definitions available to agents
---

# Tool Schemas

## read_file
Read a file from the filesystem.
```typescript
{ path: string } → { content: string, exists: boolean }
```

## write_file
Write content to a file. Creates parent directories if needed.
```typescript
{ path: string, content: string } → { success: boolean }
```

## list_directory
List files and directories at a path.
```typescript
{ path: string, pattern?: string, recursive?: boolean } → { entries: string[] }
```

## search_files
Search file contents using regex patterns.
```typescript
{ pattern: string, path?: string, glob?: string } → { matches: Array<{ file: string, line: number, content: string }> }
```

## bash
Execute a shell command.
```typescript
{ command: string, timeout?: number } → { stdout: string, stderr: string, exitCode: number }
```
Restrictions by agent:
- CodeReviewAgent: read-only commands only (build, lint, test)
- QualityGateAgent: test/lint/scan commands only
- RemediationAgent: test runner only
- DeployAgent: deploy commands only

## spawn_agent
Orchestrator-only. Spawn an agent with input.
```typescript
{ agentId: AgentId, input: AgentInput } → { output: AgentOutput }
```
