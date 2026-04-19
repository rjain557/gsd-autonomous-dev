---
description: Check if vault should upgrade to LightRAG or stay on file-based memory
---

Read `C:/Users/rjain/OneDrive - Technijian, Inc/Documents/obsidian/gsd-autonomous-dev/gsd-autonomous-dev/claude-memory/HEALTH.md` and give a graduated recommendation:

**GREEN** — "Stay put. Next check: [today + 1 week]. Vault is healthy."

**YELLOW** — "Cleanup before upgrade. Run /consolidate, review never-accessed topics, update stale hot topics. Recheck in a week."

**RED** — Provide a tailored recommendation based on the cause:
- Topic count > 400 with hit rate < 50% → "Migrate to LightRAG."
- Miss rate > 30%, moderate topic count → "Try aliases first for 2 weeks. If still RED, migrate to LightRAG."
- Stale > 25% → "Not a tooling problem. Run /consolidate aggressively."
- Heavy document corpus → "LightRAG for this repo specifically."

**PENDING** — "Need 30 days of retrieval data. Log shows N days. Keep using the vault and recheck after [date]."

If the last review was more than 30 days ago, respond: "Cannot give a graduation recommendation until /review is run. Last review: [date]. Run /review first."

Always include: what would be lost in a migration, and the concrete next command to run.
