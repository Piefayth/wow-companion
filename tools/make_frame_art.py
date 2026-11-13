"""The Companion window's frame (Window.lua: ButtonFrameTemplate's border,
title bar and close button) and its wells' borders (InsetFrameTemplate),
drawn here as vector shapes, bevelled and lit from the top left, many samples
to a pixel and averaged down, never Blizzard's art.

    python tools/make_frame_art.py   writes addon/WowCompanion_Agent/Art/Frame-*-<v>.tga,
                                     Inset-*-<v>.tga, Close-*-<v>.tga,
                                     target/window-4k.png (the window mocked at 4K, its
                                     tabs and focus glow too) and target/window-top-4k.png
                                     (its top, Chat and then Settings chosen, and 3x zooms
                                     of the tabs' joins to the rim and the glow round them)

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
import artout
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage
from make_scrollbar_art import write_tga, LIGHT, HALF, FOCUS_GLOW

VERSION = 22
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


def shade(hgt, pal, k=K, gloss=0.35, power=18, out=None):
    """A height field's colour lit from the top left: the palette's shadow,
    mid and light by how the surface faces the light, a highlight on top.
    `out`, each point's outward direction (x, y) where the field is a rim,
    turns the light with it: every edge is lit as the top edge is, so a rim
    reads the same on all four sides and through every bend."""
    gy, gx = np.gradient(hgt, 1 / k)
    n = np.stack([-gx, -gy, np.ones_like(gx)], -1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    if out is None:
        light, half = LIGHT, HALF
    else:
        ox, oy = out[..., 0], out[..., 1]
        # LIGHT is -LIGHT[1] along the top edge's outward (0, -1) and LIGHT[0] along it (1, 0)
        light = np.stack([-LIGHT[1] * ox - LIGHT[0] * oy, -LIGHT[1] * oy + LIGHT[0] * ox, np.full_like(ox, LIGHT[2])], -1)
        half = light + np.array([0, 0, 1.0])
        half /= np.linalg.norm(half, axis=-1, keepdims=True)
    diff = np.clip(np.sum(n * light, -1), 0, 1)[..., None]
    flat = LIGHT[2]
    sh, mid, li = pal
    col = np.where(diff < flat, sh + (mid - sh) * (diff / flat), mid + (li - mid) * ((diff - flat) / (1 - flat)))
    spec = np.clip(np.sum(n * half, -1), 0, 1) ** power * gloss
    return np.clip(col + spec[..., None] * 255, 0, 255)


def outward(depth, k=K):
    """The outward direction of a depth field (x, y), smoothed over its creases."""
    gy, gx = np.gradient(depth, 1 / k)
    o = np.stack([ndimage.gaussian_filter(-gx, k * 0.15), ndimage.gaussian_filter(-gy, k * 0.15)], -1)
    return o / np.maximum(np.linalg.norm(o, axis=-1, keepdims=True), 1e-6)


def bead(u):
    """A rounded bead's height across it, u -1..1."""
    return np.sqrt(np.clip(1 - u * u, 0, 1))


def bar(u, w):
    """A bar of the rim's make: its height across it, u from 0 to w, shoulders
    1.1 wide, a slightly crowned top."""
    sh = np.clip(np.minimum(u, w - u) / 1.1, 0, 1)
    return (1 - (1 - sh) ** 2) * 0.9 + 0.15 * bead(np.clip(2 * u / w - 1, -1, 1))


def rim_metal(hgt, pal=BRONZE, k=K, out=None):
    """The rim's metal on a height field, k samples a unit: the tabs' trim
    is the same (make_tab_art.py)."""
    return shade(hgt, pal, k, gloss=0.22, power=14, out=out)


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


def rim_height(s):
    """The rim's height by depth s into it from its outer edge: one broad bar,
    a raised bead along its outer half (the lit ridge the game's rim has),
    its inner half lower and darker. The window's and the drawer's."""
    return np.where((s >= 0.45) & (s < 5.35), bar(s - 0.45, 4.9) * 0.75 + 0.6 * bead(np.clip((s - 2.0) / 1.25, -1, 1)), 0)


