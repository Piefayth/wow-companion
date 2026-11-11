"""Find globals our Lua reads that nothing defines.

The game is the only Lua we can run, so a name that resolves to nothing is found
there, as a nil call, a reload later. Twice on 2026-11-10 it was a local used
above its `local` line, which Lua reads as a global (Interact.lua's trace probe:
an error on every loot). This walks each file's scopes, sees which names are
locals where they are used, and reports every other name that is not:

  - defined as a global by any of our files (addon/, modules/),
  - in the game's API list (docs/api-1.60.1.txt, first part of a dotted name),
  - defined by Blizzard's interface code (docs/wow-ui-source, functions,
    globals, XML frame names), or
  - in Lua's own library.

    python -I tools/luaglobals.py                 # every addon and module file
    python -I tools/luaglobals.py <file.lua> ...  # only these, against the rest
    --notes   also list existence checks for names defined nowhere (dead branches)

Not a Lua parser: a tokenizer with block and scope tracking. Secure snippets
(strings) and comments are blanked first (tools/luacheck.py's strip), so code
inside a snippet is not checked.
"""

import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from luacheck import strip  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEYWORDS = set("""and break do else elseif end false for function goto if in local nil not
or repeat return then true until while""".split())
LUA = set("""_G _VERSION assert collectgarbage error getfenv getmetatable ipairs load loadstring
next pairs pcall print rawequal rawget rawset select setfenv setmetatable tonumber tostring type
unpack xpcall coroutine math string table bit os debug newproxy gcinfo self arg""".split())
# made by the client itself, not by any Lua or XML in the interface source
CLIENT = set("""UIParent WorldFrame Enum SlashCmdList Constants GlobalStrings
ChatFrame1EditBox""".split())  # the last from a template ($parentEditBox)
# ours, but written by the companion (src/modules.rs) into the gitignored Modules.lua
CLIENT.add("WowCompanion_DiskModules")
# ALL_CAPS names are the client's GlobalStrings (YES, ERR_INV_FULL...): not in
# the source, so accepted by shape
GLOBAL_STRING = re.compile(r"^[A-Z][A-Z0-9_]*$")
TOKEN = re.compile(r"""
    (?P<num>0[xX][0-9a-fA-F]+|\d+\.?\d*(?:[eE][-+]?\d+)?|\.\d+)
  | (?P<name>[A-Za-z_]\w*)
  | (?P<op>\.\.\.|\.\.|==|~=|<=|>=|::|[-+*/%^#<>=(){}\[\];:,.])
""", re.X)


def tokens(code):
    line = 1
    at = 0
    for m in TOKEN.finditer(code):
        line += code.count("\n", at, m.start())
        at = m.start()
        kind = m.lastgroup
        yield kind, m.group(kind), line


def analyse(code):
    """(globals read: [(name, line)], globals assigned: {name}, all local names: {name: line})"""
    toks = list(tokens(code))
    scopes = [set()]
    reads, assigned, declared = [], set(), {}
    braces = 0
    skip_do = 0          # `for` opened its scope already; its `do` opens none
    i = 0

    def declare(name, line):
        scopes[-1].add(name)
        declared.setdefault(name, line)

    def resolved(name):
        return any(name in s for s in scopes)

    def params(j):
        # j points at "(" after `function [name]`; declare the parameters
        j += 1
        while j < len(toks) and toks[j][1] != ")":
            if toks[j][0] == "name":
                declare(toks[j][1], toks[j][2])
            j += 1
        return j

    while i < len(toks):
        kind, text, line = toks[i]
        prev = toks[i - 1][1] if i else None
        nxt = toks[i + 1][1] if i + 1 < len(toks) else None
        if text == "{":
            braces += 1
        elif text == "}":
            braces -= 1
        elif text == "local" and nxt == "function":
            declare(toks[i + 2][1], toks[i + 2][2])
            scopes.append(set())
            i = params(i + 3) + 1
            continue
        elif text == "local":
            j = i + 1
            while j < len(toks) and toks[j][0] == "name":
                declare(toks[j][1], toks[j][2])
                if j + 1 < len(toks) and toks[j + 1][1] == ",":
                    j += 2
                else:
                    break
            i = j + 1
            continue
        elif text == "function":
            # named: function a.b:c(  -- the first name is read, the rest are fields
            j = i + 1
            method = False
            if toks[j][0] == "name":
                if not resolved(toks[j][1]) and toks[j + 1][1] in ("(",):
                    assigned.add(toks[j][1])
                elif not resolved(toks[j][1]):
                    reads.append((toks[j][1], toks[j][2], False))
                while toks[j + 1][1] in (".", ":"):
                    method = method or toks[j + 1][1] == ":"
                    j += 2
                j += 1
            scopes.append(set())
            if method:
                scopes[-1].add("self")
            i = params(j) + 1
            continue
        elif text == "for":
            scopes.append(set())
            skip_do += 1
            j = i + 1
            while toks[j][0] == "name" or toks[j][1] == ",":
                if toks[j][0] == "name":
                    declare(toks[j][1], toks[j][2])
                j += 1
            i = j
            continue
        elif text == "do":
            if skip_do:
                skip_do -= 1
            else:
                scopes.append(set())
        elif text in ("then", "repeat"):
            scopes.append(set())
        elif text == "elseif":
            scopes.pop()
        elif text == "else":
            scopes.pop()
            scopes.append(set())
        elif text in ("end", "until"):
            if len(scopes) > 1:
                scopes.pop()
        elif kind == "name" and text not in KEYWORDS:
            if prev in (".", ":"):
                pass                                  # a field
            elif braces and prev in ("{", ",", ";") and nxt == "=":
                pass                                  # a table key
            elif not resolved(text):
                if nxt == "=" and not braces:
                    assigned.add(text)
                else:
                    guard = nxt in ("and", "then", "or") or prev in ("not", "if")
                    reads.append((text, line, guard))
        i += 1
    return reads, assigned, declared


