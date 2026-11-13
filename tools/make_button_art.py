"""A trial's art: buttons for the settings page, the cut-cornered slab (round
7's pick for elegance) made more of a button: crossed with the thick block and
the swelling face, and the bronze corners taken further; each at rest, lit
(under the cursor) and pressed. Drawn whole,
the stone baked in, 160 x 36 units with the 128 x 28 body in the middle so
ornament can reach past it. Goes when one is chosen.

    python tools/make_button_art.py   writes addon/WowCompanion/Art/Btn-<Kind>-<Rest|Lit|Pushed>-<ROUND>.tga
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

ROUND = 8
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


def draw(kind, state):
    lit, pushed = state == "Lit", state == "Pushed"
    c = ucanvas(W, H)
    pen = Pen(c, H)
    pal = PAL if lit else REST_PAL
    dy = 0.8 if pushed else 0.0  # pressed, the face sits a little lower
    m = pen.mask([cut(dy=dy)])
    ring = (cut(), cut(5.0, 2 * HW))
    if kind == "CutBlock":  # cut corners, the block's deep bevel, no metal
        face(c, m, lit, bevel=3.2, shade=1.7, pushed=pushed)
    elif kind == "CutBlockRim":  # the same, in a bark rim
        face(c, m, lit, bevel=2.8, shade=1.6, pushed=pushed)
        rim(c, pen, *ring, pal)
    elif kind == "CutPillow":  # cut corners, the face swelling, in a rim
        face(c, m, lit, bevel=2.0, pillow=2.6, shade=1.5, pushed=pushed)
        rim(c, pen, *ring, pal)
    elif kind == "CutBlockPillow":  # deep bevel and the swell together
        face(c, m, lit, bevel=3.0, pillow=2.2, shade=1.7, pushed=pushed)
        rim(c, pen, *ring, pal)
    elif kind == "Facets":  # the bevel cut flat, as a dressed stone, in a rim
        face(c, m, lit, bevel=3.4, shade=1.9, facets=True, pushed=pushed)
        rim(c, pen, *ring, pal)
    elif kind == "Plinth":  # the slab standing on a darker step of itself
        base = pen.mask([cut(6.0, -1.8, 2.2)])
        cast(c, base, 0.8)
        c.metal(base, M.dim(PAL, 0.55), bevel=BEVEL * U, outline=1.1, shadow=False, sheen=False, paint=True, gloss=0.2, grain=False)
        face(c, m, lit, bevel=2.2, pillow=0.8, pushed=pushed)
        rim(c, pen, *ring, pal)
    elif kind == "CutCorners":  # six on the cut slab: bronze laid along each cut, arms down the sides
        face(c, m, lit, bevel=2.4, pillow=0.8, pushed=pushed)
        k, L, o = 5.0, 4.5, HW * 0.7
        bars = []
        for sx, sy, x, y in ((1, 1, X0, Y0), (-1, 1, X1, Y0), (1, -1, X0, Y1), (-1, -1, X1, Y1)):
            bars.append(ribbon([(x + sx * (k + L), y + sy * o), (x + sx * k, y + sy * o),
                                (x + sx * o, y + sy * k), (x + sx * o, y + sy * (k + L * 0.5))], HW * 1.2))
        raised(pen, bars, pal, bevel=BEVEL, cast=0.5, grain=False)
    elif kind == "CornerScrolls":  # six's corners curling: a scroll of wire on each cut
        face(c, m, lit, bevel=2.4, pillow=0.8, pushed=pushed)
        rim(c, pen, *ring, pal)
        w = Wire((X0 + 1.4, Y0 + 3.6), 200).volute((X0 - 5.4, Y0 + 5.0), 4.8, 270, -1, 1.05, eye=1.5, out=0.3, inn=0.3)
        pieces = w.pieces(HW * 0.9, 0.8, swell=1.0) + mirrored_x(w, W / 2).pieces(HW * 0.9, 0.8, swell=1.0)
        lo = w.mirrored(H / 2)
        pieces += lo.pieces(HW * 0.9, 0.8, swell=1.0) + mirrored_x(lo, W / 2).pieces(HW * 0.9, 0.8, swell=1.0)
        raised(pen, pieces, pal, bevel=BEVEL, cast=0.4, grain=False)
    return c.final()


KINDS = ["CutBlock", "CutBlockRim", "CutPillow", "CutBlockPillow", "Facets", "Plinth", "CutCorners", "CornerScrolls"]


def render(kind):
    return {"%s-%s" % (kind, state): draw(kind, state) for state in ("Rest", "Lit", "Pushed")}


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
