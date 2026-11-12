"""The Companion window's frame (Window.lua: ButtonFrameTemplate's border,
title bar and close button) and its wells' borders (InsetFrameTemplate),
drawn here as vector shapes, bevelled and lit from the top left, many samples
to a pixel and averaged down, never Blizzard's art.

    python tools/make_frame_art.py   writes addon/WowCompanion_Agent/Art/Frame-*-<v>.tga,
                                     Inset<style>-*-<v>.tga, Close-*-<v>.tga,
                                     target/frame-fix-4k.png (the window mocked at 4K) and
                                     target/tabs-v<tab v>-sheet.png (the tab row: the shot's, ours)

The frame replaces its NineSlice region by region: four corners, four edges
stretched between them (each edge is the same all along its length, so it
stretches without a seam). Every corner is the rim's own width, as the edges
are, and every piece has the same texels a unit across the rim: a corner and
the edge beside it share their pixel columns on screen, so the rim's lines run
through the join without a step. The top pieces hold the title bar: the rim,
the dark band the title sits in, the bronze rule under it and that rule's
shadow. Nothing is drawn outside the rim; Window.lua puts it on the frame's
bounds and decides every margin. The inset's border is painted as
Blizzard's is (inset()); the tabs are
carved with the same wall (tab()).

The game keeps a texture for the session under its path, so a change bumps
VERSION (and Window.lua's ART); older files are deleted.
"""
import glob
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage
from make_scrollbar_art import write_tga, LIGHT, HALF

VERSION = 11
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "addon", "WowCompanion_Agent", "Art")
K = 32  # px a unit drawn; every piece is averaged down from this

# the frame, in units from the rim's outer edge
RIM = 6.0  # the rim's width
CHAMFER = 4.0  # its corners cut at 45 degrees
RULE = (22.6, 25.6)  # the rule under the title band
TOP_H = 28.0  # the top pieces' height: rim, band, rule and its shadow
N = 60.0  # the drawn frame's side, the pieces cut from it

# the washed-out bronze of the chat's scroll bar and dividers (make_scrollbar_art.py's
# BARK), the light a touch higher for the rim's broader bar: the window's one metal
BRONZE = (np.array((22, 15, 9.0)), np.array((68, 48, 30.0)), np.array((150, 118, 82.0)))
LINE = np.array((14, 9, 4.0))
BAND = np.array((20, 21, 25.0))  # the title band: the slate in shadow, cool as the wells


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
LINE_IN = np.array((5, 4, 3.0))  # the creases at the wall's top and foot
WALL_FOOT = 3.3  # where the wall meets the floor, its contact shadow on to INSET


