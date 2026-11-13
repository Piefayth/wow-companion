"""Raised wells, on trial (the player, 2026-11-12: the dark panels should stand
up out of the page). Each variant is the dark slate seen from straight above,
high in the middle and sloping down to its edges, its slopes the slate itself
lit from the top left (a height map, as the scroll bar's art); no walls seen
from an angle (round 2's sides read as a building seen off-angle, too dark).
The slopes run down into a channel at the edge, where the vine beside it
lies (the vines' own art, unchanged). Nine pieces per variant, laid round a well by Style.lua (RAISE_LOOKS):

    python tools/make_slab_art.py   writes addon/WowCompanion/Art/Slab-<v>-<piece>-<ROUND>.tga

  Corners  2C x 2C units, the four corners (texcoord quarters)
  Top, Bottom  L x C, Left, Right  C x L: the edges, stretched along

C = MARGIN + bevel + 2: the art reaches MARGIN past the well, where a faint
contact shadow falls. The flat top is left clear: the game tiles the slate
there. 4 texture pixels per unit, each piece resampled to power-of-two sides
(odd sizes drew wrong in the game, 2026-11-12).
"""
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import artout  # noqa: E402
import make_scrollbar_art as sb  # noqa: E402

ROUND = 4
PX = 4  # texture pixels per unit, as the controls' art
L = 384  # an edge strip's length, units
MARGIN = 3  # Style.lua's SLAB_MARGIN
OUT = sb.CORE_OUT
SLATE = os.path.join(OUT, "Slate-6.tga")  # Style.lua's STONE.you
# Each slab's edge holds a channel for the vine beside it (the vines are drawn
# by their own art over the seam, unchanged; this only carves the stone they
# lie in): name, the channel's width, its floor's darkness, a raised bead
# beside it (width), the slope's width and profile, its rise, the slate's
# shade. Style.lua's RAISE_LOOKS holds each one's whole edge width.
VARIANTS = [
    ("Channel, chamfer", 5, 0.55, 0, 8, "chamfer", 6, 0.8),
    ("Channel, cushion", 5, 0.55, 0, 12, "cushion", 8, 0.8),
    ("Channel and bead", 4, 0.5, 3, 8, "chamfer", 6, 0.8),
    ("Narrow deep channel", 3, 0.4, 0, 6, "wall", 6, 0.8),
    ("Wide shallow channel", 9, 0.7, 0, 6, "chamfer", 4, 0.8),
    ("Cove", 0, 1.0, 0, 14, "cove", 8, 0.8),
]
LIGHT = np.array([-0.55, -0.75, 0.9]); LIGHT /= np.linalg.norm(LIGHT)


def profile(r, kind):
    """The rise at r (0 at the slope's foot, 1 where the top is flat), 0..1."""
    if kind == "cushion":
        return r * r * (3 - 2 * r) * 0.5 + np.sqrt(1 - (1 - r) ** 2) * 0.5
    if kind == "wall":  # a steep wall out of the channel, then a gentle slope
        return 0.6 * np.clip(r / 0.2, 0, 1) + 0.4 * np.clip((r - 0.2) / 0.8, 0, 1)
    if kind == "cove":  # concave: rising steeply from the vine, easing to the top
        return 1 - (1 - r) ** 2
    return r


def render(channel, floor, bead, bevel, kind, rise, shade):
    E = channel + bead + bevel  # the whole edge, units
    C = MARGIN + E + 2
    N = 2 * C + L  # the whole slab's art, units
    n = N * PX
    ys, xs = np.mgrid[0:n, 0:n] / PX + 0.5 / PX  # pixel centres, units
    x0, y0, x1, y1 = MARGIN, MARGIN, N - MARGIN, N - MARGIN
    # distance inward from the slab's edge, and its height: the channel's
    # floor, the bead, then the slope up to the top
    d = np.minimum.reduce([xs - x0, ys - y0, x1 - xs, y1 - ys])
    slab = d > 0
    r = np.clip((d - channel - bead) / bevel, 0, 1)
    h = profile(r, kind) * rise
    if bead:
        t = np.clip((d - channel) / bead, 0, 1)
        h = np.maximum(h, np.sin(np.pi * t) * rise * 0.35 * (d < channel + bead))
    gy, gx = np.gradient(h, 1 / PX)
    nrm = np.dstack([-gx, -gy, np.ones_like(h)])
    nrm /= np.linalg.norm(nrm, axis=2, keepdims=True)
    lit = (nrm @ LIGHT) / LIGHT[2]
    slate = np.asarray(Image.open(SLATE).convert("RGB"), float)
    stone = slate[(ys.astype(int)) % 256, (xs.astype(int)) % 256] * shade
    # the lit slopes pushed past nature so they read at TV distance; the
    # shaded ones gentler (round 2's dark sides were "crazy")
    k = np.where(lit > 1, 1 + 2.0 * (lit - 1), 1 + 0.8 * (lit - 1))
    # the channel's floor in the slab's shadow, darkest at the foot of the wall
    sunk = 1 - (1 - floor) * np.clip(1 - d / max(channel, 1e-6), 0, 1) ** 0.5 * (d < channel)
    rgb = stone * (np.clip(k, 0.45, 2.6) * sunk)[..., None]
    # a faint contact shadow round it
    contact = np.clip(ndimage.gaussian_filter(slab.astype(float), 1.2 * PX) * 1.6, 0, 1) * 0.35
    a = np.where(slab, 1.0, contact)
    a[slab & (d >= E)] = 0  # the flat top: the game's tiled slate
    out = np.zeros((n, n, 4))
    out[..., :3] = np.where(slab[..., None], rgb, 0)
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
    for v, (name, *spec) in enumerate(VARIANTS, 1):
        C, img = render(*spec)
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
