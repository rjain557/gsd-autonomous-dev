import json

path = 'D:/vscode/tech-web-chatai.v8/tech-web-chatai.v8/.gsd/health/requirements-matrix.json'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# Nuclear option: replace ALL non-ASCII characters with ASCII equivalents
replacements = {
    '\u2014': '--',   # em dash
    '\u2013': '-',    # en dash
    '\u201c': '"',    # left double quote (but we need to be careful in JSON)
    '\u201d': '"',    # right double quote
    '\u2018': "'",    # left single quote
    '\u2019': "'",    # right single quote
    '\u00e2': '',     # part of mojibake
    '\u00c3': '',
    '\u00a2': '',
    '\u0080': '',
    '\u0094': '',
    '\u0093': '',
    '\u0099': '',
    '\u009c': '',
    '\u009d': '',
}

for old, new in replacements.items():
    if old in content:
        count = content.count(old)
        print(f"Replacing {repr(old)} ({count} occurrences)")
        content = content.replace(old, new)

# Now strip any remaining non-ASCII that could cause issues
# But preserve the content within JSON string values
cleaned = []
for c in content:
    if ord(c) > 127:
        print(f"  Remaining non-ASCII: {repr(c)} (U+{ord(c):04X})")
        cleaned.append(' ')
    else:
        cleaned.append(c)
content = ''.join(cleaned)

# Fix any double-space artifacts
while '  ' in content and content.count('  ') < 1000:
    pass  # leave double spaces, they're fine in JSON strings

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)

# Verify
try:
    data = json.loads(content)
    print("\nJSON parsed successfully!")
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
    print(f"\nStill broken: line {e.lineno} col {e.colno}: {e.msg}")
    print(f"Context: {repr(content[e.pos-80:e.pos+80])}")
