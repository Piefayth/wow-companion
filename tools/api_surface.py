"""The usable API surface of this client, and the terms of using each part.

Joins four sources, none of which says it alone:
  docs/api-1.60.1.txt              every name that exists (the client, /wc dump)
  docs/api-1.60.1-signatures.txt   signatures and flags for the documented ones
  warcraft.wiki.gg (its API)       protected / nocombat / hwevent tags, which cover
                                   the undocumented legacy globals the client's docs skip
  docs/wow-ui-source               how often Blizzard's own UI calls each function
  docs/api-useful.md               what this project has measured itself

Writes docs/api-surface.md (the answer, summarised) and docs/api-surface.tsv
(every name, one row, for grepping). Rerun after a patch:
  python -I tools/api_surface.py
"""
import collections
import json
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(ROOT, "docs")
WIKI_CACHE = os.path.join(DOCS, "api-wiki-tags.tsv")
WIKI_URL = ("https://warcraft.wiki.gg/api.php?action=parse&page=World_of_Warcraft_API"
            "&prop=wikitext&format=json")

# The tiers, strictest first. A function lands in the first that applies.
TIERS = [
    ("protected", "Not callable from addon code at all. Route: a secure button the player presses (macro text), never a call."),
    ("hardware", "Only inside the player's own press (a click or key handler). Route: a secure button."),
    ("nocombat", "Callable, but only out of combat (InCombatLockdown() false)."),
    ("restricted", "Flagged HasRestrictions: some contexts refuse it, and the docs do not say which. Read Blizzard's callers first; test once, out of combat."),
    ("secret", "Callable, but its results can come back as secret values (in combat, encounters, PvP, restricted units): opaque to addon code, so no comparing, maths or string work on them; they can only be handed to display widgets."),
    ("precondition", "Callable once its data exists (Requires...: friend list, clubs, a valid slot, a loaded cvar)."),
    ("free", "No documented condition. Still never call blind: one such read crashed the client in C."),
    ("blizzard-lua", "Not engine API: a Lua function Blizzard's own interface defines (docs/wow-ui-source). Callable, but it then runs as your code, tainted. Harmless for pure helpers (MinutesToTime); for anything that shows, hides, moves or sets Blizzard's frames it is the taint that broke A and B. Read its source first."),
    ("unknown", "Undocumented by the client and untagged by the wiki: nothing says. Blizzard's own use, if any, is the evidence."),
]


def read(path):
    with open(path, encoding="utf-8-sig") as handle:
        return handle.read()


def wiki_tags():
    """name -> set of tags, cached in docs so a rerun needs no network."""
    if not os.path.exists(WIKI_CACHE) or "--refresh" in sys.argv:
        request = urllib.request.Request(WIKI_URL, headers={"User-Agent": "wow-companion-api-survey"})
        text = json.load(urllib.request.urlopen(request, timeout=60))["parse"]["wikitext"]["*"]
        rows = []
        for line in text.splitlines():
            found = re.match(r"^:\s*\[\[API:([^|\]]+)\|", line)
            if not found:
                continue
            tags = sorted(set(re.findall(r"\{\{apitag\|([a-z]+)", line)))
            rows.append((found.group(1).strip(), ",".join(tags)))
        with open(WIKI_CACHE, "w", encoding="utf-8", newline="\n") as out:
            out.write("# from warcraft.wiki.gg World_of_Warcraft_API (retail-era; CC BY-SA), name<TAB>tags\n")
            for name, tags in rows:
                out.write(f"{name}\t{tags}\n")
    tags = {}
    for line in read(WIKI_CACHE).splitlines():
        if line.startswith("#") or "\t" not in line:
            continue
        name, found = line.split("\t", 1)
        tags[name] = set(filter(None, found.split(",")))
    return tags


def signatures():
    """name -> (signature line, {flag: value})"""
    out = {}
    for line in read(os.path.join(DOCS, "api-1.60.1-signatures.txt")).splitlines():
        found = re.match(r"^([A-Za-z_][\w.:]*)\(", line)
        if not found:
            continue
        flags = {}
        bracket = re.search(r"\[(.*)\]\s*$", line)
        if bracket:
            for pair in bracket.group(1).split():
                key, _, value = pair.partition("=")
                flags[key] = value or "true"
        out[found.group(1)] = (line, flags)
    return out


