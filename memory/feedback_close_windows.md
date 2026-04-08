---
name: feedback-close-powershell-windows
description: When killing a pipeline process, ALSO close its PowerShell window — don't leave orphaned windows
type: feedback
---

BEFORE starting any new bridge or pipeline PowerShell window, ALWAYS kill the old process AND close its PowerShell window FIRST. Never leave orphaned windows.

**Why:** User has corrected this MANY times. Old windows pile up and confuse the user. This applies to ALL restarts: bridge, pipeline, any visible PowerShell process.

**How to apply:**
1. Get the old PID from health file or config
2. Find and kill the PowerShell window hosting it: `Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -eq OLD_PID } | ForEach-Object { Stop-Process -Id $_.ParentProcessId -Force -EA SilentlyContinue }; Stop-Process -Id OLD_PID -Force -EA SilentlyContinue`
3. Wait 2s for cleanup
4. ONLY THEN start the new window

This is a BLOCKING step — never skip it.
