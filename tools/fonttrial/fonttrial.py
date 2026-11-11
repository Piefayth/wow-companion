"""Font trial: PC to game through a font's letter widths, beside the channel.

The game finds only the files that existed at its launch, and reads a font's
contents the first time it loads it, then keeps it for the life of the process
(wow-forever-codex measured this on Forever 1.60.1). So the trial addon gets a
bank of names, one per clock second (epoch second % BANK), and this writer puts
the font for each coming second in place a few seconds early; the game loads the
current second's font and checks it against the pattern both sides know.

  python -I tools/fonttrial/fonttrial.py install <AddOns> <hours>
  pythonw -I tools/fonttrial/fonttrial.py write <AddOns>     (detached)
  python -I tools/fonttrial/fonttrial.py remove <AddOns>

Each payload is 512 bytes, one per glyph (U+E000 up): "WCF1", the second as 4
bytes, then (second*31 + i*7) % 256. Advance = (16 + byte) * 16 units at 1024
per em; '!' and '"' are bytes 0 and 255, '~' trails every measurement.
"""
import json
import os
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
FOLDER = "WowCompanion_FontTrial"
BANK = 16384
AHEAD = 5
BYTES = 512
STATE = os.path.join(os.environ["LOCALAPPDATA"], "wow-companion", "fonttrial")
DATA = 4  # glyph index of the first data glyph


def name(second):
    return "f%05d.ttf" % (second % BANK)


