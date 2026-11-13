"""A trial (the player, 2026-11-13): spine ends round 10, the folded corner
cover laid over the real spine. Round 5 (2ecc90e) drew the eye; round 6
(d4896a6) smaller; round 7 (0563890) flatter and in the vine's colours, but
flat paint: no grain, no wear, its edges drawn by hand, so it read as a
colour beside the vine's metal. Round 8 (a96bcca) painted it with raised()
and its grain, which the vine leaves out: it read tarnished. Here it is the
vine's metal exactly, painted by make_scrollbar_art's raised() as vine()
paints the vine (the thick vine's palette, no grain, worn lit edges, the
dark warm outline, its cast), the strap pressed over the vine as a shallow
ridge in its height. Round 9 (259c200) was "pretty close"; round 10 varies
how it stands up (LOOKS: its bevel, cast shadow, outline and ridge), each
pickable on the Settings page's Trial row. A gusset over
the names panel's corner, its arm along the panel's edge carried on as a
strap over the vine, cut square where the vine comes out. Drawn in place for
each end, the light from the top left on both:

    python tools/make_cover_trial.py   writes addon/WowCompanion/Art/Vine-CornerCover<look><Top|Bottom>-T10.tga

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
# each look: the edge's bevel (units), its cast shadow, its outline (units),
# how high the strap stands over the vine (texels); A is round 9
LOOKS = {
    "A": dict(bevel=0.45, cast=0.3, outline=1.1, ridge=1.0),   # round 9, as was
    "B": dict(bevel=0.25, cast=0.0, outline=1.1, ridge=1.0),   # a thin sheet: a hairline bevel, no shadow
    "C": dict(bevel=0.9, cast=0.3, outline=1.1, ridge=1.0),    # softer, rounder edges
    "D": dict(bevel=0.45, cast=0.3, outline=1.1, ridge=2.2),   # pressed harder over the vine
    "E": dict(bevel=0.45, cast=0.3, outline=1.1, ridge=0.0),   # flat across the vine
    "F": dict(bevel=0.45, cast=0.55, outline=1.1, ridge=1.0),  # standing higher: a deeper shadow
    "G": dict(bevel=0.45, cast=0.3, outline=0.5, ridge=1.0),   # a finer outline
    "H": dict(bevel=0.3, cast=0.0, outline=0.0, ridge=0.6),    # flush, no outline nor shadow
}


def gusset():
    sweep = sb.bez((EDGE_X - 3.0, TIP), (EDGE_X - 3.2, TIP * 0.5), (EDGE_X - 5.6, 2), (EDGE_X - 10, 0))
    return [(EDGE_X - 10, 0), (STRAP, 0), (STRAP, TIP)] + [tuple(p) for p in sweep]


def draw(flip, bevel, cast, outline, ridge):
    c = sb.ucanvas(TW, TH)
    pen = sb.Pen(c, TH, flip)
    xx = (np.arange(c.W) / c.s - c.pad) / U  # units across
    d = (xx - MID) / (VINE + 0.6)
    lift = np.where(np.abs(d) < 1, ridge * np.cos(np.pi / 2 * d) ** 2, 0)
    lift = np.broadcast_to(lift[None, :], (c.H, c.W))
    sb.raised(pen, [gusset()], PAL, bevel=bevel, cast=cast, outline=outline, lift=lift, grain=False)
    return c.final()


def main():
    for key, look in LOOKS.items():
        for flip, end in ((False, "Top"), (True, "Bottom")):
            sb.write_tga(os.path.join(sb.CORE_OUT, "Vine-CornerCover%s%s-T10.tga" % (key, end)), draw(flip, **look))
    print(2 * len(LOOKS), "textures")


if __name__ == "__main__":
    main()
