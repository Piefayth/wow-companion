"""The chat's scroll bar candidates (the Scroll bars tab, ScrollGallery.lua),
drawn here as vector shapes, bevelled and lit from the top left, at 16x and
averaged down, never Blizzard's art.

    python tools/make_scrollbar_art.py   writes addon/WowCompanion_Agent/Art/Scroll-*-<v>.tga
                                         and target/scrollbar-sheet-6.png (the comparison sheet: the
                                         gallery's panes redrawn at true size, then zoomed, then every state)

The game keeps a texture for the session under its path, so a change bumps
the version (VERSION for the spearhead, VERSION6 for round 6, and
ScrollGallery.lua's ROUND6); older files are deleted.

The spearhead (round 1, kept): an up and a down arrow in four states (Normal,
Pushed, Highlight drawn for ADD blending, Disabled), 32x32 shown at 16x16, set
over Blizzard's slim bar; a rod tile (RuleMid, 16x32, shown 8 wide, repeated
down), its caps (RuleTop, RuleBottom, 16x16) and the joint where a divider
meets it (Joint, 32x32). The down arrow is drawn mirrored, not flipped, so its
light still comes from the top left. Round 6's grooves: see below.
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


# --- round 6: four sets, each a groove carved into the stone between two
# borders of the set's material, the arrows rising out of the groove's ends
# where the borders close round it, the dividers joining the left border
# (docs/proposals/scrollbar-concepts.md)
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

VERSION6 = 5
PRESS = 1.25  # how far a pressed arrow sinks toward the groove, in units
GT = 24.0  # the arrows' groove end (its round end's centre)
FOOT = GT - 4.0 - PRESS  # an arrow's foot: under the border's arc, pressed or not
U = 4
SS = 4
GX0, GX1 = 12, 20
RAIL = (11.1, 20.9)  # the borders' centres
ARC = 16 - RAIL[0]  # their radius round the groove's end

# Blizzard's own UI metal, read off the game's atlases drawn in a frame of ours
# (UI-Frame-Metal, DiamondMetal, QuestLog-frame-devider): muted, warm, the
# lights never white
BRZ = ((34, 21, 9), (88, 58, 28), (176, 136, 84))
IRN = ((14, 13, 10), (44, 41, 32), (112, 104, 80))
BARK = ((22, 15, 9), (68, 48, 30), (138, 108, 74))
BUD = ((20, 22, 15), (62, 68, 48), (128, 132, 100))  # olive-grey, the green all but gone
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


def hprofile(pts, cy=8):
    """The same lying on its side: (x, half-width) knots about y = cy."""
    return [(y, x) for x, y in profile(pts, cy)]


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


def engrave(c, m):
    """Lines cut into metal: dark, the cut's far wall catching light."""
    k = U * c.s
    on = np.clip(c.a, 0, 1)
    c.over(np.broadcast_to(np.array((34, 20, 9), float), c.rgb.shape), m * on * 0.85)
    wall = m * (1 - ndimage.shift(m, (-k * 0.22, -k * 0.16), order=1))
    c.over(np.broadcast_to(np.array((214, 178, 120), float), c.rgb.shape), np.clip(wall, 0, 1) * on * 0.55)


def glint(c, pen, x, y, r=1.6, k=0.7):
    """A soft warm light on the metal at (x, y): the one bright spot."""
    yy, xx = np.mgrid[0:c.H, 0:c.W]
    cx, cy = (x * U + c.pad) * c.s, (pen.y(y) * U + c.pad) * c.s
    g = np.clip(1 - np.hypot(xx - cx, yy - cy) / (r * U * c.s), 0, 1) ** 2
    c.over(np.broadcast_to(WARM, c.rgb.shape), g * np.clip(c.a, 0, 1) * k)


def flush(pen, pieces, pal):
    """Pieces of bronze inlaid flush in the stone: a hairline seam, no shadow."""
    c = pen.c
    m = pen.mask(pieces)
    k = U * c.s
    seam = np.clip(ndimage.gaussian_filter(ndimage.maximum_filter(m, size=int(k * 0.6) | 1), k * 0.1) - m, 0, 1)
    c.over(np.broadcast_to(np.array((10, 8, 6), float), c.rgb.shape), seam * 0.8)
    c.metal(m, pal, bevel=0.3 * U, outline=0, shadow=False, sheen=False, paint=True, gloss=0.5, grain=False)
    return m


# --- the groove's borders: straight down a Mid; in a cap closing over the
# groove's round end. No grain: a cap's borders and the Mid's meet seamlessly.

def border_path(pen, gt=GT):
    """The borders as one line: up the left, over the groove's end, down the right."""
    far = pen.h + 12
    th = np.linspace(np.pi, 0, 60)
    arc = np.stack([16 + ARC * np.cos(th), gt - ARC * np.sin(th)], 1)
    return np.vstack([[(RAIL[0], far), (RAIL[0], gt + 2)], arc, [(RAIL[1], gt + 2), (RAIL[1], far)]])


def straight_borders(pen, kind):
    return [ribbon([(x, -12), (x, pen.h + 12)], INLAY_HW if kind == "flush" else BORDER_HW) for x in RAIL]


BORDER_HW = 0.9
INLAY_HW = 0.7


def border(pen, pieces, kind):
    if kind == "flush":
        return flush(pen, pieces, INLAY)
    return raised(pen, pieces, kind, bevel=0.6, cast=0.4, grain=False)


# --- 2. The bronze lance: a slim leaf-bladed head, its barbs on the shoulders

def lance_cap(c, down, mode):
    still = Pen(c, 32, down)
    pen = Pen(c, 32, down, PRESS if mode == "Pushed" else 0)
    if mode != "Bare":
        carve(c, groove_end(still))
    under = c.rgb.copy()
    barbs = pair(lambda s: stroke(scroll(bez((X(s, 17.0), 15.4), (X(s, 19.8), 15.6), (X(s, 22.8), 16.4), (X(s, 23.8), 19.0), n=24),
                                         0.95, s * 0.85, 0.4), 0.55, 0.3))
    barbs += pair(lambda s: stroke(scroll(bez((X(s, 17.2), 14.6), (X(s, 18.6), 13.6), (X(s, 19.8), 12.4), (X(s, 19.4), 10.8), n=20),
                                          0.6, -s * 0.8, 0.45), 0.42, 0.24))
    raised(pen, barbs, BRZ, bevel=0.5, cast=0.45)
    raised(pen, [profile([(14.0, 0.95), (16.4, 1.05), (17.8, 1.3), (FOOT, 1.4)])], BRZ, bevel=0.8)  # the socket, its foot under the border
    raised(pen, [profile([(1.0, 0), (2.6, 0.7), (5.0, 1.7), (8.0, 2.6), (10.4, 2.9), (12.2, 2.25), (13.6, 1.15), (14.4, 0.95)])], BRZ, bevel=1.2)
    raised(pen, [profile([(2.2, 0), (4.0, 0.28), (9.0, 0.4), (13.4, 0.3)])], BRZ, bevel=0.3, cast=0, gloss=0.8)  # the midrib
    raised(pen, [[(16 - 1.8, 14.5), (16 + 1.8, 14.5), (16 + 1.8, 15.9), (16 - 1.8, 15.9)]], BRZ, bevel=0.45, cast=0.4)  # the collar
    sink(c, pen, under)
    if mode != "Bare":  # the highlight glows round the arrow alone, not the groove's border
        border(still, [ribbon(border_path(still), BORDER_HW)], BRZ)
    if mode == "Pushed":
        glint(c, pen, 16, 3.0)


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


