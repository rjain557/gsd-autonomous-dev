import json, re

path = 'D:/vscode/tech-web-chatai.v8/tech-web-chatai.v8/.gsd/health/requirements-matrix.json'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# Strip ALL remaining non-ASCII
cleaned = []
for c in content:
    if ord(c) > 127:
        cleaned.append(' ')
    else:
        cleaned.append(c)
content = ''.join(cleaned)

# Now find stray quotes inside JSON string values
# Pattern: space+space+"+space+space inside what should be a string value
# These are artifacts from em-dash mojibake cleanup (3 chars became spaces + quote)
content = re.sub(r'  "   ', ' -- ', content)
content = re.sub(r' " ', ' -- ', content)

# Also handle: text  "  text (2 spaces, quote, 2 spaces)
content = re.sub(r'(\w)  "  (\w)', r'\1 -- \2', content)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)

# Iteratively find and fix remaining issues
for attempt in range(10):
    try:
        data = json.loads(content)
        print(f"JSON parsed successfully on attempt {attempt + 1}!")
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

        # Write the clean version
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2, ensure_ascii=True)
        print("\nWrote clean ASCII JSON")
        break
    except json.JSONDecodeError as e:
        # Find the problematic quote and replace it
        pos = e.pos
        context = content[max(0,pos-20):pos+20]
        print(f"Attempt {attempt+1}: fixing at pos {pos}: {repr(context)}")

        # Find the stray quote - look backwards from error position for a quote that's inside a value
        # The error is typically "Expecting ',' delimiter" which means we hit a quote that closed a string early
        # Find the offending quote and replace it with --
        search_start = max(0, pos - 5)
        search_end = min(len(content), pos + 5)
        chunk = content[search_start:search_end]

        # Replace the first quote in this chunk that seems to be a stray
        # Look for pattern: non-backslash + " + non-comma/colon/bracket
        for i in range(search_start, search_end):
            if content[i] == '"' and i > 0 and i < len(content)-1:
                before = content[i-1]
                after = content[i+1]
                # A legitimate JSON quote would be followed by , : ] } or preceded by { [ , :
                if before not in '\\{[,:' and after not in ',:]}\n':
                    content = content[:i] + '--' + content[i+1:]
                    print(f"  Replaced stray quote at pos {i}")
                    break

        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)
