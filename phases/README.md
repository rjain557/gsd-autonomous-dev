# GSD Convergence Engine - Phase Definitions

## Phase Flow Per Iteration

```
+-------------------------------------------------------------+
|                    GSD CONVERGENCE LOOP                      |
|                                                             |
|  +--------------+    CLAUDE CODE (token-conserving)         |
|  | 1. CODE      |    Scan repo vs matrix. Score health.     |
|  |    REVIEW    |    Update requirement statuses.            |
|  |              |    Output: ~3K tokens                      |
|  +------+-------+                                           |
|         | health < 100%                                     |
|         ?                                                   |
|  +--------------+    CLAUDE CODE (one-time or on spec       |
|  | 2. CREATE    |    change). Extract all requirements      |
|  |    PHASES    |    from docs + Figma into matrix.          |
|  |              |    Output: ~5K tokens                      |
|  +------+-------+                                           |
|         ?                                                   |
|  +--------------+    GEMINI (deep-read, plan mode)          |
|  | 3. RESEARCH  |    Deep-read specs, design deliverables,  |
|  |              |    and codebase. Build dependency maps.   |
|  |              |    Pattern guides and conflicts.          |
|  |              |    Output: ~10K+ tokens                    |
|  +------+-------+                                           |
|         ?                                                   |
|  +--------------+    CLAUDE CODE (token-conserving)         |
|  | 4. PLAN      |    Prioritize next 3-8 requirements.      |
|  |              |    Write specific generation instructions. |
|  |              |    Output: ~3K tokens                      |
|  +------+-------+                                           |
|         ?                                                   |
|  +--------------+    CODEX (unlimited tokens)               |
|  | 5. EXECUTE   |    Generate ALL code for the batch.       |
|  |              |    Full files, stored procs, components.   |
|  |              |    Output: ~50K+ tokens                    |
|  +------+-------+                                           |
|         |                                                   |
|         ? git commit                                        |
|     LOOP BACK TO 1                                          |
+-------------------------------------------------------------+
```

## Token Budget Per Iteration

| Phase         | Agent       | Est. Output Tokens | Monthly @ 20 iters |
|---------------|-------------|-------------------:|-------------------:|
| code-review   | Claude Code |       2,000-5,000  |     40K-100K       |
| create-phases | Claude Code |       3,000-6,000  |     one-time ~5K   |
| research      | Gemini      |      5,000-15,000  |     shared support |
| plan          | Claude Code |       1,500-4,000  |     30K-80K        |
| execute       | Codex       |    15,000-100,000+ |     unlimited      |
|               |             |                    |                    |
| **Claude Code total** |     |   **~11K/iter**    |   **~220K/mo**     |
| **Codex total**       |     |   **~65K+/iter**   |   **unlimited**    |

Claude Code stays focused on reasoning, Codex does the heavy file-writing, and Gemini absorbs read-heavy research.

## Agent Boundaries

| Domain                   | Claude Code (Reviewer/Architect/Planner) | Codex (Developer) |
|--------------------------|------------------------------------------|------------------------------|
| Source code              | READ only                                | READ + WRITE                 |
| .gsd\health\             | READ + WRITE                             | READ only                    |
| .gsd\code-review\        | READ + WRITE                             | READ only                    |
| .gsd\generation-queue\   | READ + WRITE                             | READ only                    |
| .gsd\research\           | READ only                                | READ + WRITE                 |
| .gsd\agent-handoff\      | WRITE current-assignment.md              | APPEND handoff-log.jsonl     |
| docs\                    | READ only                                | READ only                    |
| design\{interface}\      | READ only                                | READ only                    |