def lance_rule(c, piece):
    """A thin bronze rod; its left end a slim butt-spike in a collar, two barbs
    hooked back; at the Joint a collar where it meets the left border, its
    barbs lying along the border, and past the groove on to the edge."""
    pen = Pen(c, 16)
    rod = lambda x0, x1: [ribbon([(x0, 8), (x1, 8)], 0.55)]
    if piece == "Mid":
        raised(pen, rod(-12, 76), BRZ, bevel=0.5, cast=0.4, grain=False)
    elif piece == "Left":
        raised(pen, rod(8.6, 44), BRZ, bevel=0.5, cast=0.4, grain=False)
        barbs = [p for s in (1, -1) for p in stroke(scroll(bez((9.6, 8 - s * 0.9), (10.6, 8 - s * 2.2), (9.8, 8 - s * 3.4), (8.2, 8 - s * 3.4), n=20),
                                                          0.6, s * 0.8, 0.45), 0.4, 0.24)]
        raised(pen, barbs, BRZ, bevel=0.45, cast=0.4)
        raised(pen, [hprofile([(1.0, 0), (3.0, 0.55), (5.6, 0.95), (7.4, 0.75), (8.0, 0.7)])], BRZ, bevel=0.6, cast=0.4)
        raised(pen, [[(8.0, 8 - 1.25), (9.6, 8 - 1.25), (9.6, 8 + 1.25), (8.0, 8 + 1.25)]], BRZ, bevel=0.45, cast=0.4)
    else:
        raised(pen, rod(-12, RAIL[0]) + rod(RAIL[1], 26), BRZ, bevel=0.5, cast=0.4, grain=False)
        barbs = [p for s in (1, -1) for p in stroke(scroll(bez((7.6, 8 - s * 0.9), (6.6, 8 - s * 2.2), (7.4, 8 - s * 3.4), (9.0, 8 - s * 3.4), n=20),
                                                          0.6, -s * 0.8, 0.45), 0.4, 0.24)]
        raised(pen, barbs, BRZ, bevel=0.45, cast=0.4)
        raised(pen, [[(6.8, 8 - 1.3), (8.6, 8 - 1.3), (8.6, 8 + 1.3), (6.8, 8 + 1.3)]], BRZ, bevel=0.45, cast=0.4)


# --- 3. The wrought-iron fleur-de-lis: a slim petal and four volutes over a twisted collar

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
    c.over(np.broadcast_to(np.array(IRN[2], float), c.rgb.shape), ndimage.gaussian_filter(pen.mask(light), blur) * bar * 0.45)


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
    raised(pen, vol, IRN, bevel=0.55, cast=0.45)
    raised(pen, [[(16 - 1.2, 15), (16 + 1.2, 15), (16 + 1.2, FOOT), (16 - 1.2, FOOT)]], IRN, bevel=0.7)  # the stem, its foot under the border
    raised(pen, [profile([(1.0, 0), (2.6, 0.8), (5.2, 1.75), (8.0, 2.3), (10.2, 1.9), (11.8, 1.1), (12.8, 0.9)])], IRN, bevel=1.0)
    raised(pen, [profile([(2.4, 0), (5, 0.3), (9.6, 0.35), (12.2, 0.2)])], IRN, bevel=0.3, cast=0, gloss=0.7)
    raised(pen, [[(16 - 1.55, 12.6), (16 + 1.55, 12.6), (16 + 1.55, 16.6), (16 - 1.55, 16.6)]], IRN, bevel=0.7, cast=0.4)
    twist_marks(c, pen, 12.6, 16.6, 1.55)
    sink(c, pen, under)
    if mode != "Bare":  # the highlight glows round the arrow alone, not the groove's border
        border(still, [ribbon(border_path(still), BORDER_HW)], IRN)
    glint(c, pen, 16, 2.6, 1.8, 0.8 if mode == "Pushed" else 0.55)  # the point's one warm light


def twist_thumb(c):
    pen = Pen(c, 48)
    raised(pen, [profile([(0.6, 0), (1.3, 1.8), (2.8, 2.6), (45.2, 2.6), (46.7, 1.8), (47.4, 0)])], IRN, bevel=1.2, cast=0.4)
    raised(pen, [[(16 - 2.9, 19.0), (16 + 2.9, 19.0), (16 + 2.9, 29.0), (16 - 2.9, 29.0)]], IRN, bevel=1.2, cast=0.3)
    twist_marks(c, pen, 19.0, 29.0, 2.9)


def fleur_rule(c, piece):
    """An iron rod; at each end it splits into two volutes: at its left end
    curling back, at the Joint gripping the left border above and below."""
    pen = Pen(c, 16)
    rod = lambda x0, x1: [ribbon([(x0, 8), (x1, 8)], 0.6)]
    if piece == "Mid":
        raised(pen, rod(-12, 76), IRN, bevel=0.5, cast=0.4, grain=False)
    elif piece == "Left":
        raised(pen, rod(6.0, 44), IRN, bevel=0.5, cast=0.4, grain=False)
        v = [p for s in (1, -1) for p in stroke(scroll(bez((7.0, 8), (5.0, 8 - s * 0.2), (3.0, 8 - s * 1.2), (2.6, 8 - s * 3.0), n=24),
                                                       1.0, -s * 0.9, 0.4), 0.55, 0.3)]
        raised(pen, v, IRN, bevel=0.5, cast=0.45)
    else:
        raised(pen, rod(-12, 7.0) + rod(RAIL[1], 26), IRN, bevel=0.5, cast=0.4, grain=False)
        v = [p for s in (1, -1) for p in stroke(scroll(bez((6.4, 8), (8.6, 8 - s * 0.2), (9.9, 8 - s * 1.6), (9.9, 8 - s * 3.6), n=24),
                                                       0.9, s * 0.85, 0.4), 0.55, 0.3)]
        raised(pen, v, IRN, bevel=0.5, cast=0.45)