def rim_dark(s):
    """The dark line outside the rim and the lip inside it, by depth."""
    return np.clip(1 - s / 0.5, 0, 1) + np.clip((s - 5.35) / 0.5, 0, 1)


def frame():
    """The window's frame."""
    xx, yy = grid(N, N)
    s = octagon_depth(xx, yy, 0, 0, N, N, CHAMFER)  # into the rim from its outer edge
    lay = Layers(xx.shape)
    # the rim: a dark line, one broad bar with rounded shoulders (the one
    # toward the light lit), a dark lip down into the panel; the rule a
    # narrower bar of the same make, meeting the rim in a T. The metal is
    # brushed along its length: its grain a function of the depth alone, so
    # the edges stretch and the corners turn without a seam.
    hr = rim_height(s)
    rc, rh = (RULE[0] + RULE[1]) / 2, (RULE[1] - RULE[0]) / 2
    hrule = np.where((np.abs(yy - rc) < rh) & (s > 2.5), bar(yy - RULE[0], RULE[1] - RULE[0]) * 0.85, 0)
    hrule = np.where(hrule > hr, hrule, 0)  # the rim's bar runs over the rule's end
    hgt = ndimage.gaussian_filter(np.maximum(hr, hrule), K * 0.1)
    metal = (s >= 0) & (s < RIM) | (hrule > 0)
    out = np.where(((hrule > hr) | (s >= RIM))[..., None], np.array((0, -1.0)), outward(s))
    col = rim_metal(hgt, out=out)
    col = col * (1 + 0.09 * brushed(s))[..., None]
    rule = hrule > 0
    col = np.where(rule[..., None], col * (1 + 0.07 * brushed(yy, 5))[..., None], col)
    # the dark line outside, the lip inside, and the rule's edges, deepened
    edge_r = np.minimum(np.abs(yy - RULE[0]), np.abs(yy - RULE[1]))
    dark = np.where(rule, np.clip(1 - edge_r / 0.4, 0, 1), rim_dark(s))
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


DRAWER_VERSION = 24  # ConvMenu.lua's
DW, DH = 60.0, 60.0  # the drawn drawer, from the window's outer edge
DRULE = DH - RIM - 24.0  # the legend's rule (ConvMenu.lua's FOOT under it)
ELBOW = 11.0  # the radius the drawer's rims bend up and down into the window's by
WIRE = 1.4  # the volute's wire, its radius
JOIN = 24.0  # how far a joint piece reaches past the window's rim, out and up


def volute(cx, cy, r0, a0, hug, turns, shrink, sense=1, n=700):
    """A spiral from angle a0 at radius r0: r0 held for `hug` of a turn, then
    closing in by shrink a turn."""
    t = np.linspace(0, turns, n)
    a = np.radians(a0) + sense * 2 * np.pi * t
    r = r0 - shrink * np.clip(t - hug, 0, None)
    return np.stack([cx + r * np.cos(a), cy + r * np.sin(a)], 1)


