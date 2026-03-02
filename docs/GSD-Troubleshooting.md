\# GSD Troubleshooting Guide



\## Installation Issues



\### "running scripts is disabled on this system"

Fix: Run with execution policy bypass:

&nbsp; powershell -ExecutionPolicy Bypass -File install-gsd-all.ps1



\### "gsd-assess is not recognized"

The profile was not loaded. Either:

1\. Restart your terminal (close and reopen)

2\. Manually source: . $PROFILE



\### "command claude not found" or "command codex not found"

CLI not installed or not in PATH:

&nbsp; npm install -g @anthropic-ai/claude-code

&nbsp; npm install -g @openai/codex

Then restart terminal.



\## Runtime Issues



\### "Another GSD process is running (lock file age: X min)"

A previous run left a stale lock. Clear it:

&nbsp; Remove-Item ".gsd\\.gsd-lock" -Force



\### "Quota exhausted on claude" / "Sleeping 60 minutes"

Your API quota (or OAuth session limit) is exhausted. The engine sleeps and retries automatically. If using OAuth, close other Claude sessions to free quota. Check usage at console.anthropic.com/settings/usage



\### "Network unavailable. Polling every 30s..."

Network connectivity lost. The engine polls until back. Check your internet connection. If you are behind a firewall, ensure claude CLI can reach Anthropic APIs.



\### Codex "exit code 2" with batch reduction to minimum

Codex CLI crashed. Common causes:

1\. \*\*Wrong working

