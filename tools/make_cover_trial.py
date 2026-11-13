"""A trial (the player, 2026-11-13): spine ends round 11, the folded corner
cover laid over the real spine. Round 5 (2ecc90e) drew the eye; round 6
(d4896a6) smaller; round 7 (0563890) flatter and in the vine's colours, but
flat paint: no grain, no wear, its edges drawn by hand, so it read as a
colour beside the vine's metal. Round 8 (a96bcca) painted it with raised()
and its grain, which the vine leaves out: it read tarnished. Here it is the
vine's metal exactly, painted by make_scrollbar_art's raised() as vine()
paints the vine (the thick vine's palette, no grain, worn lit edges, the
dark warm outline, its cast), the strap pressed over the vine as a shallow
ridge in its height. Round 9 (259c200) was "pretty close"; round 10
(d99cde6) varied how it stands up and its D, pressed harder, was liked;
round 11 varies D (LOOKS); round 11b's E with a foot was rejected (one
shape, not a piece); round 12 is E with a connector of its own, each pickable on the Settings page's Trial row. A gusset over
the names panel's corner, its arm along the panel's edge carried on as a
strap over the vine, cut square where the vine comes out. Drawn in place for
each end, the light from the top left on both:

    python tools/make_cover_trial.py   writes addon/WowCompanion/Art/Vine-CornerCover<look><Top|Bottom>-T11.tga

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
# how high the strap stands over the vine (ridge, texels), how far either side
# of the vine's middle the ridge reaches (span, units) and how its shoulders
# round (shape: 2 soft, 1 full and round, 4 tight to the vine). Round 10's D
# (pressed harder) was liked: "set into it rather than translucent"; round 11
# presses it further and varies the pressing.
LOOKS = {
    "D": dict(bevel=0.45, cast=0.3, outline=1.1, ridge=2.2, span=2.2, shape=2),   # round 10's D
    "D2": dict(bevel=0.45, cast=0.3, outline=1.1, ridge=3.2, span=2.2, shape=2),  # pressed harder still
    "D3": dict(bevel=0.45, cast=0.3, outline=1.1, ridge=4.4, span=2.2, shape=2),  # hardest
    "D4": dict(bevel=0.45, cast=0.3, outline=1.1, ridge=3.2, span=1.8, shape=4),  # tight round the vine
    "D5": dict(bevel=0.45, cast=0.3, outline=1.1, ridge=3.2, span=3.0, shape=2),  # a broad swell
    "D6": dict(bevel=0.45, cast=0.3, outline=1.1, ridge=3.2, span=2.2, shape=1),  # a full round ridge
    "D7": dict(bevel=0.25, cast=0.3, outline=1.1, ridge=3.2, span=2.2, shape=2),  # thinner edges
    "D8": dict(bevel=0.45, cast=0.5, outline=1.1, ridge=3.2, span=2.2, shape=2),  # a deeper shadow
}
# the player's other idea, round 12: E (flat) and a connector where the vine
# comes out, a piece of its own (CONNECTORS' kinds), raised above the cover or
# set under it, never one shape with it (round 11's feet were rejected)
FLAT = dict(bevel=0.45, cast=0.3, outline=1.1, ridge=0.0, span=2.2, shape=2)
for key, part in (("F1", "clamp"), ("F2", "collar"), ("F3", "tab"), ("F4", "sleeve"),
                  ("F5", "bands"), ("F6", "bridge")):
    LOOKS[key] = dict(FLAT, part=part)

def gusset():
    sweep = sb.bez((EDGE_X - 3.0, TIP), (EDGE_X - 3.2, TIP * 0.5), (EDGE_X - 5.6, 2), (EDGE_X - 10, 0))
    return [(EDGE_X - 10, 0), (STRAP, 0), (STRAP, TIP)] + [tuple(p) for p in sweep]


def connector(kind):
    """The connector at the top end (the vine leaving downward): its pieces,
    whether it sits over the cover (else under it), and how round it stands
    across the vine (half-width in units, height in texels)."""
    L, R = EDGE_X - 3.0, STRAP  # the strap's end
    vl, vr = MID - VINE, MID + VINE
    box = lambda x0, y0, x1, y1: [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    if kind == "clamp":  # a band wider than the strap, laid across its end and the vine
        return [box(L - 0.8, TIP - 1.6, R + 0.8, TIP + 0.9)], True, (4.2, 1.6)
    if kind == "collar":  # a ring round the vine, seated against the strap's end
        return [box(vl - 1.1, TIP - 0.6, vr + 1.1, TIP + 2.0)], True, (2.8, 2.6)
    if kind == "tab":  # a strip riveted on the strap and lapped down over the vine
        return [box(vl - 0.5, TIP - 3.4, vr + 0.5, TIP + 2.8)], True, (2.2, 2.0)
    if kind == "sleeve":  # a ferrule the strap's end is set over, narrowing to the vine
        side = sb.bez((vl - 1.6, TIP - 1.5), (vl - 1.6, TIP + 1.4), (vl - 0.4, TIP + 2.0), (vl - 0.2, TIP + 3.4))
        return [[tuple(p) for p in side] + [(2 * MID - x, y) for x, y in [tuple(p) for p in side][::-1]]], False, (3.0, 2.4)
    if kind == "bands":  # two thin rings round the vine below the end
        return [box(vl - 0.8, TIP + 0.4, vr + 0.8, TIP + 1.4), box(vl - 0.8, TIP + 2.2, vr + 0.8, TIP + 3.2)], True, (2.4, 2.0)
    if kind == "bridge":  # a bar across the end whose ends turn down round the vine
        return [box(vl - 1.8, TIP - 1.0, vr + 1.8, TIP + 0.6), box(vl - 1.8, TIP - 1.0, vl - 0.6, TIP + 2.8),
                box(vr + 0.6, TIP - 1.0, vr + 1.8, TIP + 2.8)], True, (3.4, 1.4)
    return None


def draw(flip, bevel, cast, outline, ridge, span, shape, part=None):
    c = sb.ucanvas(TW, TH)
    pen = sb.Pen(c, TH, flip)
    xx = (np.arange(c.W) / c.s - c.pad) / U  # units across

    def swell(height, half, power):
        d = (xx - MID) / half
        line = np.where(np.abs(d) < 1, height * np.cos(np.pi / 2 * d) ** power, 0)
        return np.broadcast_to(line[None, :], (c.H, c.W))

    cover = lambda: sb.raised(pen, [gusset()], PAL, bevel=bevel, cast=cast, outline=outline,
                              lift=swell(ridge, span, shape), grain=False)
    if part is None:
        cover()
        return c.final()
    pieces, over, (half, height) = connector(part)
    joint = lambda: sb.raised(pen, pieces, PAL, bevel=0.4, cast=0.45, outline=1.1,
                              lift=swell(height, half, 1), grain=False)
    (cover, joint)[0 if over else 1]()
    (cover, joint)[1 if over else 0]()
    return c.final()


def main():
    for key, look in LOOKS.items():
        for flip, end in ((False, "Top"), (True, "Bottom")):
            sb.write_tga(os.path.join(sb.CORE_OUT, "Vine-CornerCover%s%s-T11.tga" % (key, end)), draw(flip, **look))
    print(2 * len(LOOKS), "textures")


if __name__ == "__main__":
    main()
