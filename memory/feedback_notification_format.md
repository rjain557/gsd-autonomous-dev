---
name: notification-format
description: WhatsApp gets full detailed message first, ntfy gets short summary. Never send ntfy as attachment.
type: feedback
---

Full message goes to WhatsApp FIRST, then shortened summary to ntfy.

**Why:** User reported ntfy messages were arriving as attachments (too long) and WhatsApp wasn't getting the full message. ntfy should be brief; WhatsApp is for detail.

**How to apply:**
1. Write full detailed status to `C:\Users\rjain\.gsd-global\whatsapp-bridge\wa-outgoing.jsonl` as `{"text":"full message here"}`
2. Then send SHORT summary to ntfy (keep under ~200 chars in the body to avoid attachment mode)
3. Bridge polls wa-outgoing.jsonl every 5s and sends to WhatsApp group
