"""The Companion window's frame (Window.lua: ButtonFrameTemplate's border,
title bar and close button) and its wells' borders (InsetFrameTemplate),
drawn here as vector shapes, bevelled and lit from the top left, many samples
to a pixel and averaged down, never Blizzard's art.

    python tools/make_frame_art.py   writes addon/WowCompanion_Agent/Art/Frame-*-<v>.tga,
                                     Inset-*-<v>.tga, Close-*-<v>.tga and
                                     target/frame-sheet-<v>.png (the comparison sheet)

The frame replaces its NineSlice region by region: four corners, four edges
stretched between them (each edge is the same all along its length, so it
stretches without a seam). Every corner is the rim's own width, as the edges
are, and every piece has the same texels a unit across the rim: a corner and
the edge beside it share their pixel columns on screen, so the rim's lines run
through the join without a step. The top pieces hold the title bar: the rim,
the dark band the title sits in, the bronze rule under it and that rule's
shadow. Nothing is drawn outside the rim; Window.lua puts it on the frame's
bounds and decides every margin. The inset's border is painted as
Blizzard's is (inset()).

The game keeps a texture for the session under its path, so a change bumps
VERSION (and Window.lua's ART); older files are deleted.
"""
import glob
import os
import numpy as np
from PIL import Image
from scipy import ndimage
from make_scrollbar_art import write_tga, LIGHT, HALF

VERSION = 4
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "addon", "WowCompanion_Agent", "Art")
K = 32  # px a unit drawn; every piece is averaged down from this

# the frame, in units from the rim's outer edge
RIM = 6.0  # the rim's width
CHAMFER = 4.0  # its corners cut at 45 degrees
RULE = (22.6, 25.6)  # the rule under the title band
TOP_H = 28.0  # the top pieces' height: rim, band, rule and its shadow
N = 60.0  # the drawn frame's side, the pieces cut from it

BRONZE = (np.array((28, 16, 4.0)), np.array((72, 46, 16.0)), np.array((196, 154, 98.0)))
LINE = np.array((14, 9, 4.0))
BAND = np.array((33, 19, 10.0))
GOLD = (np.array((120, 72, 0.0)), np.array((236, 186, 16.0)), np.array((255, 238, 110.0)))


def grid(w, h, k=K):
    yy, xx = np.mgrid[0:int(round(h * k)), 0:int(round(w * k))]
    return (xx + 0.5) / k, (yy + 0.5) / k