def carve(d, wall, k=K, lip=False, rim=False):
    """A well's border painted on a depth field d (units into the cavity from
    its edge, negative outside). The wall: opaque stone carved down from the
    panel, a dark crease where the panel breaks, a rounded, worn wall lit by
    the frame's light (walls facing away fall dark, the others catch it), a
    dark crease at its foot, a short contact shadow onto the floor. lip: a
    bead of the window's bronze along the wall's top. rim: a bar of the
    window's rim along it. The whole is blurred a quarter unit, so no line is
    razor sharp."""
    lay = Layers(d.shape)
    inside = (d >= 0).astype(float)
    top = 0.35
    # the wall's height: the panel's level at its top, the floor's at its
    # foot, rounded over at the lip as worn stone is
    t = np.clip((d - top) / (WALL_FOOT - top), 0, 1)
    hgt = 1.6 * (1 - t) ** 1.6
    col = shade(ndimage.gaussian_filter(hgt, k * 0.15), wall, k, gloss=0.08, power=10)
    lay.over(col, ((d >= 0) & (d < WALL_FOOT + 0.2)).astype(float))
    lay.over(LINE_IN, np.clip(1 - np.abs(d - 0.12) / 0.22, 0, 1) * inside * 0.9)
    if lip:
        # a rounded bead a unit wide on the wall's top, a crease inside it
        u = (d - 0.75) / 0.6
        bh = ndimage.gaussian_filter(bead(np.clip(u, -1, 1)) * (np.abs(u) < 1), k * 0.1)
        lay.over(shade(bh, BRONZE, k, gloss=0.15, power=12), np.clip((1 - np.abs(u)) / 0.25, 0, 1))
        lay.over(LINE_IN, np.clip(1 - np.abs(d - 1.45) / 0.2, 0, 1) * 0.7)
    if rim:
        # a bar of the frame's own make at the well's edge: its rim's
        # shoulders and brushed bronze, a dark line outside and a dark lip
        # down into the wall, so the well is framed as the window is
        w = 1.7
        u = np.clip(d / w, 0, 1)
        sh = np.clip(np.minimum(d, w - d) / 0.5, 0, 1)
        bh = ndimage.gaussian_filter(((1 - (1 - sh) ** 2) * 0.9 + 0.15 * bead(2 * u - 1)) * (d < w), k * 0.08)
        col = shade(bh, BRONZE, k, gloss=0.22, power=14) * (1 + 0.09 * brushed(d * 8))[..., None]
        lay.over(col, ((d >= 0) & (d < w)).astype(float))
        lay.over(LINE, np.clip(1 - d / 0.25, 0, 1) * inside * 0.9)
        lay.over(LINE, np.clip(1 - np.abs(d - w) / 0.3, 0, 1) * 0.9)
    lay.over(LINE_IN, np.clip(1 - np.abs(d - WALL_FOOT) / 0.3, 0, 1) * 0.9)
    lay.over(np.zeros(3), np.where(d > WALL_FOOT, np.clip(1 - (d - WALL_FOOT) / (INSET - WALL_FOOT), 0, 1) * 0.45, 0))
    pre = lay.pre()
    return np.stack([ndimage.gaussian_filter(pre[..., i], k * 0.25) for i in range(4)], -1)


# The wells' border, four ways while the player chooses (Window.lua's
# WC.Window.WellStyle): A the dark wall with a bronze lip, C the dark wall
# alone, its light evened (the top a shade lighter, the bottom a shade darker
# than DARK gives), D the grey wall the wells had before, E the dark wall
# framed by a bar of the window's rim.
DARK = (np.array((7, 7, 9.0)), np.array((20, 21, 24.0)), np.array((46, 47, 52.0)))
EVEN = (np.array((13, 13, 16.0)), np.array((22, 23, 26.0)), np.array((36, 37, 41.0)))
GREY = (np.array((11, 11, 13.0)), np.array((32, 33, 37.0)), np.array((70, 71, 76.0)))
WELLS = {"A": dict(wall=DARK, lip=True), "C": dict(wall=EVEN), "D": dict(wall=GREY), "E": dict(wall=DARK, rim=True)}


def inset(style):
    """An inset's border, cut from a 20-unit square carved by carve(); the
    corners turn softly (a rounded box's depth)."""
    n, pad = 20.0, 1.0
    xx, yy = grid(n + 2 * pad, n + 2 * pad)
    xx, yy = xx - pad, yy - pad
    r = 1.2
    qx = np.maximum(np.minimum(xx, n - xx), 0)
    qy = np.maximum(np.minimum(yy, n - yy), 0)
    ex, ey = np.maximum(r - qx, 0), np.maximum(r - qy, 0)
    d = np.where((ex > 0) & (ey > 0), r - np.hypot(ex, ey), np.minimum(qx, qy))
    d = np.where((xx < 0) | (yy < 0) | (xx > n) | (yy > n), -1, d)
    pre = carve(d, **WELLS[style])
    k = K

    def cut(x0, y0, x1, y1):
        return pre[int(round((y0 + pad) * k)):int(round((y1 + pad) * k)), int(round((x0 + pad) * k)):int(round((x1 + pad) * k))]
    c, mid = INSET, n / 2
    return {
        "Inset" + style + "-TopLeftCorner": fit(cut(0, 0, c, c), (64, 64)),
        "Inset" + style + "-TopRightCorner": fit(cut(n - c, 0, n, c), (64, 64)),
        "Inset" + style + "-BottomLeftCorner": fit(cut(0, n - c, c, n), (64, 64)),
        "Inset" + style + "-BottomRightCorner": fit(cut(n - c, n - c, n, n), (64, 64)),
        "Inset" + style + "-TopEdge": fit(cut(mid - 0.5, 0, mid + 0.5, c), (16, 64)),
        "Inset" + style + "-BottomEdge": fit(cut(mid - 0.5, n - c, mid + 0.5, n), (16, 64)),
        "Inset" + style + "-LeftEdge": fit(cut(0, mid - 0.5, c, mid + 0.5), (64, 16)),
        "Inset" + style + "-RightEdge": fit(cut(n - c, mid - 0.5, n, mid + 0.5), (64, 16)),
    }