# --- 4. Vine and leaf-bud: two vines line the groove and close into a bud

def bud_cap(c, down, mode):
    still = Pen(c, 32, down)
    pen = Pen(c, 32, down, PRESS if mode == "Pushed" else 0)
    if mode != "Bare":
        carve(c, groove_end(still))
    under = c.rgb.copy()
    t = pair(lambda s: stroke(scroll(bez((X(s, 16.8), 16.6), (X(s, 19.6), 15.6), (X(s, 22.6), 16.0), (X(s, 23.7), 18.6), n=24),
                                     0.9, s * 1.1, 0.35), 0.48, 0.24, knob=False))
    raised(pen, t, BARK, bevel=0.45, cast=0.45)
    raised(pen, [leaf((X(s, 20.4), 15.9), (X(s, 22.4), 13.0), 1.3) for s in (1, -1)], dim(BUD, 0.8), bevel=0.4, cast=0.4)
    raised(pen, [profile([(10.5, 0.95), (14, 1.1), (FOOT, 1.2)])], dim(BARK, 0.75), bevel=0.9)
    raised(pen, [leaf((X(s, 16.3), 12.8), (X(s, 18.5), 9.0), 1.35) for s in (1, -1)], dim(BUD, 0.75), bevel=0.45, cast=0.35)  # the sepals
    raised(pen, [profile([(1.0, 0), (2.8, 0.95), (5.4, 2.0), (8.0, 2.5), (10.0, 2.15), (11.4, 1.3), (12.2, 0.95)])], BUD, bevel=1.3)
    seam = pen.mask([ribbon(bez((16, 2.6), (16.25, 5.0), (16.35, 7.8), (16.1, 11.0), n=20), np.linspace(0.12, 0.22, 20))])
    c.over(np.broadcast_to(np.array(BUD[0], float), c.rgb.shape), seam * 0.6)
    sink(c, pen, under)
    if mode != "Bare":  # the highlight glows round the arrow alone, not the groove's border
        border(still, [ribbon(border_path(still), BORDER_HW)], BARK)
    if mode == "Pushed":
        glint(c, pen, 16, 3.0, 1.6, 0.5)


def bud_thumb(c):
    pen = Pen(c, 48)
    raised(pen, [profile([(0.6, 0), (1.4, 1.8), (3.0, 2.5), (45.0, 2.5), (46.6, 1.8), (47.4, 0)])], dim(BARK, 0.85), bevel=1.3, cast=0.4)
    raised(pen, [profile([(23.0, 2.7), (23.6, 3.05), (24.4, 3.05), (25.0, 2.7)])], BARK, bevel=0.6, cast=0.35)  # the node, a ring


def bud_rule(c, piece):
    """A thin vine; its left end a tendril's coil and one leaf; at the Joint a
    node where it grows into the left border, a tendril coiling off it."""
    pen = Pen(c, 16)
    vine = lambda x0, x1: [ribbon([(x0, 8), (x1, 8)], 0.55)]
    if piece == "Mid":
        raised(pen, vine(-12, 76), BARK, bevel=0.5, cast=0.4, grain=False)
    elif piece == "Left":
        raised(pen, vine(9.0, 44), BARK, bevel=0.5, cast=0.4, grain=False)
        raised(pen, stroke(scroll(bez((9.5, 8), (6.5, 8), (4.0, 7.6), (3.0, 5.8), n=24), 1.1, 1.0, 0.35), 0.55, 0.26, knob=False),
               BARK, bevel=0.45, cast=0.45)
        raised(pen, [leaf((10.0, 8.5), (13.4, 11.2), 1.4)], dim(BUD, 0.8), bevel=0.4, cast=0.4)
    else:
        raised(pen, vine(-12, RAIL[0]) + vine(RAIL[1], 26), BARK, bevel=0.5, cast=0.4, grain=False)
        raised(pen, stroke(scroll(bez((8.6, 7.6), (8.0, 6.0), (6.6, 4.8), (5.0, 5.0), n=24), 0.9, -1.0, 0.35), 0.45, 0.24, knob=False),
               BARK, bevel=0.45, cast=0.45)
        raised(pen, [leaf((8.4, 8.6), (5.6, 11.4), 1.3)], dim(BUD, 0.8), bevel=0.4, cast=0.4)
        raised(pen, [(9.3, 8, 1.05)], BARK, bevel=0.5, cast=0.4)  # the node


# --- 5. Inlaid bronze lancet: everything flush, the borders drawn on up into a pointed arch

INLAY = dim(BRZ, 0.85)


def lancet_cap(c, down, mode):
    pen = Pen(c, 32, down)
    if mode != "Bare":
        carve(c, groove_end(pen, GT + 0.3))
    arch = [bez((RAIL[0], GT + 2), (RAIL[0], 15.0), (15.0, 9.0), (16, 2.6)),
            bez((RAIL[1], GT + 2), (RAIL[1], 15.0), (17.0, 9.0), (16, 2.6))]
    lines = [ribbon(np.vstack([[(x, 44)], a]), INLAY_HW) for x, a in zip(RAIL, arch)]
    if mode != "Bare":  # the ring is the groove's, not the arrow's: no highlight round it
        lines += [ribbon(border_path(pen)[2:-2], INLAY_HW * 0.8)]  # the groove's end ringed
    lines += [[(16, 0.2), (17.5, 2.9), (16, 5.6), (14.5, 2.9)]]  # the finial
    lines += [[(16, 9.6), (17.15, 12.8), (16, 16.0), (14.85, 12.8)]]  # a lozenge in the arch
    lines += pair(lambda s: stroke(scroll(bez((X(s, 21.5), 18.4), (X(s, 23.2), 17.4), (X(s, 24.4), 18.4), (X(s, 24.0), 20.4), n=24),
                                          0.8, s * 0.9, 0.4), 0.45, 0.3))
    flush(pen, lines, INLAY)


def inlay_thumb(c):
    pen = Pen(c, 48)
    raised(pen, [profile([(0.6, 0), (1.6, 2.2), (3.4, 3.0), (44.6, 3.0), (46.4, 2.2), (47.4, 0)])], dim(BRZ, 0.8), bevel=0.9, cast=0.4)
    line = [ribbon([(16, 3.6), (16, 20.6)], 0.4), ribbon([(16, 27.4), (16, 44.4)], 0.4),
            ribbon([(16, 20.6), (17.6, 24.0), (16, 27.4), (14.4, 24.0), (16, 20.6)], 0.38)]
    engrave(c, pen.mask(line))


