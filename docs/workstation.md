# GSD Autonomous Dev — Workstation Configuration

This document covers the Claude Code + memory stack configuration that must be set up on every workstation. It supplements [GSD-Workstation-Setup.md](GSD-Workstation-Setup.md), which covers base tooling (Node, Python, Git, AI CLIs).

**Complete base setup first**, then follow this document.

---

## What Lives in the Repo vs. Per-Workstation

| Item | Tracked in repo | Per-workstation action needed |
|------|:--------------:|:------------------------------|
| `.claude/settings.json` — hooks, MCP config | Yes | None — already wired |
| `.claude/hooks/*.sh` — hook scripts | Yes | None — relative paths work anywhere |
| `.claude/commands/*.md` — slash commands | Yes | None — auto-discovered |
| `.claude/skills/` — skill symlinks | Yes | None |
| `.claude/settings.local.json` — permissions | **No** (gitignored) | Copy from this doc or generate fresh |
| `GSD_VAULT_MEMORY` env var — vault path | **No** | Set if your vault path differs (see Step 2) |
| `GITHUB_PERSONAL_ACCESS_TOKEN` | **No** | Set per machine (see Step 3) |
| `ANTHROPIC_API_KEY` | **No** | Set per machine (see Step 3) |
| `claude-memory/` vault contents | **No** (Obsidian/OneDrive synced) | Verify vault is accessible (see Step 1) |
| `.gitnexus/` index | **No** (gitignored) | Rebuild after clone (see Step 4) |
| `graphify-out/` | **No** (gitignored) | Rebuild after clone (see Step 5) |

---

## Step 1: Verify Obsidian Vault Access

The `claude-memory/` vault is stored in Obsidian and syncs via OneDrive. Check it exists:

```bash
# Bash (Git Bash / WSL)
ls "/c/Users/$USERNAME/OneDrive - Technijian, Inc/Documents/obsidian/gsd-autonomous-dev/gsd-autonomous-dev/claude-memory/"
```

Expected output: `CHANGELOG.md  HEALTH.md  _archive  index.md  topics`

**If missing:** OneDrive hasn't synced yet. Wait for sync, or manually copy the vault from another machine. The vault must exist before hooks can write to it.

**If your OneDrive path differs** (e.g. different org name), set the `GSD_VAULT_MEMORY` environment variable (see Step 2).

---

## Step 2: Set GSD_VAULT_MEMORY (only if your vault path differs)

The hooks default to:
```
/c/Users/rjain/OneDrive - Technijian, Inc/Documents/obsidian/gsd-autonomous-dev/gsd-autonomous-dev/claude-memory
```

If your Windows username or OneDrive folder name differs, set this variable permanently:

```powershell
# PowerShell — replace the path with your actual vault path
$vaultPath = "C:\Users\YOUR_USERNAME\OneDrive - YOUR_ORG\Documents\obsidian\gsd-autonomous-dev\gsd-autonomous-dev\claude-memory"
[System.Environment]::SetEnvironmentVariable('GSD_VAULT_MEMORY', $vaultPath, 'User')
```

Then restart your terminal and verify:
```bash
echo $GSD_VAULT_MEMORY
ls "$GSD_VAULT_MEMORY/topics"
```

---

## Step 3: Set Environment Variables

Set all three permanently. Claude Code reads these from the Windows user environment.

```powershell
# Anthropic — backup LLM routing (CLI OAuth is primary, this activates on quota exhaustion)
[System.Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', 'sk-ant-YOUR_KEY', 'User')

# GitHub MCP — PR creation, issue tracking, review comments
[System.Environment]::SetEnvironmentVariable('GITHUB_PERSONAL_ACCESS_TOKEN', 'ghp_YOUR_TOKEN', 'User')

# Optional: Gemini fallback agent
[System.Environment]::SetEnvironmentVariable('GEMINI_API_KEY', 'YOUR_KEY', 'User')

# Optional: OpenAI Codex fallback agent
[System.Environment]::SetEnvironmentVariable('OPENAI_API_KEY', 'sk-YOUR_KEY', 'User')
```

**Restart your terminal** after setting these.

---

## Step 4: Rebuild GitNexus Index

The `.gitnexus/` index is gitignored and must be built per machine after clone.

```bash
cd C:\vscode\gsd-autonomous-dev\gsd-autonomous-dev

# First-time build
npx gitnexus analyze

# Verify
npx gitnexus --version   # should be 1.5.3+
ls .gitnexus/meta.json   # should exist
```

Expected output from meta.json: ~1084 symbols, ~2133 edges, 68 processes.

The `reindex.sh` hook will keep it current automatically after each `git commit` or `git merge`.

---

## Step 5: Rebuild Graphify Knowledge Graph

```bash
cd C:\vscode\gsd-autonomous-dev\gsd-autonomous-dev

# Build the graph
graphify .

# Verify
ls graphify-out/GRAPH_REPORT.md
```

---

## Step 6: Configure settings.local.json

`settings.local.json` is gitignored (it accumulates machine-specific permission approvals). Create a minimal version for a new workstation:

```bash
# From the project directory
cat > .claude/settings.local.json << 'EOF'
{
  "permissions": {
    "allow": [
      "Bash(grep:*)",
      "Bash(ls:*)",
      "Bash(git add:*)",
      "Bash(git commit:*)",
      "Bash(powershell:*)",
      "Bash(pwsh:*)",
      "Bash(claude:*)",
      "Bash(gemini:*)",
      "Bash(sed:*)",
      "Bash(awk:*)"
    ]
  }
}
EOF
```

Claude Code will prompt for additional approvals as you work; accepted permissions accumulate here automatically.

