"""The settings page's controls in the chat's language (tools/make_scrollbar_art.py,
whose helpers this uses): the same carved groove, bark borders, fleur-de-lis
arrows and heartwood thumb, so a slider, a choice and a button are visibly
of one family with the scroll bar.

    python tools/make_control_art.py   writes addon/WowCompanion/Art/Control-*-<VERSION>.tga

Pieces (UI units, U texture px each, as the scroll bar's):
  Slide-<Left|Right>-<state> 32x32  the scroll bar's arrow caps turned on their
                                    side: the slider's ends
  Slide-Mid 32 wide x 8 tall turned: 8x32, stretched sideways between them
  Slide-Thumb 48x32                 the heartwood thumb lying down
  Choice-<Left|Right>-<state> 40x32 the arrows joined to a slot as wide as the
                                    value's line, as the slider's to its groove
  Choice-Mid 8x32                   that slot, stretched between them
  Button-<state> 128x28             a thick slate slab standing out of the stone
                                    in a bark border

Turned pieces are transposed, never rotated: a transpose keeps the light
from the top left. The game keeps a texture for the session under its path,
so a change bumps VERSION (and Style.lua's CONTROL_VERSION); older files are
deleted.
"""
import glob
import os
import sys

import numpy as np
from scipy import ndimage

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_scrollbar_art as sb  # noqa: E402

VERSION = 1
OUT = sb.CORE_OUT
SLATE = ((7, 8, 11), (27, 29, 35), (72, 74, 84))  # the button's raised slate: the stone's own dark, a step lighter at its lit edge


def T(img):
    return np.ascontiguousarray(img.transpose(1, 0, 2))


def stadium(cx0, cx1, cy, r, n=48):
    """A rounded slot from x cx0 to cx1 (the round ends' centres), radius r."""
    th = np.linspace(-np.pi / 2, np.pi / 2, n)
    right = [(cx1 + r * np.cos(t), cy + r * np.sin(t)) for t in th]
    left = [(cx0 - r * np.cos(t), cy - r * np.sin(t)) for t in th]
    return right + left


def ring(pen, outer, inner):
    return np.clip(pen.mask([outer]) - pen.mask([inner]), 0, 1)


def plate(w, h, face):
    """A slot w x h units in a bark border: face "carved" (a value shown),
    "raised" (a button's slate) or None (the border alone, for its glow)."""
    c = sb.ucanvas(w, h)
    pen = sb.Pen(c, h)
    r = h / 2 - 2.2
    cy = h / 2
    inner = stadium(2.2 + r, w - 2.2 - r, cy, r)
    if face == "raised":
        # a thick slab standing out of the stone: a broad bevel, lit along its
        # top edge, its shadow cast down and right
        m = pen.mask([inner])
        sb.shadow(c, m, 0.8)
        c.metal(m, SLATE, bevel=3.2 * sb.U, outline=0, shadow=False, sheen=True, paint=True, grain=False, gloss=0.3)
    elif face == "carved":
        sb.carve(c, pen.mask([inner]))
    hw = sb.BORDER_HW
    border = ring(pen, stadium(2.2 + r, w - 2.2 - r, cy, r + hw), stadium(2.2 + r, w - 2.2 - r, cy, r - hw))
    sb.shadow(c, border, 0.4)
    c.metal(border, sb.BARK, bevel=0.6 * sb.U, outline=1.1, shadow=False, sheen=False, paint=True, grain=False, gloss=0.35)
    return c.final()


def choice_set():
    """A choice's arrows joined to its slot, as the slider's are to its groove:
    the scroll bar's caps drawn round a groove as wide as the slot (20 units,
    its borders at 5.1 and 26.9), the round end lower so it clears the fleur;
    40 tall, turned to 40 x 32. Returns the caps by state and the slot's Mid."""
    saved = {k: getattr(sb, k) for k in ("GT", "FOOT", "GX0", "GX1", "RAIL", "ARC", "Pen", "groove_end", "border_path")}
    groove_end, border_path, Pen = sb.groove_end, sb.border_path, sb.Pen
    try:
        sb.GX0, sb.GX1, sb.RAIL = 6, 26, (5.1, 26.9)
        sb.ARC = 16 - sb.RAIL[0]
        sb.GT = 32.0
        sb.FOOT = sb.GT - sb.ARC + 1.5

        class Tall(Pen):
            def __init__(self, c, h, flip=False, dy=0.0):
                Pen.__init__(self, c, CAP, flip, dy)
        sb.Pen = Tall
        sb.groove_end = lambda pen, gt=None: groove_end(pen, sb.GT if gt is None else gt)
        sb.border_path = lambda pen, gt=None: border_path(pen, sb.GT if gt is None else gt)
        out = {}
        for down in (False, True):
            d = "Left" if not down else "Right"
            imgs = {}
            for mode in ("Normal", "Pushed", "Bare"):
                c = sb.ucanvas(32, CAP)
                sb.fleur_cap(c, down, mode)
                imgs[mode] = c.final()
            imgs["Pushed"][..., :3] *= 0.84
            out[d + "-Normal"], out[d + "-Pushed"] = T(imgs["Normal"]), T(imgs["Pushed"])
            out[d + "-Disabled"] = T(sb.greyed(imgs["Normal"]))
            out[d + "-Highlight"] = T(sb.glow(imgs["Bare"]))
        c = sb.ucanvas(32, 8)
        sb.carve(c, sb.groove_run(c))
        sb.border(Pen(c, 8), sb.straight_borders(Pen(c, 8)))
        m = c.final()
        out["Mid"] = T(np.repeat(m.mean(0, keepdims=True), m.shape[0], 0))
        return out
    finally:
        for k, v in saved.items():
            setattr(sb, k, v)


CAP = 40  # a choice cap's length in units


def main():
    scroll = sb.render_set()
    out = {}
    for src, dst in (("Up", "Left"), ("Down", "Right")):
        for state in ("Normal", "Pushed", "Highlight", "Disabled"):
            out["Slide-%s-%s" % (dst, state)] = T(scroll["Scroll-%s-%s" % (src, state)])
    out["Slide-Mid"] = T(scroll["Scroll-Mid"])
    c = sb.ucanvas(32, 48)
    sb.flat_grain(c)
    sb.heart_thumb(c)
    out["Slide-Thumb"] = T(c.final())
    for k, v in choice_set().items():
        out["Choice-" + k] = v
    b = plate(128, 28, "raised")
    # pressed: the slab pushed down into the stone, a unit lower and darker
    pushed = np.zeros_like(b)
    pushed[sb.U:] = b[:-sb.U]
    pushed[..., :3] *= 0.78
    out["Button-Normal"], out["Button-Pushed"] = b, pushed
    # the glow warms the bark border alone, never the face
    out["Button-Highlight"], out["Button-Disabled"] = sb.glow(plate(128, 28, None)), sb.greyed(b)
    for old in glob.glob(os.path.join(OUT, "Control-*.tga")):
        os.remove(old)
    for stem, rgba in out.items():
        sb.write_tga(os.path.join(OUT, "Control-%s-%d.tga" % (stem, VERSION)), np.clip(rgba, 0, 255))
    print(len(out), "textures")


if __name__ == "__main__":
    main()