def shade(hgt, pal, k=K, gloss=0.35, power=18):
    """A height field's colour lit from the top left: the palette's shadow,
    mid and light by how the surface faces the light, a highlight on top."""
    gy, gx = np.gradient(hgt, 1 / k)
    n = np.stack([-gx, -gy, np.ones_like(gx)], -1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    diff = np.clip(n @ LIGHT, 0, 1)[..., None]
    flat = LIGHT[2]
    sh, mid, li = pal
    col = np.where(diff < flat, sh + (mid - sh) * (diff / flat), mid + (li - mid) * ((diff - flat) / (1 - flat)))
    spec = np.clip(n @ HALF, 0, 1) ** power * gloss
    return np.clip(col + spec[..., None] * 255, 0, 255)


def bead(u):
    """A rounded bead's height across it, u -1..1."""
    return np.sqrt(np.clip(1 - u * u, 0, 1))


class Layers:
    def __init__(self, shape):
        self.rgb = np.zeros(shape + (3,))
        self.a = np.zeros(shape)

    def over(self, col, alpha):
        alpha = np.clip(alpha, 0, 1)[..., None]
        col = np.broadcast_to(col, self.rgb.shape)
        out = alpha + self.a[..., None] * (1 - alpha)
        self.rgb = np.where(out > 0, (col * alpha + self.rgb * self.a[..., None] * (1 - alpha)) / np.maximum(out, 1e-6), 0)
        self.a = out[..., 0]

    def pre(self):
        return np.concatenate([self.rgb * self.a[..., None], self.a[..., None]], -1)


def fit(pre, size):
    """A premultiplied piece averaged down to `size` (w, h) px, as RGBA."""
    w, h = size
    ch = [np.asarray(Image.fromarray(pre[..., i].astype(np.float32), "F").resize((w, h), Image.BOX)) for i in range(4)]
    al = ch[3]
    out = np.zeros((h, w, 4))
    for i in range(3):
        out[..., i] = np.where(al > 0, ch[i] / np.maximum(al, 1e-6), 0)
    out[..., 3] = al * 255
    return np.clip(out, 0, 255)


def octagon_depth(xx, yy, x0, y0, x1, y1, c):
    """How far inside a box with its corners cut by c each point is (negative
    outside): the least distance to its eight sides."""
    r2 = np.sqrt(2)
    return np.minimum.reduce([xx - x0, x1 - xx, yy - y0, y1 - yy,
                              (xx - x0 + yy - y0 - c) / r2, (x1 - xx + yy - y0 - c) / r2,
                              (xx - x0 + y1 - yy - c) / r2, (x1 - xx + y1 - yy - c) / r2])


# --- the frame ---------------------------------------------------------------

def streaks(yy, seed=3):
    """The title band's grain: fine streaks along it, the same all along, so
    its edge piece stretches without a seam."""
    rng = np.random.default_rng(seed)
    rows = rng.normal(0, 1, 400)
    rows = ndimage.gaussian_filter1d(rows, 1.2) * 0.7 + ndimage.gaussian_filter1d(rng.normal(0, 1, 400), 5) * 1.6
    return np.interp(yy, np.linspace(0, N, 400), rows)


def brushed(u, seed=7):
    """Brushed metal's grain across a bar, by depth: the same all along it."""
    rng = np.random.default_rng(seed)
    v = ndimage.gaussian_filter1d(rng.normal(0, 1, 600), 1.5) * 0.8 + ndimage.gaussian_filter1d(rng.normal(0, 1, 600), 6) * 1.4
    return np.interp(u, np.linspace(0, N, 600), v)


def frame():
    xx, yy = grid(N, N)
    s = octagon_depth(xx, yy, 0, 0, N, N, CHAMFER)  # into the rim from its outer edge
    lay = Layers(xx.shape)
    # the rim: a dark line, one broad bar with rounded shoulders (the one
    # toward the light lit), a dark lip down into the panel; the rule a
    # narrower bar of the same make, meeting the rim in a T. The metal is
    # brushed along its length: its grain a function of the depth alone, so
    # the edges stretch and the corners turn without a seam.
    def bar(u, w):
        """A bar's height across it, u from 0 to w: shoulders 1.1 wide, a
        slightly crowned top."""
        sh = np.clip(np.minimum(u, w - u) / 1.1, 0, 1)
        return (1 - (1 - sh) ** 2) * 0.9 + 0.15 * bead(np.clip(2 * u / w - 1, -1, 1))
    # the rim's bar carries a raised bead along its outer half, the lit
    # ridge the game's rim has, its inner half lower and darker
    hr = np.where((s >= 0.45) & (s < 5.35), bar(s - 0.45, 4.9) * 0.75 + 0.6 * bead(np.clip((s - 2.0) / 1.25, -1, 1)), 0)
    rc, rh = (RULE[0] + RULE[1]) / 2, (RULE[1] - RULE[0]) / 2
    hrule = np.where((np.abs(yy - rc) < rh) & (s > 2.5), bar(yy - RULE[0], RULE[1] - RULE[0]) * 0.85, 0)
    hrule = np.where(hrule > hr, hrule, 0)  # the rim's bar runs over the rule's end
    hgt = ndimage.gaussian_filter(np.maximum(hr, hrule), K * 0.1)
    metal = (s >= 0) & (s < RIM) | (hrule > 0)
    col = shade(hgt, BRONZE, gloss=0.22, power=14)
    col = col * (1 + 0.09 * brushed(s))[..., None]
    rule = hrule > 0
    col = np.where(rule[..., None], col * (1 + 0.07 * brushed(yy, 5))[..., None], col)
    # the dark line outside, the lip inside, and the rule's edges, deepened
    edge_r = np.minimum(np.abs(yy - RULE[0]), np.abs(yy - RULE[1]))
    dark = np.where(rule, np.clip(1 - edge_r / 0.4, 0, 1), np.clip(1 - s / 0.5, 0, 1) + np.clip((s - 5.35) / 0.5, 0, 1))
    col = col + (LINE - col) * np.clip(dark, 0, 0.9)[..., None]
    # the title band: dark wood, shadowed under the rim and over the rule
    band = (s >= RIM) & (yy < RULE[0])
    bcol = BAND * (1 + 0.06 * streaks(yy))[..., None]
    occl = np.maximum(np.exp(-(s - RIM) / 0.9) * 0.75, np.exp(-(RULE[0] - yy) / 0.6) * 0.45)
    bcol = bcol * (1 - np.clip(occl, 0, 0.8))[..., None]
    lay.over(np.where(band[..., None], bcol, col), (metal | band).astype(float))
    # the panel under the rule: only the rule's shadow
    panel = (s >= RIM) & (yy >= RULE[1])
    under = np.clip(1 - (yy - RULE[1]) / (TOP_H - RULE[1]), 0, 1) ** 2 * 0.7
    lay.over(np.zeros(3), np.where(panel & ~metal, under, 0))
    return lay.pre()


def frame_pieces():
    pre = frame()
    k = K

    def cut(x0, y0, x1, y1):
        return pre[int(round(y0 * k)):int(round(y1 * k)), int(round(x0 * k)):int(round(x1 * k))]
    c, mid = RIM, N / 2
    return {
        "Frame-TopLeftCorner": fit(cut(0, 0, c, TOP_H), (64, 256)),
        "Frame-TopRightCorner": fit(cut(N - c, 0, N, TOP_H), (64, 256)),
        "Frame-BottomLeftCorner": fit(cut(0, N - c, c, N), (64, 64)),
        "Frame-BottomRightCorner": fit(cut(N - c, N - c, N, N), (64, 64)),
        "Frame-TopEdge": fit(cut(mid - 1, 0, mid + 1, TOP_H), (16, 256)),
        "Frame-BottomEdge": fit(cut(mid - 1, N - c, mid + 1, N), (16, 64)),
        "Frame-LeftEdge": fit(cut(0, mid - 1, c, mid + 1), (64, 16)),
        "Frame-RightEdge": fit(cut(N - c, mid - 1, N, mid + 1), (64, 16)),
    }


# --- the close button ----------------------------------------------------------

CLOSE = 14.0  # its side: it sits inside the title band (16.6 tall under the rim)
BRASS = (np.array((62, 42, 16.0)), np.array((150, 114, 52.0)), np.array((214, 186, 120.0)))  # aged, not new gold


def close(state):
    """The close button, 14 units, inside the title band: no plate of its own,
    only a cross of aged brass struck into the band's dark leather, with a dark outline and the shadow it casts. Pushed
    sinks and dims it; Highlight is a soft warm light behind it, for ADD
    blending; Disabled is greyed."""
    xx, yy = grid(CLOSE, CLOSE)
    lay = Layers(xx.shape)
    push = state == "Pushed"
    o = 0.5 if push else 0.0
    c0 = CLOSE / 2
    half, reach = 1.05, 4.6

    def cross(x, y):
        """How far inside the cross a point is (negative outside)."""
        u, v = (x - c0 + y - c0) / np.sqrt(2), (x - c0 - (y - c0)) / np.sqrt(2)
        one = np.minimum(half - np.abs(v), reach - np.abs(u))
        two = np.minimum(half - np.abs(u), reach - np.abs(v))
        return np.maximum(one, two)
    if state == "Highlight":
        r = np.hypot(xx - c0, yy - c0)
        lay.over(np.array((255, 190, 90.0)), np.clip(1 - r / (CLOSE / 2), 0, 1) ** 1.5 * 0.35)
        lay.over(np.array((255, 220, 130.0)), np.clip((cross(xx, yy) + 1.2) / 1.2, 0, 1) * 0.25)
        return lay.pre()
    d = cross(xx - o, yy - o)
    lay.over(np.zeros(3), np.clip((cross(xx - o - 0.5, yy - o - 0.7) + 0.8) / 0.8, 0, 1) * 0.6)
    lay.over(LINE, np.clip((d + 0.45) / 0.4, 0, 1))
    hx = np.clip(d / 0.8, 0, 1)
    hx = (1 - (1 - hx) ** 2) * 0.8
    gold = shade(ndimage.gaussian_filter(hx, K * 0.08), BRASS, gloss=0.1, power=12)
    if push:
        gold = gold * 0.75
    lay.over(gold, np.clip((d + 0.05) / 0.15, 0, 1))
    pre = lay.pre()
    pre = np.stack([ndimage.gaussian_filter(pre[..., i], K * 0.12) for i in range(4)], -1)
    if state == "Disabled":
        grey = (pre[..., :3] @ np.array([0.3, 0.59, 0.11]))[..., None] * 0.7
        pre = np.concatenate([np.repeat(grey, 3, -1), pre[..., 3:]], -1)
    return pre


# --- the inset ------------------------------------------------------------------

INSET = 4.0  # the inset's corners' side and its edges' width
STONE = (np.array((16, 14, 12.0)), np.array((52, 48, 43.0)), np.array((112, 104, 92.0)))  # the wall: shadow, mid, lit
LINE_IN = np.array((5, 4, 3.0))  # the creases at the wall's top and foot


def inset():
    """An inset's border in a 20-unit square: a wall carved down from the
    panel into the well, opaque stone, so the well reads as cut into the
    frame rather than shaded over. A dark crease where the panel breaks, a
    rounded, worn wall lit by the frame's light (the top and left walls face
    away and fall dark, the bottom and right catch it), a dark crease at its
    foot, and a short contact shadow onto the well's floor. The corners turn
    softly, and the whole is blurred a quarter unit, so no line is razor
    sharp."""
    n, pad = 20.0, 1.0
    xx, yy = grid(n + 2 * pad, n + 2 * pad)
    xx, yy = xx - pad, yy - pad
    # depth into the border: a rounded box's, so the corners turn softly
    r = 1.2
    qx = np.maximum(np.minimum(xx, n - xx), 0)
    qy = np.maximum(np.minimum(yy, n - yy), 0)
    ex, ey = np.maximum(r - qx, 0), np.maximum(r - qy, 0)
    d = np.where((ex > 0) & (ey > 0), r - np.hypot(ex, ey), np.minimum(qx, qy))
    d = np.where((xx < 0) | (yy < 0) | (xx > n) | (yy > n), -1, d)
    lay = Layers(xx.shape)
    top, foot = 0.35, 3.3
    # the wall's height: the panel's level at its top, the well's at its foot,
    # rounded over at the lip as worn stone is
    t = np.clip((d - top) / (foot - top), 0, 1)
    hgt = 1.6 * (1 - t) ** 1.6
    wall = shade(ndimage.gaussian_filter(hgt, K * 0.15), STONE, gloss=0.08, power=10)
    lay.over(wall, ((d >= 0) & (d < foot + 0.2)).astype(float))
    lay.over(LINE_IN, np.clip(1 - np.abs(d - 0.12) / 0.22, 0, 1) * (d >= 0) * 0.9)
    lay.over(LINE_IN, np.clip(1 - np.abs(d - foot) / 0.3, 0, 1) * 0.9)
    lay.over(np.zeros(3), np.where(d > foot, np.clip(1 - (d - foot) / (INSET - foot), 0, 1) * 0.45, 0))
    pre = lay.pre()
    pre = np.stack([ndimage.gaussian_filter(pre[..., i], K * 0.25) for i in range(4)], -1)
    k = K

    def cut(x0, y0, x1, y1):
        return pre[int(round((y0 + pad) * k)):int(round((y1 + pad) * k)), int(round((x0 + pad) * k)):int(round((x1 + pad) * k))]
    c, mid = INSET, n / 2
    return {
        "Inset-TopLeftCorner": fit(cut(0, 0, c, c), (64, 64)),
        "Inset-TopRightCorner": fit(cut(n - c, 0, n, c), (64, 64)),
        "Inset-BottomLeftCorner": fit(cut(0, n - c, c, n), (64, 64)),
        "Inset-BottomRightCorner": fit(cut(n - c, n - c, n, n), (64, 64)),
        "Inset-TopEdge": fit(cut(mid - 0.5, 0, mid + 0.5, c), (16, 64)),
        "Inset-BottomEdge": fit(cut(mid - 0.5, n - c, mid + 0.5, n), (16, 64)),
        "Inset-LeftEdge": fit(cut(0, mid - 0.5, c, mid + 0.5), (64, 16)),
        "Inset-RightEdge": fit(cut(n - c, mid - 0.5, n, mid + 0.5), (64, 16)),
    }


def render():
    art = frame_pieces()
    art.update(inset())
    for state in ("Normal", "Pushed", "Highlight", "Disabled"):
        art["Close-" + state] = fit(close(state), (128, 128))
    return art


# --- the comparison sheet ---------------------------------------------------------
#
# The window as the game draws it, rebuilt at a 4K screen's own pixels from the
# written textures and Window.lua's layout, beside the shot it replaces
# (%LOCALAPPDATA%/wow-companion/shots/full.png: the medium window at 1.5 scale,
# 2.7 px a unit, its top left at 28.8, 208.8; read in game with GetLeft/GetTop).
# Every edge is rounded to a whole pixel, as the game snaps a texture.

PX = 2.7
ORIGIN = (28.8, 208.8)
SIZE = (760.0, 520.0)
SHOT = os.path.join(os.environ.get("LOCALAPPDATA", ""), "wow-companion", "shots", "full.png")
GLOW_SHOT = os.path.join(ROOT, "target", "glowshot.png")  # the focus glow's atlas drawn 1:1 on black

# Window.lua's layout, in units
RIM, GAP, WELL_TOP, FOOT, WELL = 6.0, 4.0, 64.0, 20.0, 130.0
CLOSE_PAD = 3.0  # Window.lua: the close button's gap from the rim
GLOW = (14.0, 10.75, 13.0, 11.0)
TAB_W, TAB_GAP, TAB_H, TAB_ACTIVE_H, CAP, HALO, EDGE = 69.0, 3.0, 20.2, 25.6, 6.0, 2.0, 3.0


class Mock:
    def __init__(self, backdrop):
        self.im = backdrop.convert("RGBA")

    def px(self, x, y):
        return int(round(ORIGIN[0] + x * PX)), int(round(ORIGIN[1] + y * PX))

    def put(self, img, x0, y0, x1, y1):
        """img over the rect (units from the frame's top left), snapped."""
        a, b = self.px(x0, y0)
        c, d = self.px(x1, y1)
        if c <= a or d <= b:
            return
        if isinstance(img, tuple):
            self.im.alpha_composite(Image.new("RGBA", (c - a, d - b), img), (a, b))
            return
        im = Image.fromarray(img.astype(np.uint8), "RGBA").resize((c - a, d - b), Image.BILINEAR)
        self.im.alpha_composite(im, (a, b))

    def nine(self, art, prefix, x0, y0, x1, y1, rim, top):
        """dress(): every piece rim wide, the top ones top tall."""
        self.put(art[prefix + "TopLeftCorner"], x0, y0, x0 + rim, y0 + top)
        self.put(art[prefix + "TopRightCorner"], x1 - rim, y0, x1, y0 + top)
        self.put(art[prefix + "BottomLeftCorner"], x0, y1 - rim, x0 + rim, y1)
        self.put(art[prefix + "BottomRightCorner"], x1 - rim, y1 - rim, x1, y1)
        self.put(art[prefix + "TopEdge"], x0 + rim, y0, x1 - rim, y0 + top)
        self.put(art[prefix + "BottomEdge"], x0 + rim, y1 - rim, x1 - rim, y1)
        self.put(art[prefix + "LeftEdge"], x0, y0 + top, x0 + rim, y1 - rim)
        self.put(art[prefix + "RightEdge"], x1 - rim, y0 + top, x1, y1 - rim)

    def glow(self, x0, y0, x1, y1):
        """The focus glow (gamepad-uiframemetal-focus, 392 x 265, slice margins
        156, 115, 220, 179, at half scale), gold, blended over what is under."""
        if not os.path.exists(GLOW_SHOT):
            return
        src = np.asarray(Image.open(GLOW_SHOT).convert("RGB")).astype(float)[650:915, 1450:1842]
        a = src.max(-1) / 255.0
        ml, mt, mr, mb = 156, 115, 220, 179
        H, W = a.shape
        pieces = {}
        xs = ((0, ml), (ml, W - mr), (W - mr, W))
        ys = ((0, mt), (mt, H - mb), (H - mb, H))
        ux = ((x0, x0 + ml / 2), (x0 + ml / 2, x1 - mr / 2), (x1 - mr / 2, x1))
        uy = ((y0, y0 + mt / 2), (y0 + mt / 2, y1 - mb / 2), (y1 - mb / 2, y1))
        for j in range(3):
            for i in range(3):
                if i == 1 and j == 1:
                    continue
                piece = a[ys[j][0]:ys[j][1], xs[i][0]:xs[i][1]]
                rgba = np.zeros(piece.shape + (4,))
                rgba[..., :3] = (255, 230, 102)
                rgba[..., 3] = piece * 255
                self.put(rgba, ux[i][0], uy[j][0], ux[i][1], uy[j][1])


def mock(art, backdrop):
    w, h = SIZE
    m = Mock(backdrop)
    m.put((49, 45, 41, 255), 2, 21, w - 2, h - 2)  # the template's Bg
    m.put((33, 19, 10, 255), 2, 2, w - 2, 21)
    wells = (RIM + GAP, w - (RIM + GAP + WELL + GAP), w - (RIM + GAP + WELL), w - (RIM + GAP))
    top, foot = WELL_TOP, h - (RIM + FOOT)
    m.put((20, 21, 24, 255), wells[0], top, wells[1], foot)
    m.put((34, 28, 24, 255), wells[2], top, wells[3], foot)
    m.nine(art, "Inset-", wells[0], top, wells[1], foot, INSET, INSET)
    m.nine(art, "Inset-", wells[2], top, wells[3], foot, INSET, INSET)
    tabs = {s: np.asarray(Image.open(os.path.join(OUT, "Tab-%s-2.tga" % s)).convert("RGBA")).astype(float)
            for s in ("Left", "Middle", "Right", "Left-Active", "Middle-Active", "Right-Active")}
    for i in range(5):
        x = wells[0] + EDGE + i * (TAB_W + TAB_GAP)
        y1 = top + 1
        if i == 0:
            m.put(tabs["Left-Active"], x - HALO, y1 - TAB_ACTIVE_H, x + CAP, y1)
            m.put(tabs["Middle-Active"], x + CAP, y1 - TAB_ACTIVE_H, x + TAB_W - CAP, y1)
            m.put(tabs["Right-Active"], x + TAB_W - CAP, y1 - TAB_ACTIVE_H, x + TAB_W + HALO, y1)
        else:
            m.put(tabs["Left"], x, y1 - TAB_H, x + CAP, y1)
            m.put(tabs["Middle"], x + CAP, y1 - TAB_H, x + TAB_W - CAP, y1)
            m.put(tabs["Right"], x + TAB_W - CAP, y1 - TAB_H, x + TAB_W, y1)
    m.glow(-GLOW[0], -GLOW[1], w + GLOW[2], h + GLOW[3])
    m.nine(art, "Frame-", 0, 0, w, h, RIM, TOP_H)
    cx, cy = w - RIM - CLOSE_PAD - CLOSE, (RIM + 22.6 - CLOSE) / 2
    m.put(art["Close-Normal"], cx, cy, cx + CLOSE, cy + CLOSE)
    return m.im.convert("RGB")


def sheet(art):
    old = Image.open(SHOT).convert("RGB")
    # the backdrop: the shot with the old window and its glow covered by the
    # world from the screen's right, so nothing of the old frame shows
    back = old.copy()
    world = old.crop((2300, 300, 3800, 1900))
    for x in range(0, 2300, world.width):
        for y in range(0, 1830, world.height):
            back.paste(world, (x, y + 100))
    new = mock(art, back)
    box = (0, 150, 2130, 1680)
    a, b = old.crop(box), new.crop(box)
    rows = [[a.resize((a.width // 2, a.height // 2), Image.LANCZOS), b.resize((b.width // 2, b.height // 2), Image.LANCZOS)]]
    w, h = SIZE
    wells_x = w - (RIM + GAP + WELL + GAP)
    spots = [(-20, -20), (w - 90, -20), (-20, h - 50), (w - 90, h - 50),
             (wells_x - 30, 200), (40, WELL_TOP - 40), (wells_x - 30, h - 50)]
    for x, y in spots:
        x0, y0 = int(ORIGIN[0] + x * PX), int(ORIGIN[1] + y * PX)
        crop = (x0, y0, x0 + 300, y0 + 200)
        rows.append([old.crop(crop).resize((900, 600), Image.NEAREST), new.crop(crop).resize((900, 600), Image.NEAREST)])
    W = max(sum(i.width for i in r) + 12 * len(r) for r in rows) + 12
    H = sum(max(i.height for i in r) + 12 for r in rows) + 12
    out = Image.new("RGB", (W, H), (52, 50, 46))
    y = 12
    for r in rows:
        x = 12
        for i in r:
            out.paste(i, (x, y))
            x += i.width + 12
        y += max(i.height for i in r) + 12
    path = os.path.join(ROOT, "target", "frame-fix-sheet.png")
    out.save(path)
    new.save(os.path.join(ROOT, "target", "frame-fix-4k.png"))
    return path


def main():
    art = render()
    os.makedirs(OUT, exist_ok=True)
    for pat in ("Frame-*.tga", "Inset-*.tga", "Close-*.tga"):
        for old in glob.glob(os.path.join(OUT, pat)):
            os.remove(old)
    for stem, img in art.items():
        write_tga(os.path.join(OUT, "%s-%d.tga" % (stem, VERSION)), img)
    print(len(art), "textures;", sheet(art))


if __name__ == "__main__":
    main()
