---
description: Weekly vault review — quality check, contradictions, volatility calibration
---

Run the weekly vault review for claude-memory. This should take 5–10 minutes.

1. Read `C:/Users/rjain/OneDrive - Technijian, Inc/Documents/obsidian/gsd-autonomous-dev/gsd-autonomous-dev/claude-memory/HEALTH.md` for current status.

2. Read `C:/Users/rjain/OneDrive - Technijian, Inc/Documents/obsidian/gsd-autonomous-dev/gsd-autonomous-dev/claude-memory/CHANGELOG.md` and filter entries from the last 7 days.

3. List all topic files in `topics/` and identify:
   - **New topics this week** (last_updated within 7 days, access_count = 0): review for quality
   - **Updated topics this week** (last_updated within 7 days): spot-check accuracy
   - **Unresolved contradictions**: any topic with "CONTRADICTION detected" in `## Open questions`
   - **Volatility candidates**: stable topics updated recently (should they be evolving?); ephemeral topics stable for 60+ days (should they be stable?)
   - **Ephemeral topics near archive**: ephemeral + last_accessed > 45 days ago
   - **Prune candidates**: never-accessed (access_count = 0) + last_updated > 90 days

4. Present a numbered checklist. For each item, give me a link to the topic file and a one-line action.

5. After I work through the checklist, update HEALTH.md with today's date as "Last review:" and append a `[manual] YYYY-MM-DD — Weekly review completed. N items addressed.` entry to CHANGELOG.md.
