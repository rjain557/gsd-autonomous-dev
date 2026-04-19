# Claude Code Memory System — Bootstrap Prompt

> Paste this entire prompt into Claude Code at the root of any repo to install, repair, or reorganize the full memory + code-intelligence stack. Safe to re-run any time.

---

I want you to set up, repair, or reorganize a full memory + code-intelligence stack for this repo. The stack has four active layers, a monitoring layer, and a maintenance discipline layer. This prompt is idempotent and self-healing: run it on a fresh repo, a partially configured repo, a fully configured repo, or a repo with corrupted data, and it will do the right thing in each case.

## Layer boundaries (enforce these)

1. **Vault (Obsidian)** — durable human knowledge under `claude-memory/` only
2. **Auto-memory (Anthropic built-in)** — Claude's working notes, managed by CC
3. **GitNexus** — code structure, `.gitnexus/` + MCP server
4. **Auto Dream** — consolidation for layer 2 (when flag is enabled)
5. **Monitoring** — vault health tracking, drives `/graduate`
6. **Maintenance** — vault versioning + weekly review discipline

## Step 0: Discovery pass (always run first)

Audit current state before changing anything. Classify each item as MISSING, PARTIAL, PRESENT, or INCONSISTENT. Do NOT write anything yet.

**Claude Code baseline:**
- CC version (need v2.1.59+)
- Node.js, Python + uv/uvx, git
- Existing `~/.claude/projects/<project>/memory/`

**Repo-level config:**
- `CLAUDE.md` — exists? references vault path? has layer boundaries?
- `.claude/` contents, `.claude/hooks/` contents with per-hook spec match analysis, `.claude/commands/`, `.claude/mcp.json`, `.claude/skills/`

**GitNexus state:**
- `.gitnexus/` present? `meta.json` readable? counts + embeddings?
- MCP configured? Reindex hook? gitignore entry?

**Obsidian vault state:**
- Vault path in CLAUDE.md? Vault exists? Writable?
- `claude-memory/` exists? Inventory topics, index.md, CHANGELOG.md, HEALTH.md, `.retrieval-log.jsonl`
- **Vault version control**: is the vault a git repo? Is `claude-memory/` tracked? When was the last commit?

## Step 0.3: Vault version control bootstrap

This runs before any data audit or writes, so every subsequent change is reversible.

If the vault is NOT a git repo:
- Ask me if I want to initialize one. Default: yes, strongly recommended.
- If yes: run `git init` in the vault root
- Create a vault-appropriate `.gitignore`:
  ```
  .obsidian/workspace*
  .obsidian/cache
  .obsidian/graph.json
  .trash/
  *.tmp
  ```
- Commit the current state as "baseline before Claude memory setup" so there's a restore point even if the vault had content before this run
- Tell me the commit hash to record somewhere safe

If the vault IS a git repo but has uncommitted changes:
- Show me `git status`
- Ask me to commit or stash before proceeding
- Do NOT start making changes on top of a dirty working tree — that makes reverting this prompt's work much harder

If the vault is a git repo with clean working tree:
- Note the current HEAD as the pre-run baseline
- Include it in the final summary

After bootstrap, install a git pre-commit hook at `.git/hooks/pre-commit` that:
- Runs `/vault-status` equivalent logic (reads HEALTH.md if present)
- If status is RED, prints a warning but allows the commit (never blocks — the hook is a nudge, not a gate)
- If `claude-memory/CHANGELOG.md` was modified, validates the new entries have proper format

Every subsequent write to `claude-memory/` by the other hooks should produce commits (or at minimum, leave clean staging). The consolidate and reorganization flows should end with a git commit prefixed appropriately:
- `[consolidate]` for topic updates from stop hook
- `[reorg]` for reorganization fixes
- `[health]` for HEALTH.md updates
- `[manual]` for user edits

## Step 0.5: Data quality audit

If `claude-memory/` exists, audit data health. Sample up to 20 topic pages (or all if fewer).

**Schema issues:**
- Missing frontmatter or required fields: `topic`, `last_updated`, `access_count`, `last_accessed`, `confidence`, `sources`, `aliases`, **`volatility`**
- Wrong field types, invalid dates, legacy fields

**Content issues:**
- Transcript-style pages, duplicates, near-duplicates (>80% overlap), empty/near-empty, oversized (>2000 words), missing required sections

**Structural issues:**
- Orphans, phantom index entries, broken wiki-links, alias conflicts, misplaced files

**Metadata issues:**
- `access_count` + `last_accessed` never updated, empty `sources`, `last_updated` stale vs CHANGELOG

