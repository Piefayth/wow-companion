"""The inbox trial, session by session (docs/proposals/reliable-channel.md): what
the PC wrote (audit.log, "trial write n session=s") against what the game saw
(Link's audit as of the last reload, "trial ..." from Trial.lua).

    python -I tools/inbox_trial.py [--sessions 5]

For each session: the writes the PC made and the game saw, any never seen, the
false rings (a trial slot spent, nothing newer), the slots spent, and how long
after the PC's write the game saw each (the game's clock has whole seconds).
Removed with the trial when the inbox becomes the channel.
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from audit import game_lines, pc_lines  # noqa: E402

WRITE = re.compile(r"^(\d+) pc \S+ trial write (\d+) session=(\d+) slot=(\S+) messages=(\d+) bytes=(\d+)")
GAME = re.compile(r"^(\d+) game \S+ trial (.*)$")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sessions", type=int, default=5)
    a = ap.parse_args()
    sessions = {}

    def of(number):
        return sessions.setdefault(number, {"writes": {}, "seen": {}, "empty": 0, "stale": 0, "unread": 0,
                                            "slots": 0, "missing": [], "stopped": None, "start": None})

    for line in pc_lines():
        m = WRITE.match(line)
        if m:
            of(int(m[3]))["writes"][int(m[2])] = (int(m[1]), m[4], int(m[6]))
    current = None
    for line in sorted(game_lines(), key=lambda line: int(line.split(" ", 1)[0]) if line[:1].isdigit() else 0):
        m = GAME.match(line)
        if not m:
            continue
        at, detail = int(m[1]), m[2]
        start = re.match(r"start session=(\d+) set=\d+ slots=(\d+)", detail)
        if start:
            current = of(int(start[1]))
            current["start"], current["trialSlots"] = at, int(start[2])
            continue
        if current is None:
            continue
        if re.match(r"T\d+ ", detail):
            current["slots"] += 1
        new = re.match(r"T\d+ new (\d+)-(\d+)", detail)
        if new:
            for n in range(int(new[1]), int(new[2]) + 1):
                current["seen"].setdefault(n, at)
            gone = re.search(r"MISSING ([\d,]+)", detail)
            if gone:
                current["missing"] += [int(n) for n in gone[1].split(",")]
        elif " nothing newer " in detail:
            current["empty"] += 1
        elif " stale " in detail:
            current["stale"] += 1
        elif " unread " in detail:
            current["unread"] += 1
        elif detail.startswith("stopped: "):
            current["stopped"] = detail[len("stopped: "):]
    started = sorted(n for n, s in sessions.items() if s["start"])
    for number in started[-a.sessions:]:
        s = sessions[number]
        written = sorted(s["writes"])
        # a write in the moment between the game's last save and its next load
        # was made for a session already over: said apart from a loss
        later = [sessions[n]["start"] for n in started if n > number]
        unseen = [f"{n}" + (f" ({(later[0] - s['writes'][n][0]) / 1000:.1f} s before the next load)"
                            if later and later[0] - s["writes"][n][0] < 30_000 else "")
                  for n in written if n not in s["seen"]]
        late = sorted(max(0, s["seen"][n] - s["writes"][n][0]) for n in written if n in s["seen"])
        biggest = max((w[2] for w in s["writes"].values()), default=0)
        print(f"session {number}: {len(written)} written, {len(s['seen'])} seen, "
              f"{len(unseen)} never seen{(' ' + str(unseen[:20])) if unseen else ''}; "
              f"{s['empty']} false rings, {s['stale']} stale, {s['unread']} unread; "
              f"{s['slots']} of {s.get('trialSlots', '?')} trial slots; inbox up to {biggest} bytes"
              + (f"; gaps {s['missing']}" if s["missing"] else "")
              + (f"; stopped: {s['stopped']}" if s["stopped"] else ""))
        if late:
            print(f"  seen after the write: median {late[len(late) // 2] / 1000:.1f} s, worst {late[-1] / 1000:.1f} s")


if __name__ == "__main__":
    main()