# --- the tabs -------------------------------------------------------------------
#
# The tabs have no art of their own (Window.lua): the chosen one is a plate of
# the replies' slate crowned by the dividers' vine (Scroll-RuleLeft and
# -RuleMid), the rest only labels. The mock draws them from those.

TAB_W, TAB_GAP, TAB_H = 69.0, 3.0, 25.6  # Window.lua's
VINE = os.path.join(OUT, "Scroll-%s-18.tga")  # ChatBar.lua's VERSION


def render():
    art = frame_pieces()
    for style in WELLS:
        art.update(inset(style))
    for state in ("Normal", "Pushed", "Highlight", "Disabled"):
        art["Close-" + state] = fit(close(state), (128, 128))
    return art


# --- the comparison sheet ---------------------------------------------------------
#
# The window as the game draws it, rebuilt at a 4K screen's own pixels from the
# written textures and Window.lua's layout, beside the shot it replaces
# (%LOCALAPPDATA%/wow-companion/shots/full4.png: the medium window at 1.5 scale,
# 2.7 px a unit, its top left at 28.8, 208.8; read in game with GetLeft/GetTop).
# Every edge is rounded to a whole pixel, as the game snaps a texture.

PX = 2.7
ORIGIN = (28.8, 208.8)
SIZE = (760.0, 520.0)
SHOT = os.path.join(os.environ.get("LOCALAPPDATA", ""), "wow-companion", "shots", "full4.png")
GLOW_SHOT = os.path.join(ROOT, "target", "glowshot.png")  # the focus glow's atlas drawn 1:1 on black
SLATE = os.path.join(ROOT, "addon", "WowCompanion", "Art", "%s-6.tga")  # Style.lua's STONE

