"""Drawer trials, temporary: ways the conversation menu's drawer
(ConvMenu.lua) could hook into the Companion window's rim, shown side by side
on a "Drawers" tab (DrawerTrials.lua, the text on top). Goes when the player
has picked one.

    python tools/make_drawer_trials.py   writes addon/WowCompanion_Agent/Art/DrawerTrial-*-<v>.tga
                                         and target/drawer-trials.png (all of them, text mocked)

Round 5 (round 1 d5d8e49, 2 4c49c05, 3 beb6100, 4 5ed179c): the crossing
itself as the settings joint's, a four-filleted star of one metal with one
unbroken ridge of light, the ornament springing from the star. A cell is drawn as the game would draw
the drawer: a base picture (a slice of the window's right side, faded where
it is cut, and the drawer butted against its rim, with the legend's panel)
and, over each place the drawer's top and bottom rims meet the window's rim, a
joint piece (Joint-<n>-Top/Bottom) in which the drawer's rim runs through the
window's as one forged piece, crowned by the settings joint's own scrollwork.
A joint's edges carry exactly the rims under them, so where it ends nothing
shows; its shadow adds only what the base's lacks.

Drawn at 2.7 screen pixels a unit (the window's scale at 4K), a texel a pixel.
The metal is one height field in the rim's bronze (make_frame_art.py's look):
the rim's bar with its raised bead along the outer edge, lit from the top
left; a fork where the window's bead runs on and the drawer's leaves it.
The stones are the window's own (Style.lua's Slate and SlateLight).
"""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage
import artout
from make_frame_art import grid, bead, rim_metal, Layers, fit, octagon_depth, brushed, streaks, BRONZE, LINE, BAND
from make_scrollbar_art import write_tga, Wire

VERSION = 5  # DrawerTrials.lua's
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "addon", "WowCompanion_Agent", "Art")
STONE = os.path.join(ROOT, "addon", "WowCompanion", "Art", "%s-6.tga")
K = 12  # samples a unit
PX = 2.7  # screen px a unit

# a cell, in units (DrawerTrials.lua's): the window's outer right edge at X0,
# its rim RIM wide inside it; the drawer from under the rim (XL) out to XR,
# DT to DB; its rows from ROWS, ROW tall; the legend's panel LEG, smaller
# than round 1's (the player)
CW, CH = 172.0, 180.0
RIM = 6.0
X0 = 16.0
XL = X0 - RIM
XR = 170.0
DT = 46.0
ROWS, ROW = DT + 12.0, 24.0
LEG = (DT + 62.0, DT + 87.0)
DB = LEG[1] + RIM
FADE = 8.0  # the slice's cut edges fade over this
# the joint pieces' boxes (units, whole multiples of 10 so a box is whole pixels)
JOINT_W, JOINT_H = 60.0, 70.0
TOP_BOX = (0.0, 0.0, JOINT_W, JOINT_H)
BOTTOM_BOX = (0.0, CH - JOINT_H, JOINT_W, CH)
TEX = 512  # a base's texture
JTEX = 256  # a joint's

xx, yy = grid(CW, CH, K)
xx, yy = xx.astype(np.float32), yy.astype(np.float32)
W_PX, H_PX = int(round(CW * PX)), int(round(CH * PX))


def edt(mask):
    return ndimage.distance_transform_edt(mask) / K


def closing(mask, r):
    """Concave corners filled with round fillets of radius r (padded, so
    the picture's edge is not taken for metal)."""
    if r <= 0:
        return mask
    p = int(r * K) + 2
    big = np.pad(mask, p)
    grown = edt(~big) <= r
    return (edt(grown) > r)[p:-p, p:-p]


def polys(pieces):
    """Polygons and (x, y, r) circles in units as a mask."""
    im = Image.new("L", (xx.shape[1], xx.shape[0]), 0)
    d = ImageDraw.Draw(im)
    for p in pieces:
        if isinstance(p, tuple):
            x, y, r = p
            d.ellipse([(x - r) * K, (y - r) * K, (x + r) * K, (y + r) * K], fill=255)
        else:
            d.polygon([(x * K, y * K) for x, y in p], fill=255)
    return np.asarray(im) > 127


def rect(x0, y0, x1, y1):
    return (xx >= x0) & (xx < x1) & (yy >= y0) & (yy < y1)


def smoothstep(t):
    t = np.clip(t, 0, 1)
    return t * t * (3 - 2 * t)


