---
agent_id: phase-reconcile-agent
model: claude-sonnet-4-6
tools: [read_file, bash]
forbidden_tools: [deploy]
reads:
  - knowledge/quality-gates.md
  - knowledge/tools-reference.md
writes:
  - sessions/
max_retries: 2
timeout_seconds: 180
escalate_after_retries: true
---

## Role

SDLC Phase agent. See src/agents/phase-reconcile-agent.ts for full implementation.
