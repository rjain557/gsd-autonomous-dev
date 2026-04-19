---
description: Save durable knowledge from this session to the vault
---

Review the current conversation and decide what durable human knowledge it produced. Follow this process:

**Step 1 — Qualify**
Skip consolidation if the exchange was: trivial Q&A, code-structural only (naming/formatting), or procedural-only (running commands). Only save knowledge that will still be relevant in future sessions.

**Step 2 — For each piece of durable knowledge:**
1. Find the matching topic in `C:/Users/rjain/OneDrive - Technijian, Inc/Documents/obsidian/gsd-autonomous-dev/gsd-autonomous-dev/claude-memory/topics/` (or create a new one if the knowledge is substantial enough for its own topic).
2. Before writing, compare against existing `## Key facts` and `## Decisions & rationale` sections:
   - **Compatible**: new info extends existing → proceed with update
   - **Clarifying**: more precise version of existing fact → update in-place, note in CHANGELOG
   - **Contradicting**: genuine conflict → append to `## Open questions` as "CONTRADICTION detected on [date]: existing says X, new says Y. Resolve.", lower confidence by one step, do NOT overwrite
   - **Replacing**: I explicitly said the old info was wrong → overwrite, record what changed and why
3. Respect volatility: stable topics need strong evidence to update; ephemeral topics can be overwritten freely.

**Step 3 — Update files**
- Update the topic page(s) with the new knowledge
- Update `last_updated` frontmatter to today
- Increment `access_count` if this topic was retrieved this session
- Append a `[consolidate] YYYY-MM-DD — <summary of what was added/changed>` line to CHANGELOG.md
- Update index.md if a new topic was created

**Step 4 — Report**
List what was saved, what was skipped (and why), and any contradictions detected.