def drawer():
    """The conversation menu's drawer (ConvMenu.lua; drawer round 9's 6, the
    player's pick, 2026-11-13), out of the window's right side: its own rim on
    three sides, the window rim's profile by depth inside the outline of
    window and drawer together, its inside corners rounded by ELBOW, so the
    drawer's top and bottom rims bend into the window's; in each bend a
    volute of wire hugging it. The legend's rule, the title rule's make,
    across it. Drawn with the window's rim at x 0..RIM (its outer edge at
    RIM), JOIN above and below the drawer for the elbows, and ELBOW + 4 past its right
    edge for the depth; returns the picture from y -JOIN, x 0."""
    from scipy.spatial import cKDTree
    k = K
    w = RIM + DW
    xx, yy = grid(w + ELBOW + 4, DH + 2 * JOIN, k)
    yy = yy - JOIN
    sw = RIM - xx  # into the window's rim from its outer edge
    box = (xx >= RIM - 1) & (xx < w) & (yy >= 0) & (yy < DH)
    box &= (w - xx + yy >= CHAMFER) & (w - xx + DH - yy >= CHAMFER)
    shape = (xx < RIM) | box
    grown = ndimage.distance_transform_edt(~shape) / k <= ELBOW
    shape = ndimage.distance_transform_edt(grown) / k > ELBOW
    sd = (ndimage.distance_transform_edt(shape) / k).astype(np.float32)
    # members by height, the higher showing where they overlap
    # and the way each faces, for its light (shade's out): the rims outward,
    # the rule and the wire as the top edge
    h = np.zeros(xx.shape)
    dark = np.zeros(xx.shape)
    grain = np.zeros(xx.shape)
    face = np.broadcast_to(np.array((0, -1.0)), xx.shape + (2,))
    m = np.zeros(xx.shape, bool)
    up = np.array((0, -1.0))

    def add(mask, hh, dd, gg, oo=up):
        nonlocal h, dark, grain, face, m
        won = mask & (~m | (hh > h))
        h, dark, grain = np.where(won, hh, h), np.where(won, dd, dark), np.where(won, gg, grain)
        face = np.where(won[..., None], oo, face)
        m = m | mask
    add((sw > 0) & (sw < RIM), rim_height(sw), rim_dark(sw), brushed(np.clip(sw, 0, N - 1)), np.array((1, 0.0)))
    add((sw <= 0) & (sd > 0) & (sd < RIM), rim_height(sd), rim_dark(sd), brushed(np.clip(sd, 0, N - 1)), outward(sd, k))
    u = yy - DRULE
    rule = (u >= 0) & (u < 3.0) & (xx >= RIM) & (sd > 2.5)
    add(rule, bar(np.clip(u, 0, 3.0), 3.0) * 0.85, np.clip(1 - np.minimum(u, 3.0 - u) / 0.4, 0, 1), brushed(u * 9, 5))
    # the volutes, round wire hugging each elbow's bend
    rad = ELBOW - WIRE - 0.4
    curls = [volute(RIM + ELBOW, cy, rad, a0, 0.3, 1.7, (rad - 1.6) / 1.4 * 0.75, sense=sense)
             for cy, a0, sense in ((-ELBOW, 90, 1), (DH + ELBOW, 270, -1))]
    dist, _ = cKDTree(np.concatenate(curls)).query(np.stack([xx.ravel(), yy.ravel()], 1), distance_upper_bound=WIRE + 1)
    d = np.where(np.isfinite(dist), WIRE - dist, -1).reshape(xx.shape)
    dd = np.clip(d, 0, WIRE)
    wire = d > 0
    add(wire, np.sqrt(dd * (2 * WIRE - dd)) / WIRE * 1.05 + 0.25, np.clip(1 - d / 0.45, 0, 1), brushed(np.clip(d * 6, 0, 59), 9))
    hgt = ndimage.gaussian_filter(h, k * 0.1)
    col = rim_metal(hgt, BRONZE, k, face) * (1 + 0.09 * grain)[..., None]
    col = col + (LINE - col) * np.clip(dark, 0, 0.9)[..., None]
    # the legend's band: the title band's dark slate, shadowed under the rule
    # and over the bottom rim
    band = (yy >= DRULE + 3.0) & (sd >= RIM) & (xx >= RIM)
    bcol = BAND * (1 + 0.06 * streaks(yy))[..., None]
    occl = np.maximum(np.exp(-(sd - RIM) / 0.9) * 0.75, np.exp(-(yy - DRULE - 3.0) / 0.6) * 0.45)
    bcol = bcol * (1 - np.clip(occl, 0, 0.8))[..., None]
    lay = Layers(xx.shape)
    # the volutes' shadow on what is behind them
    cast = ndimage.gaussian_filter(ndimage.shift(wire.astype(float), (0.8 * k, 0.6 * k), order=0), k * 0.7)
    lay.over(np.zeros(3), np.clip(cast, 0, 1) * 0.6 * ~m)
    lay.over(np.where(band[..., None], bcol, col), (m | band).astype(float))
    return lay.pre()[:, :int(round(w * k))]


