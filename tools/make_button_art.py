"""Our button (Style.lua's WC.Style.Button; the player's pick, 2026-11-12,
docs/looks.md rounds 7-9): a slab of the dark stone with cut corners and a
faceted bevel, in a bark rim. Drawn whole, the stone baked in, 160 x 36 units
with the 128 x 28 body in its middle so the glow can reach past it; the game
cuts it in three to stretch it to the word.

    python tools/make_button_art.py   writes addon/WowCompanion/Art/Button-<State>-<VERSION>.tga

States:
  Rest    the dark stone, the rim's bark dimmed
  Lit     under the cursor: the face stays dark, so the button stands out of
          the page rather than into it; the focus glow round it and the rim a
          brighter bronze
  Pushed  the face sunk a little and darker, the rim's shadow over its top,
          no shadow cast
Unavailable is Rest, desaturated in the game.

The game keeps a texture for the session under its path, so a change bumps
VERSION (and Style.lua's BUTTON_VERSION).
"""
import os
import sys

import numpy as np
from scipy import ndimage

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import artout  # noqa: E402
import make_scrollbar_art as M  # noqa: E402
import make_tab_art as tab  # noqa: E402
from make_listitem_art import cast  # noqa: E402
from make_scrollbar_art import Pen, U, WEIGHTS, LIGHT, ucanvas  # noqa: E402

VERSION = 1
W, H = 160, 36
X0, Y0, X1, Y1 = 16, 4, 144, 32  # the body
CUT = 5.0  # the corners' cut, in units
BEVEL = 3.4  # the faceted bevel's width
HW, PAL = WEIGHTS[""]  # the rim: the medium vine's weight and bark
RIM_BEVEL = 0.5 * HW / 0.55
PALS = {"Rest": M.dim(PAL, 0.8), "Pushed": M.dim(PAL, 0.8), "Lit": M.dim(PAL, 1.9)}
GLOW = np.array(M.FOCUS_GLOW, float)  # every hover glow of ours


def cut(inset=0.0, dy=0.0):
    """The body's outline, its corners cut, `inset` in from it."""
    k = max(CUT - inset * 0.6, 0.5)
    x0, y0, x1, y1 = X0 + inset, Y0 + inset + dy, X1 - inset, Y1 - inset + dy
    return [(x0 + k, y0), (x1 - k, y0), (x1, y0 + k), (x1, y1 - k), (x1 - k, y1), (x0 + k, y1), (x0, y1 - k), (x0, y0 + k)]


def face(c, m, pushed):
    """The dark stone, its bevel cut flat in facets lit from the top left, a
    dark edge round it and (unless pushed) its shadow cast."""
    s = U * c.s
    shade = 1.9
    if not pushed:
        cast(c, m, 0.8 * shade)
    edge = ndimage.gaussian_filter(ndimage.maximum_filter(m, size=int(0.9 * 2 * s) | 1), s * 0.25) * (1 - m)
    c.over(np.broadcast_to(np.array((8, 7, 6), float), c.rgb.shape), edge * 0.85)
    tab.stone(c, m, False)
    d = ndimage.distance_transform_edt(m > 0.5) / s
    hgt = ndimage.gaussian_filter(np.clip(d / BEVEL, 0, 1) * BEVEL * s, s * 0.06)
    gy, gx = np.gradient(hgt)
    nrm = np.stack([-gx, -gy, np.ones_like(gx)], -1)
    nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True)
    k = nrm @ LIGHT - LIGHT[2]
    c.over(np.broadcast_to(np.array((236, 214, 176), float), c.rgb.shape), np.clip(k * 1.6, 0, 1) * m * 0.32 * shade)
    c.over(np.zeros_like(c.rgb), np.clip(-k * 1.6, 0, 1) * m * 0.55 * shade)
    if pushed:  # sunk into its place: darker, the rim's shadow over its top
        yy = np.arange(c.H)[:, None] / s - c.pad / U + 0 * m
        c.over(np.zeros_like(c.rgb), m * (0.22 + 0.3 * np.clip(1 - (yy - Y0) / 8, 0, 1)))


def draw(state):
    c = ucanvas(W, H)
    pen = Pen(c, H)
    if state == "Lit":  # the focus glow, outside the body
        m = pen.mask([cut()])
        g = np.clip(ndimage.gaussian_filter(m, U * c.s * 1.8) * 2.2, 0, 1) * (1 - m)
        c.over(np.broadcast_to(GLOW, c.rgb.shape), g * 0.8)
    face(c, pen.mask([cut(dy=0.8 if state == "Pushed" else 0.0)]), state == "Pushed")
    ring = np.clip(pen.mask([cut()]) - pen.mask([cut(2 * HW)]), 0, 1)
    M.shadow(c, ring, 0.4)
    c.metal(ring, PALS[state], bevel=RIM_BEVEL * U, outline=1.1, shadow=False, sheen=False, paint=True, gloss=0.35, grain=False)
    return c.final()


def main():
    out = {state: draw(state) for state in PALS}
    artout.clear(M.CORE_OUT, "Button-*.tga")
    for state, rgba in out.items():
        M.write_tga(os.path.join(M.CORE_OUT, "Button-%s-%d.tga" % (state, VERSION)), np.clip(rgba, 0, 255))
    print(len(out), "textures")


if __name__ == "__main__":
    main()
