"""A trial (the player, 2026-11-13): the settings page's thick spine where it
meets the raised panel's top and bottom edges. Round 3: a corner fitting of
the spine's own weight and metal (make_scrollbar_art.py), the spine turning
square into an arm along the panel's edge, the whole kept inside the panel
(nothing over its edges into the border; round 2's plates spilled over and
were too thick). Each drawn for the top (y OFF the panel's edge, the panel
left of x m - 1.5, the seam's middle m) and flipped for the bottom, the light
still from the top left:

    Square      a square corner, the arm cut square
    Point       its arm ending in a point
    Scroll      its arm ending in a volute
    Heavier     a little heavier than the spine, square
    Deeper      square, set further inside the panel
    Brace       square, a brace across its inside corner

    python tools/make_spine_trials.py   writes addon/WowCompanion/Art/Vine-ThickEnd<Kind><Top|Bottom>-T3.tga

Round 1 (bends, Ts, a fleur) is in 2ad8970, round 2 (plates) in f966f39.
Removed with the trial once one is picked (docs/looks.md).
"""
import os
import numpy as np
import artout
import make_scrollbar_art as sb

R = sb.WEIGHTS["Thick"][0]
PAL = sb.WEIGHTS["Thick"][1]
H = 32
KINDS = ("Square", "Point", "Scroll", "Heavier", "Deeper", "Brace")
WIDE = {k: 48 for k in KINDS}
ROUNDN = 3
LH = 15  # the arm along the edge, from the spine's middle
OFF = 2  # the panel's edge this far into the piece (SettingsPage.lua's END_OFF)
INSET = 0.9  # the fitting's outer edge inside the panel's


def line(pts, hw0, hw1):
    """A wire through pts, hw0 wide tapering to hw1, its ends round."""
    p = np.asarray(pts, float)
    hw = np.linspace(hw0, hw1, len(p))
    return [sb.ribbon(p, hw), (p[-1][0], p[-1][1], hw1), (p[0][0], p[0][1], hw0)]


def fitting(kind, m):
    w = R * (1.25 if kind == "Heavier" else 1.0)
    yt = OFF + INSET + (1.5 if kind == "Deeper" else 0)
    xr, xl = m + w, m - LH
    yi = yt + 2 * w  # the arm's inner edge
    L = [(xl, yt), (xr, yt), (xr, 44), (m - w, 44), (m - w, yi), (xl, yi)]
    if kind == "Point":
        L = [(xl - 2.6, yt + w), (xl, yt), (xr, yt), (xr, 44), (m - w, 44), (m - w, yi), (xl, yi)]
    out = [L]
    if kind == "Scroll":
        wire = Wire((xl + 0.5, yt + w), 180).volute((xl - 3.4, yt + w + 3.4), 3.4, -90, -1, 1.0, eye=1.5, grow=1.2)
        out += line(wire.pts, w, 1.0)
    if kind == "Brace":
        k = 5.0
        out.append([(m - w + 0.2, yi - 0.2), (m - w - k, yi - 0.2), (m - w + 0.2, yi + k)])
    return out, w


def draw(kind, flip):
    c = sb.ucanvas(WIDE[kind], H)
    pen = sb.Pen(c, H, flip)
    pieces, w = fitting(kind, WIDE[kind] / 2)
    sb.raised(pen, pieces, PAL, bevel=0.5 * w / 0.55, cast=0.4, grain=False)
    return c.final()


Wire = sb.Wire


def main():
    out = sb.CORE_OUT
    artout.clear(out, "Vine-ThickEnd*-T*.tga")
    for kind in WIDE:
        for flip, end in ((False, "Top"), (True, "Bottom")):
            sb.write_tga(os.path.join(out, "Vine-ThickEnd%s%s-T%d.tga" % (kind, end, ROUNDN)), draw(kind, flip))
    print(len(WIDE) * 2, "textures")


if __name__ == "__main__":
    main()