def blizzard_uses():
    """identifier -> how many times Blizzard's UI code mentions it, and the set of
    names Blizzard's Lua itself defines"""
    counts = collections.Counter()
    defined = set()
    definition = re.compile(r"^\s*(?:local\s+)?function\s+([A-Za-z_][\w.:]*)\s*\(|^\s*([A-Za-z_]\w*)\s*=\s*(?:function|[A-Za-z_][\w.:]*\s*;?\s*$)", re.M)
    source = os.path.join(DOCS, "wow-ui-source")
    token = re.compile(r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)?")
    for folder, _, files in os.walk(source):
        if "APIDocumentationGenerated" in folder:
            continue
        for name in files:
            if name.endswith(".lua"):
                with open(os.path.join(folder, name), encoding="utf-8", errors="replace") as handle:
                    text = handle.read()
                    counts.update(token.findall(text))
                    for one, two in definition.findall(text):
                        defined.add((one or two).replace(":", "."))
    return counts, defined


def measured():
    """names that docs/api-useful.md records as measured or do-not-use"""
    statuses = {}
    for line in read(os.path.join(DOCS, "api-useful.md")).splitlines():
        if not line.startswith("|") or "---" in line:
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if len(cells) < 2:
            continue
        status = "do not use" if "do not use" in cells[1] else cells[1].split(":")[0].strip("* ")
        for name in re.findall(r"`([A-Za-z_][\w.]*)", cells[0]):
            statuses[name] = status
    return statuses


# Lua 5.1's own library and WoW's aliases of it: plain Lua, no game terms at all
LUA = set("""assert collectgarbage date difftime error gcinfo getfenv getmetatable ipairs
load loadstring next newproxy pairs pcall print rawequal rawget rawset select setfenv
setmetatable tonumber tostring type unpack xpcall acos asin atan atan2 cos sin tan sqrt
floor ceil abs exp log log10 max min mod random fastrandom time frexp ldexp deg rad
strbyte strchar strfind strlen strlower strmatch strrep strrev strsub strupper format
gmatch gsub tinsert tremove sort wipe foreach foreachi getn""".split())

def tier(name, flags, tags):
    if name in LUA:
        return "free"
    # our own measurement beats every other source
    if "protected" in ours.get(name, ""):
        return "protected"
    if "protected" in tags or flags.get("IsProtectedFunction") == "true" or flags.get("Environment") == "SecureOnly":
        return "protected"
    if "hwevent" in tags:
        return "hardware"
    if "nocombat" in tags:
        return "nocombat"
    if flags.get("HasRestrictions") == "true":
        return "restricted"
    if any(key.startswith("SecretWhen") or key in ("SecretReturns", "SecretInChatMessagingLockdown", "SecretInActivePvPMatch") for key in flags):
        return "secret"
    if any(key.startswith("Requires") or key.startswith("Require") for key in flags):
        return "precondition"
    # documented, or on the wiki's list: something vouches for it existing as an API
    if flags or name in documented_names or name in wiki:
        return "free"
    if name in blizzard_defined:
        return "blizzard-lua"
    return "unknown"


names = read(os.path.join(DOCS, "api-1.60.1.txt")).split()
names = [name for name in names if re.match(r"^[A-Za-z_][\w.]*$", name)]
# the dump's own header line ("World of Warcraft 1.60.1 build ...") is not a name
names = [name for name in names if name not in ("World", "of", "Warcraft", "build")]
sigs = signatures()
documented_names = set(sigs)
wiki = wiki_tags()
uses, blizzard_defined = blizzard_uses()
ours = measured()

rows = []
for name in sorted(set(names)):
    line, flags = sigs.get(name, ("", {}))
    tags = wiki.get(name, set())
    placed = tier(name, flags, tags)
    conditions = sorted(
        [f"{key}={value}" if value != "true" else key for key, value in flags.items() if key not in ("SecretArguments",)]
        + [f"wiki:{tag}" for tag in tags]
    )
    secret_args = flags.get("SecretArguments", "")
    rows.append({
        "name": name,
        "tier": placed,
        "documented": "yes" if line else "no",
        "conditions": " ".join(conditions),
        "secret_args": secret_args,
        "blizzard_uses": uses.get(name, 0),
        "ours": ours.get(name, ""),
        "signature": line.split(" [")[0] if line else "",
    })

