"""Drawer trials, temporary: six ways the conversation menu's drawer
(ConvMenu.lua) could hook into the Companion window's rim, each with its own
panel for the legend, drawn whole as one picture a cell (DrawerTrials.lua
shows them side by side on a "Drawers" tab, the text on top). Goes when the
player has picked one.

    python tools/make_drawer_trials.py   writes addon/WowCompanion_Agent/Art/DrawerTrial-<n>-<v>.tga
                                         and target/drawer-trials.png (all six, text mocked)

Each cell is a slice of the window's right side (its panel and rim, faded
where the slice is cut) with the drawer coming out of it, at the drawer's
true size, drawn at 2.7 screen pixels a unit (the window's scale at 4K) so a
texel is a pixel. The metal is one height field in the rim's bronze
(make_frame_art.py's look): the rim's bar with its raised bead along the
outer edge, the drawer's rims, and each option's joins and ornament, forged
as one piece (concave corners closed with round fillets), lit from the top
left. The stones are the window's own (Style.lua's Slate and SlateLight),
tiled a texel a pixel.
"""
import glob
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage
from make_frame_art import (grid, bead, rim_metal, Layers, fit, octagon_depth, brushed, streaks, carve,
                            shade, BRONZE, LINE, BAND, BAR_STONE)
from make_scrollbar_art import write_tga, Wire, ribbon

VERSION = 1  # DrawerTrials.lua's
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "addon", "WowCompanion_Agent", "Art")
STONE = os.path.join(ROOT, "addon", "WowCompanion", "Art", "%s-6.tga")
K = 12  # samples a unit
PX = 2.7  # screen px a unit
TEX = 512

# a cell, in units (DrawerTrials.lua's): the window's outer right edge at X0,
# its rim RIM wide inside it; the drawer from under the rim (XL) out to XR,
# DT to DB; its rows from ROWS, ROW tall; the legend's panel LEG
CW, CH = 186.0, 188.0
RIM = 6.0
X0 = 16.0
XL = X0 - RIM
XR = 170.0
DT = 46.0
DB = DT + 104.0
ROWS, ROW = DT + 12.0, 24.0
LEG = (DT + 64.0, DB - RIM)
FADE = 8.0  # the slice's cut edges fade over this

xx, yy = grid(CW, CH, K)
xx, yy = xx.astype(np.float32), yy.astype(np.float32)


def edt(mask):
    return ndimage.distance_transform_edt(mask) / K


