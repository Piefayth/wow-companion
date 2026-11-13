"""A trial (the player, 2026-11-13): the settings page's thick spine where it
meets the raised panel's top and bottom edges, in the vine's own metal
(make_scrollbar_art.py), each end drawn for the top (y 0 the panel's edge) and
flipped for the bottom, the light still from the top left:

    Bend        the spine bends left over the panel's corner and runs along its edge
    BendVolute  the same, its end curling down onto the panel in a volute
    Foot        a forged T: a short arm each way along the edge, welded by fillets
    FootVolute  the T's arms each curling down in a volute
    Fleur       the scroll bar's fleur point on the spine's end

    python tools/make_spine_trials.py   writes addon/WowCompanion/Art/Vine-ThickEnd<Kind><Top|Bottom>-T1.tga

Removed with the trial once one is picked (docs/looks.md).
"""
import os
import numpy as np
import artout
import make_scrollbar_art as sb

R = sb.WEIGHTS["Thick"][0]
PAL = sb.WEIGHTS["Thick"][1]
E = 1.2 + R  # the line's centre from the panel's edge, as a round end's is
H = 32
WIDE = {"Bend": 48, "BendVolute": 48, "Foot": 48, "FootVolute": 48, "Fleur": 32}


def line(pts, hw0, hw1=None):
    """A wire through pts, hw0 wide tapering to hw1, its end round."""
    p = np.asarray(pts, float)
    hw1 = hw0 if hw1 is None else hw1
    hw = np.linspace(hw0, hw1, len(p))
    return [sb.ribbon(p, hw), (p[-1][0], p[-1][1], hw1), (p[0][0], p[0][1], hw0)]


def bend(m, volute):
    w = sb.Wire((m, 44), -90).to((m, E + 6), -90).to((m - 6, E), 180, out=0.55, inn=0.55)
    if volute:
        w.to((m - 13, E), 180).volute((m - 13, E + 5), 5, -90, -1, 1.1, eye=2.4, grow=1.25)
        return line(w.pts, R, 1.05)
    w.to((m - 17, E), 180)
    return line(w.pts, R)


def tee(m, reach, fillet=3.0):
    """The run up to the edge and an arm each way along it, `reach` from the
    middle, welded under the arm by round fillets."""
    xs = np.linspace(m - reach, m + reach, 400)
    d = np.clip(np.abs(xs - m) - R, 0, None)
    d = np.minimum(d, fillet)
    under = R + fillet - np.sqrt(np.maximum(fillet ** 2 - (fillet - d) ** 2, 0))
    under = np.where(np.abs(xs - m) <= R, 44, under)  # the run itself
    top = [(x, E - R) for x in xs]
    bottom = [(x, E + min(u, 44)) for x, u in zip(xs[::-1], under[::-1])]
    return [top + bottom, (m - reach, E, R), (m + reach, E, R), sb.ribbon([(m, E), (m, 44)], R)]


def foot(m, volute):
    if not volute:
        return tee(m, 11)
    out = tee(m, 6)
    right = sb.Wire((m + 5, E), 0).to((m + 9, E), 0).volute((m + 9, E + 4.6), 4.6, -90, 1, 1.1, eye=2.2, grow=1.25)
    for sgn in (1, -1):
        pts = [(m + sgn * (x - m), y) for x, y in right.pts]
        out += line(pts, R, 1.0)
    return out


def draw(kind, flip):
    w = WIDE[kind]
    c = sb.ucanvas(w, H)
    pen = sb.Pen(c, H, flip)
    m = w / 2
    if kind == "Fleur":
        sb.fleur_cap(c, flip, "Bare")
        pieces = [sb.ribbon([(m, 16.0), (m, 44)], R)]
    elif kind.startswith("Bend"):
        pieces = bend(m, kind.endswith("Volute"))
    else:
        pieces = foot(m, kind.endswith("Volute"))
    sb.raised(pen, pieces, PAL, bevel=0.5 * R / 0.55, cast=0.4, grain=False)
    return c.final()


def main():
    out = sb.CORE_OUT
    artout.clear(out, "Vine-ThickEnd*-T*.tga")
    for kind in WIDE:
        for flip, end in ((False, "Top"), (True, "Bottom")):
            sb.write_tga(os.path.join(out, "Vine-ThickEnd%s%s-T1.tga" % (kind, end)), draw(kind, flip))
    print(len(WIDE) * 2, "textures")


if __name__ == "__main__":
    main()
