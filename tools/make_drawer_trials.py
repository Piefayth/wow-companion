"""Drawer trials, temporary: ways the conversation menu's drawer
(ConvMenu.lua) could hook into the Companion window's rim, shown side by side
on a "Drawers" tab (DrawerTrials.lua, the text on top). Goes when the player
has picked one.

    python tools/make_drawer_trials.py   writes addon/WowCompanion_Agent/Art/DrawerTrial-*-<v>.tga
                                         and target/drawer-trials.png (all of them, text mocked)

Round 2 (round 1, the six concepts, is d5d8e49): the player picked the
scroll brackets and asked for the joins to be seamless, as the settings
page's vine joints are. So a cell is drawn as the game would draw the drawer:
a base picture (a slice of the window's right side, faded where it is cut, and
the drawer butted against its rim, with the legend's panel) and, over each
place the drawer's top and bottom rims meet the window's rim, a joint piece
(Joint-<n>-Top/Bottom) that redraws both rims through the meeting as one
forged metal, rounded fillets inside and out, its ornament grown out of it.
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
from make_frame_art import (grid, bead, rim_metal, Layers, fit, octagon_depth, brushed, streaks, carve,
                            shade, BRONZE, LINE, BAND, BAR_STONE)
from make_scrollbar_art import write_tga, Wire, ribbon

VERSION = 2  # DrawerTrials.lua's
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


def swell(y):
    """The window's rim swelling out a little round each meeting, no collar:
    eased in and out over the joint's reach."""
    return 2.6 * (np.exp(-((y - DT + 4) / 10.0) ** 2) + np.exp(-((y - DB - 4) / 10.0) ** 2))


def box():
    """The drawer's box, its left end under the window, its right corners
    cut at 45 degrees (the frame's chamfer)."""
    return octagon_depth(xx, yy, XL - 30, DT, XR, DB, 4.0) >= 0


class Joint:
    """How a meeting is forged: the outer fillet's radius, the inner one
    (between the window's rim and the drawer's, on the drawer's side), the
    rim's swell, extra metal (braces) and wires (ornament)."""

    def __init__(self, outer, inner, bulge=no_bulge, extra=None, wires=()):
        self.outer, self.inner, self.bulge = outer, inner, bulge
        self.extra = extra if extra is not None else np.zeros(xx.shape, bool)
        self.wires = list(wires)


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
    if j.wires:
        orn = polys([q for w, w0, w1 in j.wires for q in w.pieces(w0, w1)])
        # fillets only where a wire meets the frame; a volute's own gaps stay open
        m = m | orn | (closing(m | orn, 0.8) & (edt(~m) < 1.5))
    return m, s_out, np.where(strip, s_w, np.inf)


def metal_layer(j, legend_extra):
    """The metal and the shadow it casts, premultiplied at final pixels,
    and the shadow's own alpha."""
    m, s_out, s_w = metal(j, legend_extra)
    d = edt(m)
    sh = np.clip(d / 1.1, 0, 1)
    hgt = (1 - (1 - sh) ** 2) * 0.68 + 0.11 * np.clip(d / 2.45, 0, 1)
    # the beads: the outer edge's, round the drawer, and the window's own,
    # on down through the meeting: one leaves the other along the fillet
    beads = np.maximum(bead(np.clip((s_out - 2.0) / 1.25, -1, 1)), bead(np.clip((s_w - 2.0) / 1.25, -1, 1)))
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

def well_d(x0, y0, x1, y1, r=1.2):
    qx = np.maximum(np.minimum(xx - x0, x1 - xx), 0)
    qy = np.maximum(np.minimum(yy - y0, y1 - yy), 0)
    ex, ey = np.maximum(r - qx, 0), np.maximum(r - qy, 0)
    d = np.where((ex > 0) & (ey > 0), r - np.hypot(ex, ey), np.minimum(qx, qy))
    return np.where(rect(x0, y0, x1, y1), d, -1).astype(np.float64)


def paint_carve(lay, d):
    pre = carve(d, K)
    al = pre[..., 3]
    lay.over(np.where(al[..., None] > 0, pre[..., :3] / np.maximum(al, 1e-6)[..., None], 0), al)


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


def legend_carved():
    """A strip carved into the drawer's floor, as the wells are, a darker
    stone at its foot."""
    g = Legend("Carved")
    x0, y0, x1, y1 = X0 + 3, LEG[0] + 1, XR - RIM - 3, LEG[1] - 2
    g.stones.append((rect(x0, y0, x1, y1), "Slate", 0.45))
    g.paint.append(lambda lay: paint_carve(lay, well_d(x0, y0, x1, y1)))
    return g


