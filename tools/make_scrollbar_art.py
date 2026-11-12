"""The chat's scroll bar (ChatBar.lua): a groove carved in the stone between
two bark borders, fleur-de-lis arrows in bark over its ends, a heartwood thumb,
and the dividers between turns joining its left border; drawn here as vector
shapes, bevelled and lit from the top left, at 16x and averaged down, never
Blizzard's art.

    python tools/make_scrollbar_art.py   writes addon/WowCompanion_Agent/Art/Scroll-*-<VERSION>.tga

The game keeps a texture for the session under its path, so a change bumps
VERSION (and ChatBar.lua's); older files are deleted.
"""
import glob
import os
import struct
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

S = 16  # supersampling
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "addon", "WowCompanion_Agent", "Art")
LIGHT = np.array([-0.55, -0.75, 0.9]); LIGHT /= np.linalg.norm(LIGHT)
HALF = LIGHT + np.array([0, 0, 1.0]); HALF /= np.linalg.norm(HALF)

OUTLINE = (10, 7, 4)


def write_tga(path, rgba):
    h, w = rgba.shape[:2]
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 8 | 0x20)
    bgra = rgba[:, :, [2, 1, 0, 3]].astype(np.uint8)
    with open(path, "wb") as f:
        f.write(header + bgra.tobytes())


