"""The settings page's controls in the chat's language (tools/make_scrollbar_art.py,
whose helpers this uses): the same carved groove, bark borders, fleur-de-lis
arrows and heartwood thumb, so a slider and a choice are visibly of one
family with the scroll bar.

    python tools/make_control_art.py   writes addon/WowCompanion/Art/Control-*-<VERSION>.tga

Pieces (UI units, U texture px each, as the scroll bar's):
  Slide-<Left|Right>-<state> 32x32  the scroll bar's arrow caps turned on their
                                    side: the slider's ends
  Slide-Mid 32 wide x 8 tall turned: 8x32, stretched sideways between them
  Slide-Thumb 48x32                 the heartwood thumb lying down
  Choice-<Left|Right>-<state> 40x32 the arrows joined to a slot as wide as the
                                    value's line, as the slider's to its groove
  Choice-<Left|Right>-Closed 16x32  the slot's plain round ends (a key row)
  Choice-Mid 8x32                   that slot, stretched between them

Turned pieces are transposed, never rotated: a transpose keeps the light
from the top left. The game keeps a texture for the session under its path,
so a change bumps VERSION (and Style.lua's CONTROL_VERSION); older files are
deleted.
"""
import os
import artout
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_scrollbar_art as sb  # noqa: E402

VERSION = 2
OUT = sb.CORE_OUT


def greyed_fleur(normal, bare):
    """Disabled: the fleur alone greyed, the groove and its borders it joins
    left as they are (a whole greyed cap read as the bar greying where it met)."""
    out = normal.copy()
    m = (bare[..., 3] / 255)[..., None]
    g = sb.greyed(bare)
    out[..., :3] = normal[..., :3] * (1 - m) + g[..., :3] * m
    return out


def T(img):
    return np.ascontiguousarray(img.transpose(1, 0, 2))


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
            out[d + "-Disabled"] = T(greyed_fleur(imgs["Normal"], imgs["Bare"]))
            out[d + "-Highlight"] = T(sb.glow(imgs["Bare"]))
        for down in (False, True):
            # the slot closed with a plain round end, no arrow: a key row's
            c = sb.ucanvas(32, SLOT_END)
            pen = Pen(c, SLOT_END, down)
            sb.carve(c, sb.groove_end(pen, SLOT_END - 4))
            sb.border(pen, [sb.ribbon(sb.border_path(pen, SLOT_END - 4), sb.BORDER_HW)])
            out[("Right" if down else "Left") + "-Closed"] = T(c.final())
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
SLOT_END = 16  # a closed end's


def main():
    scroll = sb.render_set()
    out = {}
    for src, dst in (("Up", "Left"), ("Down", "Right")):
        for state in ("Normal", "Pushed", "Highlight"):
            out["Slide-%s-%s" % (dst, state)] = T(scroll["Scroll-%s-%s" % (src, state)])
        c = sb.ucanvas(32, 32)
        sb.fleur_cap(c, src == "Down", "Bare")
        out["Slide-%s-Disabled" % dst] = T(greyed_fleur(scroll["Scroll-%s-Normal" % src], c.final()))
    out["Slide-Mid"] = T(scroll["Scroll-Mid"])
    c = sb.ucanvas(32, 48)
    sb.flat_grain(c)
    sb.heart_thumb(c)
    out["Slide-Thumb"] = T(c.final())
    for k, v in choice_set().items():
        out["Choice-" + k] = v
    artout.clear(OUT, "Control-*.tga")
    for stem, rgba in out.items():
        sb.write_tga(os.path.join(OUT, "Control-%s-%d.tga" % (stem, VERSION)), np.clip(rgba, 0, 255))
    print(len(out), "textures")


if __name__ == "__main__":
    main()
