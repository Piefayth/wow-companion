"""A trial (the player, 2026-11-13): spine ends round 6, the folded corner
cover laid over the real spine, smaller (round 5, 2ecc90e, drew the eye). Round 4 (a33d974) drew its own vine and a
mock panel's side face the game does not have, so its vine missed the spine's
and the bottom was not the top's. Here the spine is the game's own, whole, its
round end under the cover; the cover is only a thin sheet: a gusset over the
names panel's corner, its arm along the panel's edge carried on as a strap
over the vine, pressed round it, cut square where the vine comes out. Drawn
in place for each end, the light from the top left on both:

    python tools/make_cover_trial.py   writes addon/WowCompanion/Art/Vine-CornerCover<Top|Bottom>-T5.tga

48 x 16 units, 4 texels each; the spine's middle at x 24, the panel's edge
at x 22.5 and at the texture's top (bottom). Removed with the trial once one
is picked (docs/looks.md).
"""
import math, os
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage as nd
import make_scrollbar_art as sb

U, SS = sb.U, 4
TW, TH = 48, 16
MID, EDGE_X = 24.0, 22.5  # the spine's middle, the panel's edge
VINE = sb.WEIGHTS["Thick"][0]  # the spine's half-width
STRAP = MID + VINE + 0.5  # the strap's right edge, past the vine
TIP = 12.0  # where the cover's arm ends down the panel's edge
FACE = np.array((116, 99, 77.)); LIGHT = np.array((206, 188, 152.)); DARK = np.array((44, 33, 22.))
L = np.array((-1., -1.)) / math.sqrt(2)


def mask(polys, circles=()):
    s = U * SS
    im = Image.new("L", (TW * s, TH * s), 0); d = ImageDraw.Draw(im)
    for p in polys: d.polygon([(x * s, y * s) for x, y in p], fill=255)
    for cx, cy, r in circles: d.ellipse([(cx - r) * s, (cy - r) * s, (cx + r) * s, (cy + r) * s], fill=255)
    return np.asarray(im, float) / 255


def down(a): return np.asarray(Image.fromarray(a).resize((TW * U, TH * U), Image.BOX), float) if a.ndim == 2 else a


def gusset():
    sweep = sb.bez((EDGE_X - 3.0, TIP), (EDGE_X - 3.2, TIP * 0.5), (EDGE_X - 5.6, 2), (EDGE_X - 10, 0))
    return [(EDGE_X - 10, 0), (STRAP, 0), (STRAP, TIP)] + [tuple(p) for p in sweep]


def outward(m):
    g = nd.gaussian_filter(m, SS * 0.8); gy, gx = np.gradient(g)
    n = np.hypot(gx, gy) + 1e-9
    return (-gx * L[0] - gy * L[1]) / n


def lay(img, a, col):
    a = np.clip(a, 0, 1)[..., None]
    return img * (1 - a) + col * a


def draw(flip):
    Y = (lambda y: TH - y) if flip else (lambda y: y)
    poly = [(x, Y(y)) for x, y in gusset()]
    m = mask([poly])
    h, w = m.shape
    yy, xx = np.mgrid[0:h, 0:w] / (U * SS)
    rgb = np.zeros((h, w, 3)); a = np.zeros((h, w))
    # the hairline where the sheet's edges away from the light meet the panel
    ring_out = np.clip(nd.grey_dilation(m, size=SS + 1) - m, 0, 1) * (xx < EDGE_X)
    dot = outward(m)
    c = ring_out * 0.5 * np.clip(-dot + 0.2, 0, 1)
    rgb = lay(rgb, c, np.zeros(3)); a = c + a * (1 - c)
    # the face, flat, a faint sheen across it
    t = ((xx - xx[m > 0.5].min()) + (yy - yy[m > 0.5].min())) / (TW * 0.6)
    face = FACE * (1 + 0.14 * (0.5 - t))[..., None]
    # pressed round the vine: a half cylinder's light across the strap
    d = (xx - MID) / (VINE + 0.3)
    bump = np.where(np.abs(d) < 1, d, 0)
    face = face * (1 - 0.35 * np.clip(bump, 0, 1) ** 1.5)[..., None]
    face = lay(face, np.clip(-bump, 0, 1) ** 2 * 0.35 * (np.abs(d) < 1), LIGHT)
    rgb = lay(rgb, m, face); a = m + a * (1 - m)
    # its cut edges, a texel: lit toward the light, dark away
    ring = np.clip(m - nd.grey_erosion(m, size=SS + 1), 0, 1)
    rgb = lay(rgb, ring * np.clip(dot, 0, 1) * 0.85, LIGHT)
    rgb = lay(rgb, ring * np.clip(-dot, 0, 1) * 0.7, DARK)
    # the vine coming out from under the strap's square end: its shadow on the vine
    end = (np.abs(yy - Y(TIP)) < 0.9) * (np.abs(xx - MID) < VINE) * (1 - m)
    sh = end * np.clip(1 - np.abs(yy - Y(TIP)) / 0.9, 0, 1) * 0.55
    rgb = lay(rgb, sh, np.zeros(3)); a = sh + a * (1 - sh)
    # a flush pin
    pm = mask([], [(EDGE_X - 7.5, Y(2.6), 0.55)])
    pr = np.clip(pm - nd.grey_erosion(pm, size=SS + 1), 0, 1); pd = outward(pm)
    rgb = lay(rgb, pm, FACE * 0.9)
    rgb = lay(rgb, pr * np.clip(-pd, 0, 1) * 0.8, DARK); rgb = lay(rgb, pr * np.clip(pd, 0, 1) * 0.6, LIGHT)
    pre = (rgb * a[..., None]).reshape(TH * U, SS, TW * U, SS, 3).mean((1, 3))
    al = a.reshape(TH * U, SS, TW * U, SS).mean((1, 3))
    out = np.zeros((TH * U, TW * U, 4))
    out[..., :3] = np.where(al[..., None] > 0, pre / np.maximum(al[..., None], 1e-6), 0)
    out[..., 3] = al * 255
    return out


def main():
    for flip, end in ((False, "Top"), (True, "Bottom")):
        sb.write_tga(os.path.join(sb.CORE_OUT, "Vine-CornerCover%s-T6.tga" % end), draw(flip))
    print("2 textures")


if __name__ == "__main__":
    main()