def blizzard_names():
    names = set()
    api = os.path.join(ROOT, "docs", "api-1.60.1.txt")
    if os.path.exists(api):
        for l in open(api, encoding="utf-8", errors="replace"):
            l = l.strip()
            if l and not l.startswith("--"):
                names.add(l.split(".")[0])
    src = os.path.join(ROOT, "docs", "wow-ui-source", "Interface")
    fn = re.compile(r"^\s*function\s+([A-Za-z_]\w*)\s*[.:(]", re.M)
    glob_assign = re.compile(r"^([A-Za-z_]\w*)\s*=[^=]", re.M)
    xml_name = re.compile(r'\bname="([A-Za-z_]\w*)"')
    for path in glob.iglob(os.path.join(src, "**", "*.*"), recursive=True):
        if path.endswith(".lua"):
            text = open(path, encoding="utf-8", errors="replace").read()
            names.update(fn.findall(text))
            names.update(glob_assign.findall(text))
        elif path.endswith(".xml"):
            names.update(xml_name.findall(open(path, encoding="utf-8", errors="replace").read()))
    return names


def ours():
    files = sorted(glob.glob(os.path.join(ROOT, "addon", "*", "**", "*.lua"), recursive=True))
    files += sorted(glob.glob(os.path.join(ROOT, "modules", "*.lua")))
    return [f for f in files if not f.endswith(os.sep + "Modules.lua")]


def main(args):
    verbose = "--notes" in args
    args = [a for a in args if a != "--notes"]
    every = ours()
    targets = [os.path.abspath(a) for a in args] or every
    parsed = {}
    defined = set()
    # the saved-variable tables each .toc declares (the game makes them)
    for toc in glob.glob(os.path.join(ROOT, "addon", "*", "*.toc")):
        for line in open(toc, encoding="utf-8", errors="replace"):
            m = re.match(r"##\s*SavedVariables(?:PerCharacter)?\s*:\s*(.+)", line)
            if m:
                defined.update(n.strip() for n in m.group(1).split(","))
    for path in set(every) | set(targets):
        code, _ = strip(open(path, encoding="utf-8").read())
        parsed[path] = analyse(code)
        defined |= parsed[path][1]
        # also frames our Lua names: CreateFrame("Button", "WCName", ...)
        raw = open(path, encoding="utf-8").read()
        defined.update(re.findall(r"""CreateFrame\(\s*["']\w+["']\s*,\s*["']([A-Za-z_]\w*)["']""", raw))
        defined.update(re.findall(r"""_G\[\s*["']([A-Za-z_]\w*)["']\s*\]\s*=""", raw))
        defined.update(re.findall(r'\bSLASH_\w+', raw))
    # other addons' globals, from what we know of each (integrations/*.md)
    for md in glob.glob(os.path.join(ROOT, "integrations", "*.md")):
        defined.update(re.findall(r"`([A-Z][A-Za-z_]\w*)[.:(]", open(md, encoding="utf-8").read()))
    known = LUA | CLIENT | blizzard_names() | defined
    problems = 0
    for path in targets:
        reads, _, declared = parsed[path]
        # `if X then X()` / `X and X()`: a check for something this client may
        # lack. Not an error, but when the name exists nowhere, the branch is dead.
        guarded = {}
        for name, line, guard in reads:
            if guard:
                guarded.setdefault(name, set()).update(range(line, line + 8))
        seen = set()
        for name, line, _ in reads:
            if name in known or GLOBAL_STRING.match(name) or (name, line) in seen:
                continue
            if line in guarded.get(name, ()):
                if (name, "dead") not in seen and verbose:
                    print(f"{os.path.relpath(path, ROOT)}:{line}: note: {name} is checked for but defined nowhere (a dead branch?)")
                seen.add((name, "dead"))
                continue
            seen.add((name, line))
            hint = ""
            if name in declared:
                hint = f" (a local of that name is declared at line {declared[name]}: used above it, or outside its block?)"
            print(f"{os.path.relpath(path, ROOT)}:{line}: global {name} is defined nowhere{hint}")
            problems += 1
    print("no undefined globals" if not problems else f"{problems} undefined global(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