def lancet_rule(c, piece):
    """A bronze line inlaid flush; its left end a lozenge and the line drawn to
    a point; at the Joint it meets the left border at a lozenge, and runs on
    past the groove to the edge."""
    pen = Pen(c, 16)
    line = lambda x0, x1: [ribbon([(x0, 8), (x1, 8)], 0.45)]
    if piece == "Mid":
        flush(pen, line(-12, 76), INLAY)
    elif piece == "Left":
        flush(pen, line(7.8, 44) + [hprofile([(1.0, 0), (3.5, 0.3), (5.0, 0.42)])]
              + [[(4.4, 8), (6.1, 6.4), (7.8, 8), (6.1, 9.6)]], INLAY)
    else:
        flush(pen, line(-12, 7.0) + line(RAIL[1], 26)
              + [[(6.4, 8), (8.25, 6.25), (10.1, 8), (8.25, 9.75)], ribbon([(9.9, 8), (RAIL[0], 8)], 0.45)]
              + [p for s in (1, -1) for p in stroke(scroll(bez((8.25, 8 - s * 1.9), (8.4, 8 - s * 3.4), (7.4, 8 - s * 4.4), (5.8, 8 - s * 4.2), n=24),
                                                         0.7, s * 0.9, 0.4), 0.42, 0.3)], INLAY)


# --- the thick dividers (between parts of a conversation): each set's own
# heavy piece, the same weight from its left end through the Joint, ornament at
# the ends only. What runs along the divider is the same in every column (the
# RuleMid is stretched sideways), so its texture is rows: grain along the bar.

TH = 1.7  # a thick bar's half-width, in units


def row_grain(c, k=1.0, seed=11):
    """Grain running along the divider: one value per row, the same for every
    piece of its height, so the Left, Mid and Joint meet without a seam."""
    rng = np.random.default_rng(seed)
    n = c.H // c.s
    g = sum(w * ndimage.gaussian_filter(rng.standard_normal(n), r) for w, r in ((0.55, 0.5), (0.45, 1.5)))
    g = ndimage.zoom(g / g.std(), c.s, order=1)[:c.H] * 0.09 * k
    c._grain = np.repeat(g[:, None], c.W, 1)


def plain_grain(c):
    if hasattr(c, "_grain"):
        del c._grain


def clip_right(c, x):
    """Everything past x (the column's edge) cut away, as the Mid is cut."""
    c.a[:, int((x * U + c.pad) * c.s):] = 0


def hbar(x0, x1, hw=TH):
    return [ribbon([(x0, 8), (x1, 8)], hw)]


def stripe(pen, x0, x1, y0, y1, rgb, a, within, blur=0.08):
    """A band along the bar (rows only) shading what is under `within`."""
    c = pen.c
    m = ndimage.gaussian_filter(pen.mask([[(x0, y0), (x1, y0), (x1, y1), (x0, y1)]]), U * c.s * blur)
    c.over(np.broadcast_to(np.array(rgb, float), c.rgb.shape), m * within * a)


def lance_bar(pen, x0, x1):
    """A bronze shaft: bevelled, a raised rib along its crown catching the light."""
    c = pen.c
    row_grain(c, 0.8)
    m = raised(pen, hbar(x0, x1), BRZ, bevel=0.9, cast=0.6)
    stripe(pen, x0, x1, 8 + 0.75, 8 + TH, BRZ[0], 0.35, m)  # the underside turned from the light
    raised(pen, hbar(x0, x1, 0.42), BRZ, bevel=0.35, cast=0.3, gloss=0.8)
    plain_grain(c)


def lance_ring(pen, x0, x1, hw=2.55):
    """A cast ring round the shaft."""
    raised(pen, [[(x0, 8 - hw), (x1, 8 - hw), (x1, 8 + hw), (x0, 8 + hw)]], BRZ, bevel=0.45, cast=0.45)


def lance_thick(c, piece):
    """A bronze shaft, ribbed; its left end the lance's butt, a faceted spike
    in a double collar, two heavy barbs hooked back; at the Joint a socket
    flush to the left border, its barbs reaching back along the shaft."""
    pen = Pen(c, 16)
    if piece == "Mid":
        lance_bar(pen, -12, 76)
    elif piece == "Left":
        lance_bar(pen, 11.0, 44)
        barbs = [p for s in (1, -1) for p in stroke(scroll(bez((12.4, 8 - s * 1.8), (14.4, 8 - s * 3.6), (13.4, 8 - s * 5.6), (10.6, 8 - s * 5.6), n=24),
                                                           0.85, s * 0.8, 0.45), 0.7, 0.36)]
        raised(pen, barbs, BRZ, bevel=0.55, cast=0.5)
        raised(pen, [hprofile([(0.6, 0), (3.0, 0.9), (6.4, 1.8), (8.8, 1.95), (9.6, 1.9)])], BRZ, bevel=0.9, cast=0.55)  # the spike
        raised(pen, [hprofile([(1.6, 0), (4.0, 0.25), (8.6, 0.35)])], BRZ, bevel=0.25, cast=0, gloss=0.8)  # its rib
        lance_ring(pen, 8.4, 9.9)
        lance_ring(pen, 11.0, 12.5)
        glint(c, pen, 5.5, 7.0, 1.4, 0.35)
    else:
        lance_bar(pen, -12, RAIL[0])
        lance_bar(pen, RAIL[1], 26)
        barbs = [p for s in (1, -1) for p in stroke(scroll(bez((8.0, 8 - s * 1.8), (6.0, 8 - s * 3.6), (7.0, 8 - s * 5.6), (9.8, 8 - s * 5.6), n=24),
                                                           0.85, -s * 0.8, 0.45), 0.7, 0.36)]
        raised(pen, barbs, BRZ, bevel=0.55, cast=0.5)
        lance_ring(pen, 7.4, RAIL[0])  # the socket, flush to the border
        engrave(c, pen.mask([[(9.1, 8 - 2.4), (9.4, 8 - 2.4), (9.4, 8 + 2.4), (9.1, 8 + 2.4)]]))
        clip_right(c, 26)


