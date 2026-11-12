"""Crest trial: the junction in the fleur arrow's own language, at its scale.
Temporary, beside make_junction_trials.py.

    python tools/make_crest.py   writes Art/Try-Crest-<Big|Small>-1.tga (C units square),
                                 and Core's Vine-ThickTRight[FromMedium]Crest for the settings page
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_scrollbar_art as M  # noqa: E402
from make_scrollbar_art import BARK, Pen, bez, raised, ribbon, scroll, ucanvas, write_tga, WEIGHTS, dim  # noqa: E402

OUT = os.path.join(M.ROOT, "addon", "WowCompanion_Agent", "Art")
C = 96
m = C / 2
THICK, MEDIUM = WEIGHTS["Thick"], WEIGHTS[""]
WIRE = dim(BARK, 0.92)


def wire(path, w0, w1):
    return ribbon(path, np.linspace(w0, w1, len(path)))


def crest(c, big):
    """The two vines threaded: the arm runs under the trunk (the trunk drawn
    last, its shadow on the arm), so they read as one piece, never a joint laid
    over two lines. A branch's end parts into two tendrils that pass behind the
    trunk and curl on its far side, gripping it. Two trunks: the arm runs on
    through to the left as a stem that forks into the crest, long sweeps along
    the trunk and pincers clasping it."""
    rhw, rpal = THICK
    ahw, apal = THICK if big else MEDIUM
    pen = Pen(c, C)
    e, wl = m + rhw, m - rhw  # the trunk's faces
    work = []
    if big:
        stem = wl - 22  # the fork, on the left
        for s in (-1, 1):
            lead = bez((stem, m), (stem + 2, m + s * 15), (wl - 2.5, m + s * 11), (wl - 1.6, m + s * 27), n=60)
            work.append(wire(scroll(lead, 3.0, s * 0.9, 0.5), ahw * 0.85, ahw * 0.6))
            lead = bez((stem + 9, m + s * ahw * 0.3), (stem + 11, m + s * 8.5), (wl - 3.5, m + s * 9.5), (wl - 0.6, m + s * 5.0), n=40)
            work.append(wire(scroll(lead, 1.9, -s * 0.85, 0.5), ahw * 0.7, ahw * 0.5))
        arm = [ribbon([(stem + 2.5, m), (C + 12, m)], ahw)]  # its end under the fork
    else:
        for s in (-1, 1):
            # leaving the branch well out, passing behind the trunk on a slant
            # away from it, and curling off along the trunk's far side
            lead = bez((e + 18, m + s * ahw * 0.2), (e + 9, m + s * 2), (e + 2, m + s * 6), (wl - 5, m + s * 13), n=60)
            work.append(wire(scroll(lead, 2.4, s * 0.85, 0.5), ahw * 0.95, ahw * 0.75))
        arm = [ribbon([(m, m), (C + 12, m)], ahw)]
    raised(pen, work, WIRE, bevel=0.6, cast=0.5)
    raised(pen, arm, apal, bevel=0.5 * ahw / 0.55, cast=0.4, grain=False)
    raised(pen, [ribbon([(m, -12), (m, C + 12)], rhw)], rpal, bevel=0.5 * rhw / 0.55, cast=0.55, grain=False)


def main():
    for big in (True, False):
        c = ucanvas(C, C)
        crest(c, big)
        img = c.final()
        write_tga(os.path.join(OUT, "Try-Crest-%s-1.tga" % ("Big" if big else "Small")), img)
        # on the settings page too, as Style.VineJoin names it
        write_tga(os.path.join(M.CORE_OUT, "Vine-ThickTRight%sCrest-%d.tga" % ("" if big else "FromMedium", M.VINE_VERSION)), img)


if __name__ == "__main__":
    main()
