---
description: Set the volatility of a vault topic (usage: /volatility <topic-name> <stable|evolving|ephemeral>)
---

$ARGUMENTS

Parse the arguments as: <topic-name> <volatility-level>

Valid volatility levels: stable | evolving | ephemeral

Volatility semantics:
- **stable**: architectural decisions, domain invariants, immutable facts. Review cadence: yearly. Conservative consolidation.
- **evolving**: active development state, current approaches. Review cadence: quarterly. Normal consolidation. (default)
- **ephemeral**: flaky tests, library workarounds, "current state of X" snapshots. Review cadence: aggressive. Auto-archive after 60 days with no access or update.

Find the topic file at `C:/Users/rjain/OneDrive - Technijian, Inc/Documents/obsidian/gsd-autonomous-dev/gsd-autonomous-dev/claude-memory/topics/<topic-name>.md`.

Update the `volatility:` field in the YAML frontmatter to the new value.

Append to CHANGELOG.md: `[manual] YYYY-MM-DD — Set volatility of <topic-name> to <level>. Reason: [ask me if not provided]`

Confirm the change with the old and new volatility values.

If the topic file is not found, list the available topics and ask which one was meant.
