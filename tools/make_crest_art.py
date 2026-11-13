"""The conversation list's crest: one ornament on the thick rule, standing on
it at the list's head and hung under it at its foot, the two the same size
(the player, 2026-11-13: both the foot's), each drawn the right way up so
the light stays the frame's. Wire scrollwork in the vine's bark
(make_scrollbar_art's Wire), every wire one weight from root to tip (the
player: the old crest's corners, where the wing left the volute, were blobby).

    python tools/make_crest_art.py      writes addon/WowCompanion_Agent/Art/Crest-Head-<V>.tga, Crest-Foot-<V>.tga
                                        and target/tmp/crest/crest.png (both, 4x, on dark stone)

Each piece is W units wide, the well's whole width, its rule running off both
ends under the walls; H tall, the rule RULE from the ornament's far side. The
game keeps a texture for the session under its path, so a change bumps
VERSION; older files go through artout.
"""
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import artout  # noqa: E402
import make_scrollbar_art as M  # noqa: E402
from make_scrollbar_art import Pen, Wire, WEIGHTS, ucanvas, raised, ribbon, write_tga  # noqa: E402

VERSION = 3
OUT = os.path.join(M.ROOT, "addon", "WowCompanion_Agent", "Art")
TMP = os.path.join(M.ROOT, "target", "tmp", "crest")

W = 130  # the well's width (Window.lua's WELL)
H, RULE = 28, 4  # a piece's height; its rule's centre from the piece's edge on the rule's side
K = 0.8  # the crest's scale
WIRE = 1.35 * K  # every wire's half-width, root to tip
THICK = WEIGHTS["Thick"]  # (half-width, bark)


def mirrored_x(wire, x):
    """The wire mirrored about the line x (points moved, so the light stays the frame's)."""
    w = Wire((0, 0), 0)
    w.pts = [np.array([2 * x - p[0], p[1]]) for p in wire.pts]
    w.hs = [np.pi - h for h in wire.hs]
    w.pitch = getattr(wire, "pitch", np.inf)
    return w


def fillet(x, y, sx, sy, f):
    """The web filling the square corner at (x, y) between a face running
    away along sx and one along sy, rounded to radius f."""
    x, y, f = x - sx * 0.3, y - sy * 0.3, f + 0.3  # sunk into both faces, so no seam shows where they meet
    t = np.radians(np.linspace(0, 90, 16))
    arc = [(x + sx * f * (1 - np.sin(a)), y + sy * f * (1 - np.cos(a))) for a in t]
    return [(x, y)] + arc


def crest(r, down):
    """The ornament on the rule at y r (hung under it when down): an Ionic
    capital in wire. A post rises from the rule into a flat bar, the highest
    thing, which rolls at each end into a volute curling down and in to rest
    on the rule; from each volute's outer side a wing runs out along the rule
    and curls up. Its middle is the post, flat on top: never two scrolls
    meeting in a notch (that reads as a heart)."""
    cx = W / 2

    def P(dx, dy):
        return (cx + dx * K, r - dy * K)
    R, top = 9.5, 21.0
    vol = Wire(P(0, top), 0).volute(P(R + 1.5, top - R), R * K, 270, 1, 1.45, eye=1.2,
                                    out=0.4, inn=0.4)
    i = len(vol.pts) // 4  # the volute's outer side, heading down
    # the wing leaves along the volute (no angle between them), so its root
    # lies in the volute's own wire instead of a wedge beside it
    wing = Wire(vol.pts[i], np.degrees(vol.hs[i])).volute(P(2 * R + 16, 6.5), 5.5 * K, 90, -1, 1.0,
                                                          eye=1.2, out=0.5, inn=0.5)
    y_bar, y_rule = r - (top * K - WIRE), r - THICK[0]
    polys = [ribbon([P(0, 0), P(0, top)], WIRE)]
    for sx in (1, -1):  # the post's webs, under the bar and over the rule
        polys.append(fillet(cx + sx * WIRE, y_bar, sx, 1, 1.4 * K))
        polys.append(fillet(cx + sx * WIRE, y_rule, sx, -1, 1.4 * K))
    wires = [vol, wing]
    if down:  # turned over the rule: points moved, so the light stays the frame's
        wires = [w.mirrored(r) for w in wires]
        polys = [[(x, 2 * r - y) for x, y in p] for p in polys]
    return [q for w in wires for v in (w, mirrored_x(w, cx)) for q in v.pieces(WIRE, WIRE, swell=1.0)] + polys


def piece(down):
    """The thick rule across the whole piece, running off both ends, and the
    crest forged to it as one metal."""
    r = RULE if down else H - RULE
    c = ucanvas(W, H)
    pieces = [ribbon([(-12, r), (W + 12, r)], THICK[0])] + crest(r, down)
    raised(Pen(c, H), pieces, THICK[1], bevel=0.5 * THICK[0] / 0.55, cast=0.4, grain=False)
    return c.final()


def main():
    art = {"Head": piece(False), "Foot": piece(True)}
    artout.clear(OUT, "Crest-*.tga")
    for name, img in art.items():
        write_tga(os.path.join(OUT, "Crest-%s-%d.tga" % (name, VERSION)), img)
    os.makedirs(TMP, exist_ok=True)
    rows = []
    for name in ("Head", "Foot"):
        a = Image.fromarray(np.asarray(art[name]).astype(np.uint8), "RGBA") if not isinstance(art[name], Image.Image) else art[name]
        bg = Image.new("RGBA", a.size, (20, 22, 28, 255))
        bg.alpha_composite(a)
        rows.append(bg.resize((a.width * 2, a.height * 2), Image.NEAREST))
    sheet = Image.new("RGBA", (rows[0].width, sum(r.height for r in rows)))
    y = 0
    for r in rows:
        sheet.paste(r, (0, y))
        y += r.height
    sheet.save(os.path.join(TMP, "crest.png"))


if __name__ == "__main__":
    main()
