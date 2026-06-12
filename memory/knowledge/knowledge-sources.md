# Knowledge Sources Registry (canonical)

> Machine-readable registry of every external knowledge store this project depends on.
> CLAUDE.md links here. Edit this file when a path moves — do not hardcode paths in code.

## Workstation context

- **Active host**: `Administrator` (Technijian TE-AI fleet host, Windows Server 2025).
- **Repo git author**: `Ravi Jain` (rjain@technijian.com). Some legacy notes reference a
  `C:\Users\rjain\...` laptop layout; on this host the `Administrator` paths below are authoritative.
- **OneDrive root**: `C:\Users\Administrator\OneDrive - Technijian, Inc\Documents\`

## Sources

| # | Name | Kind | Path | Authority for |
|---|------|------|------|---------------|
| 1 | GSD project vault | Obsidian (durable) | `…\obsidian\gsd-autonomous-dev\gsd-autonomous-dev\` | Engineering knowledge: diseases, solutions, patterns, ADRs, sessions, feedback rules |
| 2 | Key vault | Secrets ⚠️ | `…\VSCODE\keys\` | API keys, certs, gateway creds — **never print/commit** |
| 3 | Cortex knowledge brain | Obsidian (research) | `…\obsidian\rjain557-knowledge\rjain557-knowledge\` | Research feed: agent-harness/Claude-Code/RAG clippings + live model catalog |
| — | Auto-memory (CC built-in) | File memory | `C:\Users\Administrator\.claude\projects\d--VSCode-gsd-autonomous-dev-gsd-autonomous-dev\memory\` | Claude's working notes for this repo |

`…` = `C:\Users\Administrator\OneDrive - Technijian, Inc\Documents`

### 1. GSD project vault
- Full path: `C:\Users\Administrator\OneDrive - Technijian, Inc\Documents\obsidian\gsd-autonomous-dev\gsd-autonomous-dev\`
  (the folder name is doubled; `claude-memory\` is one level deeper).
- Entry points: `00-Home\GSD-Index.md`, `03-Patterns\index.md` (16 diseases / 9 solutions),
  `05-Architecture\index.md` (ADRs), `07-Feedback\index.md` (binding standing rules),
  `claude-memory\topics\` (gsd-pipeline-architecture, sdlc-phases, agent-orchestration,
  llm-routing-strategy, quality-gates).
- Binding feedback rules to honor: **No Pipeline Auto-Start**, **Requirements from specs only**,
  **Proactive not reactive**, **Spec-Alignment Guard before any run**, **Mark reqs complete immediately**.

### 2. Key vault  ⚠️ SECRETS
- Full path: `C:\Users\Administrator\OneDrive - Technijian, Inc\Documents\VSCODE\keys\`
- 186 files. LLM credentials: `anthropic.md`, `openai.md`, `azure-openai.md`, `deepseek.md`,
  `gemini.md`, `kimi-moonshot.md` / `moonshot-kimi.md`, `minimax.md`, `glm-zhipu.md`,
  `nvidia-build.md`, `amazon-bedrock.md`. Central gateway: `litellm.md`, `litellm-master.md`,
  `litellm-server.md`, `litellm-virtual-keys.md`. Identity/cert: `Technijian-Agent-Harness.pfx`,
  M365 `*-m365-ga.md` / `*-eop-cert-auth.md` / `*-eop-automation.cer` per tenant.
- **Rules**: open a file only when a task needs that exact secret. Never print, echo, log, or commit
  values. Never paste a key into source — load from environment or the LiteLLM gateway. Reference by
  filename. This directory is intentionally outside the repo; keep it so.

### 3. Cortex knowledge brain ("rjain557-knowledge", a.k.a. Inbox Brain)
- Full path: `C:\Users\Administrator\OneDrive - Technijian, Inc\Documents\obsidian\rjain557-knowledge\rjain557-knowledge\`
  (folder name doubled; is its own git repo).
- `Inbox\` — 450+ clipped articles (2026+) on agent harnesses, Claude Code workflows, agentic design
  patterns, RAG/hybrid memory, LLM observability. Research evidence base.
- `claude-memory\topics\` — durable facts: `model_catalog` & `litellm_gateway` (re-verified weekly —
  check before model-routing changes), `llm_cost_tracking`, `ai_fleet_infrastructure`,
  `deep_research_pipeline`, `litellm_gateway`.
- Read before designing/upgrading any agent, harness, skill, or workflow.

## Retrieval guidance for sessions
1. For "why did X fail / how did we fix Y" → **GSD vault** patterns + sessions.
2. For "what's the current model / price / routing" → **Cortex** `model_catalog` + repo `config/model-registry.json`; creds in **key vault**.
3. For "what's the latest technique for agents/harnesses" → **Cortex** `Inbox\`.
4. Never resolve a credential by guessing — read the named key-vault file (and keep its value out of output).
