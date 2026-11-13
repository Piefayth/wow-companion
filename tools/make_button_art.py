"""A trial's art: buttons for the settings page, each a variation on the
list's raised slab (make_listitem_art.py's Slab-Edge and Slab-Rim, the look the
player liked, 2026-11-12), at rest and lit (under the cursor). Drawn whole,
the stone baked in, 160 x 36 units with the 128 x 28 body in the middle so
ornament can reach past it. Goes when one is chosen.

    python tools/make_button_art.py   writes addon/WowCompanion/Art/Btn-<Kind>-<Rest|Lit>-<ROUND>.tga
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

ROUND = 7
W, H = 160, 36
X0, Y0, X1, Y1 = 16, 4, 144, 32  # the body
HW, PAL = WEIGHTS[""]
BEVEL = 0.5 * HW / 0.55
REST_PAL = M.dim(PAL, 0.8)


def chamfered(x0, y0, x1, y1, k):
    return [(x0 + k, y0), (x1 - k, y0), (x1, y0 + k), (x1, y1 - k), (x1 - k, y1), (x0 + k, y1), (x0, y1 - k), (x0, y0 + k)]


def face(c, m, lit, bevel=1.4, pillow=0.0, shade=1.0):
    """The slab's face: the stone (the light one lit), its edge lit top left
    and shaded bottom right, a dark edge round it and its shadow cast."""
    s = U * c.s
    cast(c, m, 0.8 * shade)
    edge = ndimage.gaussian_filter(ndimage.maximum_filter(m, size=int(0.9 * 2 * s) | 1), s * 0.25) * (1 - m)
    c.over(np.broadcast_to(np.array((8, 7, 6), float), c.rgb.shape), edge * 0.85)
    tab.stone(c, m, lit)
    d = ndimage.distance_transform_edt(m > 0.5) / s
    t = np.clip(d / bevel, 0, 1)
    hgt = (1 - (1 - t) ** 2) * bevel
    if pillow:
        yy = np.arange(c.H)[:, None] / s - c.pad / U
        v = np.clip((yy - Y0) / (Y1 - Y0) * 2 - 1, -1, 1)
        hgt = hgt + pillow * (1 - v ** 2) * t
    hgt = ndimage.gaussian_filter(hgt * s, s * 0.15)
    gy, gx = np.gradient(hgt)
    nrm = np.stack([-gx, -gy, np.ones_like(gx)], -1)
    nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True)
    k = nrm @ LIGHT - LIGHT[2]
    c.over(np.broadcast_to(np.array((236, 214, 176), float), c.rgb.shape), np.clip(k * 1.6, 0, 1) * m * 0.32 * shade)
    c.over(np.zeros_like(c.rgb), np.clip(-k * 1.6, 0, 1) * m * 0.55 * shade)


def rim(c, pen, outline, inner, pal):
    ring = np.clip(pen.mask([outline]) - pen.mask([inner]), 0, 1)
    M.shadow(c, ring, 0.4)
    c.metal(ring, pal, bevel=BEVEL * U, outline=1.1, shadow=False, sheen=False, paint=True, gloss=0.35, grain=False)


def box(r=3.0, inset=0.0):
    return rounded(X0 + inset, Y0 + inset, X1 - inset, Y1 - inset, max(r - inset, 0.6))


def draw(kind, lit):
    c = ucanvas(W, H)
    pen = Pen(c, H)
    pal = PAL if lit else REST_PAL
    if kind == "Slab":  # the list's slab as it is: the rim only when lit
        face(c, pen.mask([box()]), lit)
        if lit:
            rim(c, pen, box(3.2), box(3.2, 2 * HW), PAL)
    elif kind == "Rimmed":  # the rim always, dimmer at rest
        face(c, pen.mask([box()]), lit)
        rim(c, pen, box(3.2), box(3.2, 2 * HW), pal)
    elif kind == "Chamfer":  # corners cut, as a plaque is
        face(c, pen.mask([chamfered(X0, Y0, X1, Y1, 5)]), lit)
        rim(c, pen, chamfered(X0, Y0, X1, Y1, 5), chamfered(X0 + 2 * HW, Y0 + 2 * HW, X1 - 2 * HW, Y1 - 2 * HW, 5 - HW), pal)
    elif kind == "Scrolls":  # a scroll of the rim's wire curling from each end
        face(c, pen.mask([box()]), lit)
        rim(c, pen, box(3.2), box(3.2, 2 * HW), pal)
        w = Wire((X0 + 0.5, (Y0 + Y1) / 2), 180).volute((X0 - 7.5, (Y0 + Y1) / 2 - 4.2), 6.2, 90, 1, 1.05, eye=1.8, out=0.3, inn=0.3)
        raised(pen, w.pieces(HW, 0.85, swell=1.0) + mirrored_x(w, W / 2).pieces(HW, 0.85, swell=1.0),
               pal, bevel=BEVEL, cast=0.4, grain=False)
    elif kind == "Block":  # a thick stone block, its bevel deep, no metal
        face(c, pen.mask([box(2.0)]), lit, bevel=3.0, shade=1.25)
        if lit:  # the lamp's warmth caught round its edge
            m = pen.mask([box(2.0)])
            d = ndimage.distance_transform_edt(m > 0.5) / (U * c.s)
            c.over(np.broadcast_to(np.array(M.FOCUS_GLOW, float), c.rgb.shape), m * np.clip(1 - d / 2.5, 0, 1) * 0.35)
    elif kind == "Corners":  # the slab held by bronze corner pieces
        face(c, pen.mask([box()]), lit)
        L = 7
        arms = []
        for (x, y, sx, sy) in ((X0, Y0, 1, 1), (X1, Y0, -1, 1), (X0, Y1, 1, -1), (X1, Y1, -1, -1)):
            x += sx * HW * 0.6
            y += sy * HW * 0.6
            arms.append(ribbon([(x + sx * L, y), (x, y), (x, y + sy * L * 0.55)], HW * 1.1))
        raised(pen, arms, pal, bevel=BEVEL, cast=0.5, grain=False)
    elif kind == "Pillow":  # the face swelling toward the light
        face(c, pen.mask([box(4.0)]), lit, bevel=2.0, pillow=1.6)
        rim(c, pen, box(4.2), box(4.2, 2 * HW), pal)
    elif kind == "Inlaid":  # a wire of the bark laid into the face, in from its edge
        face(c, pen.mask([box()]), lit)
        loop = box(2.0, 3.2)
        raised(pen, [ribbon(loop + loop[:1], HW * 0.65)], pal, bevel=BEVEL * 0.7, cast=0.25, grain=False)
    return c.final()


KINDS = ["Slab", "Rimmed", "Chamfer", "Scrolls", "Block", "Corners", "Pillow", "Inlaid"]


def render(kind):
    return {"%s-%s" % (kind, tag): draw(kind, lit) for lit, tag in ((False, "Rest"), (True, "Lit"))}


def main():
    from multiprocessing import Pool
    out = {}
    with Pool(4) as pool:
        for part in pool.map(render, KINDS):
            out.update(part)
    artout.clear(M.CORE_OUT, "Btn-*.tga")
    for stem, rgba in out.items():
        M.write_tga(os.path.join(M.CORE_OUT, "Btn-%s-%d.tga" % (stem, ROUND)), np.clip(rgba, 0, 255))
    print(len(out), "textures")


if __name__ == "__main__":
    main()
