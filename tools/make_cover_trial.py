"""A trial (the player, 2026-11-13): spine ends round 8, the folded corner
cover laid over the real spine. Round 5 (2ecc90e) drew the eye; round 6
(d4896a6) smaller; round 7 (0563890) flatter and in the vine's colours, but
flat paint: no grain, no wear, its edges drawn by hand, so it read as a
colour beside the vine's metal. Here it is the vine's own metal, painted by
make_scrollbar_art's raised() as the vine and its joints are (the thick
vine's palette, grain, worn lit edges, the dark warm outline, its cast), the
strap pressed over the vine as a shallow ridge in its height. A gusset over
the names panel's corner, its arm along the panel's edge carried on as a
strap over the vine, cut square where the vine comes out. Drawn in place for
each end, the light from the top left on both:

    python tools/make_cover_trial.py   writes addon/WowCompanion/Art/Vine-CornerCover<Top|Bottom>-T8.tga

48 x 16 units, 4 texels each; the spine's middle at x 24, the panel's edge
at x 22.5 and at the texture's top (bottom). Removed with the trial once one
is picked (docs/looks.md).
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
RIDGE = 1.0  # how high the strap stands over the vine, in texels


def gusset():
    sweep = sb.bez((EDGE_X - 3.0, TIP), (EDGE_X - 3.2, TIP * 0.5), (EDGE_X - 5.6, 2), (EDGE_X - 10, 0))
    return [(EDGE_X - 10, 0), (STRAP, 0), (STRAP, TIP)] + [tuple(p) for p in sweep]


def draw(flip):
    c = sb.ucanvas(TW, TH)
    pen = sb.Pen(c, TH, flip)
    xx = (np.arange(c.W) / c.s - c.pad) / U  # units across
    d = (xx - MID) / (VINE + 0.6)
    ridge = np.where(np.abs(d) < 1, RIDGE * np.cos(np.pi / 2 * d) ** 2, 0)
    lift = np.broadcast_to(ridge[None, :], (c.H, c.W))
    sb.raised(pen, [gusset()], PAL, bevel=0.45, cast=0.3, lift=lift)
    return c.final()


def main():
    for flip, end in ((False, "Top"), (True, "Bottom")):
        sb.write_tga(os.path.join(sb.CORE_OUT, "Vine-CornerCover%s-T8.tga" % end), draw(flip))
    print("2 textures")


if __name__ == "__main__":
    main()
