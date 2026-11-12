"""The Companion window's tabs (Window.lua): slate plaques rising from under
the window's top rim: the chat's slate, trimmed in the rim's metal.

    python tools/make_tab_art.py   writes addon/WowCompanion_Agent/Art/Tab-<Idle|Chosen>-<v>.tga

One piece a tab, the same for every tab (the names are the game's), drawn in
UI units on a canvas of U texels a unit, PLAQUE units, at its rect in
Window.lua: its top PLAQUE_UP over the window's top, the plaque from x X0 to
X1, its head HEADS down (Chosen on the lighter slate), its foot running off
the piece's bottom, under the rim. A trim on the three sides that show, of the
rim's own metal (make_frame_art.py's bar() and rim_metal()): the chosen tab's in
the rim's bronze, the others' in IDLE times it.

The tuck: the plaque runs on behind the rim, so the slot between them is
dark. The face and the trim darken over the last TUCK units above the rim's
top line, steeply at the line, as stone does in a crevice; the trim runs
straight down into the rim at its full width.

The chosen plaque's focus glow (make_focus_art.py) is drawn round outline().

The game keeps a texture for the session under its path, so a change bumps
VERSION (and Window.lua's TAB_ART); older files are deleted.
"""
import glob
import os

import numpy as np
from PIL import Image

from scipy import ndimage

from make_frame_art import BRONZE, LINE, bar, rim_metal
from make_scrollbar_art import U, Pen, ribbon, shadow, ucanvas, write_tga

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "addon", "WowCompanion_Agent", "Art")
SLATE = os.path.join(ROOT, "addon", "WowCompanion", "Art", "%s-6.tga")  # Style.lua's STONE
VERSION = 3
PLAQUE = (80, 34)  # Window.lua's PLAQUE_W, PLAQUE_H
PLAQUE_UP = 30  # Window.lua's: the rim's top line, from the piece's top
HEADS = {"Idle": 7, "Chosen": 2}  # Window.lua's IDLE_HEAD, CHOSEN_HEAD
X0, X1, R = 3, 77, 4.5  # the plaque's sides and its corners' radius
TRIM = 0.85  # the trim's half-width, on the plaque's edge
EDGE = TRIM + 0.3  # the plaque's outer edge out from its outline: the trim and its dark line
TUCK = 3.2  # units above the rim the plaque starts into the slot's shade
PX_4K = 2.7  # 4K pixels a UI unit: the game tiles the slate a texel a pixel
IDLE = 0.7  # the unchosen tabs' trim: the rim's bronze this much darker


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


def trim(c, m, pal):
    """The trim where m is: a bar of the rim's make across it, in the rim's
    metal in pal, its shadow and the rim's dark line round it."""
    k = U * c.s  # samples a unit
    shadow(c, m, 0.4)
    ring = ndimage.gaussian_filter(ndimage.maximum_filter(m, size=int(0.6 * k) | 1), k * 0.06)
    c.over(np.broadcast_to(LINE, c.rgb.shape), ring * 0.9)
    d = ndimage.distance_transform_edt(m > 0.5) / k  # units in from its edge
    hgt = ndimage.gaussian_filter(bar(d, 2 * TRIM), k * 0.1)
    c.over(rim_metal(hgt, pal, k), m)


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
    trim(c, pen.mask([ribbon(np.array(edge, float), TRIM)]), BRONZE if lit else tuple(col * IDLE for col in BRONZE))
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
