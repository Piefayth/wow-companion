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
    ("precondition", "Callable once its situation holds: its data loaded (Requires...: friend list, clubs, a valid slot, a cvar), or, per the wiki, outside instances (noinstance) or in a group (grouponly)."),
    ("read", "Reads game state, no documented condition, and Blizzard's Forever UI calls it: the safe, well-trodden part. Still never call in bulk: one read crashed the client in C."),
    ("change", "Changes game state (Set, Add, Use, Buy, Post, Delete...), no documented condition, and Blizzard's Forever UI calls it. Usually needs a context the docs omit (a vendor, the auction house, a mailbox open). Read how Blizzard calls it first."),
    ("dormant", "No Blizzard code that loads in Forever calls it. Either the feature is absent here (garrisons, delves, housing), or Blizzard does the same job with another function (it lists your auctions with GetOwnedAuctionInfo, not GetOwnedAuctions): use the one Blizzard calls. Also deprecated ones."),
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


# Forever's internal game type is "camelot": Blizzard_Gamepad, its signature UI,
# loads only there. "mainline" includes it (the garrison UI has to exclude
# camelot explicitly), while standard, plunderstorm, cata, mists and the classic
# flavours are other games. Inferred from the manifests, not measured.
FOREVER_TYPES = {"mainline", "camelot"}
OTHER_FLAVOURS = {"classic", "vanilla", "tbc", "wrath", "cata", "mists", "glue", "plunderstorm", "standard"}


def loads_in_forever(addon_dir):
    """does this Blizzard addon's manifest load in camelot?"""
    tocs = [name for name in os.listdir(addon_dir) if name.lower().endswith(".toc")]
    if not tocs:
        return False
    for toc in tocs:
        text = read(os.path.join(addon_dir, toc))
        allow = re.search(r"^## AllowLoadGameType:\s*(.+)$", text, re.M)
        exclude = re.search(r"^## ExcludeLoadGameType:\s*(.+)$", text, re.M)
        allowed = {part.strip().lower() for part in allow.group(1).split(",")} if allow else None
        excluded = {part.strip().lower() for part in exclude.group(1).split(",")} if exclude else set()
        if "camelot" in excluded:
            continue
        if allowed is None or allowed & FOREVER_TYPES:
            return True
    return False


def live_file(path):
    """a file inside a loading addon that is not another flavour's override"""
    parts = {part.lower() for part in re.split(r"[\\/]", path)}
    return not (parts & OTHER_FLAVOURS)


def blizzard_uses():
    """identifier -> mentions in all of Blizzard's UI code, mentions in the code
    that loads in Forever, and the names Blizzard's Lua itself defines"""
    source = os.path.join(DOCS, "wow-ui-source")
    counts = collections.Counter()
    live = collections.Counter()
    defined = set()
    addons = os.path.join(source, "Interface", "AddOns")
    loading = {name for name in os.listdir(addons) if loads_in_forever(os.path.join(addons, name))}
    definition = re.compile(r"^\s*(?:local\s+)?function\s+([A-Za-z_][\w.:]*)\s*\(|^\s*([A-Za-z_]\w*)\s*=\s*(?:function|[A-Za-z_][\w.:]*\s*;?\s*$)", re.M)
    token = re.compile(r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)?")
    for folder, _, files in os.walk(source):
        if "APIDocumentationGenerated" in folder:
            continue
        for name in files:
            if name.endswith(".lua"):
                with open(os.path.join(folder, name), encoding="utf-8", errors="replace") as handle:
                    text = handle.read()
                    found = token.findall(text)
                    counts.update(found)
                    relative = os.path.relpath(os.path.join(folder, name), addons)
                    if relative.split(os.sep)[0] in loading and live_file(relative):
                        live.update(found)
                    for one, two in definition.findall(text):
                        defined.add((one or two).replace(":", "."))
    return counts, live, defined


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