def htwist(c, pen, x0, x1, hw):
    """The twist along a bar lying flat: its faces turning, bands at 45 degrees."""
    bar = pen.mask([[(x0, 8 - hw), (x1, 8 - hw), (x1, 8 + hw), (x0, 8 + hw)]])
    dark, light = [], []
    for x in np.arange(x0 - 2 * hw, x1 + 0.4, 1.6):
        dark.append([(x + 2 * hw, 8 - hw), (x, 8 + hw), (x + 0.75, 8 + hw), (x + 2 * hw + 0.75, 8 - hw)])
        light.append([(x + 2 * hw + 0.8, 8 - hw), (x + 0.8, 8 + hw), (x + 1.2, 8 + hw), (x + 2 * hw + 1.2, 8 - hw)])
    blur = U * c.s * 0.08
    c.over(np.zeros_like(c.rgb), ndimage.gaussian_filter(pen.mask(dark), blur) * bar * 0.6)
    c.over(np.broadcast_to(np.array((150, 140, 112), float), c.rgb.shape), ndimage.gaussian_filter(pen.mask(light), blur) * bar * 0.5)


def fleur_bar(pen, x0, x1):
    """A square iron bar set on its edge, hammered: the upper face to the light,
    the lower in shadow, a bright arris between, the hammer's marks along it."""
    c = pen.c
    row_grain(c, 1.7, seed=5)
    m = raised(pen, hbar(x0, x1, TH - 0.1), IRN, bevel=0.45, cast=0.6, gloss=0.25)
    plain_grain(c)
    ridge = 8 - (TH - 0.1) * 0.2  # 40% down
    stripe(pen, x0, x1, 8 - TH, ridge, IRN[2], 0.4, m)
    stripe(pen, x0, x1, ridge, 8 + TH, (0, 0, 0), 0.55, m)
    stripe(pen, x0, x1, 8 + TH - 0.55, 8 + TH, (0, 0, 0), 0.5, m, blur=0.04)  # the underside
    stripe(pen, x0, x1, ridge - 0.24, ridge + 0.06, (178, 168, 138), 0.75, m, blur=0.04)  # the arris


def knop(pen, x, hw=2.4, w=1.6):
    """A forged collar round the bar."""
    raised(pen, [[(x - w / 2, 8 - hw), (x + w / 2, 8 - hw), (x + w / 2, 8 + hw), (x - w / 2, 8 + hw)]], IRN, bevel=0.6, cast=0.5)


def fleur_thick(c, piece):
    """A square iron bar on its edge; its left end twisted and split into two
    heavy volutes curling back; at the Joint a twisted length in a forged
    collar, two volutes from it gripping the left border above and below."""
    pen = Pen(c, 16)
    if piece == "Mid":
        fleur_bar(pen, -12, 76)
    elif piece == "Left":
        fleur_bar(pen, 7.0, 44)
        htwist(c, pen, 7.0, 13.2, TH - 0.1)
        v = [p for s in (1, -1) for p in stroke(scroll(bez((8.0, 8 - s * 0.4), (5.2, 8 - s * 0.6), (2.6, 8 - s * 1.8), (2.0, 8 - s * 4.2), n=40),
                                                       1.35, -s * 0.9, 0.6), 0.95, 0.6)]
        raised(pen, v, IRN, bevel=0.6, cast=0.55)
        knop(pen, 7.4, 2.2, 1.4)
        knop(pen, 13.8)
        glint(c, pen, 2.4, 4.2, 1.2, 0.3)
    else:
        fleur_bar(pen, -12, RAIL[0])
        fleur_bar(pen, RAIL[1], 26)
        htwist(c, pen, 0.6, 5.4, TH - 0.1)
        v = [p for s in (1, -1) for p in stroke(scroll(bez((6.0, 8 - s * 1.2), (8.6, 8 - s * 1.8), (10.2, 8 - s * 3.0), (9.8, 8 - s * 5.4), n=40),
                                                       1.0, s * 0.85, 0.5), 0.85, 0.5)]
        raised(pen, v, IRN, bevel=0.55, cast=0.55)
        knop(pen, 0.4, 2.2, 1.4)
        knop(pen, 5.6)
        clip_right(c, 26)


FURROWS = ((-0.6, 0.3), (0.55, 0.15))  # the bark's furrows (y, half-width): unequal, a third and two thirds down
RIDGES = ((-1.15, 0.22, 0.3), (0.0, 0.25, 0.12))  # the bark between them (y, half-width, light): one lit, one dull


def bud_bar(pen, x0, x1):
    """A grown branch: round, its bark furrowed along its length."""
    c = pen.c
    row_grain(c, 2.0, seed=3)
    m = raised(pen, hbar(x0, x1, TH - 0.05), BARK, bevel=1.6, cast=0.6, gloss=0.15)
    plain_grain(c)
    for y, hw, k in RIDGES:
        stripe(pen, x0, x1, 8 + y - hw, 8 + y + hw, (160, 124, 82), k, m, blur=0.12)
    for y, hw in FURROWS:
        stripe(pen, x0, x1, 8 + y - hw, 8 + y + hw, BARK[0], 0.8, m, blur=0.04)
    stripe(pen, x0, x1, 8 + 1.1, 8 + TH, (0, 0, 0), 0.35, m)  # the underside


def knot(cx, cy, rx, top, bottom, phase=0.0, n=120):
    """A lumpy swelling of the branch, bulging more below than above."""
    t = np.linspace(0, 2 * np.pi, n, endpoint=False)
    lumps = 1 + 0.06 * np.sin(3 * t + phase) + 0.04 * np.sin(5 * t + 2 * phase)
    ry = np.where(np.sin(t) > 0, bottom, top)
    return [(cx + rx * np.cos(a) * l, cy + r * np.sin(a) * l) for a, r, l in zip(t, ry, lumps)]


def bark_marks(c, pen, m, lines):
    c.over(np.broadcast_to(np.array(BARK[0], float), c.rgb.shape), pen.mask(lines) * m * 0.75)


def vein(c, pen, base, tip):
    b, t = np.array(base, float), np.array(tip, float)
    path = bez(b, b + (t - b) * [0.3, 0.4], b + (t - b) * [0.7, 0.75], t, n=20)
    c.over(np.broadcast_to(np.array(BUD[0], float), c.rgb.shape), pen.mask([ribbon(path, 0.12)]) * 0.55)


