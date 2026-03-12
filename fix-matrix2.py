import json, re

path = 'D:/vscode/tech-web-chatai.v8/tech-web-chatai.v8/.gsd/health/requirements-matrix.json'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# Find the mojibake pattern: \u00e2\u20ac followed by " (which breaks JSON)
# This is an em-dash that got double-encoded
# Replace â€" (where " is literal) with --
# The char â is \u00e2, € is \u20ac
target = '\u00e2\u20ac"'
count = content.count(target)
print(f"Found {count} occurrences of mojibake em-dash with stray quote")
content = content.replace(target, '--')

# Also replace â€ (without the quote, just the leftover)
target2 = '\u00e2\u20ac'
count2 = content.count(target2)
print(f"Found {count2} remaining occurrences of â€")
content = content.replace(target2, '--')

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)

# Verify
try:
    data = json.loads(content)
    print("JSON parsed successfully!")
    reqs = data['requirements']
    s = sum(1 for r in reqs if r['status'] == 'satisfied')
    p = sum(1 for r in reqs if r['status'] == 'partial')
    n = sum(1 for r in reqs if r['status'] == 'not_started')
    t = len(reqs)
    score = round((s + 0.5 * p) / t * 100, 1)
    print(f'Matrix: {s} satisfied, {p} partial, {n} not_started / {t} total = {score}%')
    print()
    print('NOT STARTED:')
    for r in reqs:
        if r['status'] == 'not_started':
            print(f"  {r['id']}: {r['description'][:90]}")
    print()
    print('PARTIAL:')
    for r in reqs:
        if r['status'] == 'partial':
            print(f"  {r['id']}: {r['description'][:90]}")
except json.JSONDecodeError as e:
    print(f"Still broken: line {e.lineno} col {e.colno}: {e.msg}")
    print(f"Context: {repr(content[e.pos-50:e.pos+50])}")
