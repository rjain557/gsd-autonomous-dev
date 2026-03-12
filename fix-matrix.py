import json

path = 'D:/vscode/tech-web-chatai.v8/tech-web-chatai.v8/.gsd/health/requirements-matrix.json'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# Fix mojibake patterns (UTF-8 interpreted as latin-1 then re-encoded)
content = content.replace('\u00e2\u0080\u0094', '\u2014')  # em dash
content = content.replace('\u00e2\u0080\u0093', '\u2013')  # en dash
content = content.replace('\u00e2\u0080\u0099', '\u2019')  # right single quote
content = content.replace('\u00e2\u0080\u009c', '\u201c')  # left double quote
content = content.replace('\u00e2\u0080\u009d', '\u201d')  # right double quote

# Replace smart quotes and dashes with ASCII equivalents
content = content.replace('\u201c', '"')
content = content.replace('\u201d', '"')
content = content.replace('\u2018', "'")
content = content.replace('\u2019', "'")
content = content.replace('\u2014', '--')
content = content.replace('\u2013', '-')

# Try to find remaining issues by attempting parse
try:
    data = json.loads(content)
    print("JSON parsed successfully after fixes")
except json.JSONDecodeError as e:
    print(f"Still broken at line {e.lineno} col {e.colno}: {e.msg}")
    pos = e.pos
    print(f"Context: {repr(content[pos-50:pos+50])}")
    # Try brute force: replace all non-ASCII with closest ASCII
    import unicodedata
    fixed = []
    for c in content:
        if ord(c) > 127:
            fixed.append(' ')
        else:
            fixed.append(c)
    content = ''.join(fixed)
    try:
        data = json.loads(content)
        print("JSON parsed after ASCII cleanup")
    except json.JSONDecodeError as e2:
        print(f"STILL broken: line {e2.lineno} col {e2.colno}: {e2.msg}")
        print(f"Context: {repr(content[e2.pos-50:e2.pos+50])}")
        exit(1)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)

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
