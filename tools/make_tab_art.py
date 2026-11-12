"""The Companion window's tabs (Window.lua): slate plaques rising from under
the window's top rim, painted with the chat's own painters
(make_scrollbar_art.py: bark, carving) on the chat's slate.

    python tools/make_tab_art.py   writes addon/WowCompanion_Agent/Art/Tab-<Idle|Chosen>-<v>.tga

One piece a tab, the same for every tab (the names are the game's), drawn in
UI units on a canvas of U texels a unit, PLAQUE units, at its rect in
Window.lua: its top PLAQUE_UP over the window's top, the plaque from x X0 to
X1, its head HEADS down (Chosen on the lighter slate, its bark lit), its foot
running off the piece's bottom, under the rim. Bark trim on the three sides
that show.

The tuck: the plaque runs on behind the rim, so the slot between them is
dark. The face and the bark darken over the last TUCK units above the rim's
top line, steeply at the line, as stone does in a crevice; the bark runs
straight down into the rim at its full width.

The chosen plaque's focus glow (make_focus_art.py) is drawn round outline().

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
VERSION = 2
PLAQUE = (80, 34)  # Window.lua's PLAQUE_W, PLAQUE_H
PLAQUE_UP = 30  # Window.lua's: the rim's top line, from the piece's top
HEADS = {"Idle": 7, "Chosen": 2}  # Window.lua's IDLE_HEAD, CHOSEN_HEAD
X0, X1, R = 3, 77, 4.5  # the plaque's sides and its corners' radius
TRIM = 0.85  # the bark's half-width, on the plaque's edge
EDGE = TRIM + 0.3  # the plaque's outer edge out from its outline: the bark and its dark line
TUCK = 3.2  # units above the rim the plaque starts into the slot's shade
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


def outline(head, foot=PLAQUE[1] + 10):
    """The plaque's edge, in piece units: up the left from below the piece,
    round its head, down the right."""
    return [(X0, foot)] + arc(X0 + R, head + R, R, 180, 270) + arc(X1 - R, head + R, R, 270, 360) + [(X1, foot)]


def tuck(c):
    """Each canvas row's light left in the slot under the rim: 1 above it,
    falling over TUCK units to its line, steepest there."""
    yy = (np.arange(c.H) / c.s - c.pad) / U
    t = np.clip((PLAQUE_UP - yy) / TUCK, 0, 1)
    return (0.3 + 0.7 * (1 - (1 - t) ** 2.4))[:, None, None]


def plaque(kind):
    w, h = PLAQUE
    lit = kind == "Chosen"
    head = HEADS[kind]
    c = ucanvas(w, h)
    pen = Pen(c, h)
    edge = outline(head)
    m = pen.mask([edge])
    shadow(c, m, 0.7)
    stone(c, m, lit)
    raised(pen, [ribbon(np.array(edge, float), TRIM)], LIT if lit else DULL, bevel=0.55, cast=0.4, grain=False)
    if lit:
        glint(c, pen, X0 + 1.3, head + 1.3, 2.6, 0.4)
    c.rgb = c.rgb * tuck(c)
    return c.final()


def main():
    for old in glob.glob(os.path.join(OUT, "Tab-*.tga")):
        os.remove(old)
    for kind in HEADS:
        img = Image.fromarray(np.clip(plaque(kind), 0, 255).astype(np.uint8), "RGBA")
        # stretched to power-of-two sides (the game draws it at its rect)
        img = img.resize((pot(img.width), pot(img.height)), Image.LANCZOS)
        write_tga(os.path.join(OUT, "Tab-%s-%d.tga" % (kind, VERSION)), np.asarray(img))
    print("2 textures")


if __name__ == "__main__":
    main()