def legend_sill():
    """A sill of smooth grey stone (the wells' bar's) across the drawer's
    foot, bevelled, casting its shadow."""
    g = Legend("Sill")
    sill = rect(X0, LEG[0] + 1, XR - RIM, LEG[1])

    def paint(lay):
        d = edt(sill)
        t = np.clip(d / 1.6, 0, 1)
        h = ndimage.gaussian_filter((1 - (1 - t) ** 2) * 1.2, K * 0.12)
        col = shade(h, BAR_STONE, K, gloss=0.05, power=12) * 1.05
        col = col + (np.array((8, 8, 10.0)) - col) * (np.clip(1 - d / 0.35, 0, 1) * 0.8)[..., None]
        cast = ndimage.gaussian_filter(ndimage.shift(sill.astype(np.float32), (-0.9 * K, 0), order=0), K * 0.8)
        lay.over(np.zeros(3), np.clip(cast, 0, 1) * 0.5 * ~sill)
        lay.over(col, sill.astype(float))
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


# --- the joints -------------------------------------------------------------------

def both(wires):
    """Each wire and its mirror for the bottom meeting (points moved, so the
    light stays the frame's)."""
    mid = (DT + DB) / 2
    return wires + [(w.mirrored(mid), a, b) for w, a, b in wires]


def bracket(scale=1.0):
    """Round 1's scroll bracket, the one the player liked: a stem down the
    window's rim sweeping out into a volute that rests on the drawer's rim,
    a small volute off its sweep."""
    k = scale
    stem = Wire((X0 - 2.0, DT - 36 * k), 90).volute((X0 + 24.0 * k, DT - 10.6 * k), 9.6 * k, -90, 1, 1.6, eye=2.2,
                                                     out=0.6, inn=0.5)
    near = stem.fork(0.30, 0).volute((X0 + 8.5 * k, DT - 8.5 * k), 5.0 * k, 180, -1, 0.9 if k >= 1 else 0.8,
                                     eye=1.9, out=0.3, inn=0.5)
    return both([(stem, 1.7, 1.15), (near, 1.3 if k >= 1 else 1.2, 0.9 if k >= 1 else 0.8)])


def grown():
    """Grown from the joint: a stem leaves the fillet up the window's rim and
    curls out over the drawer into a volute; a second, smaller, curls back
    under it toward the joint."""
    stem = Wire((X0 + 1.5, DT - 4.0), -80).volute((X0 + 20.0, DT - 21.0), 9.0, 180, 1, 1.5, eye=2.2, out=0.55,
                                                  inn=0.5)
    low = stem.fork(0.22, 30).volute((X0 + 14.0, DT - 6.5), 4.6, -90, 1, 0.8, eye=1.8, out=0.4, inn=0.5)
    return both([(stem, 1.8, 1.15), (low, 1.3, 0.9)])


def great():
    """One great volute: the stem down the rim into a single big scroll
    resting on the drawer, nothing else."""
    stem = Wire((X0 - 2.0, DT - 40), 90).volute((X0 + 27.0, DT - 13.0), 12.4, -90, 1, 1.8, eye=2.4, out=0.6, inn=0.5)
    return both([(stem, 1.9, 1.2)])


def cascade():
    """The settings page's cascade, along the drawer: a stem out of the
    joint along the drawer's rim curling up into a big volute, a satellite
    off its root curling back toward the window's rim."""
    stem = Wire((X0 + 2.0, DT - 1.5), -20).volute((X0 + 31.0, DT - 11.0), 8.4, 90, -1, 1.6, eye=2.2, out=0.5, inn=0.5)
    up = stem.fork(0.16, -55).volute((X0 + 10.0, DT - 16.0), 5.2, 0, -1, 0.9, eye=1.9, out=0.4, inn=0.5)
    return both([(stem, 1.8, 1.15), (up, 1.35, 0.9)])


def braces():
    """Knee braces, plain: a diagonal bar from the window's rim to each of
    the drawer's rims, forged in with fillets."""
    m = np.zeros(xx.shape, bool)
    for sgn, y in ((1, DT), (-1, DB)):
        m |= polys([ribbon([(X0 - 1, y - sgn * 21), (X0 + 21, y + sgn * 1)], 2.3)])
    return m


def options():
    band, carved, sill = legend_band(), legend_carved(), legend_sill()
    return [
        (1, "The bracket, forged: the rims flow through round fillets", Joint(6.0, 4.0, wires=bracket()), band),
        (2, "Grown from the joint: the scroll rises out of the fillet", Joint(6.0, 4.0, wires=grown()), band),
        (3, "One great volute, deep fillets", Joint(9.0, 5.0, wires=great()), band),
        (4, "A collarless swell at the joint, the bracket smaller", Joint(5.0, 4.0, swell, wires=bracket(0.9)), band),
        (5, "The cascade, along the drawer's rim", Joint(6.0, 4.0, wires=cascade()), band),
        (6, "Plain: the forged joint alone, wide fillets", Joint(10.0, 6.0), band),
        (7, "Round 1's sweep, forged; a carved strip", Joint(16.0, 6.0), carved),
        (8, "Round 1's knee braces, forged; a grey sill", Joint(2.0, 2.5, extra=braces()), sill),
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
    for n, title, j, g in options():
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