---

## Step 7: Configure Global CLAUDE.md

Each workstation needs `C:\Users\<username>\.claude\CLAUDE.md` with the LLM API quick reference. Copy the reference from the existing workstation's file at `C:\Users\rjain\.claude\CLAUDE.md` — it contains model endpoint configs for Anthropic, OpenAI, DeepSeek, Kimi, MiniMax, and GLM5.

If you are a different user, create `~/.claude/CLAUDE.md` and add:

```markdown
# userEmail
The user's email address is YOUR_EMAIL@technijian.com.
```

---

## Step 8: Install MCP Servers

MCP servers are workstation-level — they must be installed on each machine.

```bash
# Context7 — live library documentation (used in architecture, contract freeze, remediation)
claude mcp add context7 -- npx -y @upstash/context7-mcp@latest

# GitHub MCP is already declared in .claude/settings.json.
# It resolves from npm automatically when Claude Code starts.
# Just ensure GITHUB_PERSONAL_ACCESS_TOKEN is set (Step 3).
```

---

## Step 9: Initialize Vault Git Repo (recommended)

The Obsidian vault is not currently tracked by git. Initializing it lets you roll back any vault mutation.

```bash
VAULT_ROOT="/c/Users/$USERNAME/OneDrive - Technijian, Inc/Documents/obsidian/gsd-autonomous-dev/gsd-autonomous-dev"

git -C "$VAULT_ROOT" init

# Create .gitignore for Obsidian noise
cat > "$VAULT_ROOT/.gitignore" << 'EOF'
.obsidian/workspace*
.obsidian/cache
.obsidian/graph.json
.trash/
*.tmp
EOF

git -C "$VAULT_ROOT" add .
git -C "$VAULT_ROOT" commit -m "baseline: vault before Claude memory setup"
```

Note the commit hash somewhere safe — this is your rollback point.

---

## Verification Checklist

Run these after completing all steps:

```bash
cd C:\vscode\gsd-autonomous-dev\gsd-autonomous-dev

# 1. Vault accessible
ls "$GSD_VAULT_MEMORY/topics" 2>/dev/null || \
  ls "/c/Users/$USERNAME/OneDrive - Technijian, Inc/Documents/obsidian/gsd-autonomous-dev/gsd-autonomous-dev/claude-memory/topics"
# Expected: 5+ .md files

# 2. GitNexus indexed
ls .gitnexus/meta.json
# Expected: file exists, recent timestamp

# 3. Graphify graph built
ls graphify-out/GRAPH_REPORT.md
# Expected: file exists

# 4. Hooks are registered
cat .claude/settings.json | python3 -c "import sys,json; s=json.load(sys.stdin); print(list(s['hooks'].keys()))"
# Expected: ['PreToolUse', 'UserPromptSubmit', 'PostToolUse', 'Stop']

# 5. Hook scripts exist and are readable
ls .claude/hooks/
# Expected: consolidate.sh  health-check.sh  impact-check.sh  preference-extract.sh  reindex.sh  retrieve.sh

# 6. Slash commands registered
ls .claude/commands/
# Expected: consolidate.md  contradictions.md  graduate.md  review.md  vault-status.md  volatility.md

# 7. Env vars set
python3 -c "import os; vars=['ANTHROPIC_API_KEY','GITHUB_PERSONAL_ACCESS_TOKEN']; [print(f'OK: {v}') if os.environ.get(v) else print(f'MISSING: {v}') for v in vars]"

# 8. MCP — Context7
claude mcp list | grep context7
# Expected: context7 listed
```

---

## Slash Commands Available After Setup

| Command | Purpose |
|---------|---------|
| `/vault-status` | Health dashboard — topics, retrieval quality, freshness |
| `/consolidate` | Save durable session knowledge to vault |
| `/review` | Weekly vault review (run every 7 days) |
| `/contradictions` | List and resolve unresolved fact conflicts |
| `/volatility <topic> <stable\|evolving\|ephemeral>` | Set topic volatility |
| `/graduate` | Recommend stay vs. migrate to LightRAG |

---

## How the Memory Stack Works

```
User prompt
    │
    ▼
retrieve.sh (UserPromptSubmit)
    │  Loads matching vault topics + preferences.md into context
    ▼
Claude processes with vault context
    │
    ▼
Edit/Write tool called?
    │  impact-check.sh warns if HIGH/CRITICAL file (agent, orchestrator, harness)
    ▼
git commit/merge?
    │  reindex.sh rebuilds GitNexus index in background
    ▼
Session ends (Stop)
    ├── consolidate.sh  → reminds to run /consolidate if vault was accessed
    ├── health-check.sh → rewrites HEALTH.md with live metrics
    └── preference-extract.sh → signals to check for new preferences
```

Vault health is tracked in `claude-memory/HEALTH.md`. Run `/vault-status` to see it.
Run `/review` weekly — the health-check hook will escalate warnings if you skip it.

---

## Troubleshooting

**Hooks not firing:**
- Verify `.claude/settings.json` has the `hooks` key with all four event types
- Run `claude --version` — hooks require Claude Code v2.1.59+
- Check that bash is available: `bash --version`

**Vault topics not loading:**
- Run `/vault-status` and check if topics directory exists
- Verify `GSD_VAULT_MEMORY` points to the right path or that the default path exists
- Check `.claude/hooks/retrieve.sh` line 5 for the default path

**GitNexus stale:**
- Run `npx gitnexus analyze` manually
- The `reindex.sh` hook only fires after `git commit` or `git merge`

**health-check.sh fails:**
- Requires Python 3 — verify with `python3 --version`
- Must have read/write access to the vault path
