---
name: feedback-mark-reqs-complete
description: ALWAYS mark requirements as satisfied and update health score after fixing them — never forget this step
type: feedback
---

When fixing requirements (directly or through validation), ALWAYS mark them as satisfied in requirements-matrix.json and update the health score immediately after.

**Why:** User has had to remind multiple times. Fixing code without updating the tracking matrix means the health score is wrong and nobody knows the fix was applied.

**How to apply:** After every successful requirement fix (direct edit, pipeline validation fix, or any other method), immediately:
1. Update `requirements-matrix.json` — set status to `satisfied`
2. Recalculate and report the new health score
3. Update cross-session.md shared state with new health numbers
