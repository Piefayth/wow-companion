"""A trial (the player, 2026-11-13): the settings page's thick spine where it
meets the raised panel's top and bottom edges. Round 2: a bronze corner
fitting held tight on the panel's corner (as the Corners button of buttons
round 7), the spine feeding into it, in the vine's own metal
(make_scrollbar_art.py); each drawn for the top (y 0 the panel's edge, the
panel left of x m - 1.5, the seam's middle m) and flipped for the bottom, the
light still from the top left:

    Plate       an L plate on the corner
    Rounded     the same, its corners rounded
    Strap       its arms ending in points, as a strap hinge's
    Gusset      a triangle filling the corner
    PlateScroll the plate, its arm along the edge curling into a volute
    Clamp       the plate wrapped over the panel's edges, a lip down each

    python tools/make_spine_trials.py   writes addon/WowCompanion/Art/Vine-ThickEnd<Kind><Top|Bottom>-T2.tga

Round 1 (bends, Ts, a fleur: none looked joined to the panel) is in 2ad8970.
Removed with the trial once one is picked (docs/looks.md).
"""
import os
import numpy as np
import artout
import make_scrollbar_art as sb

R = sb.WEIGHTS["Thick"][0]
PAL = sb.WEIGHTS["Thick"][1]
H = 32
WIDE = {k: 48 for k in ("Plate", "Rounded", "Strap", "Gusset", "PlateScroll", "Clamp")}
ROUNDN = 2
A = 2.6  # the fitting's arm, half its width
LH, LV = 16, 12  # its arm along the top edge and down the spine, from the corner
OFF = 2  # the panel's edge this far into the piece, room for what holds it (SettingsPage.lua's END_OFF)


def rounded(pts, r, n=8):
    """A polygon with each corner rounded by r."""
    out = []
    P = [np.array(p, float) for p in pts]
    for i, p in enumerate(P):
        a, b = P[i - 1], P[(i + 1) % len(P)]
        u, v = (a - p) / np.linalg.norm(a - p), (b - p) / np.linalg.norm(b - p)
        p0, p1 = p + u * r, p + v * r
        for t in np.linspace(0, 1, n):
            out.append(tuple((1 - t) ** 2 * p0 + 2 * (1 - t) * t * p + t ** 2 * p1))
    return out


def line(pts, hw0, hw1):
    """A wire through pts, hw0 wide tapering to hw1, its ends round."""
    p = np.asarray(pts, float)
    hw = np.linspace(hw0, hw1, len(p))
    return [sb.ribbon(p, hw), (p[-1][0], p[-1][1], hw1), (p[0][0], p[0][1], hw0)]


def feed(m, y0, half):
    """The spine from y0 down, flaring into the fitting's edge at y0 by
    round fillets no wider than the fitting's arm."""
    f = 3.0
    ys = np.linspace(y0 - 0.5, 44, 300)
    d = np.clip(ys - y0, 0, f)
    hw = np.minimum(R + f - np.sqrt(np.maximum(f * f - (f - d) ** 2, 0)), half)
    return [[(m - w, y) for w, y in zip(hw, ys)] + [(m + w, y) for w, y in zip(hw[::-1], ys[::-1])]]


def fitting(kind, m):
    xr, yt = m + A, OFF - 0.6  # the outer corner: just past the panel's edges, holding them
    xl, yb = xr - LH, yt + LV
    inner = (xr - 2 * A, yt + 2 * A)
    plate = [(xl, yt), (xr, yt), (xr, yb), (inner[0], yb), inner, (xl, inner[1])]
    if kind == "Plate":
        return [plate] + feed(m, yb, A)
    if kind == "Rounded":
        return [rounded(plate, 1.4)] + feed(m, yb, A)
    if kind == "Strap":
        k = 2 * A
        pts = [(xl - k, yt + A), (xl, yt), (xr, yt), (xr, yb), (m, yb + k), (inner[0], yb), inner, (xl, inner[1])]
        return [pts] + feed(m, yb + k - 1.2, 1.2)
    if kind == "Gusset":
        g = LH * 0.85
        tri = rounded([(xr - g, yt), (xr, yt), (xr, yt + g)], 1.0)
        return [tri] + feed(m, yt + g - 2 * A, A)
    if kind == "PlateScroll":
        w = Wire((xl + 1.0, yt + A), 180).volute((xl - 4.0, yt + A + 4.2), 4.2, -90, -1, 1.0, eye=1.8, grow=1.25)
        return [plate] + feed(m, yb, A) + line(w.pts, A * 0.75, 1.05)
    if kind == "Clamp":  # the lips, a unit and a half past each edge, lie lower
        return [plate] + feed(m, yb, A)


def draw(kind, flip):
    w = WIDE[kind]
    c = sb.ucanvas(w, H)
    pen = sb.Pen(c, H, flip)
    m = w / 2
    if kind == "Clamp":
        xr, yt = m + A, OFF - 0.6
        lip = [[(xr - LH - 0.2, yt - 1.4), (xr + 1.4, yt - 1.4), (xr + 1.4, yt + LV + 0.2), (xr, yt + LV + 0.2), (xr, yt), (xr - LH - 0.2, yt)]]
        sb.raised(pen, lip, sb.dim(PAL, 0.55), bevel=0.4, cast=0.6, grain=False)
    sb.raised(pen, fitting(kind, m), PAL, bevel=0.5 * R / 0.55 * 1.3, cast=0.5, grain=False)
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