def drawer_pieces():
    """The drawer's pieces: each joint holds the window's rim beside it (put
    over the window's own) and its elbow and volute, above or below the
    drawer; the rest as the frame's are."""
    pre = drawer()
    k = K

    def cut(x0, y0, x1, y1):
        return pre[int(round((y0 + JOIN) * k)):int(round((y1 + JOIN) * k)), int(round(x0 * k)):int(round(x1 * k))]
    c, w, mid = RIM, RIM + DW, RIM + DW / 2
    return {
        "Drawer-TopJoin": fit(cut(0, -JOIN, c + JOIN, c), (128, 128)),
        "Drawer-BottomJoin": fit(cut(0, DH - c, c + JOIN, DH + JOIN), (128, 128)),
        "Drawer-TopEdge": fit(cut(mid - 1, 0, mid + 1, c), (16, 64)),
        "Drawer-BottomEdge": fit(cut(mid - 1, DH - c, mid + 1, DH), (16, 64)),
        "Drawer-TopRightCorner": fit(cut(w - c, 0, w, c), (64, 64)),
        "Drawer-BottomRightCorner": fit(cut(w - c, DH - c, w, DH), (64, 64)),
        "Drawer-RightEdge": fit(cut(w - c, c + 4, w, c + 6), (64, 16)),
        "Drawer-RightRule": fit(cut(w - c, DRULE, w, DRULE + 3.0), (64, 32)),
        "Drawer-Rule": fit(cut(mid - 1, DRULE, mid + 1, DRULE + 3.0), (16, 32)),
        "Drawer-Band": fit(cut(mid - 1, DRULE + 3.0, mid + 1, DH - c), (16, 256)),
    }


# --- the close button ----------------------------------------------------------

CLOSE = 14.0  # its side: it sits inside the title band (16.6 tall under the rim)
BRASS = (np.array((62, 42, 16.0)), np.array((150, 114, 52.0)), np.array((214, 186, 120.0)))  # aged, not new gold


