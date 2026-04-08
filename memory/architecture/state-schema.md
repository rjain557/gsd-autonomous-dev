---
type: architecture
description: Typed state definitions for the pipeline
---

# State Schema

Full TypeScript definitions are in `src/harness/types.ts`.

See [[05-Architecture/agent-system-design]] Section 5 for the complete schema.

## Key Types

- **PipelineState** — Full pipeline execution state, flows through all agents
- **ConvergenceReport** — BlueprintAnalysisAgent output
- **ReviewResult** — CodeReviewAgent output
- **PatchSet** — RemediationAgent output
- **GateResult** — QualityGateAgent output
- **DeployRecord** — DeployAgent output
- **Decision** — Orchestrator decision log entry (append-only)
- **CostEntry** — Per-agent cost tracking
