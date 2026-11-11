"""Load times from the game's own logs, no input needed.

python -I tools/loadtimes.py [Logs folder ...]   (default: the game's Logs)

Per launch: process start (cpu.log) -> Glues Resume (the engine and the
Interface scan), and per world load, launch or /reload: PreLoadGameCVars ->
LoadGameCVars request dispatch (the addons loading) and, on a reload,
GameUI::Shutdown -> PreLoadGameCVars (the old UI closing). The game rewrites
its logs at every launch, so a run worth keeping is copied out first.
"""
import os
import statistics
import sys

DEFAULT = r"S:\World of Warcraft\_forever_\Logs"


def seconds(clock):
    h, m, s = clock.split(":")
    return int(h) * 3600 + int(m) * 60 + float(s)


def lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.split(None, 2)
                if len(parts) == 3 and parts[1].count(":") == 2:
                    yield parts[1], parts[2]
    except FileNotFoundError:
        return


def report(folder):
    print(f"== {folder}")
    start = next(lines(os.path.join(folder, "cpu.log")), None)
    shutdown = preload = None
    loads, reloads = [], []
    for clock, text in lines(os.path.join(folder, "General.log")):
        t = seconds(clock)
        if "[Glues] Resume()" in text and start:
            print(f"launch {start[0]}: process -> Glues Resume {t - seconds(start[0]):.2f}s")
            start = None
        elif "GameUI::Shutdown invalidated" in text:
            shutdown = t
        elif "PreLoadGameCVars initialized" in text:
            preload = t
        elif "LoadGameCVars request dispatch" in text and preload is not None:
            loads.append(t - preload)
            if shutdown is not None:
                reloads.append(preload - shutdown)
            shutdown = preload = None
    if loads:
        print(f"addons loading, {len(loads)} world loads: first {loads[0]:.2f}s, "
              f"median {statistics.median(loads):.2f}s, spread {min(loads):.2f}-{max(loads):.2f}s")
    if reloads:
        print(f"old UI closing, {len(reloads)} reloads: median {statistics.median(reloads):.2f}s")


for folder in sys.argv[1:] or [DEFAULT]:
    report(folder)