def close(state):
    """The close button, 14 units, inside the title band: no plate of its own,
    only a cross of aged brass struck into the band's dark leather, with a dark outline and the shadow it casts. Pushed
    sinks and dims it; Highlight is a soft light behind it in the focus
    glow's colour, for ADD
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
        lay.over(np.array(FOCUS_GLOW, float), np.clip(1 - r / (CLOSE / 2), 0, 1) ** 1.5 * 0.35)
        lay.over(np.array(FOCUS_GLOW, float), np.clip((cross(xx, yy) + 1.2) / 1.2, 0, 1) * 0.25)
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
LINE_IN = np.array((5, 4, 3.0))  # the crease at the wall's top
WALL_FOOT = 3.3  # where the wall meets the floor, its contact shadow on to INSET


# The wells' border (the player's pick of seven, 2026-11-12): quiet stone, lit
# just enough to have form, so neither the bar's lit edge nor the wall turned
# from the light stands out, and no dark line anywhere inside it
BAR_STONE = (np.array((16, 16, 19.0)), np.array((30, 31, 35.0)), np.array((54, 55, 60.0)))
WALL_STONE = (np.array((15, 16, 19.0)), np.array((24, 25, 28.0)), np.array((40, 41, 46.0)))
BAR_W = 1.1  # the bar along the well's edge, in units


def carve(d, k=K):
    """A well's border painted on a depth field d (units into the cavity from
    its edge, negative outside): a bar of the window's rim's make in grey stone
    along the edge, a dark line where the panel breaks outside it, then a
    rounded wall carved down to the floor, lit by the frame's light, and a
    soft contact shadow onto the floor. Blurred a quarter unit, so no line is
    razor sharp."""
    lay = Layers(d.shape)
    inside = (d >= 0).astype(float)
    top = 0.35
    # the wall's height: the panel's level at its top, the floor's at its
    # foot, rounded over at the lip as worn stone is
    t = np.clip((d - top) / (WALL_FOOT - top), 0, 1)
    hgt = 1.6 * (1 - t) ** 1.6
    col = shade(ndimage.gaussian_filter(hgt, k * 0.15), WALL_STONE, k, gloss=0.0, power=10)
    lay.over(col, ((d >= 0) & (d < WALL_FOOT + 0.2)).astype(float))
    lay.over(LINE_IN, np.clip(1 - np.abs(d - 0.12) / 0.22, 0, 1) * inside * 0.9)
    # the bar: the rim's shoulders, brushed, the dark line outside it
    u = np.clip(d / BAR_W, 0, 1)
    sh = np.clip(np.minimum(d, BAR_W - d) / 0.5, 0, 1)
    bh = ndimage.gaussian_filter(((1 - (1 - sh) ** 2) * 0.9 + 0.15 * bead(2 * u - 1)) * (d < BAR_W), k * 0.08)
    col = shade(bh, BAR_STONE, k, gloss=0.04, power=14) * (1 + 0.09 * brushed(d * 8))[..., None]
    lay.over(col, ((d >= 0) & (d < BAR_W)).astype(float))
    lay.over(LINE, np.clip(1 - d / 0.25, 0, 1) * inside * 0.9)
    lay.over(np.zeros(3), np.where(d > WALL_FOOT, np.clip(1 - (d - WALL_FOOT) / (INSET - WALL_FOOT), 0, 1) * 0.45, 0))
    pre = lay.pre()
    return np.stack([ndimage.gaussian_filter(pre[..., i], k * 0.25) for i in range(4)], -1)


def inset():
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
    pre = carve(d)
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
    art.update(drawer_pieces())
    art.update(inset())
    for state in ("Normal", "Pushed", "Highlight", "Disabled"):
        art["Close-" + state] = fit(close(state), (128, 128))
    return art


# --- the mock ------------------------------------------------------------------------
#
# The window as the game draws it, rebuilt at a 4K screen's own pixels from the
# written textures and Window.lua's layout, over the world from a shot
# (%LOCALAPPDATA%/wow-companion/shots/full4.png: the medium window at 1.5 scale,
# 2.7 px a unit, its top left at 28.8, 208.8; read in game with GetLeft/GetTop),
# with the controller's focus glow on. Every edge is rounded to a whole pixel,
# as the game snaps a texture. Drawn in the game's order: the glow (a level
# under the tabs, its top edge cut either side of the chosen tab's glow), the
# panel and the tabs, then the rim over the tabs' feet and the wells.

PX = 2.7
ORIGIN = (28.8, 208.8)
SIZE = (760.0, 520.0)
SHOT = os.path.join(os.environ.get("LOCALAPPDATA", ""), "wow-companion", "shots", "full4.png")
SLATE = os.path.join(ROOT, "addon", "WowCompanion", "Art", "%s-6.tga")  # Style.lua's STONE
GLOW_ART = os.path.join(OUT, "Focus-%s-1.tga")  # make_focus_art.py's: Glow and Tab, -<style> after either
TAB_ART = os.path.join(OUT, "Tab-%s-3.tga")  # make_tab_art.py's

# Window.lua's layout, in units
RIM, GAP, FOOT, WELL = 6.0, 7.0, 20.0, 130.0
WELL_TOP = 25.6 + GAP  # the rule's foot, then GAP, as at the sides
CLOSE_PAD = 3.0  # the close button's gap from the rim
PLAQUE_W, PLAQUE_H, PLAQUE_UP, TABS_X, STEP = 80.0, 34.0, 30.0, 18.0, 80.0
IDLE_HEAD, CHOSEN_HEAD = 7.0, 2.0
NAME, NAME_LIT = (199, 176, 135), (250, 235, 199)
# FocusArt.lua: the glow's 9-slice, its margins M units, set out OUT past the frame;
# the chosen tab's glow, TAB_GLOW units, set out from its plaque's piece
GLOW_M, GLOW_OUT, GLOW_TEX, GLOW_MARGIN = 18.0, 12.0, 128, 48
TAB_GLOW, TAB_GLOW_LEFT, TAB_GLOW_UP = (96.0, 48.0), 8.0, 12.0
EDGE = INSET
LABELS = ["Chat", "Settings", "Status", "Errands"]
# the well's top shadow (ShadowOverlay-Top, the lip), its alpha down from
# EDGE, read off the shot
LIP = ((0, 1.5, 3.0, 4.4, 5.9, 7.4, 8.9, 10.4, 11.9, 13.3, 16.3),
       (0.67, 0.57, 0.48, 0.40, 0.33, 0.24, 0.17, 0.12, 0.07, 0.02, 0))


def load(path):
    return np.asarray(Image.open(path).convert("RGBA")).astype(float)


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

    def glow(self, w, h, tab_x, style=""):
        """FocusArt.lua's glow in a style ("" or "-A".."-E"): Focus-Glow cut
        in nine, round the frame's bounds set out by GLOW_OUT, its corners
        GLOW_M square; its top edge in two runs either side of Focus-Tab on
        the chosen plaque's piece, at tab_x."""
        tex = load(GLOW_ART % ("Glow" + style))
        t = (0, GLOW_MARGIN, GLOW_TEX - GLOW_MARGIN, GLOW_TEX)
        o, m = GLOW_OUT, GLOW_M
        xs = (-o, m - o, w - m + o, w + o)
        ys = (-o, m - o, h - m + o, h + o)
        gx0, gx1 = tab_x - TAB_GLOW_LEFT, tab_x - TAB_GLOW_LEFT + TAB_GLOW[0]
        for j in range(3):
            for i in range(3):
                piece = tex[t[j]:t[j + 1], t[i]:t[i + 1]]
                if i == 1 and j == 0:
                    self.put(piece, xs[1], ys[0], gx0, ys[1])
                    self.put(piece, gx1, ys[0], xs[2], ys[1])
                elif i != 1 or j != 1:
                    self.put(piece, xs[i], ys[j], xs[i + 1], ys[j + 1])
        top = -PLAQUE_UP - TAB_GLOW_UP
        self.put(load(GLOW_ART % ("Tab" + style)), gx0, top, gx1, top + TAB_GLOW[1])


