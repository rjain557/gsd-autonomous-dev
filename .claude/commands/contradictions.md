---
description: List all unresolved contradictions in the vault
---

Scan all topic files in `C:/Users/rjain/OneDrive - Technijian, Inc/Documents/obsidian/gsd-autonomous-dev/gsd-autonomous-dev/claude-memory/topics/` for unresolved contradictions.

For each file, look for lines containing "CONTRADICTION detected" in the `## Open questions` section.

Present findings as a numbered list:
- Topic name (with link to file)
- Date the contradiction was detected
- What the existing fact says
- What the contradicting new information says
- Suggested resolution (Compatible / Clarifying / Replacing — which one and why)

For each contradiction, ask: "How do you want to resolve this? Options: (1) Keep existing, (2) Replace with new, (3) Mark as clarifying update, (4) Split into two facts."

After I decide, apply the resolution:
- Replace: overwrite the fact, prepend `[replaced]` to CHANGELOG entry
- Clarifying: update in-place, note refinement in CHANGELOG
- Keep existing: remove the contradiction flag from Open questions
- Split: add a new key fact line alongside the existing one

Lower confidence back to the appropriate level based on the resolution.