# Window.lua's layout, in units
RIM, GAP, WELL_TOP, FOOT, WELL = 6.0, 4.0, 64.0, 20.0, 130.0
CLOSE_PAD = 3.0  # Window.lua: the close button's gap from the rim
GLOW = (14.0, 10.75, 13.0, 11.0)
EDGE = INSET
LABELS = ["Chat", "Settings", "Status", "Errands"]
# the well's top shadow (ShadowOverlay-Top, the lip), its alpha down from
# EDGE, read off the shot
LIP = ((0, 1.5, 3.0, 4.4, 5.9, 7.4, 8.9, 10.4, 11.9, 13.3, 16.3),
       (0.67, 0.57, 0.48, 0.40, 0.33, 0.24, 0.17, 0.12, 0.07, 0.02, 0))


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

    def tile(self, stem, x0, y0, x1, y1, k=1.0):
        """A stone tiled over the rect, a texel a screen pixel, times k."""
        a, b = self.px(x0, y0)
        c, d = self.px(x1, y1)
        src = np.asarray(Image.open(SLATE % stem).convert("RGB")).astype(float)
        reps = ((d - b) // src.shape[0] + 1, (c - a) // src.shape[1] + 1, 1)
        rgb = np.tile(src, reps)[:d - b, :c - a] * k
        im = np.concatenate([rgb, np.full(rgb.shape[:2] + (1,), 255.0)], -1)
        self.im.alpha_composite(Image.fromarray(np.clip(im, 0, 255).astype(np.uint8), "RGBA"), (a, b))

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


def mock(art, backdrop, chosen=0):
    w, h = SIZE
    m = Mock(backdrop)
    m.put((49, 45, 41, 255), 2, 21, w - 2, h - 2)  # the template's Bg
    m.put((33, 19, 10, 255), 2, 2, w - 2, 21)
    wells = (RIM + GAP, w - (RIM + GAP + WELL + GAP), w - (RIM + GAP + WELL), w - (RIM + GAP))
    top, foot = WELL_TOP, h - (RIM + FOOT)
    m.put((20, 21, 24, 255), wells[0], top, wells[1], foot)
    m.tile("SlateLight", wells[0] + EDGE, top + EDGE, wells[1] - EDGE, foot - EDGE)
    m.put((34, 28, 24, 255), wells[2], top, wells[3], foot)
    # the tabs' feet, left to right, the first over the well's inner edge
    xs = [wells[0] + EDGE + i * (TAB_W + TAB_GAP) for i in range(len(LABELS))]
    # the lip: the shadow down from the well's top wall
    x0, x1 = wells[0] + EDGE, wells[1] - EDGE - 30
    a, b = m.px(x0, top + EDGE)
    c, d = m.px(x1, top + EDGE + 24)
    yu = (np.arange(d - b) + 0.5) / PX
    lip = np.zeros((d - b, c - a, 4))
    lip[..., 3] = np.interp(yu, *LIP)[:, None] * 255
    m.im.alpha_composite(Image.fromarray(lip.astype(np.uint8), "RGBA"), (a, b))
    m.nine(art, "InsetA-", wells[0], top, wells[1], foot, INSET, INSET)
    m.nine(art, "InsetA-", wells[2], top, wells[3], foot, INSET, INSET)
    labels = []
    vine = {n: np.asarray(Image.open(VINE % n).convert("RGBA")).astype(float) for n in ("RuleLeft", "RuleMid")}
    for i, x in enumerate(xs):
        act = i == chosen
        if act:
            m.tile("SlateLight", x, top - TAB_H, x + TAB_W, top)
            y0 = top - TAB_H - 8
            m.put(vine["RuleLeft"], x - 4, y0, x + 28, y0 + 16)
            m.put(vine["RuleMid"], x + 28, y0, x + TAB_W - 28, y0 + 16)
            m.put(vine["RuleLeft"][:, ::-1], x + TAB_W - 28, y0, x + TAB_W + 4, y0 + 16)
        # PanelTemplates_SelectTab and _DeselectTab: the label's centre 12 and
        # 8 units over the foot
        labels.append((x + TAB_W / 2, top - (12 if act else 8), LABELS[i], (240, 230, 209) if act else (199, 163, 107)))
    m.glow(-GLOW[0], -GLOW[1], w + GLOW[2], h + GLOW[3])
    m.nine(art, "Frame-", 0, 0, w, h, RIM, TOP_H)
    cx, cy = w - RIM - CLOSE_PAD - CLOSE, (RIM + 22.6 - CLOSE) / 2
    m.put(art["Close-Normal"], cx, cy, cx + CLOSE, cy + CLOSE)
    draw = ImageDraw.Draw(m.im)
    font = ImageFont.truetype("arial.ttf", int(round(10 * PX)))
    for x, y, text, col in labels:
        draw.text(m.px(x, y), text, font=font, fill=col + (255,), anchor="mm", stroke_width=1, stroke_fill=(0, 0, 0, 255))
    return m.im.convert("RGB")


def stack(rows, path):
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
    out.save(path)
    return path


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
    second = mock(art, back, chosen=1)
    new.save(os.path.join(ROOT, "target", "frame-fix-4k.png"))
    # the tab row: the shot's, then ours with Chat and with Settings chosen,
    # each at 4K's own pixels and zoomed 3x; then the chosen tabs' joins at 8x
    box = (40, 300, 640, 440)
    up = lambda im, z: im.resize((im.width * z, im.height * z), Image.NEAREST)
    rows = []
    for im in (old, new, second):
        crop = im.crop(box)
        rows += [[crop], [up(crop, 3)]]
    return stack(rows, os.path.join(ROOT, "target", "tabs-sheet.png"))


def main():
    art = render()
    os.makedirs(OUT, exist_ok=True)
    for pat in ("Frame-*.tga", "Inset*-*.tga", "Close-*.tga"):
        for old in glob.glob(os.path.join(OUT, pat)):
            os.remove(old)
    for stem, img in art.items():
        write_tga(os.path.join(OUT, "%s-%d.tga" % (stem, VERSION)), img)
    print(len(art), "textures;", sheet(art))


if __name__ == "__main__":
    main()
