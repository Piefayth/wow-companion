"""The covers over the thick spine's ends, where it meets the raised panel's
top and bottom (WC.Style.SpineCovers): a flat gusset over the panel's corner,
its arm along the panel's edge carried on as a strap over the vine, cut square
where the vine comes out, and set over a sleeve that narrows onto the vine
(the player's pick, 2026-11-13, round 12b's G3; the rounds are in
docs/looks.md). The vine's metal exactly, painted by make_scrollbar_art's
raised() as vine() paints the vine. Drawn in place for each end, the light
from the top left on both:

    python tools/make_cover_art.py   writes addon/WowCompanion/Art/Vine-CornerCover<Top|Bottom>.tga

48 x 16 units, 4 texels each; the spine's middle at x 24, the panel's edge
at x 22.5 and at the texture's top (bottom).
"""
import os
import numpy as np
import make_scrollbar_art as sb

U = sb.U
TW, TH = 48, 16
MID, EDGE_X = 24.0, 22.5  # the spine's middle, the panel's edge
VINE, PAL = sb.WEIGHTS["Thick"]  # the spine's half-width and metal
STRAP = MID + VINE + 0.5  # the strap's right edge, past the vine
TIP = 12.0  # where the cover's arm ends down the panel's edge


def gusset():
    sweep = sb.bez((EDGE_X - 3.0, TIP), (EDGE_X - 3.2, TIP * 0.5), (EDGE_X - 5.6, 2), (EDGE_X - 10, 0))
    return [(EDGE_X - 10, 0), (STRAP, 0), (STRAP, TIP)] + [tuple(p) for p in sweep]


def sleeve():
    """The ferrule the strap's end is set over, as wide as the vine and the
    strap's right edge allow (the strap is not centred on the vine: its right
    edge is the vine's), narrowing onto the vine; drawn for the top end."""
    w = STRAP - MID
    side = sb.bez((MID - w, TIP - 1.5), (MID - w, TIP + 1.2), (MID - VINE - 0.3, TIP + 1.8), (MID - VINE - 0.1, TIP + 3.4))
    side = [tuple(p) for p in side]
    return side + [(2 * MID - x, y) for x, y in side[::-1]]


def draw(flip):
    c = sb.ucanvas(TW, TH)
    pen = sb.Pen(c, TH, flip)
    xx = (np.arange(c.W) / c.s - c.pad) / U  # units across
    d = (xx - MID) / 3.0
    swell = np.where(np.abs(d) < 1, 2.4 * np.cos(np.pi / 2 * d), 0)  # the sleeve round across the vine
    swell = np.broadcast_to(swell[None, :], (c.H, c.W))
    sb.raised(pen, [sleeve()], PAL, bevel=0.4, cast=0.45, outline=1.1, lift=swell, grain=False)
    sb.raised(pen, [gusset()], PAL, bevel=0.45, cast=0.3, outline=1.1, grain=False)
    return c.final()


def main():
    for flip, end in ((False, "Top"), (True, "Bottom")):
        sb.write_tga(os.path.join(sb.CORE_OUT, "Vine-CornerCover%s.tga" % end), draw(flip))


if __name__ == "__main__":
    main()
