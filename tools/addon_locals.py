import re
P = 'addon/WowCompanion/'


def strip(s):
    s = re.sub(r'"(\\.|[^"\\])*"', '""', s)
    s = re.sub(r"'(\\.|[^'\\])*'", "''", s)
    s = re.sub(r'--.*', '', s)
    return s


def locals_of(text, top_only):
    names = set()
    for l in text.split('\n'):
        if top_only and not l.startswith('local'):
            continue
        for m in re.finditer(r'local function ([A-Za-z_]\w*)', l):
            names.add(m.group(1))
        for m in re.finditer(r'local ([A-Za-z_][\w, ]*?)\s*(=|$|\bin\b)', l):
            for n in m.group(1).split(','):
                names.add(n.strip())
        for m in re.finditer(r'function\s*[\w.:]*\(([^)]*)\)', l):
            for n in m.group(1).split(','):
                names.add(n.strip())
        for m in re.finditer(r'for ([\w, ]+) in', l):
            for n in m.group(1).split(','):
                names.add(n.strip())
        for m in re.finditer(r'for (\w+)\s*=', l):
            names.add(m.group(1))
    return names


core = open(P + 'Companion.lua', encoding='utf-8').read()
core_top = locals_of(core, True)
for name in ['Engine.lua', 'Style.lua', 'Pins.lua', 'Strip.lua', 'Bags.lua']:
    text = open(P + name, encoding='utf-8').read()
    own = locals_of(text, False)
    toks = set(re.findall(r'(?<![\w.:])([A-Za-z_]\w*)', strip(text)))
    hit = sorted(t for t in toks if t in core_top and t not in own)
    print(name, 'uses Companion locals:', hit)
# and the reverse: names the core uses that were locals only in a moved file
moved_top = set()
for name in ['Engine.lua', 'Style.lua', 'Pins.lua', 'Strip.lua', 'Bags.lua']:
    moved_top |= locals_of(open(P + name, encoding='utf-8').read(), True)
toks = set(re.findall(r'(?<![\w.:])([A-Za-z_]\w*)', strip(core)))
print('Companion uses moved locals:', sorted(t for t in toks & moved_top if t not in locals_of(core, False)))
