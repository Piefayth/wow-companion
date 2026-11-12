"""The Companion window's tabs (Window.lua): slate plaques rising from under
the window's top rim, painted with the chat's own painters
(make_scrollbar_art.py: bark, carving) on the chat's slate.

    python tools/make_tab_art.py   writes addon/WowCompanion_Agent/Art/Tab-<Idle|Chosen>-<v>.tga

One piece a tab, the same for every tab (the names are the game's), drawn in
UI units on a canvas of U texels a unit, PLAQUE units, at its rect in
Window.lua: the plaque from x 3 to 77, its head at y 8 (Idle) or 2 (Chosen,
on the lighter slate, its bark lit), its foot running off the piece's bottom,
which lies 4 units under the rim. Bark trim on the three sides that show.

The game keeps a texture for the session under its path, so a change bumps
VERSION (and Window.lua's TAB_ART); older files are deleted.
"""
import glob
import os

import numpy as np
from PIL import Image

from make_scrollbar_art import BARK, U, Pen, dim, glint, raised, ribbon, shadow, ucanvas, write_tga

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "addon", "WowCompanion_Agent", "Art")
SLATE = os.path.join(ROOT, "addon", "WowCompanion", "Art", "%s-6.tga")  # Style.lua's STONE
VERSION = 1
PLAQUE = (80, 32)  # Window.lua's
PX_4K = 2.7  # 4K pixels a UI unit: the game tiles the slate a texel a pixel
LIT = tuple(tuple(min(255, int(x * 1.18)) for x in col) for col in BARK)
DULL = dim(BARK, 0.82)


def pot(n):
    p = 1
    while p < n:
        p *= 2
    return p


_slate = {}


def stone(c, m, lit):
    """The chat's slate where m is, at the game's own scale: the lighter one
    for the chosen tab."""
    stem, k = ("SlateLight", 1.45) if lit else ("Slate", 1.0)
    key = (stem, c.s)
    if key not in _slate:
        src = Image.open(SLATE % stem).convert("RGB")
        n = int(round(src.width * U * c.s / PX_4K))
        _slate[key] = np.asarray(src.resize((n, n), Image.BICUBIC), float)
    t = _slate[key]
    reps = (c.H // t.shape[0] + 1, c.W // t.shape[1] + 1, 1)
    c.over(np.tile(t, reps)[:c.H, :c.W] * k, m)


def arc(cx, cy, r, a0, a1, n=16):
    t = np.radians(np.linspace(a0, a1, n))
    return [(cx + r * np.cos(a), cy + r * np.sin(a)) for a in t]


def plaque(lit):
    w, h = PLAQUE
    c = ucanvas(w, h)
    pen = Pen(c, h)
    head = 2 if lit else 8
    shape = arc(7.5, head + 4.5, 4.5, 180, 270) + arc(72.5, head + 4.5, 4.5, 270, 360) + [(77, h + 10), (3, h + 10)]
    trim = [(3, h + 10)] + arc(7.5, head + 4.5, 4.5, 180, 270) + arc(72.5, head + 4.5, 4.5, 270, 360) + [(77, h + 10)]
    m = pen.mask([shape])
    shadow(c, m, 0.7)
    stone(c, m, lit)
    raised(pen, [ribbon(np.array(trim, float), 0.85)], LIT if lit else DULL, bevel=0.55, cast=0.4, grain=False)
    if lit:
        glint(c, pen, 4.3, head + 1.3, 2.6, 0.4)
    return c.final()


def main():
    for old in glob.glob(os.path.join(OUT, "Tab-*.tga")):
        os.remove(old)
    for name, lit in (("Idle", False), ("Chosen", True)):
        img = Image.fromarray(np.clip(plaque(lit), 0, 255).astype(np.uint8), "RGBA")
        # stretched to power-of-two sides (the game draws it at its rect)
        img = img.resize((pot(img.width), pot(img.height)), Image.LANCZOS)
        write_tga(os.path.join(OUT, "Tab-%s-%d.tga" % (name, VERSION)), np.asarray(img))
    print("2 textures")


if __name__ == "__main__":
    main()
