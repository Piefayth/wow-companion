"""The chat's scroll bar candidates (the Scroll bars tab, ScrollGallery.lua),
drawn here as vector shapes, bevelled and lit from the top left, at 16x and
averaged down, never Blizzard's art.

    python tools/make_scrollbar_art.py   writes addon/WowCompanion_Agent/Art/Scroll-*-<v>.tga
                                         and target/scrollbar-sheet-5.png (the comparison sheet: each set
                                         drawn into the game's own grab at true size, then 4x)

The game keeps a texture for the session under its path, so a change bumps
the version (VERSION for the spearhead, VERSION5 for round 5, and
ScrollGallery.lua's ROUND5); older files are deleted.

The spearhead (round 1, kept): an up and a down arrow in four states (Normal,
Pushed, Highlight drawn for ADD blending, Disabled), 32x32 shown at 16x16, set
over Blizzard's slim bar; a rod tile (RuleMid, 16x32, shown 8 wide, repeated
down), its caps (RuleTop, RuleBottom, 16x16) and the joint where a divider
meets it (Joint, 32x32). The down arrow is drawn mirrored, not flipped, so its
light still comes from the top left. Round 5's grooves: see below.
"""
import glob
import os
import struct
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

VERSION = 1
S = 16  # supersampling
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "addon", "WowCompanion_Agent", "Art")
LIGHT = np.array([-0.55, -0.75, 0.9]); LIGHT /= np.linalg.norm(LIGHT)
HALF = LIGHT + np.array([0, 0, 1.0]); HALF /= np.linalg.norm(HALF)

# palettes: (shadow, mid, light) in 0..255
GOLD = ((70, 42, 8), (196, 146, 52), (255, 232, 150))
BRONZE = ((52, 28, 12), (160, 98, 50), (240, 190, 130))
IRON = ((14, 12, 9), (62, 55, 42), (150, 136, 108))  # the divider's rod
EMERALD = ((0, 40, 16), (14, 140, 60), (120, 255, 160))
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
              paint=False):
        """A raised piece: its outline and drop shadow under it, then the face
        shaded from a height field (a bevel `bevel` px wide, or a dome).
        paint: Blizzard's painted metal instead of clean vector metal: a dark
        warm edge rather than a black line, grain and wear in the face, a broad
        soft speculars, a little colour taken out."""
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
            grain = self.grain()
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

    def gem(self, cx, cy, r, pal, bezel=None):
        if bezel:
            self.metal(self.mask(circles=[(cx, cy, r + 1.1)]), bezel, bevel=0.9, shadow=False)
        self.metal(self.mask(circles=[(cx, cy, r)]), pal, outline=0.35, shadow=False, dome=True, gloss=1.0)

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


def mirror(pts, h=32):
    return [(x, h - y) for x, y in pts]


def sym(half):
    """A shape symmetric about x = 16 from its right half, top to bottom."""
    return half + [(32 - x, y) for x, y in reversed(half)]


# --- the arrows: each draws its up arrow (down=False) or mirrored -----------

def arrow_spear(c, down):
    f = (lambda p: mirror(p)) if down else (lambda p: p)
    leaf = f(sym([(16, 2.5), (18.6, 6.5), (21.6, 11.5), (23, 15.5), (21.2, 19), (17.6, 20.5)]))
    collar = f([(9.5, 21), (22.5, 21), (23.5, 22.6), (22.5, 24.2), (9.5, 24.2), (8.5, 22.6)])
    c.metal(c.mask([leaf]), BRONZE, bevel=1.5)
    rib = f(sym([(16, 4.5), (16.9, 12), (16.9, 19.5)]))
    c.metal(c.mask([rib]), BRONZE, bevel=0.7, outline=0, shadow=False, gloss=0.9)
    c.metal(c.mask([collar]), BRONZE, bevel=1.0)


# --- the edges: a rod down the column's left side, its caps, the joint -----

def rod(c, pal, x=8, w=4.4, y0=-10, y1=None):
    y1 = c.h + 10 if y1 is None else y1
    c.metal(c.mask([[(x - w / 2, y0), (x + w / 2, y0), (x + w / 2, y1), (x - w / 2, y1)]]), pal,
            bevel=w / 2, outline=0.5, shadow=False, gloss=0.4, sheen=False)


def cap_iron(c, top, pal=IRON, knob=GOLD):
    """The rod coming in from the tile's far side and ending in a knob and point."""
    if top:
        rod(c, pal, y0=9, y1=26)
        c.metal(c.mask([[(8, 1.5), (10.2, 6.5), (8, 9.2), (5.8, 6.5)]]), knob, bevel=1.0)
        c.metal(c.mask(circles=[(8, 9.6, 2.6)]), knob, bevel=1.1)
    else:
        rod(c, pal, y0=-10, y1=7)
        c.metal(c.mask([[(8, 14.5), (10.2, 9.5), (8, 6.8), (5.8, 9.5)]]), knob, bevel=1.0)
        c.metal(c.mask(circles=[(8, 6.4, 2.6)]), knob, bevel=1.1)


def ferrule(c, pal=GOLD, x1=12):
    """A short sleeve where the iron divider enters the joint, so the metal
    changes at a fitting, not mid-rod."""
    c.metal(c.mask([[(3, 14.2), (x1, 14.2), (x1, 17.8), (3, 17.8)]]), pal, bevel=1.0)
    c.metal(c.mask([[(3, 13.4), (4.6, 13.4), (4.6, 18.6), (3, 18.6)]]), pal, bevel=0.6, shadow=False)


