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
  Step-<Left|Right>-<state> 32x32   the fleur alone, no groove: a choice's arrows
  Plate-<Left|Mid|Right> 16x24      a slot carved in the stone, bark bordered,
                                    showing a choice's value (Mid stretched)
  Button-<state> 128x24             a raised slate plate in a bark border

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
SLATE = ((9, 10, 13), (24, 26, 31), (50, 52, 60))  # the button's raised slate: the stone's own dark, a step lighter at its lit edge


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
        m = pen.mask([inner])
        c.metal(m, SLATE, bevel=1.4 * sb.U, outline=0, shadow=False, sheen=False, paint=True, grain=False, gloss=0.15)
    elif face == "carved":
        sb.carve(c, pen.mask([inner]))
    hw = sb.BORDER_HW
    border = ring(pen, stadium(2.2 + r, w - 2.2 - r, cy, r + hw), stadium(2.2 + r, w - 2.2 - r, cy, r - hw))
    sb.shadow(c, border, 0.4)
    c.metal(border, sb.BARK, bevel=0.6 * sb.U, outline=1.1, shadow=False, sheen=False, paint=True, grain=False, gloss=0.35)
    return c.final()


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
    for down, dst in ((False, "Left"), (True, "Right")):
        c = sb.ucanvas(32, 32)
        sb.fleur_cap(c, down, "Bare")
        bare = c.final()
        pushed = bare.copy()
        pushed[..., :3] *= 0.84
        for state, img in (("Normal", bare), ("Pushed", pushed), ("Highlight", sb.glow(bare)), ("Disabled", sb.greyed(bare))):
            out["Step-%s-%s" % (dst, state)] = T(img)
    p = plate(48, 24, "carved")
    q = 16 * sb.U
    out["Plate-Left"], out["Plate-Right"] = p[:, :q], p[:, -q:]
    mid = p[:, 2 * q - 2 * sb.U:2 * q + 2 * sb.U]
    out["Plate-Mid"] = np.repeat(mid.mean(1, keepdims=True), mid.shape[1], 1)
    b = plate(128, 24, "raised")
    pushed = b.copy()
    pushed[..., :3] *= 0.8
    out["Button-Normal"], out["Button-Pushed"] = b, pushed
    # the glow warms the bark border alone, never the face
    out["Button-Highlight"], out["Button-Disabled"] = sb.glow(plate(128, 24, None)), sb.greyed(b)
    for old in glob.glob(os.path.join(OUT, "Control-*.tga")):
        os.remove(old)
    for stem, rgba in out.items():
        sb.write_tga(os.path.join(OUT, "Control-%s-%d.tga" % (stem, VERSION)), np.clip(rgba, 0, 255))
    print(len(out), "textures")


if __name__ == "__main__":
    main()