def tile(stem, k=1.0):
    """A stone over the whole cell at final pixels, a texel a pixel."""
    src = np.asarray(Image.open(STONE % stem).convert("RGB")).astype(float)
    reps = (H_PX // src.shape[0] + 1, W_PX // src.shape[1] + 1, 1)
    return np.tile(src, reps)[:H_PX, :W_PX] * k


def down(field):
    """A K-resolution field averaged to final pixels."""
    return np.asarray(Image.fromarray(np.asarray(field, np.float32), "F").resize((W_PX, H_PX), Image.BOX))


def near_meetings(r):
    """Within r of either place the drawer's rims meet the window's."""
    return (np.hypot(xx - X0, yy - DT) < r) | (np.hypot(xx - X0, yy - DB) < r)


# --- the outline ----------------------------------------------------------------

def no_bulge(y):
    return np.zeros_like(y)


def box():
    """The drawer's box, its left end under the window, its right corners
    cut at 45 degrees (the frame's chamfer)."""
    return octagon_depth(xx, yy, XL - 30, DT, XR, DB, 4.0) >= 0


class Joint:
    """How a meeting is forged: the outer fillet's radius, the inner one
    (between the window's rim and the drawer's, on the drawer's side), the
    rim's swell, extra metal, ornament (polygons and circles, in place) and
    the meetings where the drawer's rim runs through the window's."""

    def __init__(self, outer, inner, bulge=no_bulge, extra=None, pieces=(), through=(), weld=0.8):
        self.outer, self.inner, self.bulge, self.weld = outer, inner, bulge, weld
        self.extra = extra if extra is not None else np.zeros(xx.shape, bool)
        self.pieces = list(pieces)
        self.through = through


STAR_POINT = 4.0  # the drawer's rim's diamond point inside the window
STAR_FILLET = 1.8  # the crossing's four fillets


def crossings(j):
    """The crossings' middles, where the bars meet."""
    return [(X0 - RIM / 2, (DT if m == "Top" else DB - RIM) + RIM / 2) for m in j.through]


BUTT = Joint(0.0, 0.0)  # the base: the drawer's rims butted against the window's


def metal(j, legend_extra):
    """The metal's mask, its depth from the outer edge, the window rim's
    own depth (its bead runs on through the meeting) and the strip it runs in."""
    win = xx < X0 + j.bulge(yy)
    shape = closing(win | box(), j.outer)
    s_out = edt(shape)
    s_w = X0 + j.bulge(yy) - xx
    strip = win & (xx >= XL)
    m = shape & ((s_out < RIM) | strip) | legend_extra | j.extra
    m = closing(m, 2.0) & ~(near_meetings(14) & (j is BUTT)) | m
    if j.inner > 0:
        m = m | (closing(m, j.inner) & near_meetings(j.inner * 3 + 8))
    for meeting in j.through:
        # the crossing as the settings joint's: one metal, a four-pointed
        # star, a fillet in every corner (the window's side too), the drawer's
        # rim through to a short diamond point inside the window
        top = meeting == "Top"
        y0 = DT if top else DB - RIM
        cy = y0 + RIM / 2
        m = m | rect(XL, y0, X0 + 1, y0 + RIM)
        m = m | polys([[(XL, y0), (XL - STAR_POINT, cy), (XL, y0 + RIM)]])
        near = np.hypot(xx - (X0 - RIM / 2), yy - cy) < STAR_FILLET * 3 + RIM
        m = m | (closing(m, STAR_FILLET) & near)
    if j.pieces:
        orn = polys(j.pieces)
        # fillets only where a wire meets the frame; a volute's own gaps stay open
        m = m | orn | (closing(m | orn, j.weld) & (edt(~m) < j.weld + 0.7))
    return m, s_out, np.where(strip, s_w, np.inf)


def metal_layer(j, legend_extra):
    """The metal and the shadow it casts, premultiplied at final pixels,
    and the shadow's own alpha."""
    m, s_out, s_w = metal(j, legend_extra)
    d = edt(m)
    sh = np.clip(d / 1.1, 0, 1)
    hgt = (1 - (1 - sh) ** 2) * 0.68 + 0.11 * np.clip(d / 2.45, 0, 1)
    # the beads: the outer edge's, round the drawer, the window's own on down
    # through the meeting, and the drawer's on across it where it runs through
    beads = np.maximum.reduce([bead(np.clip((f - 2.0) / 1.25, -1, 1)) for f in (s_out, s_w)])
    # at a crossing the bead is the metal's own ridge (from its depth alone),
    # so the two bars' beads run into one unbroken star of light, as the
    # settings joint's do; blended out to the rims' own beads
    star = bead(np.clip((np.minimum(d, 2.0) - 2.0) / 1.25, -1, 1))
    w = np.zeros(xx.shape, np.float32)
    for cx, cy in crossings(j):
        w = np.maximum(w, smoothstep((14.0 - np.hypot(xx - cx, yy - cy)) / 6.0))
    beads = beads * (1 - w) + star * w
    hgt = ndimage.gaussian_filter(np.where(m, hgt + 0.6 * beads, 0), K * 0.1)
    s = np.clip(np.minimum(s_out, s_w), 0, 59)
    col = rim_metal(hgt, BRONZE, K) * (1 + 0.09 * brushed(s))[..., None]
    col = col + (LINE - col) * (np.clip(1 - d / 0.5, 0, 1) * 0.9)[..., None]
    cast = ndimage.gaussian_filter(ndimage.shift(m.astype(np.float32), (0.8 * K, 0.6 * K), order=0), K * 0.7)
    cast = np.clip(cast, 0, 1) * 0.6 * ~m
    lay = Layers(xx.shape)
    lay.over(np.zeros(3), cast)
    lay.over(col, m.astype(float))
    return fit(lay.pre(), (W_PX, H_PX)), down(cast), down(m)


def fade():
    """The slice of the window faded where it is cut."""
    fx, fy = (np.arange(W_PX) + 0.5) / PX, (np.arange(H_PX) + 0.5) / PX
    f = smoothstep(fy / FADE)[:, None] * smoothstep((CH - fy) / FADE)[:, None] * smoothstep(fx / FADE)[None, :]
    return 1 - down(xx < X0 + 2) * (1 - f)


# --- the legends' panels: each (extra metal, stones, paint, the lit row) ---------

class Legend:
    def __init__(self, name):
        self.name = name
        self.extra = np.zeros(xx.shape, bool)
        self.stones = []
        self.paint = []


def legend_band():
    """The window's title band turned over: a bronze rule across, T-joined
    into both rims, the band's dark leather under it."""
    g = Legend("Band")
    y0 = LEG[0]
    g.extra = rect(XL, y0, XR - 1, y0 + 3.0)
    band = rect(X0, y0 + 3.0, XR - RIM, LEG[1])

    def paint(lay):
        col = BAND * (1 + 0.06 * streaks(yy))[..., None]
        occl = np.exp(-(yy - (y0 + 3.0)) / 1.4) * 0.45
        lay.over(col * (1 - np.clip(occl, 0, 0.8))[..., None], band.astype(float))
    g.paint.append(paint)
    return g


def base(g):
    """The cell under the joints: stones, the legend's panel, the butted
    rims and their shadow."""
    win = xx < X0
    body = box() & ~win
    rgb, a = np.zeros((H_PX, W_PX, 3)), np.zeros((H_PX, W_PX))

    def stone(mask, stem, k):
        nonlocal rgb, a
        cov = down(mask)[..., None]
        rgb = rgb * (1 - cov) + tile(stem, k) * cov
        a = a * (1 - cov[..., 0]) + cov[..., 0]
    stone(win, "Slate", 0.72)
    stone(body, "Slate", 0.72)
    for mask, stem, k in g.stones:
        stone(mask & body, stem, k)
    stone(rect(X0, ROWS, XR - RIM, ROWS + ROW) & body, "SlateLight", 1.0)
    lay = Layers(xx.shape)
    for fn in g.paint:
        fn(lay)
    paint = fit(lay.pre(), (W_PX, H_PX))
    top, _, _ = metal_layer(BUTT, g.extra)
    for layer in (paint, top):
        ta = layer[..., 3:] / 255
        rgb = layer[..., :3] * ta + rgb * (1 - ta)
        a = ta[..., 0] + a * (1 - ta[..., 0])
    a = a * fade()
    return np.clip(np.concatenate([rgb, a[..., None] * 255], -1), 0, 255)


def joints(j, g, base_cast):
    """The two joint pieces over the meetings: the forged metal where it is
    metal, and only the shadow the base lacks elsewhere."""
    layer, cast, cover = metal_layer(j, g.extra)
    al = layer[..., 3] / 255
    col = np.where(al[..., None] > 0, layer[..., :3], 0)
    extra = np.clip((cast - base_cast) / np.maximum(1 - base_cast, 1e-3), 0, 1) * 0.999
    a = cover + (1 - cover) * extra
    rgb = np.where(cover[..., None] > 1e-3, col, 0)
    a = a * fade()
    img = np.clip(np.concatenate([rgb, a[..., None] * 255], -1), 0, 255)
    out = {}
    for name, (x0, y0, x1, y1) in (("Top", TOP_BOX), ("Bottom", BOTTOM_BOX)):
        crop = img[int(round(y0 * PX)):int(round(y1 * PX)), int(round(x0 * PX)):int(round(x1 * PX))]
        out[name] = crop
    return out


# --- round 4: drawn in place (L1, 2026-11-12) -------------------------------------
#
# The settings joint's technique, not its crest: the members are one forged
# metal, the drawer's rims run through the window's (the bead crossing makes the
# diamond the player likes), and the ornament grows out of the meeting: its
# wires leave the joint tangentially, through real fillets (weld), at the rim's
# own weight, never laid on top of a rim on little feet. Drawn in the drawer's
# own coordinates: x right from the window's outer edge X0, y down; the space
# for ornament is above the drawer (and mirrored below), outside the window.
# Each design is the top joint's wires; the bottom joint is the same mirrored
# about the drawer's middle (points moved, so the light stays top left).

def flip(pieces):
    """Mirrored about the drawer's middle, for the bottom joint."""
    out = []
    for p in pieces:
        if isinstance(p, tuple):
            out.append((p[0], DT + DB - p[1], p[2]))
        else:
            out.append([(x, DT + DB - y) for x, y in p])
    return out


def both(pieces):
    return list(pieces) + flip(pieces)


def wires(*ws):
    """(wire, root half-width, tip half-width) as metal."""
    # a tip as heavy as the volute's last turn leaves room for, its eye open
    return [q for w, w0, w1 in ws for q in w.pieces(w0, min(w1, (getattr(w, "pitch", 99) - 1.0) / 2))]


BOTH = ("Top", "Bottom")  # the meetings where the drawer's rim runs through


# The ornament springs from the crossing's middle, out of the star's corner
# into the free quadrant (above the drawer, outside the window), as the
# settings joint's stems leave its crossing.
CX, CY = X0 - RIM / 2, DT + RIM / 2  # the top crossing's middle
ROOT_HEADING = -45  # heading out of the star's corner, up and away


def sprig():
    """One stem out of the corner into a big two-turn volute."""
    stem = Wire((CX, CY), ROOT_HEADING).volute((X0 + 20, 22), 9.0, 180, 1, 2.0, eye=2.2, out=0.5, inn=0.45)
    return wires((stem, 1.6, 0.85))


def cascade():
    """The settings Cascade from the corner: the stem sweeps into a big
    volute, two satellites budding off its sweep and turning the other way."""
    stem = Wire((CX, CY), ROOT_HEADING).volute((X0 + 24, 20), 9.0, 180, 1, 2.0, eye=2.2, out=0.45, inn=0.4)
    a = stem.fork(0.16, 35).volute((X0 + 17, 35), 5.6, 0, -1, 1.0, eye=1.9, out=0.5, inn=0.5)
    b = stem.fork(0.30, -55).volute((X0 + 7, 13), 5.6, 0, -1, 1.0, eye=1.9, out=0.5, inn=0.5)
    return wires((stem, 1.6, 0.85), (a, 1.4, 0.9), (b, 1.4, 0.9))


def fork_pair():
    """Two stems out of the corner, one up the window's rim and one along the
    drawer's, each into its own volute curling toward the other."""
    up = Wire((CX, CY), -70).volute((X0 + 9, 12), 7.0, 180, 1, 1.5, eye=2.0, out=0.5, inn=0.45)
    along = Wire((CX, CY), -20).volute((X0 + 30, 30), 8.0, 0, -1, 1.0, eye=2.6, out=0.5, inn=0.45)
    return wires((up, 1.6, 0.9), (along, 1.6, 0.9))


def lyre():
    """A stem out of the corner rising to a volute, a long satellite off its
    root running out over the drawer and curling under: an S lying in the corner."""
    stem = Wire((CX, CY), ROOT_HEADING).volute((X0 + 14, 14), 7.5, 180, 1, 1.75, eye=2.1, out=0.5, inn=0.45)
    s2 = stem.fork(0.12, 40).volute((X0 + 34, 30), 6.0, 90, -1, 1.25, eye=2.0, out=0.55, inn=0.5)
    return wires((stem, 1.6, 0.9), (s2, 1.5, 0.9))


def triple():
    """Two volutes off one stem from the corner, the second smaller and of the
    other hand (the Triskele's rhythm)."""
    stem = Wire((CX, CY), ROOT_HEADING).volute((X0 + 12, 18), 7.0, 180, 1, 1.5, eye=2.0, out=0.5, inn=0.45)
    b = stem.fork(0.25, -10).volute((X0 + 28, 22), 6.0, 0, -1, 1.25, eye=1.9, out=0.5, inn=0.5)
    return wires((stem, 1.6, 0.9), (b, 1.4, 0.9))


def designs():
    band = legend_band()
    weld = dict(through=BOTH, weld=0.9)
    return [
        (1, "The star alone: the crossing forged, no ornament", Joint(2.0, 1.8, **weld), band),
        (2, "Sprig: one stem from the star into a big volute", Joint(2.0, 1.8, pieces=both(sprig()), **weld), band),
        (3, "Cascade from the star, two satellites", Joint(2.0, 1.8, pieces=both(cascade()), **weld), band),
        (4, "Fork: up the rim and along the drawer", Joint(2.0, 1.8, pieces=both(fork_pair()), **weld), band),
        (5, "Lyre: a volute and a long S over the drawer", Joint(2.0, 1.8, pieces=both(lyre()), **weld), band),
        (6, "Pair: two graded volutes off one stem", Joint(2.0, 1.8, pieces=both(triple()), **weld), band),
    ]


# --- the sheet --------------------------------------------------------------------

def mock(cell):
    """A cell with the game's text, roughly (Arial for Friz Quadrata)."""
    im = Image.fromarray(cell.astype(np.uint8), "RGBA")
    back = Image.new("RGBA", im.size, (40, 44, 40, 255))
    back.alpha_composite(im)
    d = ImageDraw.Draw(back)
    font = ImageFont.truetype("arial.ttf", int(12 * PX))
    for i, (t, lit) in enumerate((("Clear chat", True), ("Start over", False))):
        d.text(((X0 + 16) * PX, (ROWS + ROW * i + ROW / 2) * PX), t, font=font, anchor="lm",
               fill=(250, 235, 199) if lit else (199, 176, 135))
    d.text(((XR - RIM - 8) * PX, ((LEG[0] + 3 + LEG[1]) / 2 + 1) * PX), "X Select    O Back", font=font, anchor="rm",
           fill=(230, 230, 230))
    return back


def put(tex_size, img):
    tex = np.zeros((tex_size, tex_size, 4))
    tex[:img.shape[0], :img.shape[1]] = img
    return tex


def main():
    # earlier rounds go (committed); this round's files are rewritten in place
    artout.clear(OUT, *("DrawerTrial-*-%d.tga" % v for v in range(1, VERSION)))
    bases, casts, cells = {}, {}, []
    for n, title, j, g in designs():
        if g.name not in bases:
            bases[g.name] = base(g)
            casts[g.name] = metal_layer(BUTT, g.extra)[1]
            write_tga(os.path.join(OUT, "DrawerTrial-%s-%d.tga" % (g.name, VERSION)), put(TEX, bases[g.name]))
        pieces = joints(j, g, casts[g.name])
        cell = Image.fromarray(bases[g.name].astype(np.uint8), "RGBA")
        for name, (x0, y0, _, _) in (("Top", TOP_BOX), ("Bottom", BOTTOM_BOX)):
            write_tga(os.path.join(OUT, "DrawerTrial-Joint-%d-%s-%d.tga" % (n, name, VERSION)), put(JTEX, pieces[name]))
            cell.alpha_composite(Image.fromarray(pieces[name].astype(np.uint8), "RGBA"),
                                 (int(round(x0 * PX)), int(round(y0 * PX))))
        cells.append(mock(np.asarray(cell).astype(float)))
        print(n, title)
    w, h = cells[0].size
    sheet = Image.new("RGB", (w * 4 + 50, h * 2 + 30), (30, 30, 30))
    for i, c in enumerate(cells):
        sheet.paste(c.convert("RGB"), (10 + (i % 4) * (w + 10), 10 + (i // 4) * (h + 10)))
    path = os.path.join(ROOT, "target", "drawer-trials.png")
    sheet.save(path)
    print(path)


if __name__ == "__main__":
    main()