def mock(art, backdrop, chosen=0, style=""):
    w, h = SIZE
    m = Mock(backdrop)
    m.glow(w, h, TABS_X + chosen * STEP, style)
    m.tile("Slate", RIM, RIM, w - RIM, h - RIM, 0.72)  # the panel's body (frame.Bg)
    piece = {k: load(TAB_ART % k) for k in ("Idle", "Chosen")}
    labels = []
    for i, text in enumerate(LABELS):
        x, act = TABS_X + i * STEP, i == chosen
        m.put(piece["Chosen" if act else "Idle"], x, -PLAQUE_UP, x + PLAQUE_W, PLAQUE_H - PLAQUE_UP)
        head = CHOSEN_HEAD if act else IDLE_HEAD
        labels.append((x + PLAQUE_W / 2, -(PLAQUE_UP - head) / 2, text, NAME_LIT if act else NAME))
    m.nine(art, "Frame-", 0, 0, w, h, RIM, TOP_H)
    wells = (RIM + GAP, w - (RIM + GAP + WELL + GAP), w - (RIM + GAP + WELL), w - (RIM + GAP))
    top, foot = WELL_TOP, h - (RIM + FOOT)
    m.tile("SlateLight", wells[0] + EDGE, top + EDGE, wells[1] - EDGE, foot - EDGE)
    m.tile("Slate", wells[2] + EDGE, top + EDGE, wells[3] - EDGE, foot - EDGE)
    # the lip: the shadow down from the well's top wall
    x0, x1 = wells[0] + EDGE, wells[1] - EDGE - 30
    a, b = m.px(x0, top + EDGE)
    c, d = m.px(x1, top + EDGE + 24)
    yu = (np.arange(d - b) + 0.5) / PX
    lip = np.zeros((d - b, c - a, 4))
    lip[..., 3] = np.interp(yu, *LIP)[:, None] * 255
    m.im.alpha_composite(Image.fromarray(lip.astype(np.uint8), "RGBA"), (a, b))
    m.nine(art, "Inset-", wells[0], top, wells[1], foot, INSET, INSET)
    m.nine(art, "Inset-", wells[2], top, wells[3], foot, INSET, INSET)
    cx, cy = w - RIM - CLOSE_PAD - CLOSE, (RIM + 22.6 - CLOSE) / 2
    m.put(art["Close-Normal"], cx, cy, cx + CLOSE, cy + CLOSE)
    draw = ImageDraw.Draw(m.im)
    # GameFontNormal at 12 units, its 1-unit drop shadow (Arial for Friz Quadrata)
    font = ImageFont.truetype("arial.ttf", int(round(12 * PX)))
    for x, y, text, col in labels:
        sx, sy = m.px(x, y)
        draw.text((sx + PX, sy + PX), text, font=font, fill=(0, 0, 0, 255), anchor="mm")
        draw.text((sx, sy), text, font=font, fill=col + (255,), anchor="mm")
    title = m.px(w / 2, (RIM + 22.6) / 2)
    draw.text(title, "Companion", font=font, fill=(230, 201, 140, 255), anchor="mm")
    return m.im.convert("RGB")


