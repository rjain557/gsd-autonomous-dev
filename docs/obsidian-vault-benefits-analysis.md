# How Obsidian Vaults Could Help the GSD Autonomous Dev Engine

## 1. Replace the Flat `/memory/` System with a Linked Knowledge Graph

The current memory system is **20 flat markdown files** in `/memory/`. It works, but it's essentially a manual wiki. Obsidian would transform this into an interconnected knowledge graph:

- **Bidirectional links** (`[[patterns]]` → `[[bug-fixes]]` → `[[v3-pipeline]]`) let you see *how concepts relate* — e.g., which patterns led to which bug fixes, which bug fixes informed which pipeline changes
- **Graph view** gives a visual map of the entire project's knowledge topology — immediately spot orphaned docs, overly-coupled topics, or knowledge gaps
- **Backlinks panel** shows every file that references the current one — so when reading `model-api-reference.md`, you instantly see which feedback files, bug fixes, and session states depend on it

## 2. Supercharge the Supervisor's Pattern Memory

The supervisor currently stores failure patterns in `pattern-memory.jsonl` (append-only). Obsidian could layer on top:

- **Daily notes** for each convergence run — auto-linked to the patterns, diseases, and fixes from that session
- **Tags** like `#stall-pattern`, `#quota-exhaustion`, `#agent-crash`, `#spec-conflict` make pattern discovery instant via tag search
- **Dataview plugin** could query JSONL/JSON state files and render live dashboards: "Show me all stalls where batch reduction fixed it" or "List all sessions where health dropped below 50%"

## 3. Client Project Management

The existing `client/bwh/` folder structure maps well to Obsidian. Vaults per client (or a multi-client vault with folders) would provide:

- **Project MOCs** (Maps of Content) linking specs → requirements matrix → health history → cost summaries → developer handoffs
- **Kanban boards** (via the Kanban plugin) tracking requirement status visually — better than scanning `health-current.json`
- **Embedded queries** showing real-time status: `dataview TABLE health, iteration FROM "clients/bwh" WHERE status != "satisfied"`
- **Client-facing exports** — Obsidian's markdown renders beautifully to PDF, which could replace the current "export to Word" workflow

## 4. Prompt Template Versioning & Documentation

The ~25 prompt templates across `claude/`, `codex/`, `gemini/`, and `council/` directories would benefit from:

- **Linking prompts to the phases that use them** — `[[code-review.md]]` linked from the convergence loop documentation
- **Tracking prompt evolution** — daily notes or changelog entries showing *why* a prompt was modified, linked to the bug fix or stall that triggered it
- **A/B comparison** — side-by-side embedded views of old vs new prompt versions with notes on performance impact

## 5. Cross-Session Intelligence

The current `cross-session.md` is a "shared message board for coordinating between multiple Claude sessions." Obsidian could formalize this:

- **Session logs as daily notes** — each Claude session gets a timestamped note with linked outcomes
- **Feedback files as atomic notes** — the 7 `feedback_*.md` files become first-class nodes in the knowledge graph, linked to the sessions where the feedback was given and the code changes that resulted
- **Canvas view** — visually map the flow between sessions, showing handoff points, what each session accomplished, and where context was lost

## 6. Documentation Consolidation

The 5 major docs (69K–278K each) plus the developer guide are prime candidates:

- **Break monoliths into atomic notes** — instead of one 278K developer guide, have hundreds of linked notes (~500-2000 words each) that compose into the full guide via MOCs
- **Search actually works** — Obsidian's full-text search + tag search + link search beats scrolling through 278K markdown
- **Publish plugin** — expose docs as a website for clients/team without the Word export step

## 7. Decision Log & Architecture Decision Records (ADRs)

The V2 → V3 transition (7 agents → 2, CLI → API, 85% cost reduction) is exactly the kind of decision that benefits from structured recording:

- **ADR template** in Obsidian: Status, Context, Decision, Consequences, linked to relevant code and metrics
- **Linked to cost data** — embed or link `cost-summary.json` comparisons showing before/after
- **Searchable history** — "Why did we drop Gemini from V3?" becomes a single search away

## 8. Practical Implementation Approach

The simplest integration path:

1. **Create a vault from `/memory/` + `/docs/`** — zero migration cost, they're already markdown
2. **Add `[[wiki-links]]`** between existing files — 30 minutes of linking transforms flat files into a graph
3. **Install Dataview** — query `.gsd/` JSON/JSONL files for live dashboards
4. **Use Templater** — auto-generate session notes, convergence run logs, and client reports
5. **Obsidian Git plugin** — auto-commit vault changes, keeping everything in version control

## Bottom Line

The GSD engine already generates a massive amount of structured data (health scores, requirement matrices, cost logs, pattern memory, session states). The problem isn't *generating* knowledge — it's **finding, connecting, and acting on it** across sessions, projects, and versions. Obsidian turns the flat file memory into a queryable, linked, visual knowledge base without requiring any changes to the existing pipeline. The `.gsd/` state files stay as-is; Obsidian just becomes the *lens* through which you and your AI agents navigate the accumulated intelligence.