def bud_thick(c, piece):
    """A branch; its left end a gnarled knot where it was cut, a tendril grown
    from it and two leaves; at the Joint a swelling node where it grows into
    the left border, a leaf below and a tendril above."""
    pen = Pen(c, 16)
    if piece == "Mid":
        bud_bar(pen, -12, 76)
    elif piece == "Left":
        bud_bar(pen, 5.0, 44)
        m = raised(pen, [knot(3.9, 8.3, 2.9, 2.1, 2.7)], BARK, bevel=1.6, cast=0.55, gloss=0.15)  # the knot
        bark_marks(c, pen, m, [ribbon(bez((3.0, 5.9), (3.9, 7.4), (4.4, 9.0), (5.6, 10.6), n=20), 0.15),
                               ribbon(bez((4.6, 6.0), (5.4, 7.2), (6.0, 8.0), (6.8, 8.6), n=20), 0.12)])
        face = pen.mask([knot(1.55, 8.3, 0.75, 1.75, 2.1, 1.0)])  # the cut's end grain
        c.over(np.broadcast_to(np.array((178, 142, 98), float), c.rgb.shape), face * m * 0.85)
        c.over(np.broadcast_to(np.array(BARK[0], float), c.rgb.shape),
               pen.mask([ribbon(knot(1.6, 8.3, 0.4, 1.0, 1.25, 2.0, n=60) + [knot(1.6, 8.3, 0.4, 1.0, 1.25, 2.0, n=60)[0]], 0.08)]) * face * 0.7)
        raised(pen, stroke(scroll(bez((4.4, 6.8), (4.2, 4.8), (3.0, 3.4), (1.6, 3.4), n=30), 0.75, -1.1, 0.35), 0.62, 0.26, knob=False),
               BARK, bevel=0.45, cast=0.45)  # a tendril grown from the knot's top
        raised(pen, [leaf((8.6, 9.4), (13.2, 13.2), 2.2), leaf((9.8, 6.6), (13.6, 3.0), 1.9)], dim(BUD, 0.85), bevel=0.55, cast=0.5)
        vein(c, pen, (8.9, 9.7), (12.4, 12.6))
        vein(c, pen, (10.1, 6.3), (13.0, 3.6))
    else:
        bud_bar(pen, -12, RAIL[0])
        bud_bar(pen, RAIL[1], 26)
        raised(pen, stroke(scroll(bez((8.2, 6.6), (7.2, 4.4), (5.2, 3.0), (3.2, 3.4), n=30), 1.1, -1.0, 0.35), 1.0, 0.32, knob=False),
               BARK, bevel=0.55, cast=0.5)
        raised(pen, [leaf((7.6, 9.2), (3.2, 13.4), 2.2)], dim(BUD, 0.85), bevel=0.55, cast=0.5)
        vein(c, pen, (7.4, 9.4), (3.9, 12.7))
        m = raised(pen, [knot(8.5, 8.25, 1.9, 2.1, 2.6, 2.0)], BARK, bevel=1.4, cast=0.45)  # the node
        bark_marks(c, pen, m, [ribbon(bez((7.6, 6.2), (8.2, 7.4), (8.8, 8.8), (9.6, 10.4), n=20), 0.13)])
        clip_right(c, 26)


LANCET_CH = 1.95  # the channel's half-width


def channel(pen, cut):
    """A cut in the stone: its floor dark, the top wall shadowed (softened to
    the stone's own deepest shade), the bottom wall lit, the top lip catching light."""
    c = pen.c
    m = pen.mask(cut)
    carve(c, m, depth=0.8)
    k = U * c.s
    top = np.clip(m - ndimage.shift(m, (k * 0.7, 0), order=1), 0, 1)  # the band under the top edge
    bottom = np.clip(m - ndimage.shift(m, (-k * 0.7, 0), order=1), 0, 1)
    c.over(np.broadcast_to(np.array((40, 38, 36), float), c.rgb.shape), ndimage.gaussian_filter(top, k * 0.1) * 0.45)
    c.over(np.broadcast_to(np.array((128, 124, 114), float), c.rgb.shape), ndimage.gaussian_filter(bottom, k * 0.1) * 0.3)
    lip = np.clip(ndimage.shift(m, (k * 0.3, 0), order=1) - m, 0, 1)  # the stone just above the cut
    c.over(np.broadcast_to(np.array((150, 146, 136), float), c.rgb.shape), ndimage.gaussian_filter(lip, k * 0.08) * 0.3)


def incise(c, pen, pieces):
    """A line cut into the bronze: dark, a highlight just under it."""
    m = pen.mask(pieces)
    k = U * c.s
    c.over(np.broadcast_to(np.array((30, 18, 8), float), c.rgb.shape), m * 0.85)
    under = np.clip(ndimage.shift(m, (k * 0.3, 0), order=1) - m, 0, 1)
    c.over(np.broadcast_to(np.array((214, 178, 120), float), c.rgb.shape), under * np.clip(c.a, 0, 1) * 0.55)


def lancet_bar(pen, x0, x1, pocket=()):
    """A channel cut in the stone (with a pocket, cut as one with it), a
    bronze band laid in it, a line incised along its middle."""
    c = pen.c
    channel(pen, hbar(x0, x1, LANCET_CH) + list(pocket))
    row_grain(c, 0.6, seed=9)
    flush(pen, hbar(x0, x1, 0.95), INLAY)
    plain_grain(c)
    incise(c, pen, hbar(x0, x1, 0.18))


POCKET = lambda x: [[(x - 3.2, 8), (x, 8 - 3.4), (x + 3.2, 8), (x, 8 + 3.4)]]  # a lozenge's pocket cut in the stone
LOZENGE = lambda x: [[(x - 2.3, 8), (x, 8 - 2.3), (x + 2.3, 8), (x, 8 + 2.3)]]


def lancet_thick(c, piece):
    """An inlaid band in a carved channel; its left end a large inlaid lozenge
    in a pocket cut with the channel; at the Joint a lozenge in its pocket
    against the left border, two inlaid scrolls growing from its points, and
    on past the groove."""
    pen = Pen(c, 16)
    if piece == "Mid":
        lancet_bar(pen, -12, 76)
    elif piece == "Left":
        lancet_bar(pen, 7.2, 44, POCKET(7.2))
        flush(pen, LOZENGE(7.2), INLAY)
        incise(c, pen, [ribbon([(6.1, 8), (7.2, 8 - 1.1), (8.3, 8), (7.2, 8 + 1.1), (6.1, 8)], 0.14)])
    else:
        x = RAIL[0] - INLAY_HW - 3.2  # the pocket's point at the border
        lancet_bar(pen, -12, x, POCKET(x))
        lancet_bar(pen, RAIL[1] + INLAY_HW, 26)
        flush(pen, LOZENGE(x)
              + [p for s in (1, -1) for p in stroke(scroll(bez((x, 8 - s * 1.9), (x + 0.2, 8 - s * 4.4), (x - 1.0, 8 - s * 5.8), (x - 3.0, 8 - s * 5.6), n=40),
                                                         0.85, s * 0.9, 0.45), 0.75, 0.48)], INLAY)
        incise(c, pen, [ribbon([(x - 1.2, 8), (x, 8 - 1.2), (x + 1.2, 8), (x, 8 + 1.2), (x - 1.2, 8)], 0.14)])
        clip_right(c, 26)


