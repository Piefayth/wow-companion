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
    rhw, rpal = THICK
    ahw, apal = THICK if big else MEDIUM
    pen = Pen(c, C)
    e = m + rhw  # the trunk's right face
    work = []
    w = 1.15 if big else 1.0
    for s in (-1, 1):
        # the pincers: from the arm, out and back to clasp the trunk, curling in
        k = 1.0 if big else 1.45  # a branch's pincers are its whole ornament, so larger
        lead = bez((e + 13 * k, m + s * ahw * 0.4), (e + 11 * k, m + s * 8.5 * k), (e + 3.5 * k, m + s * 9.5 * k),
                   (e + 1.0, m + s * 5.5 * k), n=40)
        work.append(wire(scroll(lead, 1.9 * k, s * 0.85, 0.5), w, w * 0.75))
        if big:
            # the long sweep: from further out, along the trunk, an open volute at its end
            lead = bez((e + 24, m + s * ahw * 0.4), (e + 22, m + s * 15), (e + 2.5, m + s * 11), (e + 1.6, m + s * 27), n=60)
            work.append(wire(scroll(lead, 3.0, -s * 0.9, 0.5), w, w * 0.75))
            # through the trunk: the arm comes out the far side as a short fleur
            lead = bez((m - rhw, m), (m - rhw - 5, m + s * 0.3), (m - rhw - 7, m + s * 4), (m - rhw - 4.5, m + s * 7.5), n=30)
            work.append(wire(scroll(lead, 1.8, s * 0.85, 0.5), w, w * 0.75))
    stub = [ribbon([(m - rhw - 6, m), (m, m)], ahw)] if big else []
    raised(pen, work, WIRE, bevel=0.6, cast=0.5)
    raised(pen, [ribbon([(m, -12), (m, C + 12)], rhw)], rpal, bevel=0.5 * rhw / 0.55, cast=0.4, grain=False)
    raised(pen, [ribbon([(m, m), (C + 12, m)], ahw)] + stub, apal, bevel=0.5 * ahw / 0.55, cast=0.4, grain=False)


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
