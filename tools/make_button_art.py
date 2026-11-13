"""A trial's art: the settings page's button, round 8's pick (Facets), with
six ways to light it under the cursor (round 8's lit face, the light stone,
blended into the page). Drawn whole,
the stone baked in, 160 x 36 units with the 128 x 28 body in the middle so
ornament can reach past it. Goes when one is chosen.

    python tools/make_button_art.py   writes addon/WowCompanion/Art/Btn-Facets-<State>-<ROUND>.tga
"""
import os
import sys

import numpy as np
from scipy import ndimage

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import artout  # noqa: E402
import make_scrollbar_art as M  # noqa: E402
import make_tab_art as tab  # noqa: E402
from make_listitem_art import rounded, cast, mirrored_x  # noqa: E402
from make_scrollbar_art import Pen, Wire, U, WEIGHTS, LIGHT, ucanvas, raised, ribbon  # noqa: E402

ROUND = 9
W, H = 160, 36
X0, Y0, X1, Y1 = 16, 4, 144, 32  # the body
HW, PAL = WEIGHTS[""]
BEVEL = 0.5 * HW / 0.55
REST_PAL = M.dim(PAL, 0.8)


def chamfered(x0, y0, x1, y1, k):
    return [(x0 + k, y0), (x1 - k, y0), (x1, y0 + k), (x1, y1 - k), (x1 - k, y1), (x0 + k, y1), (x0, y1 - k), (x0, y0 + k)]


def face(c, m, lit, bevel=1.4, pillow=0.0, shade=1.0, facets=False, pushed=False):
    """The slab's face: the stone (the light one lit), its edge lit top left
    and shaded bottom right, a dark edge round it and its shadow cast."""
    s = U * c.s
    if not pushed:
        cast(c, m, 0.8 * shade)
    edge = ndimage.gaussian_filter(ndimage.maximum_filter(m, size=int(0.9 * 2 * s) | 1), s * 0.25) * (1 - m)
    c.over(np.broadcast_to(np.array((8, 7, 6), float), c.rgb.shape), edge * 0.85)
    tab.stone(c, m, lit)
    d = ndimage.distance_transform_edt(m > 0.5) / s
    t = np.clip(d / bevel, 0, 1)
    hgt = (t if facets else 1 - (1 - t) ** 2) * bevel
    if pillow:
        yy = np.arange(c.H)[:, None] / s - c.pad / U
        v = np.clip((yy - Y0) / (Y1 - Y0) * 2 - 1, -1, 1)
        hgt = hgt + pillow * (1 - v ** 2) * t
    hgt = ndimage.gaussian_filter(hgt * s, s * (0.06 if facets else 0.15))
    gy, gx = np.gradient(hgt)
    nrm = np.stack([-gx, -gy, np.ones_like(gx)], -1)
    nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True)
    k = nrm @ LIGHT - LIGHT[2]
    c.over(np.broadcast_to(np.array((236, 214, 176), float), c.rgb.shape), np.clip(k * 1.6, 0, 1) * m * 0.32 * shade)
    c.over(np.zeros_like(c.rgb), np.clip(-k * 1.6, 0, 1) * m * 0.55 * shade)
    if pushed:  # sunk into its place: darker, the rim's shadow over its top
        yy = np.arange(c.H)[:, None] / s - c.pad / U + 0 * m
        c.over(np.zeros_like(c.rgb), m * (0.22 + 0.3 * np.clip(1 - (yy - Y0) / 8, 0, 1)))


def rim(c, pen, outline, inner, pal):
    ring = np.clip(pen.mask([outline]) - pen.mask([inner]), 0, 1)
    M.shadow(c, ring, 0.4)
    c.metal(ring, pal, bevel=BEVEL * U, outline=1.1, shadow=False, sheen=False, paint=True, gloss=0.35, grain=False)


def box(r=3.0, inset=0.0):
    return rounded(X0 + inset, Y0 + inset, X1 - inset, Y1 - inset, max(r - inset, 0.6))


def cut(k=5.0, inset=0.0, dy=0.0):
    return chamfered(X0 + inset, Y0 + inset + dy, X1 - inset, Y1 - inset + dy, max(k - inset * 0.6, 0.5))


GLOW = np.array(M.FOCUS_GLOW, float)  # every hover glow of ours


def halo(c, m, width, k):
    """The focus glow's colour spread out round m, outside it."""
    s = U * c.s
    g = np.clip(ndimage.gaussian_filter(m, s * width) * 2.2, 0, 1) * (1 - m)
    c.over(np.broadcast_to(GLOW, c.rgb.shape), g * k)


def draw(state):
    """Round 8's pick (Facets: cut corners, a faceted bevel, a bark rim) at
    rest, pressed, and lit six ways: the face stays the dark stone in each, so
    the button under the cursor stands out of the page rather than into it."""
    pushed = state == "Pushed"
    c = ucanvas(W, H)
    pen = Pen(c, H)
    m = pen.mask([cut(dy=0.8 if pushed else 0.0)])
    outline = pen.mask([cut()])
    ring = (cut(), cut(5.0, 2 * HW))
    s = U * c.s
    if state == "LitHalo":  # the focus glow round it, outside the rim
        halo(c, outline, 2.4, 1.0)
    if state == "LitHaloRim":
        halo(c, outline, 1.8, 0.8)
    face(c, m, False, bevel=3.4, shade=1.9, facets=True, pushed=pushed)
    d = ndimage.distance_transform_edt(m > 0.5) / s
    yy = np.arange(c.H)[:, None] / s - c.pad / U + 0 * m
    if state == "LitInner":  # a warm light round the inside of the face
        c.over(np.broadcast_to(GLOW, c.rgb.shape), m * np.clip(1 - (d - 1.6) / 4.0, 0, 1) ** 1.3 * 0.75)
    elif state == "LitLamp":  # lamplight rising from its foot
        c.over(np.broadcast_to(GLOW, c.rgb.shape), m * np.clip((yy - Y0) / (Y1 - Y0), 0, 1) ** 2.2 * 0.5)
    elif state == "LitGilt":  # the facets catch gold: the bevel lit, the flat face dark
        c.over(np.broadcast_to(GLOW, c.rgb.shape), m * np.clip(1 - (d - 1.6) / 2.6, 0, 1) * 0.9)
    bright = M.dim(PAL, 1.9)
    pal = {"Rest": REST_PAL, "Pushed": REST_PAL, "LitRim": bright, "LitHaloRim": bright, "LitGilt": bright}.get(state, PAL)
    rim(c, pen, *ring, pal)
    return c.final()


STATES = ["Rest", "Pushed", "LitHalo", "LitRim", "LitHaloRim", "LitInner", "LitLamp", "LitGilt"]


def render(state):
    return {"Facets-" + state: draw(state)}


def main():
    from multiprocessing import Pool
    out = {}
    with Pool(4) as pool:
        for part in pool.map(render, STATES):
            out.update(part)
    artout.clear(M.CORE_OUT, "Btn-*.tga")
    for stem, rgba in out.items():
        M.write_tga(os.path.join(M.CORE_OUT, "Btn-%s-%d.tga" % (stem, ROUND)), np.clip(rgba, 0, 255))
    print(len(out), "textures")


if __name__ == "__main__":
    main()
