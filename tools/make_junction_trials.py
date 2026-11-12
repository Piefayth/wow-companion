"""Junction trials, temporary: directions for where the vine dividers meet,
beside the current one, for the Junctions tab (addon/WowCompanion_Agent/
JunctionTrials.lua) while the player chooses. Goes when one is chosen.

    python tools/make_junction_trials.py   writes addon/WowCompanion_Agent/Art/Try-<direction>-<Big|Small>-1.tga

Each piece is a junction as make_scrollbar_art.py draws them: J units square,
the run down x J/2, the arm leaving right along y J/2, drawn in place so its
light is the frame's. Big: two thick vines meeting. Small: the medium vine
growing into a thick one.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_scrollbar_art as M  # noqa: E402
from make_scrollbar_art import (J, BARK, BUD, Pen, bez, dim, leaf, raised, ribbon, scroll,  # noqa: E402
                                ucanvas, write_tga, WEIGHTS)

OUT = os.path.join(M.ROOT, "addon", "WowCompanion_Agent", "Art")
m = J / 2
FAR = (-12, J + 12)
THICK, MEDIUM = WEIGHTS["Thick"], WEIGHTS[""]


def bevel(hw):
    return 0.5 * hw / 0.55


def run(pen, rhw, rpal):
    raised(pen, [ribbon([(m, FAR[0]), (m, FAR[1])], rhw)], rpal, bevel=bevel(rhw), cast=0.4, grain=False)


def flared_arm(pen, rhw, ahw, apal, flare):
    """The arm, widening as it reaches the run, as a branch flares where it
    grows from a trunk."""
    xs = np.linspace(m, FAR[1], 60)
    d = xs - (m + rhw)
    w = ahw * (1 + (flare - 1) * np.exp(-np.clip(d, 0, None) / 3.0))
    raised(pen, [ribbon(np.stack([xs, np.full_like(xs, m)], 1), w)], apal, bevel=bevel(ahw), cast=0.4, grain=False)


def tendril_path(p0, p1, p2, p3, curl_r, turns):
    return scroll(bez(p0, p1, p2, p3, n=30), curl_r, turns, 0.38)


def thick_wire(path, w0, w1):
    return [ribbon(path, np.linspace(w0, w1, len(path)))]


# --- B. Graft: the small vine grows into the trunk, flaring where it joins,
# one long tendril curling off it and a leaf; two trunks meet the same way,
# balanced, a tendril each side.
def graft(c, big):
    rhw, rpal = THICK
    ahw, apal = THICK if big else MEDIUM
    pen = Pen(c, J)
    flared_arm(pen, rhw, ahw, apal, 2.1 if big else 2.4)
    run(pen, rhw, rpal)
    w = 0.55 + 0.25 * ahw
    sides = (-1, 1) if big else (-1,)
    work, leaves = [], []
    for s in sides:
        x0 = m + rhw + 7.5
        work += thick_wire(tendril_path((x0, m - s * ahw * 0.6), (x0 - 1.0, m - s * (ahw + 5)),
                                        (m + rhw + 2.5, m - s * (ahw + 8)), (m + rhw + 1.2, m - s * (ahw + 12)), 2.2, s * 1.3),
                           w * 1.3, w * 0.7)
    if not big:
        leaves.append(leaf((m + rhw + 4.5, m + ahw * 0.5), (m + rhw + 11, m + ahw + 6.5), 3.2))
    raised(pen, work, dim(apal, 0.95), bevel=0.45, cast=0.45)
    if leaves:
        raised(pen, leaves, dim(BUD, 0.8), bevel=0.45, cast=0.45)


# --- E. Long tendril: one long, slow hairpin of wire in each corner, running
# far out along both vines and turning in a single wide loop, a small curl at
# its far ends; elegant, open, nothing tight. A branch gets one, longer, on
# the upper side only.
def long_tendril(c, big):
    rhw, rpal = THICK
    ahw, apal = THICK if big else MEDIUM
    pen = Pen(c, J)
    run(pen, rhw, rpal)
    flared_arm(pen, rhw, ahw, apal, 1.3)
    w = 0.55 + 0.25 * (rhw + ahw) / 2
    work = []
    reach = 22 if big else 26
    for s in ((-1, 1) if big else (-1,)):
        a = (m + rhw + reach, m - s * ahw)
        b = (m + rhw, m - s * (ahw + reach))
        path = bez(a, (m + rhw + reach * 0.35, m - s * (ahw + 0.5)), (m + rhw + 0.5, m - s * (ahw + reach * 0.35)), b, n=60)
        path = np.vstack([scroll(path[::-1], 1.6, s * 1.2, 0.38)[::-1][:-1], scroll(path, 1.6, -s * 1.2, 0.38)[len(path) - 1:]])
        work += thick_wire(path, w, w)
    raised(pen, work, dim(apal, 0.95), bevel=0.4, cast=0.45)


def current(c, big):
    M.junction(c, THICK, THICK if big else MEDIUM, M.TURNS["TRight"], "Scroll")


TRIALS = {"Current": current, "Graft": graft, "Tendril": long_tendril}


def main():
    for name, draw in TRIALS.items():
        for big in (True, False):
            c = ucanvas(J, J)
            draw(c, big)
            write_tga(os.path.join(OUT, "Try-%s-%s-1.tga" % (name, "Big" if big else "Small")), c.final())
    print(len(TRIALS) * 2, "trials")


if __name__ == "__main__":
    main()