def backdrop():
    """The shot with the old window and its glow covered by the world from
    the screen's right, so nothing of the old frame shows."""
    old = Image.open(SHOT).convert("RGB")
    back = old.copy()
    world = old.crop((2300, 300, 3800, 1900))
    for x in range(0, 2300, world.width):
        for y in range(0, 1830, world.height):
            back.paste(world, (x, y + 100))
    return back


def sheet(art):
    back = backdrop()
    full = mock(art, back)
    full.save(os.path.join(ROOT, "target", "window-4k.png"))
    # the window's top at 4K's own pixels, Chat and then Settings chosen; then
    # 3x: the chosen plaque and its glow, and the joins of the plaques to the rim
    box = (0, 70, 1300, 400)
    up = lambda im: im.resize((im.width * 3, im.height * 3), Image.NEAREST)
    second = mock(art, back, chosen=1)
    rows = [[full.crop(box)], [second.crop(box)]]
    x0, x1 = (int(ORIGIN[0] + (TABS_X + i * STEP) * PX) for i in (1, 2))
    y = int(ORIGIN[1])
    rows.append([up(second.crop((x0 - 40, y - 115, x1 + 40, y + 25)))])
    rows.append([up(second.crop((x - 50, y - 50, x + 50, y + 22))) for x in (x0 + 8, x1, x1 + int(STEP * PX))])
    return stack(rows, os.path.join(ROOT, "target", "window-top-4k.png"))


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


def main():
    art = render()
    os.makedirs(OUT, exist_ok=True)
    artout.clear(OUT, "Frame-*.tga", "Drawer-*.tga", "Inset-*.tga", "Close-*.tga")
    for stem, img in art.items():
        v = DRAWER_VERSION if stem.startswith("Drawer-") else VERSION
        write_tga(os.path.join(OUT, "%s-%d.tga" % (stem, v)), img)
    print(len(art), "textures;", sheet(art))


if __name__ == "__main__":
    main()