def joint_lozenge(c):
    ferrule(c, BRONZE, 10)
    c.metal(c.mask([[(16, 6.5), (23.5, 16), (16, 25.5), (8.5, 16)]]), BRONZE, bevel=1.6)
    c.gem(16, 16, 2.6, EMERALD)


DESIGNS = {
    # name: (arrow, rod tile, caps, joint)
    "Spear": (arrow_spear, lambda c: rod(c, BRONZE), lambda c, t: cap_iron(c, t, BRONZE, BRONZE), joint_lozenge),
}


def states(img):
    """Normal, Pushed (darker, a pixel down), Highlight (a warm glow for ADD),
    Disabled (grey and dim)."""
    rgb, a = img[..., :3], img[..., 3:] / 255
    pushed = np.zeros_like(img)
    pushed[1:] = img[:-1]
    pushed[..., :3] *= 0.72
    halo = np.clip(ndimage.gaussian_filter(a[..., 0], 1.4) * 1.8, 0, 1)
    inner = ndimage.gaussian_filter(ndimage.minimum_filter(a[..., 0], size=5), 0.8)
    glow_a = halo * (1 - inner * 0.75) * 0.8  # a rim, the centre at most a fifth
    hl = np.zeros_like(img)
    hl[..., 0], hl[..., 1], hl[..., 2] = 255, 196, 90
    hl[..., 3] = glow_a * 255
    grey = rgb @ np.array([0.3, 0.59, 0.11])
    dis = img.copy()
    dis[..., :3] = (grey[..., None] * 0.55 + 18)
    dis[..., 3] *= 0.8
    return {"Normal": img, "Pushed": pushed, "Highlight": hl, "Disabled": dis}


def render():
    """Every texture as {file stem: rgba array}."""
    out = {}
    for name, (arrow, tile, cap, joint) in DESIGNS.items():
        for down in (False, True):
            c = Canvas(32, 32)
            arrow(c, down)
            for state, img in states(c.final()).items():
                out["Scroll-%s-%s-%s" % (name, "Down" if down else "Up", state)] = img
        if tile:
            c = Canvas(16, 32, pad=0)
            tile(c)
            out["Scroll-%s-RuleMid" % name] = c.final()
            for top in (True, False):
                c = Canvas(16, 16)
                cap(c, top)
                out["Scroll-%s-Rule%s" % (name, "Top" if top else "Bottom")] = c.final()
        c = Canvas(32, 32)
        joint(c)
        out["Scroll-%s-Joint" % name] = c.final()
    return out


# --- round 5: four sets, each a groove carved into the stone with its ornament
# at the two ends only (docs/proposals/scrollbar-concepts.md)
#
# In UI units, U texture px each; every piece is 32 units wide and centred on
# the column (20 wide, x 6..26), the groove x 12..20:
#   <Up|Down>-<state> 32x32: the button, the arrow set into the groove's end
#     (the groove runs on out of the far edge)
#   Mid 32x8: the groove alone, stretched between the buttons
#   Thumb-Top, Thumb-Mid (stretched), Thumb-Centre 32x16, Thumb-Bottom 32x8
#   Joint 32x16: where a divider (its line at y 8) meets the groove; its x 6 is
#     the column's left edge, where a divider stops
#   RuleLeft 32x16, RuleMid 64x16: the design's own divider (its left end, and
#     its line stretched whole to the Joint)

VERSION5 = 1
PRESS = 1.25  # how far a pressed arrow sinks into the groove, in units
GT, ORN = 22.0, 1.15  # the arrows' groove end (its round end's centre) and the ornament's scale
U = 4
SS = 4
GX0, GX1 = 12, 20

# Blizzard's own UI metal, read off the game's atlases drawn in a frame of ours
# (UI-Frame-Metal, DiamondMetal, QuestLog-frame-devider): muted, warm, the
# lights never white
BRZ = ((34, 21, 9), (88, 58, 28), (176, 136, 84))
IRN = ((14, 13, 10), (44, 41, 32), (112, 104, 80))  # the divider's olive iron
BARK = ((22, 15, 9), (68, 48, 30), (138, 108, 74))
BUD = ((20, 22, 15), (62, 68, 48), (128, 132, 100))  # olive-grey, the green all but gone
ROD = ((39, 36, 27), (58, 52, 40), (96, 88, 66))  # QuestLog-frame-devider's own rod
LEATHER = ((18, 11, 7), (56, 35, 21), (112, 80, 54))
WARM = np.array((255, 208, 128), float)


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


class Pen:
    """Draws in units on a canvas as the up end has them: flip mirrors y about
    h (the down end, its light still from the top left), dy moves the shapes
    toward the groove (a pressed button). An arrow's pen (cap=True) draws the
    ornament as designed round a groove end at y 19, 1.15 times larger about
    that end, set at GT (its groove itself is drawn by a plain pen)."""

    def __init__(self, c, h, flip=False, dy=0.0, cap=False):
        self.c, self.h, self.flip, self.dy = c, h, flip, dy
        self.k, self.y0 = (ORN, 19.0) if cap else (1.0, None)

    def x(self, x):
        return x if self.y0 is None else 16 + (x - 16) * self.k

    def y(self, y):
        if self.y0 is not None:
            y = GT + (y - self.y0) * self.k
        return self.h - (y + self.dy) if self.flip else y + self.dy

    def mask(self, pieces):
        polys = [[(self.x(x) * U, self.y(y) * U) for x, y in p] for p in pieces if not isinstance(p, tuple)]
        circles = [(self.x(p[0]) * U, self.y(p[1]) * U, p[2] * self.k * U) for p in pieces if isinstance(p, tuple)]
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
    shows(pen.c, m)
    return m


