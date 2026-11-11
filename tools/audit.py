"""Print the audit trail: the PC's (audit.log) and the game's (WowCompanionDB.audit,
as of the last reload) merged into one timeline.

    python -I tools/audit.py [--minutes 30] [--slot main] [--grep word]

Each line: time, side (pc/game), conversation, what, detail.
  pc   job    <id> <from> -> <to>     every state change in the ledger
  pc   hear   <id> clip <n>           a clip let go joined/started a job
  pc   words  <id> [state] <text>     what Whisper heard for a clip
  pc   send   { kind = ... }          every message sent to the game
  pc   cmd    WCCMD ...               every command the game drew
  game recv   <kind> job= state ...   every message the game took in
  game draw   <verb> <job>            every command the game drew
  game predict / claim                what the window guessed and how it resolved
"""
import argparse
import glob
import os
import re
import sys
import time


def pc_lines():
    path = os.path.join(os.environ.get("LOCALAPPDATA", ""), "wow-companion", "audit.log")
    out = []
    for name in (path.replace(".log", ".old.log"), path):
        if os.path.exists(name):
            with open(name, encoding="utf-8", errors="replace") as f:
                out += [line.rstrip("\n") for line in f if line.strip()]
    return out


def game_lines():
    roots = [r"S:\World of Warcraft\_forever_\WTF\Account"]
    files = []
    for root in roots:
        files += glob.glob(os.path.join(root, "*", "SavedVariables", "WowCompanion.lua"))
    out = []
    for name in files:
        text = open(name, encoding="utf-8", errors="replace").read()
        m = re.search(r'\["audit"\]\s*=\s*\{(.*?)\n\t?\}', text, re.S)
        if not m:
            continue
        for s in re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1)):
            out.append(s.encode().decode("unicode_escape", errors="replace"))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", type=float, default=30)
    ap.add_argument("--slot")
    ap.add_argument("--grep")
    a = ap.parse_args()
    since = (time.time() - a.minutes * 60) * 1000
    rows = []
    for line in pc_lines() + game_lines():
        parts = line.split(" ", 4)
        if len(parts) < 4 or not parts[0].isdigit():
            continue
        ms = int(parts[0])
        if ms < since:
            continue
        side, slot, what = parts[1], parts[2], parts[3]
        detail = parts[4] if len(parts) > 4 else ""
        if a.slot and slot != a.slot:
            continue
        if a.grep and a.grep.lower() not in line.lower():
            continue
        rows.append((ms, side, slot, what, detail))
    rows.sort(key=lambda r: (r[0], r[1] != "pc"))
    for ms, side, slot, what, detail in rows:
        stamp = time.strftime("%H:%M:%S", time.localtime(ms / 1000)) + ".%03d" % (ms % 1000)
        print(f"{stamp} {side:4} {slot:5} {what:7} {detail}")
    if not rows:
        print("nothing in that window", file=sys.stderr)


if __name__ == "__main__":
    main()