def closing(mask, r):
    """Concave corners filled with round fillets of radius r (padded, so
    the picture's edge is not taken for metal)."""
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
    w, h = int(round(CW * PX)), int(round(CH * PX))
    src = np.asarray(Image.open(STONE % stem).convert("RGB")).astype(float)
    reps = (h // src.shape[0] + 1, w // src.shape[1] + 1, 1)
    return np.tile(src, reps)[:h, :w] * k


def down(mask_or_val):
    """A K-resolution field averaged to final pixels."""
    w, h = int(round(CW * PX)), int(round(CH * PX))
    return np.asarray(Image.fromarray(np.asarray(mask_or_val, np.float32), "F").resize((w, h), Image.BOX))


# --- the drawer's outline ------------------------------------------------------

def bulge_none(y):
    return np.zeros_like(y)


def sleeve(y):
    """The window's rim swelling out SLEEVE along the drawer, easing in and
    out over 12 units past its top and bottom."""
    up = smoothstep((y - (DT - 22)) / 12)
    dn = smoothstep(((DB + 22) - y) / 12)
    return 5.0 * up * dn


def box(corner):
    """The drawer's box, its left end under the window: its right corners
    cut at 45 degrees (the frame's chamfer) or rounded by `corner` units."""
    if corner == "chamfer":
        return octagon_depth(xx, yy, XL - 30, DT, XR, DB, 4.0) >= 0
    r = corner
    inside = rect(XL - 30, DT, XR, DB)
    cy = np.clip(yy, DT + r, DB - r)
    cx = np.minimum(xx, XR - r)
    return inside & (np.hypot(xx - cx, yy - cy) <= r)


class Option:
    """One trial: the outline (corner, fillet radius, the rim's bulge), extra
    metal forged in (bars, braces, plates), wires (ornament), and the legend's
    panel: paint(layers) under the metal, stones by region."""

    def __init__(self, n, title, fillet, corner="chamfer", bulge=bulge_none, bay=False):
        self.n, self.title, self.fillet, self.corner, self.bulge = n, title, fillet, corner, bulge
        self.bay = bay  # the window's rim steps out round the drawer, open between
        self.extra = np.zeros(xx.shape, bool)
        self.wires = []
        self.recess = None  # a sunk plate: its mask
        self.stones = []  # (mask at K, stem, shade), drawn in order over the body
        self.paint = []  # fn(lay) painted over the stones at K
        self.lit = (X0, ROWS, XR - RIM, ROWS + ROW)  # the row under the cursor


def metal(o):
    win = xx < X0 + o.bulge(yy)
    shape = closing(win | box(o.corner), o.fillet)
    s_out = edt(shape)
    s_w = X0 + o.bulge(yy) - xx
    strip = win & (xx >= XL) & ~(o.bay & (yy > DT) & (yy < DB))
    frame_m = shape & ((s_out < RIM) | strip) | o.extra
    frame_m = closing(frame_m, 2.0)
    orn = polys([q for w, w0, w1 in o.wires for q in w.pieces(w0, w1)]) if o.wires else np.zeros(xx.shape, bool)
    m = closing(frame_m | orn, 0.5) if o.wires else frame_m
    s_bead = np.where(strip, np.minimum(s_out, s_w), s_out)
    return shape, win, m, s_bead


def render(o):
    shape, win, m, s_bead = metal(o)
    d = edt(m)
    sh = np.clip(d / 1.1, 0, 1)
    hgt = (1 - (1 - sh) ** 2) * 0.68 + 0.11 * np.clip(d / 2.45, 0, 1)
    hgt = hgt + np.where(m, 0.6 * bead(np.clip((s_bead - 2.0) / 1.25, -1, 1)), 0)
    if o.recess is not None:
        dr = edt(o.recess)
        hgt = np.where(o.recess, hgt - 0.55 * smoothstep(dr / 1.0), hgt)
    hgt = ndimage.gaussian_filter(np.where(m, hgt, 0), K * 0.1)
    col = rim_metal(hgt, BRONZE, K) * (1 + 0.09 * brushed(np.clip(s_bead, 0, 59)))[..., None]
    if o.recess is not None:
        face = smoothstep(edt(o.recess) / 1.2)
        col = col * (1 - 0.42 * face)[..., None]
    dark = np.clip(1 - d / 0.5, 0, 1) * 0.9
    col = col + (LINE - col) * dark[..., None]

    lay = Layers(xx.shape)
    for fn in o.paint:
        fn(lay)
    # the metal's shadow, down and right, on whatever is under it
    cast = ndimage.gaussian_filter(ndimage.shift(m.astype(np.float32), (0.8 * K, 0.6 * K), order=0), K * 0.7)
    lay.over(np.zeros(3), np.clip(cast, 0, 1) * 0.6 * ~m)
    lay.over(col, m.astype(float))
    pre = lay.pre()
    w, h = int(round(CW * PX)), int(round(CH * PX))
    top = fit(pre, (w, h))

    # the stones under it: the window's panel, the drawer's body, the lit row
    body = shape & ~win | (o.bay & rect(XL, DT, X0 + 1, DB))
    rgb = np.zeros((h, w, 3))
    a = np.zeros((h, w))

    def stone(mask, stem, k):
        nonlocal rgb, a
        cov = down(mask)[..., None]
        rgb = rgb * (1 - cov) + tile(stem, k) * cov
        a = a * (1 - cov[..., 0]) + cov[..., 0]
    stone(win, "Slate", 0.72)
    stone(body, "Slate", 0.72)
    for mask, stem, k in o.stones:
        stone(mask & body, stem, k)
    stone(rect(*o.lit[:2], *o.lit[2:]) & body, "SlateLight", 1.0)
    ta = top[..., 3:] / 255
    rgb = top[..., :3] * ta + rgb * (1 - ta)
    a = ta[..., 0] + a * (1 - ta[..., 0])
    # the slice of the window faded where it is cut
    fx, fy = (np.arange(w) + 0.5) / PX, (np.arange(h) + 0.5) / PX
    fade = smoothstep(fy / FADE)[:, None] * smoothstep((CH - fy) / FADE)[:, None] * smoothstep(fx / FADE)[None, :]
    cut = 1 - down(win) * (1 - fade)
    a = a * cut
    return np.clip(np.concatenate([rgb, a[..., None] * 255], -1), 0, 255)


# --- the legend's panels ------------------------------------------------------

def legend_rule_band(o):
    """The window's title band, turned over: a bronze rule across, T-joined
    into both rims, and the band's dark leather under it."""
    y0 = LEG[0]
    o.extra |= rect(XL, y0, XR - 1, y0 + 3.0)
    band = rect(X0, y0 + 3.0, XR - RIM, LEG[1])

    def paint(lay):
        col = BAND * (1 + 0.06 * streaks(yy))[..., None]
        occl = np.exp(-(yy - (y0 + 3.0)) / 1.4) * 0.45
        lay.over(col * (1 - np.clip(occl, 0, 0.8))[..., None], band.astype(float))
    o.paint.append(paint)


def legend_carved(o):
    """A strip carved into the drawer's floor, as the wells are (the wells'
    border), a darker stone at its foot."""
    x0, y0, x1, y1 = X0 + 3, LEG[0] + 1, XR - RIM - 3, LEG[1] - 3
    o.stones.append((rect(x0, y0, x1, y1), "Slate", 0.45))

    def paint(lay):
        r = 1.2
        qx = np.maximum(np.minimum(xx - x0, x1 - xx), 0)
        qy = np.maximum(np.minimum(yy - y0, y1 - yy), 0)
        ex, ey = np.maximum(r - qx, 0), np.maximum(r - qy, 0)
        d = np.where((ex > 0) & (ey > 0), r - np.hypot(ex, ey), np.minimum(qx, qy))
        d = np.where(rect(x0, y0, x1, y1), d, -1)
        pre = carve(d.astype(np.float64), K)
        al = pre[..., 3]
        lay.over(np.where(al[..., None] > 0, pre[..., :3] / np.maximum(al, 1e-6)[..., None], 0), al)
    o.paint.append(paint)


def legend_deeper(o):
    """The page's way: the stone under a divider darker (Style.DEEPER), the
    medium vine between (drawn by the game)."""
    o.stones.append((rect(X0, LEG[0], XR, DB), "Slate", 0.72 * 0.6))


def legend_plate(o):
    """The drawer's foot as one bronze plate forged with the rims, its face
    sunk and darkened under the words."""
    o.extra |= rect(XL, LEG[0], XR - 1, DB)
    o.recess = rect(X0 + 3.0, LEG[0] + 3.0, XR - RIM - 3.0, LEG[1] - 2.0)


def legend_well(o):
    """The window's own way: the rows in a well (the wells' border), the
    legend on the drawer's panel under it, as the window's legend sits under
    its wells."""
    x0, y0, x1, y1 = X0 + 3, DT + RIM + 3, XR - RIM - 3, LEG[0] - 1
    o.stones.append((rect(x0, y0, x1, y1), "Slate", 1.0))
    o.lit = (x0 + 3, ROWS, x1 - 3, ROWS + ROW)

    def paint(lay):
        r = 1.2
        qx = np.maximum(np.minimum(xx - x0, x1 - xx), 0)
        qy = np.maximum(np.minimum(yy - y0, y1 - yy), 0)
        ex, ey = np.maximum(r - qx, 0), np.maximum(r - qy, 0)
        d = np.where((ex > 0) & (ey > 0), r - np.hypot(ex, ey), np.minimum(qx, qy))
        d = np.where(rect(x0, y0, x1, y1), d, -1)
        pre = carve(d.astype(np.float64), K)
        al = pre[..., 3]
        lay.over(np.where(al[..., None] > 0, pre[..., :3] / np.maximum(al, 1e-6)[..., None], 0), al)
    o.paint.append(paint)


def legend_sill(o):
    """A fresh material: a sill of smooth grey stone (the wells' bar's)
    laid across the drawer's foot, bevelled, casting its shadow."""
    x0, y0, x1, y1 = X0, LEG[0] + 1, XR - RIM, LEG[1]
    sill = rect(x0, y0, x1, y1)

    def paint(lay):
        d = edt(sill)
        t = np.clip(d / 1.6, 0, 1)
        h = ndimage.gaussian_filter((1 - (1 - t) ** 2) * 1.2, K * 0.12)
        col = shade(h, BAR_STONE, K, gloss=0.05, power=12) * 1.05
        col = col + (np.array((8, 8, 10.0)) - col) * (np.clip(1 - d / 0.35, 0, 1) * 0.8)[..., None]
        cast = ndimage.gaussian_filter(ndimage.shift(sill.astype(np.float32), (-0.9 * K, 0), order=0), K * 0.8)
        lay.over(np.zeros(3), np.clip(cast, 0, 1) * 0.5 * ~sill)
        lay.over(col, sill.astype(float))
    o.paint.append(paint)


# --- the six --------------------------------------------------------------------

def mirrored(wires):
    mid = (DT + DB) / 2
    return wires + [(w.mirrored(mid), a, b) for w, a, b in wires]


def options():
    out = []

    o = Option(1, "One rim: the window's steps out round it", fillet=5.0, bay=True)
    legend_well(o)
    out.append(o)

    o = Option(2, "Rims sweep out of the window's;\na carved strip", fillet=16.0)
    legend_carved(o)
    out.append(o)

    o = Option(3, "Scroll brackets; a rule over\nthe title band's leather", fillet=4.0)
    stem = Wire((X0 - 2.0, DT - 36), 90).volute((X0 + 24.0, DT - 10.6), 9.6, -90, 1, 1.6, eye=2.2, out=0.6, inn=0.5)
    near = stem.fork(0.30, 0).volute((X0 + 8.5, DT - 8.5), 5.0, 180, -1, 0.9, eye=1.9, out=0.3, inn=0.5)
    o.wires = mirrored([(stem, 1.7, 1.15), (near, 1.3, 0.9)])
    legend_rule_band(o)
    out.append(o)

    o = Option(4, "The rim swells into a sleeve;\na sunk bronze plate", fillet=3.0, bulge=sleeve)
    legend_plate(o)
    out.append(o)

    o = Option(5, "A rounded tongue, wide fillets;\nthe page's vine, deeper stone", fillet=7.0, corner=14.0)
    legend_deeper(o)
    out.append(o)

    o = Option(6, "Knee braces, plain; a sill\nof grey stone", fillet=1.5)
    for sgn, y in ((1, DT), (-1, DB)):
        o.extra |= polys([ribbon([(X0 - 1, y - sgn * 21), (X0 + 21, y + sgn * 1)], 2.3)])
    legend_sill(o)
    out.append(o)
    return out


# --- the sheet --------------------------------------------------------------------

def mock(img, o):
    """The cell with the game's text, roughly (Arial for Friz Quadrata)."""
    im = Image.fromarray(img.astype(np.uint8), "RGBA")
    back = Image.new("RGBA", im.size, (40, 44, 40, 255))
    back.alpha_composite(im)
    d = ImageDraw.Draw(back)
    font = ImageFont.truetype("arial.ttf", int(12 * PX))
    for i, (t, lit) in enumerate((("Clear chat", True), ("Start over", False))):
        d.text(((X0 + 16) * PX, (ROWS + ROW * i + ROW / 2) * PX), t, font=font, anchor="lm",
               fill=(250, 235, 199) if lit else (199, 176, 135))
    d.text(((XR - RIM - 8) * PX, ((LEG[0] + LEG[1]) / 2 + 1) * PX), "X Select    O Back", font=font, anchor="rm",
           fill=(230, 230, 230))
    return back


def main():
    os.makedirs(OUT, exist_ok=True)
    for old in glob.glob(os.path.join(OUT, "DrawerTrial-*.tga")):
        os.remove(old)
    cells = []
    for o in options():
        img = render(o)
        tex = np.zeros((TEX, TEX, 4))
        tex[:img.shape[0], :img.shape[1]] = img
        write_tga(os.path.join(OUT, "DrawerTrial-%d-%d.tga" % (o.n, VERSION)), tex)
        cells.append(mock(img, o))
    w, h = cells[0].size
    sheet = Image.new("RGB", (w * 3 + 40, h * 2 + 30), (30, 30, 30))
    for i, c in enumerate(cells):
        sheet.paste(c.convert("RGB"), (10 + (i % 3) * (w + 10), 10 + (i // 3) * (h + 10)))
    path = os.path.join(ROOT, "target", "drawer-trials.png")
    sheet.save(path)
    print(path)


if __name__ == "__main__":
    main()