**Contradiction signals:**
- Pages with `## Open questions` entries marked as unresolved for >30 days
- Pages where the summary and key-facts sections disagree

**Log issues:**
- Malformed `.retrieval-log.jsonl` lines, log/frontmatter sync broken, CHANGELOG missing entries for recent `last_updated`

**Index issues:**
- Missing, stale, unsectioned at >50 topics, missing summaries

Produce discovery + audit report:

```
## Discovery Report
<CC baseline, repo config, GitNexus, vault, git state>

## Data Quality Audit
<per-category findings with counts and samples>

Overall data health: CLEAN / NEEDS_MINOR_FIXES / NEEDS_REORG / CORRUPTED

## Plan
INSTALL / REPAIR / REORGANIZE / MIGRATE / SKIP / ASK
```

Wait for my approval with sample problems shown before destructive changes.

## Step 0.75: Reorganization (if approved)

**Tier 1 — fully safe, auto-apply:**
- Add missing frontmatter fields including `volatility: evolving` default
- Normalize dates to ISO
- Rebuild `index.md` from actual files, preserving summaries
- Remove phantom entries, move misplaced files
- Rotate oversized `.retrieval-log.jsonl` (keep last 90 days)
- Drop malformed log lines (archive originals first)

**Tier 2 — confirm per item:**
- Split oversized pages, merge duplicates, fix wiki-links, resolve alias conflicts, migrate transcripts to topic format

**Tier 3 — archive, never delete:**
- Near-empty pages → `_archive/`
- Legacy-schema pages → archive originals before migration
- Stale >365 days → report only, never auto-archive

After each tier, commit with `[reorg]` prefix to CHANGELOG AND to git.

## Step 0.9: Retroactive metrics seeding

If new frontmatter fields added and `.retrieval-log.jsonl` has history: replay log to populate `access_count` + `last_accessed`. Mark HEALTH.md metrics as "reconstructed from log" for one month.

If volatility field was just added: leave all topics at default `evolving`. Tell me to review and promote stable ones manually during the next weekly review (see Step 11).

If no log: initialize fields to zero/today, mark HEALTH baseline as pending.

## Step 1: Preflight (skip passed items)

Baseline prereqs. Tell me install commands; don't run system installs myself.

## Step 2: Vault structure (create missing only)

Ensure in vault:
- `claude-memory/topics/`
- `claude-memory/index.md`
- `claude-memory/CHANGELOG.md`
- `claude-memory/HEALTH.md`
- `claude-memory/.retrieval-log.jsonl`
- `claude-memory/preferences.md` (created lazily when first preference saved)
- `claude-memory/_archive/` (created lazily)

**Topic page schema:**

```yaml
---
topic: <short name>
aliases: [<alternate names>]
volatility: stable|evolving|ephemeral
last_updated: <ISO date>
confidence: high|medium|low
sources: [<session dates, commit hashes, gitnexus symbols>]
access_count: 0
last_accessed: <ISO date>
---
```

```markdown
# <Topic>

## Summary
## Key facts
## Decisions & rationale
## Open questions
## Related code
## Related topics
```

**Volatility semantics** (record these in CLAUDE.md):
- `stable` — architectural decisions, domain invariants, immutable facts. Review cadence: yearly. Consolidation is conservative — strong preference for preserving existing content.
- `evolving` — default. Active development state, current approaches, ongoing concerns. Review cadence: quarterly. Normal consolidation.
- `ephemeral` — flaky tests, library workarounds, "current state of X" snapshots. Review cadence: aggressive. Auto-archive after 60 days with no `access` and no `last_updated`. Consolidate liberally.

## Step 3: GitNexus (install/sync/verify)

If MISSING:
- `npx gitnexus analyze` to build initial index
- `npx gitnexus analyze --skills` to generate per-module skills
- Configure GitNexus MCP in `.claude/mcp.json`
- Add `.gitnexus/` to `.gitignore`

If PARTIAL: fill in missing pieces (MCP config, skills, gitignore, reindex hook). Check staleness via `meta.json` mtime vs latest commit; refresh if old.

If PRESENT: smoke-test MCP, verify reindex hook exists, do not re-index unless stale.

If I don't want GitNexus on this repo (small codebase), ask before removing anything.

## Step 4: Hooks (install missing; reconcile conflicting)

For each hook: MISSING → create; matches → leave; differs → diff, ask.

**`impact-check.sh`** — PreToolUse on Edit/Write, GitNexus impact analysis, block HIGH/CRITICAL.