DESIGNS6 = {
    # name: (cap, thumb, thin divider, thick divider, border material ("flush": inlaid))
    "Lance": (lance_cap, spear_thumb, lance_rule, lance_thick, BRZ),
    "Fleur": (fleur_cap, twist_thumb, fleur_rule, fleur_thick, IRN),
    "Bud": (bud_cap, bud_thumb, bud_rule, bud_thick, BARK),
    "Lancet": (lancet_cap, inlay_thumb, lancet_rule, lancet_thick, "flush"),
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


def render6_one(name):
    cap, thumb, thin, thick, kind = DESIGNS6[name]
    out = {}
    for down in (False, True):
        d = "Down" if down else "Up"
        imgs = {}
        for mode in ("Normal", "Pushed", "Bare"):
            c = ucanvas(32, 32)
            cap(c, down, mode)
            imgs[mode] = c.final()
        imgs["Pushed"][..., :3] *= 0.84  # a pressed piece sits a little deeper in shadow
        out["%s-Normal" % d] = imgs["Normal"]
        out["%s-Pushed" % d] = imgs["Pushed"]
        out["%s-Disabled" % d] = greyed(imgs["Normal"])
        g = ucanvas(32, 32)  # no glow in the groove: only round what stands on the stone
        g.a = groove_end(Pen(g, 32, down), GT)
        hl = glow(imgs["Bare"])
        hl[..., 3] *= 1 - g.final()[..., 3] / 255
        out["%s-Highlight" % d] = hl
    c = ucanvas(32, 8)
    carve(c, groove_run(c))
    border(Pen(c, 8), straight_borders(Pen(c, 8), kind), kind)
    m = c.final()
    out["Mid"] = np.repeat(m.mean(0, keepdims=True), m.shape[0], 0)
    c = ucanvas(32, 48)
    flat_grain(c)
    thumb(c)
    t = c.final()
    p = 8 * U
    out["Thumb-Top"] = t[:p]
    out["Thumb-Mid"] = np.repeat(t[p:2 * p].mean(0, keepdims=True), p, 0)
    out["Thumb-Centre"] = t[2 * p:4 * p]
    out["Thumb-Bottom"] = t[5 * p:]
    for rule, tag in ((thin, ""), (thick, "Thick")):
        for piece, w in (("Left", 32), ("Mid", 64), ("Joint", 32)):
            c = ucanvas(w, 16)
            rule(c, piece)
            img = c.final()
            if piece == "Mid":  # stretched sideways: the same in every column
                img = np.repeat(img.mean(1, keepdims=True), img.shape[1], 1)
            out[("Joint" if piece == "Joint" else "Rule" + piece) + tag] = img
    return {"Scroll-%s-%s" % (name, k): v for k, v in out.items()}


# --- the comparison sheet ---------------------------------------------------
#
# The game's own grab of round 5's gallery (shots/round5-panes.png, 4K, 1:1)
# redrawn as round 6 draws it: each turn's stone (our Slate files, tiled as the
# game tiles them, a texel a UI unit at 2.7 px, from the band's top left) on to
# the pane's edge behind the groove, the text and labels kept from the grab, each set's
# pieces placed where ScrollGallery.lua anchors them.

SHOT = os.path.join(os.environ.get("LOCALAPPDATA", ""), "wow-companion", "shots", "round5-panes.png")
UG = 2.7  # px per UI unit in the grab
TOP, BOTTOM = 201, 1219  # the panes' insides
LEFTS = [42 + i * 387.6 for i in range(5)]  # each transcript's left (the bands' tile origin)
WIDTH, COLUMN = 350, 54  # a pane's inside, the column's width, in px
BANDS = [(44, "you"), (60, "claude"), (44, "you"), (60, "claude"), (44, "you"), (0, "claude")]


def slate(owner):
    path = os.path.join(ROOT, "addon", "WowCompanion", "Art", "%s-6.tga" % ("Slate" if owner == "you" else "SlateLight"))
    return np.asarray(Image.open(path).convert("RGB"), float)


def tiled(tex, x0, y0, w, h, ox, oy):
    """The stone over screen px [x0, x0+w) x [y0, y0+h), its tile origin at (ox, oy)."""
    yy, xx = np.mgrid[y0:y0 + h, x0:x0 + w].astype(float)
    u, v = (xx + 0.5 - ox) / UG - 0.5, (yy + 0.5 - oy) / UG - 0.5
    return np.dstack([ndimage.map_coordinates(tex[..., k], [v, u], order=1, mode="grid-wrap") for k in range(3)])


def band_tops():
    tops, y = [], float(TOP)
    for units, owner in BANDS:
        tops.append((y, owner))
        y += units * UG
    return tops


def backdrop(shot, left, old):
    """One pane's inside: every band's stone across the whole width (old: as
    round 5 drew it, one stone under the column)."""
    x0, w = round(left), round(left + WIDTH) - round(left)
    col = round(left + WIDTH - COLUMN) - x0
    out = shot[TOP:BOTTOM, x0:x0 + w, :3].astype(float).copy()
    tops = band_tops()
    for i, (y, owner) in enumerate(tops):
        y0, y1 = round(y), round(tops[i + 1][0]) if i + 1 < len(tops) else BOTTOM
        out[y0 - TOP:y1 - TOP] = tiled(slate(owner), x0, y0, w, y1 - y0, left, y)
    if old:
        out[:, col:] = tiled(slate("claude"), x0 + col, TOP, w - col, BOTTOM - TOP, left, TOP)
    return out


def blizzard_divider():
    """QuestLog-frame-devider as the game drew it at 2x on magenta
    (target/div-crop.png, grabbed in game), unmixed to RGBA."""
    im = np.asarray(Image.open(os.path.join(ROOT, "target", "div-crop.png")).convert("RGB"), float)[18:72, 18:353]
    a = np.clip(1 - (im[..., 0] - im[..., 1]) / 255, 0, 1)
    rgb = np.where(a[..., None] > 0.02, (im - (1 - a[..., None]) * np.array([255, 0, 255])) / np.maximum(a[..., None], 0.02), 0)
    out = np.dstack([np.clip(rgb, 0, 255), a * 255 * 0.8])  # the chat draws it at alpha 0.8
    return Image.fromarray(out.astype(np.uint8), "RGBA")


def draw_set(base, art, name, u, ox, oy, h, lines, inner, thumb=None):
    """A set onto `base` (PIL RGBA) at u px a unit; (ox, oy): the column's top
    right; h its height in units; lines: the dividers' y in units; inner: the
    transcript's left, in units from the column's left."""
    def img(stem):
        return Image.fromarray(art["Scroll-%s-%s" % (name, stem)].astype(np.uint8), "RGBA")

    def put(im, x, y, w, hh):  # x, y in units from the column's top left; edges on whole px as the game snaps them
        x0, y0 = round(ox - 20 * u + x * u), round(oy + y * u)
        x1, y1 = round(ox - 20 * u + (x + w) * u), round(oy + (y + hh) * u)
        if x1 > x0 and y1 > y0:
            base.alpha_composite(im.resize((x1 - x0, y1 - y0), Image.LANCZOS), (x0, y0))
    for y in lines:
        put(img("RuleLeft"), inner, y - 8, 32, 16)
        put(img("RuleMid"), inner + 32, y - 8, -6 - inner - 32, 16)
    put(img("Mid"), -6, 32, 32, h - 64)
    for y in lines:
        put(img("Joint"), -6, y - 8, 32, 16)
    ty, th = thumb or (32 + (h - 64) / 6, (h - 64) / 3)
    put(img("Thumb-Top"), -6, ty, 32, 8)
    put(img("Thumb-Mid"), -6, ty + 8, 32, th / 2 - 16)
    put(img("Thumb-Centre"), -6, ty + th / 2 - 8, 32, 16)
    put(img("Thumb-Mid"), -6, ty + th / 2 + 8, 32, th / 2 - 16)
    put(img("Thumb-Bottom"), -6, ty + th - 8, 32, 8)
    put(img("Up-Normal"), -6, 0, 32, 32)
    put(img("Down-Normal"), -6, h - 32, 32, 32)


def panes6(art):
    """The grab with all five panes redrawn: option 1 kept as the game drew it
    (only its backdrop now runs on behind the column), 2-5 round 6's sets."""
    shot = np.asarray(Image.open(SHOT).convert("RGBA")).copy()
    out = shot.astype(float)
    tops = band_tops()
    h = (BOTTOM - TOP) / UG
    lines = [(y - TOP) / UG for y, _ in tops[1:]]
    for i, left in enumerate(LEFTS):
        x0 = round(left)
        new = backdrop(shot, left, old=False)
        col = round(left + WIDTH - COLUMN) - x0 - 18
        for k, (y, _) in enumerate(tops):  # the text, from the grab: each band's rows clear of its dividers, left of the old art
            y0 = round(y) + 19
            y1 = (round(tops[k + 1][0]) - 19) if k + 1 < len(tops) else BOTTOM
            new[y0 - TOP:y1 - TOP, :col] = shot[y0:y1, x0:x0 + col, :3]
        if i == 0:  # round 1: Blizzard's divider, its plain middle on to the pane's edge, under its column as the grab drew it
            pane = Image.fromarray(np.dstack([new, np.full(new.shape[:2], 255.0)]).astype(np.uint8), "RGBA")
            whole = blizzard_divider()
            div = whole.resize((col + 18, round(15 * UG)), Image.LANCZOS)
            w = whole.width
            on = whole.crop((round(w * 0.45), 0, round(w * 0.55), whole.height)).resize((new.shape[1] - col - 18, div.height), Image.LANCZOS)
            for y, _ in tops[1:]:
                pane.alpha_composite(div, (0, round(y - TOP - 7.5 * UG)))
                pane.alpha_composite(on, (col + 18, round(y - TOP - 7.5 * UG)))
            new = np.asarray(pane, float)[..., :3]
            old = backdrop(shot, left, old=True)
            mine = np.abs(shot[TOP:BOTTOM, x0:x0 + new.shape[1], :3] - old).max(2) > 5
            mine = ndimage.binary_dilation(mine, iterations=1)
            mine[:, :col + 4] = False
            new = np.where(mine[..., None], shot[TOP:BOTTOM, x0:x0 + new.shape[1], :3], new)
        out[TOP:BOTTOM, x0:x0 + new.shape[1], :3] = new
    base = Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), "RGBA")
    for i, name in enumerate(DESIGNS6, 1):
        right = LEFTS[i] + WIDTH
        draw_set(base, art, name, UG, right, TOP, h, lines, -(WIDTH - COLUMN) / UG)
    # the labels as the gallery now names them (a stand-in face: the game's is not a file here)
    from PIL import ImageDraw, ImageFont
    a = np.asarray(base).copy()
    a[148:188, :] = a[124:125, :]
    base = Image.fromarray(a, "RGBA")
    d = ImageDraw.Draw(base)
    font = ImageFont.truetype("georgia.ttf", 27)
    for i, label in enumerate(LABELS):
        text = "%d. %s" % (i + 1, label)
        d.text((LEFTS[i] + WIDTH / 2 - d.textlength(text, font=font) / 2, 152), text, font=font, fill=(255, 209, 0))
    return base


