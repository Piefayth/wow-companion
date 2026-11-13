"""A design sheet's art, for now: slot floors and button faces to choose from,
each drawn whole (tools/make_control_art.py's plate). Goes when one is chosen.

    python tools/make_demo_art.py   writes addon/WowCompanion/Art/Demo-*.tga
"""
import glob
import os
import sys

import numpy as np
from scipy import ndimage

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_control_art as ctl  # noqa: E402
import make_scrollbar_art as sb  # noqa: E402

FLOORS = {
    "Grey": (31, 30, 33),  # now
    "Ink": (16, 22, 38),
    "DeepInk": (10, 14, 27),
    "Leather": (40, 26, 17),
}

BRONZE_PLATE = ((30, 22, 13), (88, 70, 46), (150, 126, 88))
HEARTWOOD = ((24, 15, 9), (70, 48, 31), (122, 92, 62))
LACQUER = ((2, 4, 8), (10, 15, 28), (26, 34, 56))


def floor(name):
    saved = sb.FLOOR
    try:
        sb.FLOOR = FLOORS[name]
        return ctl.plate(240, 32, "carved")
    finally:
        sb.FLOOR = saved


def face(kind):
    c = sb.ucanvas(128, 28)
    pen = sb.Pen(c, 28)
    r = 28 / 2 - 2.2
    inner = ctl.stadium(2.2 + r, 128 - 2.2 - r, 14, r)
    m = pen.mask([inner])
    if kind == "Slate":
        ctl.raised_face(c, m)
    else:
        sb.shadow(c, m, 0.85)
        pal = {"Heartwood": HEARTWOOD, "Bronze": BRONZE_PLATE, "Lacquer": LACQUER}[kind]
        gloss = 0.9 if kind == "Lacquer" else 0.35
        c.metal(m, pal, bevel=2.4 * sb.U, outline=0, shadow=False, sheen=True, paint=True,
                grain=False, gloss=gloss)
        if kind == "Heartwood":
            # the redder heart along its length, as the thumb's down its middle
            s = sb.U * c.s
            heart = ndimage.gaussian_filter(pen.mask([[(-4, 12.6), (132, 12.6), (132, 15.4), (-4, 15.4)]]), s * 0.8) * m
            c.over(np.broadcast_to(np.array(sb.HEART_CORE, float), c.rgb.shape), heart * 0.55)
    hw = sb.BORDER_HW
    border = ctl.ring(pen, ctl.stadium(2.2 + r, 128 - 2.2 - r, 14, r + hw), ctl.stadium(2.2 + r, 128 - 2.2 - r, 14, r - hw))
    sb.shadow(c, border, 0.4)
    c.metal(border, sb.BARK, bevel=0.6 * sb.U, outline=1.1, shadow=False, sheen=False, paint=True, grain=False, gloss=0.35)
    return c.final()


def main():
    out = {}
    for name in FLOORS:
        out["Floor-" + name] = floor(name)
    for kind in ("Slate", "Heartwood", "Bronze", "Lacquer"):
        out["Button-" + kind] = face(kind)
    for old in glob.glob(os.path.join(ctl.OUT, "Demo-*.tga")):
        os.remove(old)
    for stem, rgba in out.items():
        sb.write_tga(os.path.join(ctl.OUT, "Demo-%s.tga" % stem), np.clip(rgba, 0, 255))
    print(len(out), "textures")


if __name__ == "__main__":
    main()
