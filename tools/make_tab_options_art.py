"""The tab gallery's art (addon/WowCompanion_Agent/TabGallery.lua), cut from
the tab-row study's own painters (target/tab-options/src), so the game shows
each option as its mock drew it.

    python tools/make_tab_options_art.py   writes Art/TabOpt<n>-<piece>-1.tga
                                           and prints the layout for TabGallery.lua

Options 2, 3, 4, 5 and 7: the option's whole row drawn by its painter on a
clear sheet, once per chosen tab (Chosen1..4), with no labels (the game draws
them); the layout printed is each row's rect, the tabs' hit rects and their
labels' centres, in UI units from the window's top left. Option 1: the fleur
(the vine is the game's own). Option 6 is Blizzard's art, drawn in the game.
Temporary: goes with the gallery.
"""
import importlib
import os
import sys

import numpy as np
from PIL import Image

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(ROOT, "target", "tab-options", "src"))
import mocklib  # noqa: E402
from make_scrollbar_art import write_tga  # noqa: E402

OUT = os.path.join(ROOT, "addon", "WowCompanion_Agent", "Art")
VERSION = 1


def pot(n):
    p = 1
    while p < n:
        p *= 2
    return p


def save(stem, img):
    """RGBA img stretched to power-of-two sides (the game draws it at its rect)."""
    img = img.resize((pot(img.width), pot(img.height)), Image.LANCZOS)
    write_tga(os.path.join(OUT, "TabOpt%s-%d.tga" % (stem, VERSION)), np.asarray(img))


def rows(n):
    mod = importlib.import_module("opt%d" % n)
    # the painters draw onto the shot; here onto nothing, and the names go
    mod.clean = lambda im: im
    if hasattr(mod, "clean_title"):
        mod.clean_title = lambda im: im
    mod.label = lambda *a, **k: None
    blank = Image.new("RGBA", Image.open(mocklib.BASE).size, (0, 0, 0, 0))
    shots, tabs = [], None
    for i in range(4):
        img, t = mod.draw(blank.copy(), chosen=i)
        shots.append(img)
        tabs = tabs or t
    alpha = np.max([np.asarray(s)[..., 3] for s in shots], 0)
    ys, xs = np.where(alpha > 2)
    shift = getattr(mod, "PAD", 0) if n == 4 else 0  # option 4 widens the shot on the left
    a, b, c, d = xs.min() - 2, ys.min() - 2, xs.max() + 3, ys.max() + 3
    for i, s in enumerate(shots):
        save("%d-Chosen%d" % (n, i + 1), s.crop((a, b, c, d)))
    box = (mocklib.ux(a - shift), mocklib.uy(b), mocklib.ux(c - shift), mocklib.uy(d))
    return mod, box, tabs


def lua(v):
    return "%.1f" % v


def main():
    for old in os.listdir(OUT):
        if old.startswith("TabOpt"):
            os.remove(os.path.join(OUT, old))
    import opt1
    save("1-Fleur", Image.fromarray(np.clip(opt1.fleur(), 0, 255).astype(np.uint8), "RGBA"))
    out = []
    for n in (2, 3, 4, 5, 7):
        mod, box, tabs = rows(n)
        hits, labels = [], []
        for i, (a, b) in enumerate(tabs):
            if n == 2:
                y0, y1, cy = mod.GY0, mod.GY1, (mod.GY0 + mod.GY1) / 2
                lab = ((a + b) / 2, cy, (a + b) / 2, cy)
            elif n == 3:
                y0, y1 = mod.TOP, mod.SHORT
                cy = mod.TOP + 12.5
                lab = ((a + b) / 2, cy, (a + b) / 2, cy)
            elif n == 4:
                y0 = mod.PY + i * (mod.PH + mod.PG)
                y1 = y0 + mod.PH
                a, b = -mod.OUT_LIT, 0.0
                cy = y0 + mod.PH / 2
                lab = (-mod.OUT / 2, cy, -mod.OUT_LIT / 2, cy)
            elif n == 5:
                y0, y1 = mod.Y0, mod.Y1
                cy = (mod.Y0 + mod.Y1) / 2 + 0.3
                lab = ((a + b) / 2, cy, (a + b) / 2, cy)
            else:
                y0, y1 = mod.TALL, mocklib.WELL_TOP
                lab = ((a + b) / 2, mod.LOW + mod.FORK + 11, (a + b) / 2, mod.TALL + mod.FORK + 11)
            hits.append("{ %s }" % ", ".join(lua(v) for v in (a, y0, b, y1)))
            labels.append("{ %s }" % ", ".join(lua(v) for v in lab))
        lift = getattr(mod, "LIFT", 0) / mocklib.PX
        out.append("\t[%d] = { box = { %s }, wellTop = %s,\n\t\thits = { %s },\n\t\tlabels = { %s } },"
                   % (n, ", ".join(lua(v) for v in box), lua(mocklib.WELL_TOP - lift),
                      ", ".join(hits), ", ".join(labels)))
    print("local BAKED = {\n" + "\n".join(out) + "\n}")


if __name__ == "__main__":
    main()
