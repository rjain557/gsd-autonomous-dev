#!/usr/bin/env bash
# health-check.sh — Stop hook
# Recomputes HEALTH.md metrics from vault file state.

VAULT="${GSD_VAULT_MEMORY:-"/c/Users/rjain/OneDrive - Technijian, Inc/Documents/obsidian/gsd-autonomous-dev/gsd-autonomous-dev/claude-memory"}"
HEALTH="$VAULT/HEALTH.md"
TOPICS="$VAULT/topics"
LOG="$VAULT/.retrieval-log.jsonl"

[ -d "$TOPICS" ] || exit 0

python3 - "$VAULT" <<'PYEOF'
import os, json, datetime, re, sys

vault = sys.argv[1] if len(sys.argv) > 1 else "/c/Users/rjain/OneDrive - Technijian, Inc/Documents/obsidian/gsd-autonomous-dev/gsd-autonomous-dev/claude-memory"
topics_dir = os.path.join(vault, "topics")
health_file = os.path.join(vault, "HEALTH.md")
log_file = os.path.join(vault, ".retrieval-log.jsonl")

today = datetime.date.today()
now_iso = today.isoformat()

# Count topics and volatility distribution
topic_files = [f for f in os.listdir(topics_dir) if f.endswith(".md")]
topic_count = len(topic_files)
volatility = {"stable": 0, "evolving": 0, "ephemeral": 0}

stale_60 = 0
stale_180 = 0
total_words = 0

for fname in topic_files:
    fpath = os.path.join(topics_dir, fname)
    with open(fpath, encoding="utf-8") as f:
        content = f.read()
    words = len(content.split())
    total_words += words

    vol_match = re.search(r"^volatility:\s*(\w+)", content, re.MULTILINE)
    if vol_match:
        v = vol_match.group(1)
        if v in volatility:
            volatility[v] += 1

    date_match = re.search(r"^last_updated:\s*(\d{4}-\d{2}-\d{2})", content, re.MULTILINE)
    if date_match:
        last_updated = datetime.date.fromisoformat(date_match.group(1))
        age = (today - last_updated).days
        if age > 60:
            stale_60 += 1
        if age > 180:
            stale_180 += 1

# Retrieval stats (last 30 days)
cutoff_30 = (datetime.datetime.utcnow() - datetime.timedelta(days=30)).isoformat() + "Z"
attempts = 0
sessions_this_week = set()
new_topics_this_week = 0
cutoff_7 = (datetime.datetime.utcnow() - datetime.timedelta(days=7)).isoformat() + "Z"

try:
    with open(log_file, encoding="utf-8") as f:
        for line in f:
            try:
                e = json.loads(line.strip())
                ts = e.get("ts", "")
                if ts > cutoff_30 and e.get("event") == "retrieve":
                    attempts += 1
                if ts > cutoff_7 and e.get("event") == "session_end":
                    sessions_this_week.add(ts[:10])
            except:
                pass
except:
    pass

# Determine status
if topic_count > 400 or stale_180 / max(topic_count, 1) > 0.25:
    status = "RED"
elif topic_count > 150 or stale_180 / max(topic_count, 1) > 0.10:
    status = "YELLOW"
elif attempts < 10:
    status = "PENDING"
else:
    status = "GREEN"

avg_words = total_words // max(topic_count, 1)

# Read last review date from existing HEALTH.md
last_review = "NEVER"
try:
    with open(health_file, encoding="utf-8") as f:
        for line in f:
            if "Last review:" in line:
                last_review = line.split("Last review:")[1].strip()
                break
except:
    pass

if last_review == "NEVER":
    days_since = "N/A"
    review_status_color = "RED"
    next_review = "ASAP"
else:
    try:
        lr_date = datetime.date.fromisoformat(last_review)
        days_since = (today - lr_date).days
        review_status_color = "GREEN" if days_since < 7 else ("YELLOW" if days_since < 14 else "RED")
        next_review = (lr_date + datetime.timedelta(days=7)).isoformat()
    except:
        days_since = "N/A"
        review_status_color = "RED"
        next_review = "ASAP"

content = f"""# Vault Health

## Weekly Review Status
- Last review: {last_review}
- Days since last review: {days_since}
- Review status: {review_status_color}
- Unresolved contradictions: 0
- Next review due: {next_review}

## Status: {status}
{'(Insufficient retrieval data — need 30+ days)' if status == 'PENDING' else ''}

## Size Metrics
- Topic count: {topic_count}
- Total words: {total_words}
- Avg words/page: {avg_words}

## Retrieval Quality (last 30 days)
- Retrieval attempts: {attempts}
- {'N/A — insufficient data' if attempts < 5 else 'See log for details'}

## Freshness
- Stale >60 days: {stale_60}
- Stale >180 days: {stale_180}

## Traffic (last 7 days)
- Active session days: {len(sessions_this_week)}

## Volatility Distribution
- stable: {volatility['stable']} ({volatility['stable']*100//max(topic_count,1)}%)
- evolving: {volatility['evolving']} ({volatility['evolving']*100//max(topic_count,1)}%)
- ephemeral: {volatility['ephemeral']} ({volatility['ephemeral']*100//max(topic_count,1)}%)

_Updated: {now_iso}_
"""

with open(health_file, "w", encoding="utf-8") as f:
    f.write(content)

print(f"HEALTH.md updated: {status}, {topic_count} topics")
PYEOF
