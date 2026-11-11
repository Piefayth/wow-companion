"""Load test: what many slot-like addon folders cost the game's load.

python -I tools/loadtest.py add <AddOns> <count>    (folders like a slot's)
python -I tools/loadtest.py remove <AddOns>

The folders are load-on-demand and never loaded; they cost only what the game
does with every folder it finds. Time a launch and its reloads with
tools/loadtimes.py against a run without them. New folders count from the next
launch; removed ones too.
"""
import os
import shutil
import sys

PREFIX = "WowCompanion_LoadTest_"
TOC = ("## Interface: 16001\n## Title: WoW Companion load test\n## LoadOnDemand: 1\n"
       "## Group: {name}\n## Category: WoW Companion: load test\n\nSlot.xml\n")
XML = '<Ui xmlns="http://www.blizzard.com/wow/ui/">\n\t<Script file="Inbox.lua"></Script>\n</Ui>\n'


def add(addons, count):
    for i in range(1, int(count) + 1):
        name = PREFIX + "%04d" % i
        folder = os.path.join(addons, name)
        os.makedirs(folder, exist_ok=True)
        for file, text in ((name + ".toc", TOC.format(name=name)), ("Slot.xml", XML), ("Inbox.lua", "")):
            with open(os.path.join(folder, file), "w", encoding="utf-8", newline="\n") as f:
                f.write(text)
    print(f"{count} load-test folders in {addons}")


def remove(addons):
    gone = [e.path for e in os.scandir(addons) if e.is_dir() and e.name.startswith(PREFIX)]
    for path in gone:
        shutil.rmtree(path)
    print(f"removed {len(gone)} load-test folders")


if __name__ == "__main__":
    {"add": add, "remove": remove}[sys.argv[1]](*sys.argv[2:])
