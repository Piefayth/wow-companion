"""Move a range of Companion.lua into its own file, as a pure move.

    python -I tools/split_addon.py <first line> <line after last> <New.lua> <Table> [--dry]

The block's top-level locals that Companion.lua still uses become WC.<Table>.<name>
(functions get a one-line local wrapper where the block was; anything else is
refused, since a copied scalar would go stale). Companion.lua's locals the block
uses are published once, at the end of Companion.lua, as WC.Core.<name>, and the
new file takes them back as locals. The new file goes into the .toc right after
Companion.lua, so everything it reads is defined by the time it runs.
"""

import re
import sys

P = 'addon/WowCompanion/'
exec(open('tools/addon_locals.py', encoding='utf-8').read().split('core = open')[0])
sys.path.insert(0, 'tools')
from luacheck import strip as _blank  # strings and comments, done properly

_locals_of = locals_of


def code(text):
    return _blank(text)[0]


def locals_of(text, top_only):
    return _locals_of(code(text), top_only)


def top_locals(text):
    # only what is declared at the top level: no parameters, no inner locals
    names = set()
    for l in code(text).splitlines():
        m = re.match(r'local function (\w+)', l)
        if m:
            names.add(m.group(1))
            continue
        m = re.match(r'local ([A-Za-z_][\w, ]*?)\s*(=|$)', l)
        if m:
            names |= {n.strip() for n in m.group(1).split(',')}
    return names


def tokens(text):
    return set(re.findall(r'(?<![\w.:])([A-Za-z_]\w*)', code(text)))


def main():
    # The range is given by text, never by number: other conversations edit
    # Companion.lua too, and a cut by stale line numbers once fell mid-function.
    start_text, stop_text, newfile, table = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    dry = '--dry' in sys.argv
    src = open(P + 'Companion.lua', encoding='utf-8').read()
    lines = src.split('\n')
    starts = [i for i, l in enumerate(lines) if l.startswith(start_text)]
    stops = [i for i, l in enumerate(lines) if l.startswith(stop_text)]
    if len(starts) != 1 or len(stops) != 1 or stops[0] <= starts[0]:
        print('REFUSED: the start and stop lines must each match exactly once, in order:', starts, stops)
        sys.exit(1)
    first, after = starts[0] + 1, stops[0] + 1
    block = lines[first - 1:after - 1]
    rest = lines[:first - 1] + lines[after - 1:]
    btext, rtext = '\n'.join(block), '\n'.join(rest)
    rest_top, block_top = top_locals(rtext), top_locals(btext)
    block_all = locals_of(btext, False)
    # Generous on purpose: a name also declared in an inner scope may still be
    # used at the top, and an extra import or wrapper is harmless.
    needs = sorted(t for t in tokens(btext) if t in rest_top and t not in block_top)
    gives = sorted(t for t in tokens(rtext) & block_top if t not in rest_top)
    funcs = set(re.findall(r'^local function (\w+)', btext, re.M))
    print('block', first, '-', after - 1, f'({len(block)} lines)')
    print('needs from Companion:', needs)
    print('Companion needs from block:', gives)
    bad = [g for g in gives if g not in funcs]
    if bad:
        print('REFUSED: Companion uses non-function locals of the block:', bad)
        sys.exit(1)
    # a name Companion.lua reassigns would go stale as a copied local: the block
    # reads it through a getter instead
    mutable = [n for n in needs if re.search(r'^[ 	]+%s\s*=[^=]' % re.escape(n), rtext, re.M)
               or re.search(r'^%s\s*=[^=]' % re.escape(n), rtext, re.M)]
    inner = [n for n in mutable if n in block_all]
    if inner:
        # the block declares its own: those uses are its own, leave them alone
        print('also declared inside the block, check by hand:', inner)
        mutable = [n for n in mutable if n not in inner]
        needs = [n for n in needs if n not in inner]
    if mutable:
        print('read through getters (reassigned in Companion):', mutable)
        assigned = [n for n in mutable if re.search(r'(?<![\w.:])%s\s*=[^=]' % re.escape(n), code(btext))]
        if assigned:
            print('REFUSED: the block assigns', assigned)
            sys.exit(1)
        for n in mutable:
            block = [re.sub(r'(?<![\w.:])%s(?!\w)' % re.escape(n), n + '_now()', l) for l in block]
    needs = [n for n in needs if n not in mutable]
    if dry:
        return
    already = set(re.findall(r'^WC\.Core\.(\w+) = ', src, re.M))
    head = [f'-- Split out of Companion.lua (2026-11-10). What it needs from there comes',
            f'-- through WC.Core; what Companion.lua calls here is WC.{table}.', '',
            'local core = WC.Core'] + [f'local {n} = core.{n}' for n in needs] +         [f'local function {n}_now() return core.{n}_get() end' for n in mutable] + ['']
    tail = ['', f'WC.{table} = WC.{table} or {{}}'] + [f'WC.{table}.{g} = {g}' for g in gives] + ['']
    open(P + newfile, 'w', encoding='utf-8', newline='\n').write('\n'.join(head + block + tail))
    wrappers = [f'local function {g}(...) return WC.{table}.{g}(...) end' for g in gives]
    out = lines[:first - 1] + [f'-- moved to {newfile}'] + wrappers + lines[after - 1:]
    pub = [f'WC.Core.{n} = {n}' for n in needs if n not in already] +         [f'WC.Core.{n}_get = function() return {n} end' for n in mutable if n + '_get' not in already]
    if pub:
        out += ['', f'-- for {newfile}', 'WC.Core = WC.Core or {}'] + pub + ['']
    if open(P + 'Companion.lua', encoding='utf-8').read() != src:
        print('REFUSED: Companion.lua changed while this ran; nothing written')
        import os
        os.remove(P + newfile)
        sys.exit(1)
    open(P + 'Companion.lua', 'w', encoding='utf-8', newline='\n').write('\n'.join(out))
    toc = open(P + 'WowCompanion.toc', encoding='utf-8').read()
    if newfile not in toc:
        toc = toc.replace('Companion.lua\n', f'Companion.lua\n{newfile}\n', 1)
        open(P + 'WowCompanion.toc', 'w', encoding='utf-8', newline='\n').write(toc)
    print('moved; wrote', newfile)


main()