def shows(c, m):
    """Note where metal now shows on the canvas (carving takes it away)."""
    c.shown = np.maximum(getattr(c, "shown", 0), np.clip(m, 0, 1))


def dim(pal, k):
    return tuple(tuple(int(x * k) for x in col) for col in pal)


def carve(c, m, depth=1.0, floor=1.0):
    """A recess where `m` is: dark floor, the top-left wall in shadow, the
    bottom-right wall and lip faintly lit (measured against Blizzard's minimal
    track)."""
    c.shown = getattr(c, "shown", 0) * (1 - np.clip(m, 0, 1))
    k = U * c.s
    du = ndimage.distance_transform_edt(m > 0.5) / k
    t = np.clip(du / depth, 0, 1)
    h = ndimage.gaussian_filter(-(1 - (1 - t) ** 2) * depth * U * 1.3, k * 0.18, mode="nearest")
    gy, gx = np.gradient(h * c.s)
    n = np.stack([-gx, -gy, np.ones_like(gx)], -1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    shade = n @ LIGHT - LIGHT[2]

    def near(a, s):
        return ndimage.gaussian_filter(a, s, mode="nearest")
    rim = np.clip(near(ndimage.maximum_filter(m, size=int(k * 0.9) | 1), k * 0.2) - m, 0, 1)
    lip = np.clip(near(ndimage.shift(m, (k * 0.55, k * 0.2), order=1, mode="nearest"), k * 0.15) - m, 0, 1)
    pale = np.broadcast_to(np.array((205, 196, 178), float), c.rgb.shape)
    c.over(pale, np.clip(rim * 0.16 + lip * 0.42, 0, 1))
    c.over(np.broadcast_to(np.array((14, 12, 10), float), c.rgb.shape), m * floor)
    c.over(np.zeros_like(c.rgb), m * np.clip(-shade * 5, 0, 1) * 0.9)
    c.over(pale, m * np.clip(shade * 3.0, 0, 1) * 0.5)


def groove_end(pen, gt):
    """The groove from its round end (centred at y gt) out of the far edge."""
    return pen.mask([[(GX0, gt), (GX1, gt), (GX1, pen.h + 20), (GX0, pen.h + 20)], (16, gt, (GX1 - GX0) / 2)])


def deep(c, flip, h=32, gt=None):
    """How far into the groove's shadow each pixel is (0..1): nothing over
    the groove's round end, then a hard shadow straight across, then dark."""
    gt = GT if gt is None else gt
    yy = (np.arange(c.H)[:, None] / c.s - c.pad) / U
    depth = (yy if not flip else h - yy) - (gt - (GX1 - GX0) / 2) - (GX1 - GX0) / 2 * 0.6
    k = np.where(depth > 0, 0.55 + 0.45 * np.clip(depth / 3, 0, 1), 0)
    return k * groove_run(c)


def sink(c, pen, gt, under):
    """What lies in the groove below its end's lip goes down into the dark,
    fading into the groove as it was before (`under`) the further it runs in:
    a pressed piece, further in, darker."""
    m = deep(c, pen.flip, pen.h, gt)[..., None]
    c.rgb = c.rgb * (1 - m) + under * m


def groove_run(c):
    """The groove through a whole piece, both ends running off it."""
    return c.mask([[(GX0 * U, -40), (GX1 * U, -40), (GX1 * U, c.h + 40), (GX0 * U, c.h + 40)]])


def engrave(c, m, lit=False):
    """Lines cut into metal: dark, the cut's far wall catching light; lit, the
    cut glows warm (a pressed inlay)."""
    k = U * c.s
    on = np.clip(c.a, 0, 1)
    c.over(np.broadcast_to(np.array((34, 20, 9), float), c.rgb.shape), m * on * 0.85)
    wall = m * (1 - ndimage.shift(m, (-k * 0.22, -k * 0.16), order=1))
    c.over(np.broadcast_to(np.array((214, 178, 120), float), c.rgb.shape), np.clip(wall, 0, 1) * on * 0.55)
    if lit:
        g = np.clip(ndimage.gaussian_filter(m, k * 0.3) * 1.6, 0, 1)
        c.over(np.broadcast_to(WARM, c.rgb.shape), np.clip(g * on, 0, 1) * 0.85)


def glint(c, pen, x, y, r=1.6, k=0.7):
    """A soft warm light on the metal at (x, y): the one bright spot."""
    yy, xx = np.mgrid[0:c.H, 0:c.W]
    cx, cy = (pen.x(x) * U + c.pad) * c.s, (pen.y(y) * U + c.pad) * c.s
    g = np.clip(1 - np.hypot(xx - cx, yy - cy) / (r * U * c.s), 0, 1) ** 2
    c.over(np.broadcast_to(WARM, c.rgb.shape), g * np.clip(c.a, 0, 1) * k)


def flush(pen, pieces, pal):
    """Pieces of bronze inlaid flush in the stone: a hairline seam, no shadow."""
    c = pen.c
    m = pen.mask(pieces)
    k = U * c.s
    seam = np.clip(ndimage.gaussian_filter(ndimage.maximum_filter(m, size=int(k * 0.7) | 1), k * 0.1) - m, 0, 1)
    c.over(np.broadcast_to(np.array((10, 8, 6), float), c.rgb.shape), seam * 0.8)
    c.metal(m, pal, bevel=0.35 * U, outline=0, shadow=False, sheen=False, paint=True, gloss=0.5)
    shows(c, m)
    return m


# --- 1. Spear in the groove: the groove is the spear's sheath --------------------

def spear_cap(c, down, mode):
    pen = Pen(c, 32, down, PRESS if mode == "Pushed" else 0, cap=True)
    if mode != "Bare":
        carve(c, groove_end(Pen(c, 32, down), GT))
    blade = [(1.4, 0), (4.2, 2.3), (8.2, 5.0), (11.4, 6.3), (13.0, 5.2), (14.3, 2.9)] if not down else \
            [(1.4, 0), (4.6, 1.7), (8.6, 3.7), (11.4, 4.7), (13.0, 4.1), (14.3, 2.9)]  # the butt-spike, slimmer
    under = c.rgb.copy()
    raised(pen, [profile([(13.6, 2.9), (17, 2.75), (36, 2.5)])], BRZ, bevel=1.4)
    raised(pen, [[(16 - 3.5, 14.4), (16 + 3.5, 14.4), (16 + 3.5, 15.7), (16 - 3.5, 15.7)]], BRZ, bevel=0.5, cast=0.4)
    parts = [profile(blade)]
    for sgn in (1, -1):  # the barbs, hooked back from the shoulders, their curls lying on the groove's lips
        parts += stroke(scroll(bez((X(sgn, 20.2), 12.4), (X(sgn, 21.6), 13.2), (X(sgn, 22.2), 14.8), (X(sgn, 21.9), 16.6), n=20),
                               0.8, sgn * 0.75, 0.45), 0.8, 0.42)
    raised(pen, parts, BRZ, bevel=1.1)
    raised(pen, [profile([(2.6, 0), (6, 0.55), (11, 0.7), (14, 0.6)])], BRZ, bevel=0.35, cast=0, gloss=0.8)  # the midrib
    sink(c, pen, GT, under)
    if mode == "Pushed":
        glint(c, pen, 16, 3.2)


def spear_thumb(c):
    pen = Pen(c, 48)
    raised(pen, [profile([(0.6, 0), (1.4, 1.9), (3.0, 2.75), (45.0, 2.75), (46.6, 1.9), (47.4, 0)])], dim(BRZ, 0.8), bevel=1.4, cast=0.4)
    m = raised(pen, [[(16 - 3.0, 18.6), (16 + 3.0, 18.6), (16 + 3.0, 29.4), (16 - 3.0, 29.4)]], LEATHER, bevel=1.2, cast=0.3)
    turns = []
    for y in np.arange(18.0, 30.5, 1.5):  # the binding, wound at a slant
        turns.append([(12.6, y + 1.1), (19.4, y - 0.1), (19.4, y + 0.35), (12.6, y + 1.55)])
    c.over(np.zeros_like(c.rgb), pen.mask(turns) * m * 0.55)
    for y in (18.6, 29.4):
        raised(pen, [[(16 - 3.3, y - 0.65), (16 + 3.3, y - 0.65), (16 + 3.3, y + 0.65), (16 - 3.3, y + 0.65)]], dim(BRZ, 0.8), bevel=0.45, cast=0.3)


def spear_joint(c):
    """Blizzard's divider stops at the column's edge (x 6); its rod runs on
    and sinks into the stone, a cut as thick as it is, into the groove."""
    pen = Pen(c, 16)
    rod = raised(pen, [ribbon([(4.6, 8), (12.8, 8)], 0.8)], ROD, bevel=0.6, cast=0.3)
    xx = (np.arange(c.W)[None, :] / c.s - c.pad) / U
    k = np.clip((xx - 7.5) / 3.5, 0, 1)  # going down into the cut: dark, then gone
    c.rgb *= 1 - k[..., None]
    lit = pen.mask([ribbon([(7.0, 8.95), (12.6, 8.95)], 0.16)])  # the cut's far edge catching light
    c.over(np.broadcast_to(np.array(ROD[2], float), c.rgb.shape), lit * 0.3)
    c.a *= 1 - groove_run(c) * np.clip((xx - 11.5), 0, 1)


# --- 2. One twist of iron: the bar rises, twists once, splits into two scrolls -

def twist_cap(c, down, mode):
    pen = Pen(c, 32, down, PRESS if mode == "Pushed" else 0, cap=True)
    if mode != "Bare":
        carve(c, groove_end(Pen(c, 32, down), GT))
    under = c.rgb.copy()
    raised(pen, [[(16 - 2.9, 10.0), (16 + 2.9, 10.0), (16 + 2.9, 36), (16 - 2.9, 36)]], IRN, bevel=1.2)
    twist_marks(c, pen, 10.4, 15.4, 2.9)
    parts = [profile([(1.0, 0), (3.4, 1.7), (6.4, 3.5), (8.8, 4.4), (10.0, 3.6), (10.6, 2.9)])]
    for sgn in (1, -1):  # the scrolls, out and down onto the groove's lips like shoulders
        parts += stroke(scroll(bez((X(sgn, 19.0), 9.0), (X(sgn, 21.8), 9.6), (X(sgn, 23.8), 11.4), (X(sgn, 23.4), 14.2), n=24),
                               1.3, sgn * 0.85, 0.4), 1.0, 0.55)
    raised(pen, parts, IRN, bevel=1.0)
    sink(c, pen, GT, under)
    glint(c, pen, 16, 2.8, 2.2, 0.8 if mode == "Pushed" else 0.6)  # the point's one warm light


def twist_marks(c, pen, y0, y1, hw):
    """The twist: a square bar's faces turning, as broad slanted bands."""
    bar = pen.mask([[(16 - hw, y0), (16 + hw, y0), (16 + hw, y1), (16 - hw, y1)]])
    dark, light = [], []
    for y in np.arange(y0 - 1.2, y1 - 1.0, 2.6):
        dark.append([(16 - hw, y + 1.2), (16 + hw, y - 0.8), (16 + hw, y + 0.7), (16 - hw, y + 2.7)])
        light.append([(16 - hw, y + 2.5), (16 + hw, y + 0.5), (16 + hw, y + 0.85), (16 - hw, y + 2.85)])
    blur = U * c.s * 0.12
    c.over(np.zeros_like(c.rgb), ndimage.gaussian_filter(pen.mask(dark), blur) * bar * 0.62)
    c.over(np.broadcast_to(np.array(IRN[2], float), c.rgb.shape), ndimage.gaussian_filter(pen.mask(light), blur) * bar * 0.45)


def twist_thumb(c):
    pen = Pen(c, 48)
    raised(pen, [profile([(0.6, 0), (1.3, 1.8), (2.8, 2.6), (45.2, 2.6), (46.7, 1.8), (47.4, 0)])], IRN, bevel=1.2, cast=0.4)
    raised(pen, [[(16 - 2.9, 19.0), (16 + 2.9, 19.0), (16 + 2.9, 29.0), (16 - 2.9, 29.0)]], IRN, bevel=1.2, cast=0.3)
    twist_marks(c, pen, 19.0, 29.0, 2.9)


def twist_rule(c, piece):
    """Our own divider: a hammered iron rod (line at y 8) in the divider's own
    olive iron, drawn out to a point at its left end, swelling in its middle
    (RuleMid, stretched whole), and at the Joint a hook over the groove's lip."""
    pen = Pen(c, 16)
    if piece == "Mid":  # 64 wide, stretched: its swell stretches with it
        raised(pen, [[(x, 8 + w) for x, w in SWELL] + [(x, 8 - w) for x, w in SWELL[::-1]]], IRN, bevel=0.7, cast=0.45)
    elif piece == "Left":
        raised(pen, [[(x, 8 + w) for x, w in POINT] + [(x, 8 - w) for x, w in POINT[::-1]]], IRN, bevel=0.7, cast=0.45)
    else:  # the joint
        hook = scroll(bez((-10, 8), (8, 8), (11.6, 8.0), (12.6, 9.4), n=40), 0.9, 0.7, 0.42)
        raised(pen, stroke(hook, 0.75, 0.5), IRN, bevel=0.7, cast=0.45)


def taper(knots, x0, x1, n=120):
    from scipy.interpolate import PchipInterpolator
    xs = np.linspace(x0, x1, n)
    return list(zip(xs, PchipInterpolator([k[0] for k in knots], [k[1] for k in knots])(xs)))


POINT = taper([(2.5, 0.12), (12, 0.5), (34, 0.75)], 2.5, 34)
SWELL = taper([(-2, 0.75), (20, 1.0), (44, 1.0), (66, 0.75)], -2, 66)


# --- 3. Vine and bud: a vine in the groove, seen only where it surfaces --------

def bud_cap(c, down, mode):
    pen = Pen(c, 32, down, PRESS if mode == "Pushed" else 0, cap=True)
    t = []  # two tendrils, not a pair: each leaves the stem, crosses the lip and coils on the stone
    t += stroke(scroll(bez((15.2, 14.0), (13.8, 13.4), (12.0, 13.8), (11.6, 15.6), n=24), 1.0, -1.0, 0.35), 0.55, 0.32, knob=False)
    t += stroke(scroll(bez((16.8, 15.0), (18.4, 14.7), (20.2, 15.4), (20.5, 17.4), n=24), 0.9, 1.0, 0.35), 0.5, 0.3, knob=False)
    raised(pen, t, BARK, bevel=0.5, cast=0.45)
    if mode != "Bare":
        carve(c, groove_end(Pen(c, 32, down), GT))
    under = c.rgb.copy()
    stalk = raised(pen, [profile([(11.0, 2.0), (14, 2.6), (36, 2.8)])], dim(BARK, 0.6), bevel=2.6)
    grain = [ribbon([(x, 10.5), (x + 0.2, 36)], 0.12) for x in (15.0, 16.3, 17.4)]  # the bark's grain
    c.over(np.broadcast_to(np.array(BARK[0], float), c.rgb.shape), pen.mask(grain) * stalk * 0.55)
    raised(pen, [profile([(0.8, 0), (3.2, 2.2), (6.8, 4.6), (10.0, 5.6), (12.4, 4.2), (13.8, 1.7)])], BUD, bevel=2.2)
    seam = pen.mask([ribbon(bez((16, 2.6), (16.4, 5.2), (16.6, 8.0), (16.2, 11.2), n=20), np.linspace(0.14, 0.3, 20))])
    c.over(np.broadcast_to(np.array(BUD[0], float), c.rgb.shape), seam * 0.6)
    raised(pen, [leaf((X(s, 16.6), 13.6), (X(s, 20.0), 10.6), 2.0) for s in (1, -1)], dim(BUD, 0.7), bevel=0.6, cast=0.35)
    sink(c, pen, GT, under)
    if mode == "Pushed":
        glint(c, pen, 16, 3.0, 1.6, 0.5)


def bud_thumb(c):
    pen = Pen(c, 48)
    raised(pen, [profile([(0.6, 0), (1.4, 1.8), (3.0, 2.5), (45.0, 2.5), (46.6, 1.8), (47.4, 0)])], dim(BARK, 0.85), bevel=1.3, cast=0.4)
    raised(pen, [profile([(23.0, 2.7), (23.6, 3.05), (24.4, 3.05), (25.0, 2.7)])], BARK, bevel=0.6, cast=0.35)  # the node, a ring


def bud_joint(c):
    """Blizzard's divider stops at the column's edge; a tendril comes out from
    under the groove's lip and runs up under the divider's end, so the
    divider's own curl and the vine are one gesture."""
    pen = Pen(c, 16)
    t = stroke(bez((13.4, 9.6), (10.6, 9.9), (8.0, 9.8), (5.0, 8.9), n=30), 0.6, 0.3, knob=False)
    raised(pen, t, BARK, bevel=0.6, cast=0.45)
    c.a *= 1 - groove_run(c)  # where it comes out from under the groove's edge


# --- 4. Engraved, not cast: bronze inlaid flush, the ornament engraved -----------

ARCH = [(1.0, 0), (3.5, 1.5), (6.5, 3.3), (9.5, 4.8), (12.5, 5.8), (15.0, 6.2), (16.8, 6.0), (17.8, 5.2)]  # a pointed arch, its base corners rounded


def inlay_cap(c, down, mode):
    pen = Pen(c, 32, down, cap=True)
    flush(pen, [profile(ARCH)], BRZ)
    lines = []
    for sgn in (1, -1):  # each edge followed by an engraved line, open at the point, a small scroll out at the base
        lead = profile([(5.0, 0.8), (6.5, 1.6), (9.5, 2.9), (12.5, 3.6), (14.6, 3.8)])[:200]  # twice the size: it must read on a TV
        lead = [(X(sgn, x), y) for x, y in lead]
        lines += stroke(scroll(lead, 0.7, -sgn * 1.3, 0.45), 0.45, 0.36)
    engrave(c, pen.mask(lines), lit=mode == "Pushed")
    if mode != "Bare":
        carve(c, groove_end(Pen(c, 32, down), GT + 0.2))


def inlay_thumb(c):
    pen = Pen(c, 48)
    raised(pen, [profile([(0.6, 0), (1.6, 2.2), (3.4, 3.0), (44.6, 3.0), (46.4, 2.2), (47.4, 0)])], dim(BRZ, 0.8), bevel=0.9, cast=0.4)
    line = [ribbon([(16, 3.6), (16, 20.6)], 0.4), ribbon([(16, 27.4), (16, 44.4)], 0.4),
            ribbon([(16, 20.6), (17.6, 24.0), (16, 27.4), (14.4, 24.0), (16, 20.6)], 0.38)]
    engrave(c, pen.mask(line))


INLAY = dim(BRZ, 0.62)  # the dividers' bronze, below the text's value
INLAY_END = [(x, 0.08 + 0.42 * min(1, (x - 2) / 20) ** 0.7) for x in np.linspace(2, 42, 80)]  # drawn out to a point


def inlay_rule(c, piece):
    """Our own divider: a thin bronze line inlaid flush (y 8); its left end
    drawn out to a point; at the Joint the groove is cut through it, the
    bronze bright on the groove's wall, and it stops there."""
    pen = Pen(c, 16)
    if piece == "Mid":
        flush(pen, [ribbon([(-10, 8), (74, 8)], 0.5)], INLAY)
    elif piece == "Left":
        flush(pen, [[(x, 8 + w) for x, w in INLAY_END] + [(x, 8 - w) for x, w in INLAY_END[::-1]]], INLAY)
    else:
        flush(pen, [ribbon([(-10, 8), (13.0, 8)], 0.5)], INLAY)
        c.a *= 1 - groove_run(c)
        for x in (12.35,):  # the cut end, catching light on the groove's wall
            c.over(np.broadcast_to(np.array(INLAY[2], float), c.rgb.shape), pen.mask([(x, 8, 0.5)]))
            glint(c, pen, x, 8, 0.7, 0.4)


DESIGNS5 = {
    # name: (cap, thumb, joint, own divider or None for Blizzard's)
    "Sheath": (spear_cap, spear_thumb, spear_joint, None),
    "Twist": (twist_cap, twist_thumb, lambda c: twist_rule(c, "Joint"), twist_rule),
    "Bud": (bud_cap, bud_thumb, bud_joint, None),
    "Inlay": (inlay_cap, inlay_thumb, lambda c: inlay_rule(c, "Joint"), inlay_rule),
}


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
    out = img.copy()
    g = img[..., :3] @ np.array([0.3, 0.59, 0.11])
    out[..., :3] = (g[..., None] * 0.7 + 10)
    return out


def flat_grain(c):
    """The canvas's grain made the same down every column, so a slice of it
    can be stretched without a seam."""
    g = c.grain()
    c._grain = np.repeat(g.mean(0, keepdims=True), g.shape[0], 0)


def render5_one(name):
    cap, thumb, joint, rule = DESIGNS5[name]
    out = {}
    for down in (False, True):
        d = "Down" if down else "Up"
        imgs = {}
        for mode in ("Normal", "Pushed", "Bare"):
            c = ucanvas(32, 32)
            cap(c, down, mode)
            imgs[mode] = c.final()
            if mode == "Normal":
                metal = c.shown
        if name != "Inlay":  # a pressed piece sits a little deeper in shadow
            imgs["Pushed"][..., :3] *= 0.84
        out["%s-Normal" % d] = imgs["Normal"]
        out["%s-Pushed" % d] = imgs["Pushed"]
        out["%s-Disabled" % d] = greyed(imgs["Normal"])
        g = ucanvas(32, 32)  # the glow stops at the groove: in it, only on metal lying above its shadow
        cut = ndimage.maximum_filter(groove_end(Pen(g, 32, down), GT), size=int(U * g.s * 1.2) | 1)  # its walls and lip too
        g.a = cut * (1 - metal * (1 - np.clip(deep(g, down) / 0.55, 0, 1)))
        hl = glow(imgs["Bare"])
        hl[..., 3] *= 1 - g.final()[..., 3] / 255
        out["%s-Highlight" % d] = hl
    c = ucanvas(32, 8)
    carve(c, groove_run(c))
    out["Mid"] = c.final()
    c = ucanvas(32, 48)
    flat_grain(c)
    thumb(c)
    t = c.final()
    p = 8 * U
    out["Thumb-Top"] = t[:p]
    out["Thumb-Mid"] = np.repeat(t[p:2 * p].mean(0, keepdims=True), p, 0)
    out["Thumb-Centre"] = t[2 * p:4 * p]
    out["Thumb-Bottom"] = t[5 * p:]
    c = ucanvas(32, 16)
    joint(c)
    out["Joint"] = c.final()
    if rule:
        for piece, w in (("Left", 32), ("Mid", 64)):  # the Mid stretched whole between the Left and the Joint
            c = ucanvas(w, 16)
            rule(c, piece)
            out["Rule" + piece] = c.final()
    return {"Scroll-%s-%s" % (name, k): v for k, v in out.items()}


def blizzard_divider():
    """QuestLog-frame-devider as the game drew it at 2x on magenta
    (target/div-crop.png, grabbed in game), unmixed to RGBA."""
    im = np.asarray(Image.open(os.path.join(ROOT, "target", "div-crop.png")).convert("RGB"), float)[18:72, 18:353]
    a = np.clip(1 - (im[..., 0] - im[..., 1]) / 255, 0, 1)
    rgb = np.where(a[..., None] > 0.02, (im - (1 - a[..., None]) * np.array([255, 0, 255])) / np.maximum(a[..., None], 0.02), 0)
    out = np.dstack([np.clip(rgb, 0, 255), a * 255 * 0.8])  # the chat draws it at alpha 0.8
    return Image.fromarray(out.astype(np.uint8), "RGBA")


# --- the comparison sheet ---------------------------------------------------

SHOT = os.path.join(os.environ.get("LOCALAPPDATA", ""), "wow-companion", "shots", "round4-panes.png")
UG = 2.7  # px per UI unit in the game's grab (4K)
# the spearhead's pane in the grab: its column's right edge, the transcript's
# left, top and bottom, and the dividers' lines
RIGHT, INNER, TOP, BOTTOM, LINES = 487, 44, 200, 1219, (335, 540, 675)


def clean_pane():
    """The grab's first pane with round 1's bar, joints and dividers painted
    out with the pane's own stone: the true stone, font and frame to draw on."""
    a = np.asarray(Image.open(SHOT).convert("RGBA")).copy()
    cl = RIGHT - round(20 * UG)
    for y, below in zip(LINES, (470, 625, 820)):  # rows of the same bands with nothing on them
        a[y - 22:y, INNER:RIGHT] = a[y - 48:y - 26, INNER:RIGHT]
        a[y:y + 22, INNER:RIGHT] = a[below:below + 22, INNER:RIGHT]
    x0 = cl - 30  # the column and the art's reach left of it; its stone is the last band's
    src = a[830:1200, x0 - 130:RIGHT - 130]
    for y in range(TOP, BOTTOM, src.shape[0]):
        n = min(src.shape[0], BOTTOM - y)
        a[y:y + n, x0:RIGHT] = src[:n]
    return a


def six_turns(a):
    """The cleaned pane restacked as six shorter turns, as the chat shows a
    long conversation: its lines."""
    you, claude = a[TOP:LINES[0]], a[LINES[0]:LINES[0] + (LINES[0] - TOP)]
    out = a.copy()
    y, lines = TOP, []
    for i, band in enumerate([you, claude, you, claude, you, claude]):
        n = min(band.shape[0], BOTTOM - y)
        out[y:y + n] = band[:n] if i < 5 else a[LINES[2]:LINES[2] + n]
        if i:
            lines.append(y)
        y += n
    rest = BOTTOM - y
    if rest > 0:
        out[y:BOTTOM] = a[BOTTOM - rest:BOTTOM]
    return out, lines


def draw_set(base, art, name, u, ox, oy, lines, thumb=None):
    """A design onto `base` (PIL RGBA) at u px per unit; ox, oy: where the
    pane's (RIGHT, TOP) lands; lines: the dividers' y in the grab's px."""
    def img(stem):
        return Image.fromarray(art["Scroll-%s-%s" % (name, stem)].astype(np.uint8), "RGBA")

    def put(im, x, y, w, h):  # x, y in units from the column's left, top; edges on whole px as the game snaps them
        x0, y0 = round(ox - 20 * u + x * u), round(oy + y * u)
        x1, y1 = round(ox - 20 * u + (x + w) * u), round(oy + (y + h) * u)
        if x1 <= x0 or y1 <= y0:
            return
        base.alpha_composite(im.resize((x1 - x0, y1 - y0), Image.LANCZOS), (x0, y0))
    H = (BOTTOM - TOP) / UG
    ys = [(y - TOP) / UG for y in lines]
    inner = -(RIGHT - INNER) / UG + 20
    own = DESIGNS5[name][3]
    for y in ys:
        if own:
            put(img("RuleLeft"), inner, y - 8, 32, 16)
            put(img("RuleMid"), inner + 32, y - 8, -6 - inner - 32, 16)
        else:
            put(BLIZ, inner, y - 7.5, -inner, 15)
    put(img("Mid"), -6, 32, 32, H - 64)
    for y in ys:
        put(img("Joint"), -6, y - 8, 32, 16)
    ty, th = thumb or (32 + (H - 64) / 6, (H - 64) / 3)
    put(img("Thumb-Top"), -6, ty, 32, 8)
    put(img("Thumb-Mid"), -6, ty + 8, 32, th / 2 - 16)
    put(img("Thumb-Centre"), -6, ty + th / 2 - 8, 32, 16)
    put(img("Thumb-Mid"), -6, ty + th / 2 + 8, 32, th / 2 - 16)
    put(img("Thumb-Bottom"), -6, ty + th - 8, 32, 8)
    put(img("Up-Normal"), -6, 0, 32, 32)
    put(img("Down-Normal"), -6, H - 32, 32, 32)


def sheet5(art):
    """Row 1: each set drawn into the game's own grab at its true size (2.7 px
    a unit), the spearhead as the game drew it first; row 2: the same with six
    turns; row 3: the top of each at 4x; then every button state at 4x, the
    Highlight added over Normal as the game does."""
    global BLIZ
    BLIZ = blizzard_divider()
    shot = Image.open(SHOT).convert("RGBA")
    clean = clean_pane()
    six, six_lines = six_turns(clean)
    L, R = INNER - 12, RIGHT + 14

    def crop(a, y0=TOP - 12, y1=BOTTOM + 10):
        return a.crop((L, y0, R, y1))
    true, sixes, zooms = [crop(shot)], [crop(shot)], []
    for name in DESIGNS5:
        for src, lines, out in ((clean, LINES, true), (six, six_lines, sixes)):
            b = Image.fromarray(src)
            draw_set(b, art, name, UG, RIGHT, TOP, lines)
            out.append(crop(b))
        k = 4
        z = Image.fromarray(six).crop((RIGHT - 70, TOP, RIGHT + 8, TOP + 300)).resize((78 * k, 300 * k), Image.LANCZOS)
        draw_set(z, art, name, UG * k, 70 * k, 0, six_lines[:2], thumb=(44, 50))
        zooms.append(z)
    for name, t in zip(DESIGNS5, true[1:]):
        t.convert("RGB").save(os.path.join(ROOT, "target", "scrollbar-true-%s.png" % name))
    rows = [row(true), row(sixes), row(zooms)]
    for name in DESIGNS5:
        cells = []
        for d in ("Up", "Down"):
            for s in ("Normal", "Pushed", "Highlight", "Disabled"):
                cell = Image.fromarray(clean).crop((RIGHT - 60, 880, RIGHT - 60 + 47, 927)).resize((32 * 11, 32 * 11), Image.LANCZOS)
                over = art["Scroll-%s-%s-%s" % (name, d, "Normal" if s == "Highlight" else s)]
                cell.alpha_composite(Image.fromarray(over.astype(np.uint8), "RGBA").resize(cell.size, Image.LANCZOS))
                if s == "Highlight":
                    hl = np.asarray(Image.fromarray(art["Scroll-%s-%s-Highlight" % (name, d)].astype(np.uint8), "RGBA").resize(cell.size, Image.LANCZOS), float)
                    c = np.asarray(cell, float).copy()
                    c[..., :3] = np.clip(c[..., :3] + hl[..., :3] * hl[..., 3:] / 255, 0, 255)
                    cell = Image.fromarray(c.astype(np.uint8), "RGBA")
                cells.append(cell)
        rows.append(row(cells, 6))
    W = max(r.width for r in rows)
    out = Image.new("RGBA", (W, sum(r.height + 16 for r in rows)), (0, 0, 0, 255))
    y = 0
    for r in rows:
        out.paste(r, (0, y)); y += r.height + 16
    path = os.path.join(ROOT, "target", "scrollbar-sheet-5.png")
    out.convert("RGB").save(path)
    return path


def row(cells, gap=12):
    r = Image.new("RGBA", (sum(c.width for c in cells) + gap * len(cells), max(c.height for c in cells)), (0, 0, 0, 255))
    x = 0
    for c in cells:
        r.paste(c, (x, 0)); x += c.width + gap
    return r


def main():
    from concurrent.futures import ProcessPoolExecutor
    with ProcessPoolExecutor() as pool:  # every design at once
        spear = pool.submit(render)
        art5 = {}
        for part in pool.map(render5_one, DESIGNS5):
            art5.update(part)
        art = spear.result()
    for old in glob.glob(os.path.join(OUT, "Scroll-*.tga")):
        os.remove(old)
    for stem, rgba in art.items():
        write_tga(os.path.join(OUT, "%s-%d.tga" % (stem, VERSION)), rgba)
    for stem, rgba in art5.items():
        write_tga(os.path.join(OUT, "%s-%d.tga" % (stem, VERSION5)), rgba)
    print(len(art) + len(art5), "textures;", sheet5(art5))


if __name__ == "__main__":
    main()