# Verbs that change something: the game, the server, the UI or the player's
# stuff. Anything else (Get, Is, Calculate, Make a key...) is taken as a read.
CHANGE_VERBS = set("""Set Add Remove Delete Use Buy Sell Post Place Cancel Confirm Start Stop
Send Request Query Refresh Close Open Accept Decline Clear Create Edit Pickup Learn Unlearn
Equip Unequip Leave Join Invite Uninvite Kick Toggle Save Load Reset Apply Enable Disable
Destroy Repair Split Swap Move Drop Release Repop Retrieve Claim Complete Abandon Select
Click Activate Deactivate Show Hide Track Untrack Mark Report Register Unregister Ignore
Unignore Mute Unmute Collect Purchase Bid Restore Upgrade Craft Recraft Train Rename
Commit Respond Reply Leave Promote Demote Assign Convert Withdraw Deposit Take Give Send
Initiate Return Dismiss Summon Spend Pay Bind Unbind Expand Collapse Sort Fire Do Play
Mount Dismount Logout Quit Accept Ack Acknowledge Submit Vote Roll Pass Loot Interact
Teleport Travel Queue Dequeue Lock Unlock Tag Untag Favorite Unfavorite Pin Unpin""".split())


def reads(name):
    leaf = name.split(".")[-1]
    if leaf[:1].islower() or name in LUA:
        return True
    verb = re.match(r"[A-Z][a-z]*", leaf)
    return not (verb and verb.group(0) in CHANGE_VERBS)


def tier(name, flags, tags):
    # our own measurement beats every other source
    if "protected" in ours.get(name, ""):
        return "protected"
    if "protected" in tags or flags.get("IsProtectedFunction") == "true" or flags.get("Environment") == "SecureOnly":
        return "protected"
    if "hwevent" in tags:
        return "hardware"
    if "nocombat" in tags:
        return "nocombat"
    if "deprecated" in tags:
        return "dormant"
    if flags.get("HasRestrictions") == "true":
        return "restricted"
    if any(key.startswith("SecretWhen") or key in ("SecretReturns", "SecretInChatMessagingLockdown", "SecretInActivePvPMatch") for key in flags):
        return "secret"
    if any(key.startswith("Requires") or key.startswith("Require") for key in flags) or tags & {"noinstance", "grouponly"}:
        return "precondition"
    # documented, or on the wiki's list: something vouches for it existing as an API
    if flags or name in documented_names or name in wiki or name in LUA:
        if forever_uses.get(name, 0) == 0 and name not in LUA:
            return "dormant"
        return "read" if reads(name) else "change"
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
uses, forever_uses, blizzard_defined = blizzard_uses()
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
        "forever_uses": forever_uses.get(name, 0),
        "ours": ours.get(name, ""),
        "signature": line.split(" [")[0] if line else "",
    })

with open(os.path.join(DOCS, "api-surface.tsv"), "w", encoding="utf-8", newline="\n") as out:
    keys = ["name", "tier", "documented", "conditions", "secret_args", "forever_uses", "blizzard_uses", "ours", "signature"]
    out.write("\t".join(keys) + "\n")
    for row in rows:
        out.write("\t".join(str(row[key]) for key in keys) + "\n")

# the summary
by_tier = collections.Counter(row["tier"] for row in rows)
namespace = collections.defaultdict(collections.Counter)
for row in rows:
    space = row["name"].split(".")[0] if "." in row["name"] else "(global)"
    namespace[space][row["tier"]] += 1
used = sum(1 for row in rows if row["forever_uses"] > 0)
measured_rows = [row for row in rows if row["ours"]]

md = []
md.append("# The API surface, and the terms of each part\n")
md.append("Generated by `tools/api_surface.py`; do not edit by hand. Every name is in "
          "`api-surface.tsv` (grep it: `grep -P '^C_Spell\\.' docs/api-surface.tsv`).\n")
md.append(f"**{len(rows):,} names** exist in this client (1.60.1.70862). "
          f"{len(documented_names):,} have a signature in the client's own docs; "
          f"{sum(1 for n in names if n in wiki):,} are on the wiki's list; "
          f"Blizzard's UI code that loads in Forever calls {used:,} of them.\n")
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
md.append("- **Wiki tags** (warcraft.wiki.gg, retail-era): `protected` only secure code; "
          "`hwevent` needs keyboard/mouse/pad input; `nocombat` not in combat; `noscript` not "
          "from `/script` in chat, which addon code (our `lua` steps, our addons) is not; "
          "`noinstance` not in dungeons or raids; `deprecated` probably non-functional; "
          "`framexml` defined in Blizzard's Lua.\n")
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