class Canvas:
    """A w x h picture in final pixels, drawn at self.s times with `pad` pixels of
    room on every side (shapes running off the edge, such as a rod, continue
    into it so they get no bevel where they are cut)."""

    def __init__(self, w, h, pad=6, s=S):
        self.w, self.h, self.pad, self.s = w, h, pad, s
        self.W, self.H = (w + 2 * pad) * s, (h + 2 * pad) * s
        self.rgb = np.zeros((self.H, self.W, 3))
        self.a = np.zeros((self.H, self.W))

    def xy(self, pts):
        return [((x + self.pad) * self.s, (y + self.pad) * self.s) for x, y in pts]

    def mask(self, polys=(), circles=(), ellipses=(), holes=()):
        m = Image.new("L", (self.W, self.H), 0)
        d = ImageDraw.Draw(m)
        for p in polys:
            d.polygon(self.xy(p), fill=255)
        for cx, cy, r in circles:
            (x0, y0), (x1, y1) = self.xy([(cx - r, cy - r), (cx + r, cy + r)])
            d.ellipse([x0, y0, x1, y1], fill=255)
        for cx, cy, rx, ry in ellipses:
            (x0, y0), (x1, y1) = self.xy([(cx - rx, cy - ry), (cx + rx, cy + ry)])
            d.ellipse([x0, y0, x1, y1], fill=255)
        for cx, cy, r in holes:
            (x0, y0), (x1, y1) = self.xy([(cx - r, cy - r), (cx + r, cy + r)])
            d.ellipse([x0, y0, x1, y1], fill=0)
        return np.asarray(m, dtype=float) / 255

    def over(self, rgb, a):
        a = a[..., None]
        out_a = a + self.a[..., None] * (1 - a)
        self.rgb = np.where(out_a > 0, (rgb * a + self.rgb * self.a[..., None] * (1 - a)) / np.maximum(out_a, 1e-6), 0)
        self.a = out_a[..., 0]

    def metal(self, m, pal, bevel=1.6, outline=0.8, shadow=True, dome=False, gloss=0.55, sheen=True, glow=True,
              paint=False, grain=True):
        """A raised piece: its outline and drop shadow under it, then the face
        shaded from a height field (a bevel `bevel` px wide, or a dome).
        paint: Blizzard's painted metal instead of clean vector metal: a dark
        warm edge rather than a black line, grain and wear in the face, a broad
        soft speculars, a little colour taken out; grain=False leaves out the
        grain (pieces that must meet another texture seamlessly)."""
        inside = m > 0.5
        if shadow:
            sh = ndimage.shift(ndimage.gaussian_filter(m, self.s * 0.7), (self.s * 0.9, self.s * 0.6), order=1)
            self.over(np.zeros_like(self.rgb), sh * 0.55)
        if outline:
            o = ndimage.gaussian_filter(ndimage.maximum_filter(m, size=int(outline * 2 * self.s) | 1), self.s * 0.25)
            edge = (22, 14, 7) if paint else OUTLINE
            self.over(np.broadcast_to(np.array(edge, float), self.rgb.shape), o * (0.8 if paint else 0.95))
        d = ndimage.distance_transform_edt(inside) / self.s
        if dome:
            r = d / max(d.max(), 1e-6)
            hgt = np.sqrt(np.clip(1 - (1 - r) ** 2, 0, 1)) * d.max()
        else:
            t = np.clip(d / bevel, 0, 1)
            hgt = (1 - (1 - t) ** 2) * bevel
        hgt = ndimage.gaussian_filter(hgt, self.s * 0.18)
        gy, gx = np.gradient(hgt * self.s)
        n = np.stack([-gx, -gy, np.ones_like(gx)], -1)
        n /= np.linalg.norm(n, axis=-1, keepdims=True)
        diff = np.clip(n @ LIGHT, 0, 1)
        spec = np.clip(n @ HALF, 0, 1) ** (10 if paint else 28) * gloss
        sh_c, mid_c, li_c = (np.array(c, float) for c in pal)
        # a top-to-bottom sheen on the flat face, as polished metal shows
        ys = np.linspace(0, 1, self.H)[:, None, None]
        flat = 0.577
        k = diff[..., None]
        col = np.where(k < flat, sh_c + (mid_c - sh_c) * (k / flat), mid_c + (li_c - mid_c) * ((k - flat) / (1 - flat)))
        if sheen:  # never on a rod: its tile would band where it repeats
            col = col * (1.08 - 0.22 * ys)
        if paint:
            grain = self.grain() if grain else np.zeros(self.a.shape)
            wear = np.clip(1 - d / 1.2, 0, 1) * np.clip(diff - 0.6, 0, 1) * 0.5  # lit edges rubbed bright
            col = col * (1 + grain[..., None]) + wear[..., None] * (li_c - mid_c)
            grey = col @ np.array([0.3, 0.59, 0.11])
            col = col * 0.85 + grey[..., None] * 0.15
        col = col + spec[..., None] * (200 if paint else 255)
        if dome and glow:  # light caught inside the stone, bottom right
            yy, xx = np.mgrid[0:self.H, 0:self.W]
            cy, cx = ndimage.center_of_mass(inside)
            rad = np.sqrt(inside.sum() / np.pi)
            glow = np.clip(1 - np.hypot(yy - cy - rad * 0.35, xx - cx - rad * 0.35) / (rad * 0.8), 0, 1) ** 2
            col = col + glow[..., None] * (li_c - mid_c) * 0.7
        self.over(np.clip(col, 0, 255), m)

    def grain(self):
        """The canvas's one grain, three scales of noise, made at the final
        size and enlarged (made at the drawn size it cost minutes)."""
        if not hasattr(self, "_grain"):
            rng = np.random.default_rng(7)
            small = (self.H // self.s, self.W // self.s)
            g = [ndimage.gaussian_filter(rng.standard_normal(small), k) for k in (0.5, 2.0, 6.0)]
            g = sum(w * x / x.std() for w, x in zip((0.07, 0.09, 0.08), g))
            self._grain = ndimage.zoom(g, self.s, order=1)[:self.H, :self.W]
        return self._grain

    def final(self):
        p = self.pad * self.s
        rgb = self.rgb[p:self.H - p, p:self.W - p]
        a = self.a[p:self.H - p, p:self.W - p]
        h, w = self.h, self.w
        pre = (rgb * a[..., None]).reshape(h, self.s, w, self.s, 3).mean((1, 3))
        al = a.reshape(h, self.s, w, self.s).mean((1, 3))
        out = np.zeros((h, w, 4))
        out[..., :3] = np.where(al[..., None] > 0, pre / np.maximum(al[..., None], 1e-6), 0)
        out[..., 3] = al * 255
        return np.clip(out, 0, 255)


# --- the bar: a groove carved into the stone between two borders, the arrows
# rising out of the groove's ends where the borders close round it, the
# dividers joining the left border (docs/proposals/scrollbar-concepts.md)
#
# In UI units, U texture px each; every piece is 32 units wide and centred on
# the column (20 wide, x 6..26), the groove x 12..20, its borders' centres x
# 11.1 and 20.9:
#   <Up|Down>-<state> 32x32: the button, the arrow over the groove's end, its
#     borders closing round it (the groove runs on out of the far edge)
#   Mid 32x8: the groove and its borders, stretched between the buttons
#   Thumb-Top, Thumb-Mid (stretched), Thumb-Centre 32x16, Thumb-Bottom 32x8
#   Joint 32x16: a divider (its line at y 8) from x 0, the column's left edge
#     less 6, to the left border; past the right border, on to the column's edge
#   RuleLeft 32x16, RuleMid 64x16: the divider's left end and its line,
#     stretched whole to the Joint

VERSION = 18
PRESS = 1.25  # how far a pressed arrow sinks toward the groove, in units
GT = 24.0  # the arrows' groove end (its round end's centre)
FOOT = GT - 4.0 - PRESS  # an arrow's foot: under the border's arc, pressed or not
U = 4
SS = 4
GX0, GX1 = 12, 20
RAIL = (11.1, 20.9)  # the borders' centres
ARC = 16 - RAIL[0]  # their radius round the groove's end

# muted and warm, as Blizzard's own UI wood and metal (read off the game's
# atlases drawn in a frame of ours), the lights never white
BARK = ((22, 15, 9), (68, 48, 30), (138, 108, 74))
BUD = ((20, 22, 15), (62, 68, 48), (128, 132, 100))  # olive-grey, the green all but gone
WARM = np.array((255, 208, 128), float)
FLOOR = (31, 30, 33)  # the groove floor's middle: the slate itself in shadow, cool as it is


def ucanvas(w, h):
    return Canvas(w * U, h * U, pad=8, s=SS)


def profile(pts, cx=16):
    """A shape symmetric about x = cx from (y, half-width) knots, smoothed."""
    from scipy.interpolate import PchipInterpolator
    ys = np.array([p[0] for p in pts], float)
    f = PchipInterpolator(ys, [p[1] for p in pts])
    yy = np.linspace(ys[0], ys[-1], 200)
    hw = np.maximum(f(yy), 0)
    return [(cx + w, y) for y, w in zip(yy, hw)] + [(cx - w, y) for y, w in zip(yy[::-1], hw[::-1])]


def ribbon(path, hw):
    """A path as a polygon `hw` wide either side (per point or one)."""
    p = np.asarray(path, float)
    hw = np.broadcast_to(np.asarray(hw, float), (len(p),))
    d = np.gradient(p, axis=0)
    d /= np.maximum(np.linalg.norm(d, axis=1, keepdims=True), 1e-9)
    n = np.stack([-d[:, 1], d[:, 0]], 1)
    return [tuple(q) for q in p + n * hw[:, None]] + [tuple(q) for q in (p - n * hw[:, None])[::-1]]


def bez(*pts, n=40):
    """A cubic Bezier through four points."""
    p0, p1, p2, p3 = (np.array(q, float) for q in pts)
    t = np.linspace(0, 1, n)[:, None]
    return (1 - t) ** 3 * p0 + 3 * (1 - t) ** 2 * t * p1 + 3 * (1 - t) * t ** 2 * p2 + t ** 3 * p3


def curl(start, tangent, r0, turns, shrink=0.35, n=90):
    """A spiral leaving `start` along `tangent`, turning by `turns` (positive:
    clockwise on screen) and tightening to r0 * shrink."""
    t = np.array(tangent, float); t /= np.linalg.norm(t)
    nrm = np.array([-t[1], t[0]]) * np.sign(turns)
    centre = np.array(start, float) + nrm * r0
    a0 = np.arctan2(*(np.array(start) - centre)[::-1])
    a = a0 + np.linspace(0, turns * 2 * np.pi, n)
    r = r0 * (1 - (1 - shrink) * np.linspace(0, 1, n) ** 0.8)
    return np.stack([centre[0] + r * np.cos(a), centre[1] + r * np.sin(a)], 1)


def scroll(lead, r0, turns, shrink=0.35):
    """A lead (points) running on into a curl at its end."""
    lead = np.asarray(lead, float)
    return np.vstack([lead, curl(lead[-1], lead[-1] - lead[-2], r0, turns, shrink)[1:]])


def stroke(path, w0, w1, knob=True):
    """A line thinning from half-width w0 to w1, a round knob at its thin end."""
    p = np.asarray(path, float)
    out = [ribbon(p, np.linspace(w0, w1, len(p)))]
    if knob:
        out.append((p[-1][0], p[-1][1], w1 * 1.3))
    return out


def leaf(base, tip, width, n=40):
    """A pointed leaf from base to tip, `width` across at its widest."""
    b, t = np.array(base, float), np.array(tip, float)
    d = t - b; L = np.linalg.norm(d); d /= L
    nrm = np.array([-d[1], d[0]])
    s = np.linspace(0, 1, n)
    hw = width / 2 * np.sin(np.pi * s ** 0.8) ** 1.1
    return [tuple(b + d * L * k + nrm * w) for k, w in zip(s, hw)] + \
           [tuple(b + d * L * k - nrm * w) for k, w in zip(s[::-1], hw[::-1])]


def X(sgn, x):
    """x mirrored to the left side of the groove's centre when sgn is -1."""
    return 16 + sgn * (x - 16)


def pair(sgn_fn):
    """Both sides of a shape drawn for the right (sgn 1)."""
    return [p for sgn in (1, -1) for p in sgn_fn(sgn)]


class Pen:
    """Draws in units on a canvas as the up end has them: flip mirrors y about
    h (the down end, its light still from the top left), dy moves the shapes
    toward the groove (a pressed button)."""

    def __init__(self, c, h, flip=False, dy=0.0):
        self.c, self.h, self.flip, self.dy = c, h, flip, dy

    def y(self, y):
        return self.h - (y + self.dy) if self.flip else y + self.dy

    def mask(self, pieces):
        polys = [[(x * U, self.y(y) * U) for x, y in p] for p in pieces if not isinstance(p, tuple)]
        circles = [(p[0] * U, self.y(p[1]) * U, p[2] * U) for p in pieces if isinstance(p, tuple)]
        return self.c.mask(polys, circles=circles)


def shadow(c, m, k=0.55):
    """A soft shadow of `m` cast down and right onto what is under it."""
    s = U * c.s
    sh = ndimage.shift(ndimage.gaussian_filter(m, s * 0.35), (s * 0.45, s * 0.3), order=1)
    c.over(np.zeros_like(c.rgb), np.clip(sh, 0, 1) * k)


def raised(pen, pieces, pal, bevel=1.0, cast=0.55, **kw):
    """Pieces of one raised metal, painted as Blizzard paints it."""
    m = pen.mask(pieces)
    if cast:
        shadow(pen.c, m, cast)
    kw.setdefault("gloss", 0.35)
    pen.c.metal(m, pal, bevel=bevel * U, outline=1.1, shadow=False, sheen=False, paint=True, **kw)
    return m


def dim(pal, k):
    return tuple(tuple(int(x * k) for x in col) for col in pal)


def carve(c, m, depth=1.0):
    """A recess where `m` is: dark floor, the top-left wall in shadow, the
    bottom-right wall faintly lit (measured against Blizzard's minimal track)."""
    k = U * c.s
    du = ndimage.distance_transform_edt(m > 0.5) / k
    t = np.clip(du / depth, 0, 1)
    h = ndimage.gaussian_filter(-(1 - (1 - t) ** 2) * depth * U * 1.3, k * 0.18, mode="nearest")
    gy, gx = np.gradient(h * c.s)
    n = np.stack([-gx, -gy, np.ones_like(gx)], -1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    shade = n @ LIGHT - LIGHT[2]
    pale = np.broadcast_to(np.array((205, 196, 178), float), c.rgb.shape)
    c.over(np.broadcast_to(np.array((14, 12, 10), float), c.rgb.shape), m)
    # the floor is stone in shadow, not a void: the black lifting toward the
    # slate's own colour in the middle of the dish
    lift = np.clip((du - 0.6) / 2.4, 0, 1) ** 1.5
    c.over(np.broadcast_to(np.array(FLOOR, float), c.rgb.shape), m * lift)
    c.over(np.zeros_like(c.rgb), m * np.clip(-shade * 5, 0, 1) * 0.9)
    c.over(pale, m * np.clip(shade * 3.0, 0, 1) * 0.5)


def groove_end(pen, gt=GT):
    """The groove from its round end (centred at y gt) out of the far edge."""
    return pen.mask([[(GX0, gt), (GX1, gt), (GX1, pen.h + 20), (GX0, pen.h + 20)], (16, gt, (GX1 - GX0) / 2)])


def groove_run(c):
    """The groove through a whole piece, both ends running off it."""
    return c.mask([[(GX0 * U, -40), (GX1 * U, -40), (GX1 * U, c.h + 40), (GX0 * U, c.h + 40)]])


def deep(c, flip, h=32):
    """How far into the groove's shadow each pixel is (0..1): nothing over
    the groove's round end, then a hard shadow straight across, then dark."""
    yy = (np.arange(c.H)[:, None] / c.s - c.pad) / U
    depth = (yy if not flip else h - yy) - GT + (GX1 - GX0) / 2 * 0.4
    k = np.where(depth > 0, 0.55 + 0.45 * np.clip(depth / 3, 0, 1), 0)
    return k * groove_run(c)


def sink(c, pen, under):
    """What lies in the groove below its end's lip goes down into the dark."""
    m = deep(c, pen.flip, pen.h)[..., None]
    c.rgb = c.rgb * (1 - m) + under * m


def glint(c, pen, x, y, r=1.6, k=0.7):
    """A soft warm light on the metal at (x, y): the one bright spot."""
    yy, xx = np.mgrid[0:c.H, 0:c.W]
    cx, cy = (x * U + c.pad) * c.s, (pen.y(y) * U + c.pad) * c.s
    g = np.clip(1 - np.hypot(xx - cx, yy - cy) / (r * U * c.s), 0, 1) ** 2
    c.over(np.broadcast_to(WARM, c.rgb.shape), g * np.clip(c.a, 0, 1) * k)


# --- the groove's borders: straight down a Mid; in a cap closing over the
# groove's round end. No grain: a cap's borders and the Mid's meet seamlessly.

def border_path(pen, gt=GT):
    """The borders as one line: up the left, over the groove's end, down the right."""
    far = pen.h + 12
    th = np.linspace(np.pi, 0, 60)
    arc = np.stack([16 + ARC * np.cos(th), gt - ARC * np.sin(th)], 1)
    return np.vstack([[(RAIL[0], far), (RAIL[0], gt + 2)], arc, [(RAIL[1], gt + 2), (RAIL[1], far)]])


def straight_borders(pen):
    return [ribbon([(x, -12), (x, pen.h + 12)], BORDER_HW) for x in RAIL]


BORDER_HW = 0.9


def border(pen, pieces):
    return raised(pen, pieces, BARK, bevel=0.6, cast=0.4, grain=False)


# --- the arrow: a fleur-de-lis, a slim petal and four volutes over a twisted collar, in bark

def twist_marks(c, pen, y0, y1, hw):
    """The twist: a square bar's faces turning, as broad slanted bands."""
    bar = pen.mask([[(16 - hw, y0), (16 + hw, y0), (16 + hw, y1), (16 - hw, y1)]])
    dark, light = [], []
    step = 2.0 * hw / 1.45
    for y in np.arange(y0 - 1.2, y1 - 0.4, step):
        dark.append([(16 - hw, y + 0.9), (16 + hw, y - 0.5), (16 + hw, y + 0.5), (16 - hw, y + 1.9)])
        light.append([(16 - hw, y + 1.75), (16 + hw, y + 0.35), (16 + hw, y + 0.65), (16 - hw, y + 2.05)])
    blur = U * c.s * 0.1
    c.over(np.zeros_like(c.rgb), ndimage.gaussian_filter(pen.mask(dark), blur) * bar * 0.62)
    c.over(np.broadcast_to(np.array(BARK[2], float), c.rgb.shape), ndimage.gaussian_filter(pen.mask(light), blur) * bar * 0.45)


def fleur_cap(c, down, mode):
    still = Pen(c, 32, down)
    pen = Pen(c, 32, down, PRESS if mode == "Pushed" else 0)
    if mode != "Bare":
        carve(c, groove_end(still))
    under = c.rgb.copy()
    vol = pair(lambda s: stroke(scroll(bez((X(s, 16.9), 13.0), (X(s, 19.4), 12.6), (X(s, 20.8), 10.8), (X(s, 20.4), 8.6), n=24),
                                       0.95, -s * 0.9, 0.4), 0.6, 0.3))
    vol += pair(lambda s: stroke(scroll(bez((X(s, 17.2), 15.6), (X(s, 20.2), 16.0), (X(s, 23.2), 16.9), (X(s, 23.9), 19.4), n=24),
                                        0.85, s * 0.85, 0.4), 0.55, 0.28))
    raised(pen, vol, BARK, bevel=0.55, cast=0.45)
    raised(pen, [[(16 - 1.2, 15), (16 + 1.2, 15), (16 + 1.2, FOOT), (16 - 1.2, FOOT)]], BARK, bevel=0.7)  # the stem, its foot under the border
    raised(pen, [profile([(1.0, 0), (2.6, 0.8), (5.2, 1.75), (8.0, 2.3), (10.2, 1.9), (11.8, 1.1), (12.8, 0.9)])], BARK, bevel=1.0)
    raised(pen, [profile([(2.4, 0), (5, 0.3), (9.6, 0.35), (12.2, 0.2)])], BARK, bevel=0.3, cast=0, gloss=0.7)
    raised(pen, [[(16 - 1.55, 12.6), (16 + 1.55, 12.6), (16 + 1.55, 16.6), (16 - 1.55, 16.6)]], BARK, bevel=0.7, cast=0.4)
    twist_marks(c, pen, 12.6, 16.6, 1.55)
    sink(c, pen, under)
    if mode != "Bare":  # the highlight glows round the arrow alone, not the groove's border
        border(still, [ribbon(border_path(still), BORDER_HW)])
    glint(c, pen, 16, 2.6, 1.8, 0.8 if mode == "Pushed" else 0.55)  # the point's one warm light


# --- the divider: a vine


def bud_rule(c, piece, hw=1.0, pal=dim(BARK, 0.88)):
    """The divider: a vine nearer the quest log divider's weight than a hairline
    (the player, 2026-11-12), a shade darker than the bark so its width does
    not read brighter. Its left end round, near the turn's edge; at
    the Joint a node where it grows into the left border, a tendril coiling off it."""
    pen = Pen(c, 16)
    vine = lambda x0, x1: [ribbon([(x0, 8), (x1, 8)], hw)]
    bevel = 0.5 * hw / 0.55
    if piece == "Mid":
        raised(pen, vine(-12, 76), pal, bevel=bevel, cast=0.4, grain=False)
    elif piece == "Left":
        # it runs from near the turn's edge (covering the seam between the
        # turns' stones) and ends round, one piece with the vine
        x0 = 1.2 + hw
        raised(pen, vine(x0, 44) + [(x0, 8, hw)], pal, bevel=bevel, cast=0.4, grain=False)
    else:
        raised(pen, vine(-12, RAIL[0]) + vine(RAIL[1], 26), pal, bevel=bevel, cast=0.4, grain=False)
        raised(pen, stroke(scroll(bez((8.6, 7.6), (8.0, 6.0), (6.6, 4.8), (5.0, 5.0), n=24), 0.9, -1.0, 0.35), 0.45, 0.24, knob=False),
               BARK, bevel=0.45, cast=0.45)
        raised(pen, [leaf((8.4, 8.6), (5.6, 11.4), 1.3)], dim(BUD, 0.8), bevel=0.4, cast=0.4)
        raised(pen, [(9.3, 8, hw + 0.5)], pal, bevel=bevel, cast=0.4)  # the node


# --- the thumb, riding the groove. A thumb's middle eight
# units are stretched (one row averaged), so what runs along a body is
# lengthwise; its ends (the first and last eight) and its centre (16..32) may
# carry more.

THUMB_HW = 2.55  # a body's half-width along its length
END = 3.7  # an end's length: round once ChatBar.lua widens the art to the groove's floor (about 1.45)
_t = np.linspace(0, np.pi / 2, 9)[1:]
THUMB_ENDS = [(0.6, 0)] + [(0.6 + END * (1 - np.cos(a)), THUMB_HW * np.sin(a)) for a in _t] + [(24.0, THUMB_HW)] +              [(47.4 - END * (1 - np.cos(a)), THUMB_HW * np.sin(a)) for a in _t[::-1]] + [(47.4, 0)]


def shade(c, m, k):
    """Darkens what is under `m` by k, keeping its light and shadow."""
    c.rgb = c.rgb * (1 - np.clip(m, 0, 1)[..., None] * k)


def smooth(t):
    t = np.clip(t, 0, 1)
    return 3 * t ** 2 - 2 * t ** 3


# Painted with raised()'s grain, wear and dark edge, the body alone carrying
# the design end to end: nothing across the middle, no band or ring (the
# player: "the belt almost always looks bad"), no line finer than a unit (it
# reads as noise at true size).


def heart_thumb(c):
    """A capsule of turned heartwood: the darker, redder heart broad down its
    middle, the paler sapwood either side, the end grain darkening at both ends."""
    pen = Pen(c, 48)
    m = raised(pen, [profile(THUMB_ENDS)], HEART, bevel=1.6, cast=0.4)
    s = U * c.s
    heart = ndimage.gaussian_filter(pen.mask([[(14.6, -4), (17.4, -4), (17.4, 52), (14.6, 52)]]), s * 0.8) * m
    c.over(np.broadcast_to(np.array(HEART_CORE, float), c.rgb.shape), heart * 0.55)
    yy = (np.arange(c.H) / c.s - c.pad) / U
    ends = smooth(1 - (np.minimum(yy, 48 - yy) - 0.6) / 3.6)[:, None]
    shade(c, ends * m, 0.45)


HEART = ((32, 21, 13), (96, 72, 50), (152, 122, 90))  # heartwood, warm and muted
HEART_CORE = (72, 44, 30)  # its heart, redder and darker


def glow(bare):
    """The highlight, drawn for ADD: a warm rim round the ornament."""
    a = bare[..., 3] / 255
    halo = np.clip(ndimage.gaussian_filter(a, U * 0.8) * 1.8, 0, 1)
    inner = ndimage.gaussian_filter(ndimage.minimum_filter(a, size=int(U * 1.4) | 1), U * 0.4)
    hl = np.zeros_like(bare)
    hl[..., 0], hl[..., 1], hl[..., 2] = 255, 196, 90
    hl[..., 3] = halo * (1 - inner * 0.6) * 0.8 * 255
    return hl


def greyed(img):
    """Disabled: grey, flattened toward a dark value and faded, so even dark
    iron stands apart from its Normal."""
    out = img.copy()
    g = img[..., :3] @ np.array([0.3, 0.59, 0.11])
    out[..., :3] = 22 + (g[..., None] - 22) * 0.45
    out[..., 3] *= 0.7
    return out


def flat_grain(c):
    """The canvas's grain made the same down every column, so a slice of it
    can be stretched without a seam."""
    g = c.grain()
    c._grain = np.repeat(g.mean(0, keepdims=True), g.shape[0], 0)


def render_set():
    out = {}
    for down in (False, True):
        d = "Down" if down else "Up"
        imgs = {}
        for mode in ("Normal", "Pushed", "Bare"):
            c = ucanvas(32, 32)
            fleur_cap(c, down, mode)
            imgs[mode] = c.final()
        imgs["Pushed"][..., :3] *= 0.84  # a pressed piece sits a little deeper in shadow
        out["%s-Normal" % d] = imgs["Normal"]
        out["%s-Pushed" % d] = imgs["Pushed"]
        out["%s-Disabled" % d] = greyed(imgs["Normal"])
        g = ucanvas(32, 32)  # no glow on the groove nor its border: only round what stands on the stone
        g.a = Pen(g, 32, down).mask([[(RAIL[0] - BORDER_HW, GT), (RAIL[1] + BORDER_HW, GT), (RAIL[1] + BORDER_HW, 52), (RAIL[0] - BORDER_HW, 52)],
                                     (16, GT, ARC + BORDER_HW)])
        hl = glow(imgs["Bare"])
        hl[..., 3] *= 1 - g.final()[..., 3] / 255
        out["%s-Highlight" % d] = hl
    c = ucanvas(32, 8)
    carve(c, groove_run(c))
    border(Pen(c, 8), straight_borders(Pen(c, 8)))
    m = c.final()
    out["Mid"] = np.repeat(m.mean(0, keepdims=True), m.shape[0], 0)
    c = ucanvas(32, 48)
    flat_grain(c)
    heart_thumb(c)
    t = c.final()
    p = 8 * U
    out["Thumb-Top"] = t[:p]
    out["Thumb-Mid"] = np.repeat(t[p:2 * p].mean(0, keepdims=True), p, 0)
    out["Thumb-Centre"] = t[2 * p:4 * p]
    out["Thumb-Bottom"] = t[5 * p:]
    for piece, w in (("Left", 32), ("Mid", 64), ("Joint", 32)):
        c = ucanvas(w, 16)
        bud_rule(c, piece)
        img = c.final()
        if piece == "Mid":  # stretched sideways: the same in every column
            img = np.repeat(img.mean(1, keepdims=True), img.shape[1], 1)
        out["Joint" if piece == "Joint" else "Rule" + piece] = img
    return {"Scroll-%s" % k: v for k, v in out.items()}


def main():
    art = render_set()
    for old in glob.glob(os.path.join(OUT, "Scroll-*.tga")):
        os.remove(old)
    for stem, rgba in art.items():
        write_tga(os.path.join(OUT, "%s-%d.tga" % (stem, VERSION)), rgba)
    print(len(art), "textures")


if __name__ == "__main__":
    main()
