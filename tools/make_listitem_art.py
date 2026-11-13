"""A scrolling list's slabs (Core's Style.lua, WC.Style.List, look "A"): the
pieces that are not already the stones or the vines. In the vines' bark,
at U texels a unit, transparent round them.

    python tools/make_listitem_art.py    writes addon/WowCompanion/Art/ListItem-*-<VERSION>.tga

Pieces, in units:
  Slab-Edge 32x32, a nine-slice (corners 8): a slab of stone standing out of
    the well, its face clear (the stone shows), lit along its top and left,
    shaded along its bottom and right, a dark edge and a shadow cast down and
    right; the slab 4 in from each side of the texture
  Slab-Rim 32x32, the same nine-slice: the chosen slab's bark rim, round
    cornered, the medium vine's weight

The game keeps a texture for the session under its path, so a change bumps
VERSION (and Style.lua's LIST_ITEM_VERSION); older files are deleted.
"""
import os
import artout
import sys

import numpy as np
from scipy import ndimage

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_scrollbar_art as M  # noqa: E402
from make_scrollbar_art import Pen, U, WEIGHTS, LIGHT, ucanvas, write_tga  # noqa: E402

VERSION = 1
OUT = M.CORE_OUT
HW, PAL = WEIGHTS[""]  # the medium vine's half-width and bark
BEVEL = 0.5 * HW / 0.55  # as vine() bevels it


def rounded(x0, y0, x1, y1, r, n=12):
    """A rounded rectangle's outline as a polygon, in units."""
    pts = []
    for cx, cy, a0 in ((x1 - r, y0 + r, -90), (x1 - r, y1 - r, 0), (x0 + r, y1 - r, 90), (x0 + r, y0 + r, 180)):
        for a in np.radians(np.linspace(a0, a0 + 90, n)):
            pts.append((cx + r * np.cos(a), cy + r * np.sin(a)))
    return pts


def nine(img, margin=8):
    """A nine-slice's middle rows and columns made the same along their stretch."""
    p = margin * U
    out = img.copy()
    out[p:-p, :] = out[p:-p, :].mean(0, keepdims=True)
    out[:, p:-p] = out[:, p:-p].mean(1, keepdims=True)
    return out


def cast(c, m, k):
    """M.shadow's soft shadow of m, down and right, only outside m (a slab's face stays clear)."""
    s = U * c.s
    sh = ndimage.shift(ndimage.gaussian_filter(m, s * 0.5), (s * 0.6, s * 0.4), order=1)
    c.over(np.zeros_like(c.rgb), np.clip(sh, 0, 1) * (1 - m) * k)


def slab_edge():
    n = 32
    c = ucanvas(n, n)
    pen = Pen(c, n)
    m = pen.mask([rounded(4, 4, 28, 28, 3)])
    cast(c, m, 0.8)
    s = U * c.s  # canvas pixels a unit
    edge = ndimage.gaussian_filter(ndimage.maximum_filter(m, size=int(0.9 * 2 * s) | 1), s * 0.25) * (1 - m)
    c.over(np.broadcast_to(np.array((8, 7, 6), float), c.rgb.shape), edge * 0.85)
    d = ndimage.distance_transform_edt(m > 0.5) / s
    bevel = 1.4
    t = np.clip(d / bevel, 0, 1)
    hgt = ndimage.gaussian_filter((1 - (1 - t) ** 2) * bevel * s, s * 0.15)
    gy, gx = np.gradient(hgt)
    nrm = np.stack([-gx, -gy, np.ones_like(gx)], -1)
    nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True)
    k = nrm @ LIGHT - LIGHT[2]
    lit = np.clip(k * 1.6, 0, 1) * m
    dark = np.clip(-k * 1.6, 0, 1) * m
    c.over(np.broadcast_to(np.array((236, 214, 176), float), c.rgb.shape), lit * 0.32)
    c.over(np.zeros_like(c.rgb), dark * 0.55)
    return nine(c.final())


def slab_rim():
    n = 32
    c = ucanvas(n, n)
    pen = Pen(c, n)
    outer = pen.mask([rounded(4, 4, 28, 28, 3.2)])
    cast(c, outer, 0.8)  # the chosen slab stands out too
    ring = np.clip(outer - pen.mask([rounded(4 + 2 * HW, 4 + 2 * HW, 28 - 2 * HW, 28 - 2 * HW, 3.2 - HW)]), 0, 1)
    M.shadow(c, ring, 0.4)
    c.metal(ring, PAL, bevel=BEVEL * U, outline=1.1, shadow=False, sheen=False, paint=True, gloss=0.35, grain=False)
    return nine(c.final())


def render():
    return {"Slab-Edge": slab_edge(), "Slab-Rim": slab_rim()}


def main():
    made = render()
    artout.clear(OUT, "ListItem-*.tga")
    for name, rgba in made.items():
        write_tga(os.path.join(OUT, "ListItem-%s-%d.tga" % (name, VERSION)), rgba)
    print(len(made), "textures")


if __name__ == "__main__":
    main()