with open(os.path.join(DOCS, "api-surface.tsv"), "w", encoding="utf-8", newline="\n") as out:
    keys = ["name", "tier", "documented", "conditions", "secret_args", "blizzard_uses", "ours", "signature"]
    out.write("\t".join(keys) + "\n")
    for row in rows:
        out.write("\t".join(str(row[key]) for key in keys) + "\n")

# the summary
by_tier = collections.Counter(row["tier"] for row in rows)
namespace = collections.defaultdict(collections.Counter)
for row in rows:
    space = row["name"].split(".")[0] if "." in row["name"] else "(global)"
    namespace[space][row["tier"]] += 1
used = sum(1 for row in rows if row["blizzard_uses"] > 0)
measured_rows = [row for row in rows if row["ours"]]

md = []
md.append("# The API surface, and the terms of each part\n")
md.append("Generated by `tools/api_surface.py`; do not edit by hand. Every name is in "
          "`api-surface.tsv` (grep it: `grep -P '^C_Spell\\.' docs/api-surface.tsv`).\n")
md.append(f"**{len(rows):,} names** exist in this client (1.60.1.70862). "
          f"{len(documented_names):,} have a signature in the client's own docs; "
          f"{sum(1 for n in names if n in wiki):,} are on the wiki's list; "
          f"Blizzard's own UI calls {used:,} of them.\n")
md.append("## The tiers\n")
md.append("Strictest first; a name lands in the first that applies.\n")
md.append("| Tier | Names | Terms |\n|---|---:|---|")
for key, text in TIERS:
    md.append(f"| **{key}** | {by_tier.get(key, 0):,} | {text} |")
md.append("")
md.append("## Rules over all of it\n")
md.append("- **Taint.** Anything addon code touches is tainted. A protected action reached "
          "*through* tainted state is blocked (\"Interface action failed\"), even if the call "
          "itself was allowed. Never set a property of Blizzard's frames or replace their "
          "globals; measure new paths with the `issecurevariable` diff.\n")
md.append("- **Secret values.** `SecretArguments=AllowedWhenUntainted` (most functions) means "
          "only Blizzard's untainted code may pass a secret value in; addon code passing one "
          "errors. `AllowedWhenTainted` functions accept them from anyone; `NotAllowed` from "
          "no one. Test with `issecretvalue(v)` / `canaccessvalue(v)` before using a result "
          "that might be secret.\n")
md.append("- **This project's own terms**, on top of the client's: configuration, not play; "
          "out of combat; chat placed for the player to send, never sent; nothing that "
          "deletes items, trades, spends gold or leaves groups (the Lua sandbox refuses these "
          "by name).\n")
md.append("- **Evidence, best first:** measured here (`ours` column) > Blizzard calls it "
          "(`blizzard_uses` > 0, read how) > documented with no condition > wiki-listed > "
          "nothing. The wiki is retail-era; where it and a measurement disagree, the "
          "measurement wins (e.g. `PlaceAction`: untagged, and measured clean).\n")
md.append(f"## Measured by this project ({len(measured_rows)})\n")
md.append("| Name | Tier | Status |\n|---|---|---|")
for row in sorted(measured_rows, key=lambda r: r["name"]):
    md.append(f"| `{row['name']}` | {row['tier']} | {row['ours']} |")
md.append("")
md.append("## By namespace\n")
md.append("Counts per tier. The globals are mostly the old FrameXML-era API, which the "
          "client's docs skip and the wiki covers.\n")
cols = [key for key, _ in TIERS]
md.append("| Namespace | " + " | ".join(cols) + " | total |")
md.append("|---|" + "---:|" * (len(cols) + 1))
for space, counts in sorted(namespace.items(), key=lambda item: -sum(item[1].values())):
    md.append(f"| `{space}` | " + " | ".join(str(counts.get(c, 0) or "") for c in cols) + f" | {sum(counts.values())} |")
with open(os.path.join(DOCS, "api-surface.md"), "w", encoding="utf-8", newline="\n") as out:
    out.write("\n".join(md) + "\n")

print(f"{len(rows)} names")
for key, _ in TIERS:
    print(f"  {key:12} {by_tier.get(key, 0)}")
print(f"  blizzard calls {used}; measured here {len(measured_rows)}")