def blank_name(slot):
    # NTFS takes at most 1,024 links to a file: one blank per 512 names
    return "blank%02d.ttf" % (slot // 512)


def payload(second):
    head = b"WCF1" + struct.pack(">I", second % 2**32)
    return head + bytes((second * 31 + i * 7) % 256 for i in range(len(head), BYTES))


def template():
    from fontTools.fontBuilder import FontBuilder
    from fontTools.pens.ttGlyphPen import TTGlyphPen

    order = [".notdef", "zero", "full", "tilde"] + ["d%03d" % i for i in range(BYTES)] + ["space"]
    fb = FontBuilder(1024, isTTF=True)
    fb.setupGlyphOrder(order)
    cmap = {0x20: "space", 0x21: "zero", 0x22: "full", 0x7E: "tilde"}
    cmap.update({0xE000 + i: "d%03d" % i for i in range(BYTES)})
    fb.setupCharacterMap(cmap)
    glyphs = {}
    for g in order:
        pen = TTGlyphPen(None)
        pen.moveTo((10, 0)); pen.lineTo((10, 100)); pen.lineTo((60, 100)); pen.lineTo((60, 0)); pen.closePath()
        glyphs[g] = pen.glyph()
    fb.setupGlyf(glyphs)
    widths = {".notdef": 512, "zero": 16 * 16, "full": (16 + 255) * 16, "tilde": 512, "space": 256}
    widths.update({"d%03d" % i: 16 * 16 for i in range(BYTES)})
    # a run of equal widths at the end is stored without advances (hhea's
    # numberOfHMetrics), and font_for writes every advance in place
    widths["d%03d" % (BYTES - 1)] = 17 * 16
    fb.setupHorizontalMetrics({g: (widths[g], 10) for g in order})
    # the game refuses a font without these (wow-forever-codex's, which loads):
    # the vertical metrics in OS/2 above all, a space, a full name table
    fb.setupHorizontalHeader(ascent=800, descent=-224)
    fb.setupNameTable({"familyName": "WCFontTrial", "styleName": "Regular", "uniqueFontIdentifier": "WCFontTrial",
                       "fullName": "WCFontTrial", "psName": "WCFontTrial", "version": "Version 1.0"})
    fb.setupOS2(sTypoAscender=800, sTypoDescender=-224, usWinAscent=800, usWinDescent=224)
    fb.setupPost()
    fb.setupMaxp()
    path = os.path.join(STATE, "template.ttf")
    fb.save(path)
    from fontTools.ttLib import TTFont
    assert TTFont(path).getGlyphOrder() == order, "glyph order kept"
    return path


def hmtx_offset(font):
    count = struct.unpack(">H", font[4:6])[0]
    for i in range(count):
        tag, _, offset, _ = struct.unpack(">4sIII", font[12 + 16 * i: 28 + 16 * i])
        if tag == b"hmtx":
            return offset
    raise ValueError("no hmtx")


def font_for(blank, offset, second):
    font = bytearray(blank)
    for i, b in enumerate(payload(second)):
        struct.pack_into(">H", font, offset + (DATA + i) * 4, (16 + b) * 16)
    return bytes(font)


def install(addons, hours):
    os.makedirs(STATE, exist_ok=True)
    blank_path = template()
    target = os.path.join(addons, FOLDER)
    os.makedirs(target, exist_ok=True)
    end = int(time.time() + float(hours) * 3600)
    assert hours and float(hours) * 3600 < BANK, "a name is never read twice in one process"
    with open(os.path.join(HERE, "Trial.lua"), encoding="utf-8") as f:
        lua = f.read().replace("TRIAL_END = 0", "TRIAL_END = %d" % end).replace("BANK = 0", "BANK = %d" % BANK)
    with open(os.path.join(target, "Trial.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write(lua)
    with open(os.path.join(target, FOLDER + ".toc"), "w", encoding="utf-8", newline="\n") as f:
        f.write("## Interface: 16001\n## Title: WoW Companion font trial\n## Group: WowCompanion\n"
                "## Category: WoW Companion\n## SavedVariables: WowCompanionFontTrialDB\n\nTrial.lua\n")
    # every name a hard link to a blank font: 16,384 names, 32 files' bytes
    made = 0
    for slot in range(BANK):
        blank = os.path.join(target, blank_name(slot))
        if not os.path.exists(blank):
            with open(blank_path, "rb") as src, open(blank, "wb") as dst:
                dst.write(src.read())
        path = os.path.join(target, "f%05d.ttf" % slot)
        if not os.path.exists(path):
            os.link(blank, path)
            made += 1
    json.dump({"end": end, "addons": addons}, open(os.path.join(STATE, "trial.json"), "w"))
    print(f"installed {FOLDER}: {made} names made, trial ends {time.ctime(end)}")


def write(addons):
    import psutil

    target = os.path.join(addons, FOLDER)
    blank = open(os.path.join(target, blank_name(0)), "rb").read()
    offset = hmtx_offset(blank)
    end = json.load(open(os.path.join(STATE, "trial.json")))["end"]
    log = open(os.path.join(STATE, "writer.log"), "a", buffering=1)
    log.write(f"{time.ctime()} writer starts, ends {time.ctime(end)}\n")
    written, failures, last_memory = {}, {"write": 0, "restore": 0}, 0
    while time.time() < end:
        now = int(time.time())
        for second in range(now + 1, now + 1 + AHEAD):
            if second not in written:
                tmp = os.path.join(target, "w.tmp")
                try:
                    with open(tmp, "wb") as f:
                        f.write(font_for(blank, offset, second))
                    os.replace(tmp, os.path.join(target, name(second)))
                    written[second] = time.time()
                except OSError as err:
                    failures["write"] += 1
                    log.write(f"{time.ctime()} write {second} failed: {err}\n")
                    written[second] = None
        # a past second's name goes back to the blank (a link again), so the
        # disk holds a few fonts; one the game holds open says so here
        for second in [s for s in written if s < now - 30]:
            try:
                tmp = os.path.join(target, "r.tmp")
                if os.path.exists(tmp):
                    os.remove(tmp)
                os.link(os.path.join(target, blank_name(second % BANK)), tmp)
                os.replace(tmp, os.path.join(target, name(second)))
            except OSError as err:
                failures["restore"] += 1
                if failures["restore"] <= 20:
                    log.write(f"{time.ctime()} restore {second} failed: {err}\n")
            del written[second]
        if time.time() - last_memory >= 60:
            last_memory = time.time()
            wows = [p for p in psutil.process_iter(["name"]) if (p.info["name"] or "").lower() == "wow.exe"]
            memory = ", ".join(f"pid {p.pid} {p.memory_info().private / 2**20:.0f} MB" for p in wows) or "no Wow.exe"
            log.write(f"{time.ctime()} {memory}; failures {failures}\n")
        time.sleep(0.2)
    log.write(f"{time.ctime()} writer ends; failures {failures}\n")


def remove(addons):
    import shutil

    shutil.rmtree(os.path.join(addons, FOLDER))
    print("removed", FOLDER)


if __name__ == "__main__":
    {"install": install, "write": write, "remove": remove}[sys.argv[1]](*sys.argv[2:])