**`retrieve.sh`** — UserPromptSubmit with topic/entity triggers. Updates frontmatter counters, logs to `.retrieval-log.jsonl`. ALSO always loads `claude-memory/preferences.md` on every retrieval (not gated — preferences are universally applicable).

**`reindex.sh`** — PostToolUse on git commit/merge for GitNexus.

**`consolidate.sh`** — Stop hook. Updated spec:

1. Decide if exchange produced durable human knowledge. Skip if trivial, code-structural only, or procedural only.

2. If worth saving: find matching topic page (or create if substantial).

3. **Contradiction detection:**
   Before updating, compare new information against existing `## Key facts` and `## Decisions & rationale` sections. Classify:
   - **Compatible** — new info extends existing without conflict. Proceed with normal update.
   - **Clarifying** — new info refines existing (more precise, better-sourced version of the same fact). Update in place, note the refinement in CHANGELOG.
   - **Contradicting** — new info genuinely conflicts with existing. DO NOT overwrite. Instead:
     - Append to `## Open questions` section: "CONTRADICTION detected on [date]: existing says X, new session says Y. Resolve."
     - Update `last_updated` but preserve both versions
     - Append a `[contradiction]` entry to CHANGELOG with context
     - Lower `confidence` field by one step (high→medium, medium→low)
   - **Replacing** — I explicitly told Claude the old info is wrong. Only then overwrite, and record what changed and why in CHANGELOG with a `[replaced]` prefix.

4. Respect volatility:
   - `stable` topics: contradiction threshold is much stricter. Small differences default to clarifying, not contradicting. Never overwrite without explicit "this was wrong" signal.
   - `ephemeral` topics: contradictions are normal (state changes). Overwrite freely, note in CHANGELOG.
   - `evolving` topics: use the logic above as-is.

5. Commit the change to git with `[consolidate]` prefix.

**`health-check.sh`** — SessionEnd, writes HEALTH.md. Includes weekly review section (see Step 6).

**`preference-extract.sh`** — separate stop-hook logic that detects preference-shaped statements ("I prefer X", "don't do Y", "always Z") and offers to save them to `preferences.md` rather than a topic page. Ask before writing — preferences should feel intentional.

## Step 5: Slash commands (install missing only)

Existing: `/consolidate`, `/impact`, `/vault-status`, `/sync`, `/graduate`.