LABELS = ["Bronze spearhead", "Bronze lance", "Wrought-iron fleur-de-lis", "Vine and leaf-bud", "Inlaid bronze lancet"]


def sheet6(art):
    """Row 1: the five panes at true size; row 2: each set's top, a joint and
    its bottom at 3x; then every button state at 8x on the stone, the
    Highlight added over Normal as the game does."""
    panes = panes6(art)
    panes.convert("RGB").save(os.path.join(ROOT, "target", "scrollbar-panes-6.png"))
    rows = [panes]
    zooms = []
    for i in range(1, 5):
        right = round(LEFTS[i] + WIDTH)
        for y0, y1 in ((TOP, TOP + 140), (300, 340), (BOTTOM - 110, BOTTOM)):
            zooms.append(panes.crop((right - 120, y0, right + 6, y1)).resize((126 * 3, (y1 - y0) * 3), Image.LANCZOS))
    rows.append(row(zooms[:6]))
    rows.append(row(zooms[6:]))
    stone = Image.fromarray(np.clip(tiled(slate("claude"), 0, 0, 87, 87, 0, 0), 0, 255).astype(np.uint8)).convert("RGBA")
    for name in DESIGNS6:
        cells = []
        for d in ("Up", "Down"):
            for s in ("Normal", "Pushed", "Highlight", "Disabled"):
                cell = stone.resize((86 * 4, 86 * 4), Image.LANCZOS)
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
    path = os.path.join(ROOT, "target", "scrollbar-sheet-6.png")
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
        art6 = {}
        for part in pool.map(render6_one, DESIGNS6):
            art6.update(part)
        art = spear.result()
    for old in glob.glob(os.path.join(OUT, "Scroll-*.tga")):
        os.remove(old)
    for stem, rgba in art.items():
        write_tga(os.path.join(OUT, "%s-%d.tga" % (stem, VERSION)), rgba)
    for stem, rgba in art6.items():
        write_tga(os.path.join(OUT, "%s-%d.tga" % (stem, VERSION6)), rgba)
    print(len(art) + len(art6), "textures;", sheet6(art6))


if __name__ == "__main__":
    main()
