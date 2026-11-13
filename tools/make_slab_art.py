"""Raised wells, on trial (the player, 2026-11-12: the dark panels should stand
up out of the page, hard-edged). Each variant is a slab of the dark slate
standing on the light slate: its bevel the slate itself lit from the top left
(a height map, as the scroll bar's art), its bottom and right faces showing
its thickness, a tight contact shadow and a soft cast shadow on the floor
round it. Nine pieces per variant, laid round a well by Style.lua (RAISED):

    python tools/make_slab_art.py   writes addon/WowCompanion/Art/Slab-<v>-<piece>-<ROUND>.tga

  Corners  2C x 2C units, the four corners (texcoord quarters)
  Top, Bottom  L x C, Left, Right  C x L: the edges, stretched along

C = margin + thickness + bevel + 2: the art covers the well's whole rectangle,
the slab inset from it by the margin (and its thickness at the bottom and
right). The slab's flat face is left clear: the game tiles the slate there.
4 texture pixels per unit, each piece resampled to power-of-two sides (odd
sizes drew wrong in the game, 2026-11-12).
"""
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import artout  # noqa: E402
import make_scrollbar_art as sb  # noqa: E402

ROUND = 2
PX = 4  # texture pixels per unit, as the controls' art
L = 384  # an edge strip's length, units
OUT = sb.CORE_OUT
SLATE = os.path.join(OUT, "Slate-6.tga")  # Style.lua's STONE.you
# name, bevel (units), round bevel, thickness, margin, the slate's shade:
# the same table is Style.lua's RAISED
VARIANTS = [
    ("Chamfer, dark", 3, False, 2, 8, 0.6),
    ("Chamfer, lifted", 3, False, 3, 8, 0.8),
    ("Rounded edge", 5, True, 2, 8, 0.8),
    ("Thick slab", 2, False, 5, 10, 0.8),
    ("Wide bevel, no sides", 6, False, 0, 8, 0.85),
    ("Tight margin", 3, False, 3, 5, 0.9),
]
LIGHT = np.array([-0.55, -0.75, 0.9]); LIGHT /= np.linalg.norm(LIGHT)


def render(bevel, rounded, thick, margin, shade):
    C = margin + thick + bevel + 2
    N = 2 * C + L  # the whole slab's art, units
    n = N * PX
    ys, xs = np.mgrid[0:n, 0:n] / PX + 0.5 / PX  # pixel centres, units
    x0, y0, x1, y1 = margin, margin, N - margin - thick, N - margin - thick
    # distance inward from the slab's edge, and its height
    d = np.minimum.reduce([xs - x0, ys - y0, x1 - xs, y1 - ys])
    inside = d > 0
    r = np.clip(d / bevel, 0, 1)
    h = (np.sqrt(1 - (1 - r) ** 2) if rounded else r) * bevel
    gy, gx = np.gradient(h, 1 / PX)
    nrm = np.dstack([-gx, -gy, np.ones_like(h)])
    nrm /= np.linalg.norm(nrm, axis=2, keepdims=True)
    lit = (nrm @ LIGHT) / LIGHT[2]
    slate = np.asarray(Image.open(SLATE).convert("RGB"), float)
    stone = slate[(ys.astype(int)) % 256, (xs.astype(int)) % 256] * shade
    # the slope's light pushed past nature, so the bevel reads at TV distance
    rgb = stone * np.clip(1 + 2.2 * (lit - 1), 0.3, 2.8)[..., None]
    # its thickness: the slab swept down and right, the faces in shadow
    slab = inside
    sweep = slab.copy()
    for k in range(1, thick * PX + 1):
        sweep |= np.roll(np.roll(slab, k, 0), k, 1)
    side = sweep & ~slab
    rgb[side] = stone[side] * 0.42
    # a hard dark line round the faces, and where they meet the slab's top;
    # none round the lit top and left, where a line read as a groove
    edge = side & ~ndimage.binary_erosion(sweep, iterations=1)
    lip = side & ndimage.binary_dilation(slab, iterations=1)
    rgb[edge | lip] = np.array(sb.OUTLINE, float)
    # shadows on the floor: tight contact, and a soft one cast down and right
    s = sweep.astype(float)
    contact = np.clip(ndimage.gaussian_filter(s, 1.2 * PX) * 1.6, 0, 1) * 0.75
    cast = ndimage.gaussian_filter(np.roll(np.roll(s, 3 * PX, 0), 2 * PX, 1), 5 * PX) * 0.5
    shadow = 1 - (1 - contact) * (1 - cast)
    a = np.where(sweep, 1.0, shadow)
    a[slab & (r >= 1)] = 0  # the flat face: the game's tiled slate
    out = np.zeros((n, n, 4))
    out[..., :3] = np.where(sweep[..., None], rgb, 0)
    out[..., 3] = a * 255
    return C, out


def pow2(rgba):
    """The piece resampled to the nearest power of two on each side."""
    h, w = rgba.shape[:2]
    p = lambda n: 1 << max(2, round(np.log2(n)))
    if (p(h), p(w)) == (h, w):
        return rgba
    im = Image.fromarray(np.clip(rgba, 0, 255).astype(np.uint8), "RGBA")
    return np.asarray(im.resize((p(w), p(h)), Image.LANCZOS), float)


def main():
    artout.clear(OUT, "Slab-*.tga")
    for v, (name, bevel, rounded, thick, margin, shade) in enumerate(VARIANTS, 1):
        C, img = render(bevel, rounded, thick, margin, shade)
        c, n = C * PX, img.shape[0]
        pieces = {
            "Corners": np.concatenate([np.concatenate([img[:c, :c], img[:c, -c:]], 1),
                                       np.concatenate([img[-c:, :c], img[-c:, -c:]], 1)], 0),
            "Top": img[:c, c:n - c], "Bottom": img[-c:, c:n - c],
            "Left": img[c:n - c, :c], "Right": img[c:n - c, -c:],
        }
        for piece, rgba in pieces.items():
            rgba = pow2(rgba)
            sb.write_tga(os.path.join(OUT, "Slab-%d-%s-%d.tga" % (v, piece, ROUND)), np.clip(rgba, 0, 255))
        print(v, name, "corner", C)


if __name__ == "__main__":
    main()