**`/review`** — weekly review command. Reads HEALTH.md, CHANGELOG (last 7 days), and contradiction log. Presents:
1. New topics added this week (review for quality)
2. Topics updated this week (spot-check accuracy)
3. Unresolved contradictions from `## Open questions` sections
4. Topics whose volatility might need updating (stable topic that changed recently? ephemeral topic that's been stable for months?)
5. Ephemeral topics approaching 60-day auto-archive
6. Prune candidates (never-accessed, stale evolving topics)

The output is a checklist with topic links. I go through it, make decisions, and the command can apply the decisions I approve. Target: 5–10 minutes.

**`/contradictions`** — list all unresolved contradictions in the vault with context. Shorter focused version of `/review` when I specifically want to resolve ambiguities.

**`/volatility <topic> <stable|evolving|ephemeral>`** — manually set the volatility of a topic. Use after reviewing.

If any of these names are already taken by a user-written command, prefix mine with `cc-` and tell me.

## Step 6: Monitoring — HEALTH.md

Metrics (size, retrieval quality, freshness, traffic) and GREEN/YELLOW/RED classification:

**Size metrics:**
- Topic page count, total word count, avg + max page size

**Retrieval quality (from `.retrieval-log.jsonl`, last 30 days):**
- Attempts, hit rate, miss rate
- Never-accessed topics (dead weight)
- Hot topics accessed >10 times
- Avg topics matched per query (target 1-2)

**Freshness:**
- Stale >60 days, stale >180 days
- Orphans (not in index.md)
- Broken wiki-links

**Traffic:**
- Sessions/week, new topics/week, consolidations/week

**Classification:**

GREEN — all of:
- Topic count < 150
- Hit rate > 70%
- Miss rate < 15%
- Stale-180 < 10% of total

YELLOW — any of:
- Topic count 150-400
- Hit rate 50-70%
- Miss rate 15-30%
- Stale-180 10-25%
- Dead weight > 30%

RED — any of:
- Topic count > 400
- Hit rate < 50%
- Miss rate > 30%
- Stale-180 > 25%

**Weekly Review Status section at top of HEALTH.md:**
- Date of last `/review` run
- Days since last review (green <7, yellow 7–14, red >14)
- Unresolved contradiction count
- Ephemeral topics approaching archive deadline
- Count of topics edited this week
- Next review due

If days-since-last-review > 14, the health-check hook prints a loud warning at SessionEnd: "Weekly review is overdue. Run /review."

**Volatility distribution metric:**
- % stable / evolving / ephemeral
- Flag if distribution is suspicious (e.g., 90% evolving suggests volatility isn't being used; 90% stable suggests overfitting)

## Step 7: `/graduate` command

Reads HEALTH.md and recommends stay/cleanup/upgrade.

**GREEN:** "Stay put. Next check: [today + 1 week]."

**YELLOW:** "Cleanup before upgrade. Run `/consolidate`, review never-accessed topics, update hot stale topics. Recheck in a week."

**RED:** Upgrade recommendation tailored to cause:
- Topic count > 400 with hit rate < 50% → "Migrate to LightRAG."
- Miss rate > 30%, topic count moderate → "Try aliases first for two weeks. If still RED, then LightRAG."
- Stale > 25% → "Not a tooling problem. Run `/consolidate` aggressively."
- Heavy PDF/document corpus → "LightRAG for this repo specifically."

Always include concrete migration command and "what you'd lose" note.

**Insufficient-data case:** "Need 30 days of retrieval data. Currently [N] days logged."

If I haven't run `/review` in 30+ days, `/graduate` refuses to give a recommendation and tells me to review first.

## Step 8: CLAUDE.md (merge, don't overwrite)

If CLAUDE.md doesn't exist: create with full layer boundaries, rules, pointers.

If it exists: preserve all existing content. Append a new section `## Memory + Code Intelligence Stack` with:
- Vault path for this repo
- Layer boundaries (from Step 1)
- Retrieval rules (only on topic/entity match)
- Write rules (topic pages in place, never transcripts, never outside `claude-memory/`)
- GitNexus rules: MUST run `gitnexus_impact` before editing; MUST warn on HIGH/CRITICAL risk
- Volatility semantics and review cadence per level
- Contradiction handling policy
- **Weekly review mandate: "Run `/review` every week. Non-negotiable for vault hygiene."**
- Vault git policy: every mutation produces a commit with appropriate prefix
- Pointers: `claude-memory/index.md`, `claude-memory/HEALTH.md`, `.claude/skills/generated/`

If the section already exists: diff against target, update only changed parts.

## Step 9: Bootstrap (only if vault was MISSING or just reorganized)

If fresh: seed 3–5 topic pages, populate index, baseline HEALTH. Ask me for any strong preferences to initialize `preferences.md` with.

If reorganized: skip seeding, regenerate index, write HEALTH with "reconstructed" flag. Surface topics needing volatility classification in the next `/review` run.

If healthy and present: skip entirely.

## Step 10: Verification

Always run:
1. Trivial prompt ("what's 2+2") — no retrieval, no log entry
2. Topic prompt — retrieval fires, log entry written, access_count increments, **preferences.md always loaded**
3. SessionEnd — health-check updates HEALTH.md including weekly-review status
4. `/vault-status` — readable dashboard
5. `/graduate` — state-appropriate recommendation
6. `/review` — produces checklist

If GitNexus installed:
7. Code symbol prompt — GitNexus context loads
8. High-risk edit — impact-check blocks

If reorg happened:
9. Spot-check 3 reorganized pages — schema + content intact
10. Verify archives readable
11. `git log` in vault shows reorg commits with proper prefixes

**Contradiction test (always):**
12. Seed a test topic with a fact, then in a new session tell Claude something that contradicts it. Verify consolidate detects the conflict and writes to `## Open questions` rather than overwriting.

## Step 11: Weekly review discipline — make it stick

Set up a calendar event (tell me to do this manually — don't touch my calendar):
- Weekly, same day/time, 10 minutes
- Title: "Vault review — run /review in Claude Code"
- Add a link to the repo in the description

At the end of every session, if HEALTH.md shows days-since-review > 7, the health-check hook appends a visible notice to its output. The notice escalates:
- 7–14 days: gentle reminder
- 14–21 days: warning
- >21 days: "vault health cannot be trusted — metrics reflect unreviewed data; please run /review before making graduation decisions"

If I haven't run `/review` in 30+ days, `/graduate` refuses to give a recommendation. The nagging is the feature.

## Rules of engagement

- Discovery + audit BEFORE any changes, every run
- Git-initialize the vault before any writes (Step 0.3)
- Show sample problems before reorg approval
- Non-destructive by default: preserve, append, migrate, archive — never delete
- Every vault mutation produces a git commit with prefix
- Contradictions are recorded, not silenced
- Ask before touching user-authored content
- Skip correct items
- Final summary includes: git baseline commit, what changed, what was skipped, what's archived, first review due date
