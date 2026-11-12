"""The chat's scroll bar candidates (the Scroll bars tab, ScrollGallery.lua),
drawn here as vector shapes, bevelled and lit from the top left, at 16x and
averaged down, never Blizzard's art.

    python tools/make_scrollbar_art.py   writes addon/WowCompanion_Agent/Art/Scroll-*-<v>.tga
                                         and target/scrollbar-sheet-4.png (the comparison sheet)

The game keeps a texture for the session under its path, so a change bumps
the version (VERSION for the spearhead, VERSION4 for the ornate ones, and
ScrollGallery.lua's art()); older files are deleted.

The spearhead (round 1, kept): an up and a down arrow in four states (Normal,
Pushed, Highlight drawn for ADD blending, Disabled), 32x32 shown at 16x16, set
over Blizzard's slim bar; a rod tile (RuleMid, 16x32, shown 8 wide, repeated
down), its caps (RuleTop, RuleBottom, 16x16) and the joint where a divider
meets it (Joint, 32x32). The down arrow is drawn mirrored, not flipped, so its
light still comes from the top left. Round 4's ornate grooves: see below.
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
SAPPHIRE = ((4, 14, 60), (24, 70, 190), (130, 200, 255))
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

    def metal(self, m, pal, bevel=1.6, outline=0.8, shadow=True, dome=False, gloss=0.55, sheen=True, glow=True):
        """A raised piece: its outline and drop shadow under it, then the face
        shaded from a height field (a bevel `bevel` px wide, or a dome)."""
        inside = m > 0.5
        if shadow:
            sh = ndimage.shift(ndimage.gaussian_filter(m, self.s * 0.7), (self.s * 0.9, self.s * 0.6), order=1)
            self.over(np.zeros_like(self.rgb), sh * 0.55)
        if outline:
            o = ndimage.gaussian_filter(ndimage.maximum_filter(m, size=int(outline * 2 * self.s) | 1), self.s * 0.25)
            self.over(np.broadcast_to(np.array(OUTLINE, float), self.rgb.shape), o * 0.95)
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
        spec = np.clip(n @ HALF, 0, 1) ** 28 * gloss
        sh_c, mid_c, li_c = (np.array(c, float) for c in pal)
        # a top-to-bottom sheen on the flat face, as polished metal shows
        ys = np.linspace(0, 1, self.H)[:, None, None]
        flat = 0.577
        k = diff[..., None]
        col = np.where(k < flat, sh_c + (mid_c - sh_c) * (k / flat), mid_c + (li_c - mid_c) * ((k - flat) / (1 - flat)))
        if sheen:  # never on a rod: its tile would band where it repeats
            col = col * (1.08 - 0.22 * ys)
        col = col + spec[..., None] * 255
        if dome and glow:  # light caught inside the stone, bottom right
            yy, xx = np.mgrid[0:self.H, 0:self.W]
            cy, cx = ndimage.center_of_mass(inside)
            rad = np.sqrt(inside.sum() / np.pi)
            glow = np.clip(1 - np.hypot(yy - cy - rad * 0.35, xx - cx - rad * 0.35) / (rad * 0.8), 0, 1) ** 2
            col = col + glow[..., None] * (li_c - mid_c) * 0.7
        self.over(np.clip(col, 0, 255), m)

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




# --- round 4: ornate ends wrapped round a groove carved into the panel ------
#
# The groove is a recess in the stone (dark floor, the top wall in shadow, a
# faint lit bottom lip), 8 wide in the middle of a 32-wide column; its ends
# are ornaments raised on the stone round it, outside the groove, that resolve
# into an arrow; each divider meets the groove through the same ornament. In
# UI units, U texture px each:
#   <Up|Down>-<state> 32x64: the groove's end and its ornament (the button;
#     the groove runs on out of the far edge)
#   Mid 32x8: the groove alone (stretched between caps and joints)
#   Joint 64x32: the divider's line (y 16) meeting the groove; its right edge
#     is the column's, the groove at x 44..52
#   RuleLeft, RuleMid, Knot 32x16: our own divider's left end, its line
#     (x-invariant, stretched) and its middle ornament (line at y 8)

VERSION4 = 4
U = 4
SS = 8
GX0, GX1 = 12, 20
GROOVE_TOP = 26  # the up cap's groove end (round, its top at 22)

IRON = ((12, 12, 8), (64, 62, 44), (160, 150, 108))  # Blizzard's divider's olive iron
WOOD = ((24, 14, 6), (96, 64, 34), (186, 146, 96))
LEAF = ((10, 30, 10), (66, 112, 40), (196, 222, 128))
RUBY = ((60, 4, 8), (170, 24, 36), (255, 150, 150))


def ucanvas(w, h):
    return Canvas(w * U, h * U, pad=8, s=SS)


def umask(c, polys=(), circles=()):
    return c.mask([[(x * U, y * U) for x, y in p] for p in polys],
                  circles=[(x * U, y * U, r * U) for x, y, r in circles])


def profile(pts, cx=16):
    """A shape symmetric about x = cx from (y, half-width) knots, smoothed."""
    from scipy.interpolate import PchipInterpolator
    ys = np.array([p[0] for p in pts], float)
    f = PchipInterpolator(ys, [p[1] for p in pts])
    yy = np.linspace(ys[0], ys[-1], 200)
    hw = np.maximum(f(yy), 0)
    return [(cx + w, y) for y, w in zip(yy, hw)] + [(cx - w, y) for y, w in zip(yy[::-1], hw[::-1])]


def ribbon(path, hw):
    """A path (units) as a polygon `hw` wide either side (per point or one)."""
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
    """A scroll's spiral leaving `start` along `tangent`, turning by `turns`
    (positive: clockwise on screen) and tightening to r0 * shrink."""
    t = np.array(tangent, float); t /= np.linalg.norm(t)
    sgn = np.sign(turns)
    nrm = np.array([-t[1], t[0]]) * sgn  # toward the centre
    centre = np.array(start, float) + nrm * r0
    a0 = np.arctan2(*(np.array(start) - centre)[::-1])
    a = a0 + np.linspace(0, turns * 2 * np.pi, n)
    r = r0 * (1 - (1 - shrink) * np.linspace(0, 1, n) ** 0.8)
    return np.stack([centre[0] + r * np.cos(a), centre[1] + r * np.sin(a)], 1)


def scroll_path(lead, r0, turns, shrink=0.35):
    """A lead (points) running on into a curl at its end."""
    lead = np.asarray(lead, float)
    sp = curl(lead[-1], lead[-1] - lead[-2], r0, turns, shrink)
    return np.vstack([lead, sp[1:]])


def tapered(path, hw0, hw1, knob=True):
    """A ribbon thinning from hw0 to hw1, a round knob at the thin end."""
    p = np.asarray(path, float)
    poly = ribbon(p, np.linspace(hw0, hw1, len(p)))
    return poly, ((p[-1][0], p[-1][1], hw1 * 1.35) if knob else None)


def leaf_poly(base, tip, width, n=40):
    """A pointed leaf from base to tip, `width` across at its widest."""
    b, t = np.array(base, float), np.array(tip, float)
    d = t - b; L = np.linalg.norm(d); d /= L
    nrm = np.array([-d[1], d[0]])
    s = np.linspace(0, 1, n)
    hw = width / 2 * np.sin(np.pi * s ** 0.8) ** 1.1
    left = [b + d * L * k + nrm * w for k, w in zip(s, hw)]
    right = [b + d * L * k - nrm * w for k, w in zip(s[::-1], hw[::-1])]
    return [tuple(q) for q in left + right]


def sym32(pts, cx=16):
    """Points and their mirror about x = cx."""
    return [(2 * cx - x, y) for x, y in pts]


def flipy(shape, h):
    return [(x, h - y) for x, y in shape]


def groove_mask(c, y0, y1, round_top=None, round_bottom=None):
    circles = []
    if round_top is not None:
        circles.append((16, round_top, (GX1 - GX0) / 2))
    if round_bottom is not None:
        circles.append((16, round_bottom, (GX1 - GX0) / 2))
    return umask(c, [[(GX0, y0), (GX1, y0), (GX1, y1), (GX0, y1)]], circles)


def carve4(c, m, depth=1.0, floor=0.84):
    """A recess where `m` is: dark floor, walls shaded from a depth field
    (top-left light), a faint light rim and the lit bottom lip (measured
    against Blizzard's minimal track)."""
    k = U * c.s
    inside = m > 0.5
    du = ndimage.distance_transform_edt(inside) / k
    t = np.clip(du / depth, 0, 1)
    h = -(1 - (1 - t) ** 2) * depth * U * 1.3
    h = ndimage.gaussian_filter(h, k * 0.18, mode="nearest")
    gy, gx = np.gradient(h * c.s)
    n = np.stack([-gx, -gy, np.ones_like(gx)], -1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    shade = n @ LIGHT - LIGHT[2]

    def near(a, s):
        return ndimage.gaussian_filter(a, s, mode="nearest")
    rim = np.clip(near(ndimage.maximum_filter(m, size=int(k * 0.9) | 1), k * 0.2) - m, 0, 1)
    lip = np.clip(near(ndimage.shift(m, (k * 0.55, k * 0.2), order=1, mode="nearest"), k * 0.15) - m, 0, 1)
    pale = np.broadcast_to(np.array((205, 196, 178), float), c.rgb.shape)
    c.over(pale, np.clip(rim * 0.14 + lip * 0.32, 0, 1))
    dark = np.broadcast_to(np.array((5, 4, 3), float), c.rgb.shape)
    c.over(dark, m * np.clip(floor + 0.15 * np.clip(-shade * 4, 0, 1), 0, 0.98))
    c.over(pale, m * np.clip(shade * 3.0, 0, 1) * 0.42)


def forged(c, pieces, pal, bevel=1.1, minus=(), **kw):
    """Pieces (polygons, and circles as (x, y, r)) in units, one raised metal,
    pierced where `minus` (polygons) is."""
    polys = [p for p in pieces if p is not None and not (isinstance(p, tuple) and len(p) == 3 and np.isscalar(p[0]))]
    circles = [p for p in pieces if isinstance(p, tuple) and len(p) == 3 and np.isscalar(p[0])]
    m = umask(c, polys, circles)
    if minus:
        m = m * (1 - umask(c, list(minus)))
    c.metal(m, pal, bevel=bevel * U, outline=0.55, sheen=False, **kw)


def pieces_of(*parts):
    out = []
    for p in parts:
        if isinstance(p, tuple) and len(p) == 2 and isinstance(p[0], list):
            out.append(p[0]); out.append(p[1])
        else:
            out.append(p)
    return out


# --- the ornaments, each drawn for the up cap (tip at the top, groove below)

def iron_cap(c, pal):
    """Wrought iron: an arrowhead over the groove's end, its barbs
    rolled into scrolls, two bars down the groove's lips ending in curls."""
    head = [(16, 1.2), (20.6, 7.2), (25.2, 13.0), (27.4, 16.6), (23.4, 16.4), (19.6, 19.6), (18.6, 23.2)]
    head = head + sym32(head[::-1])
    parts = [head]
    for sgn in (1, -1):
        X = lambda x: 16 + sgn * (x - 16)
        barb = scroll_path([(X(26.9), 16.2), (X(27.6), 18.6), (X(27.4), 20.6)], 2.6, sgn * 0.85, 0.42)
        parts += pieces_of(tapered(barb, 1.15, 0.7))
        bar = scroll_path(np.vstack([[(X(18.0), 22.0)], bez((X(18.6), 23), (X(22.4), 24.5), (X(22.4), 30), (X(22.2), 44))]),
                          3.0, sgn * 0.9, 0.4)
        parts += pieces_of(tapered(bar, 1.2, 0.75))
    forged(c, parts, pal, bevel=1.0)


def vine_cap(c, pal):
    """A living vine: two stems climb the groove's lips, wrap round its end
    and grow into a broad leaf, the arrow; tendrils curl off at the sides."""
    stems = []
    for sgn in (1, -1):
        X = lambda x: 16 + sgn * (x - 16)
        stem = bez((X(16.6), 20.5), (X(23.8), 22.0), (X(22.6), 30), (X(22.4), 40))
        stem = np.vstack([stem, bez((X(22.4), 40), (X(22.2), 46), (X(24.6), 50), (X(26.4), 48))[1:]])
        stem = scroll_path(stem, 1.9, -sgn * 0.8, 0.45)
        stems += pieces_of(tapered(stem, 1.25, 0.6))
        tend = scroll_path(bez((X(22.8), 27.5), (X(25.8), 26.5), (X(27.6), 28.5), (X(27.8), 31.5), n=20), 1.6, sgn * 0.9, 0.4)
        stems += pieces_of(tapered(tend, 0.6, 0.35))
    forged(c, stems, WOOD, bevel=0.8)
    for sgn in (1, -1):
        X = lambda x: 16 + sgn * (x - 16)
        small = leaf_poly((X(22.6), 36.0), (X(28.6), 39.6), 4.0)
        forged(c, [small], pal, bevel=0.9)
    big = profile([(1.0, 0), (6.0, 3.6), (11.0, 7.4), (15.6, 11.4), (18.4, 10.0), (20.6, 5.6), (22.4, 1.6)], cx=16)
    forged(c, [big], pal, bevel=1.4)
    # its veins pressed in: a midrib and three pairs
    veins = [ribbon([(16, 3.2), (16, 21.0)], 0.32)]
    for y0, y1, dx in ((9.0, 6.0, 5.2), (13.2, 10.6, 7.4), (17.4, 15.4, 6.6)):
        for sgn in (1, -1):
            veins.append(ribbon(bez((16, y0), (16 + sgn * dx * 0.4, y0 - 0.8), (16 + sgn * dx * 0.8, y1 + 0.6), (16 + sgn * dx, y1), n=16),
                                np.linspace(0.28, 0.12, 16)))
    vm = umask(c, veins) * (c.a > 0.5)
    c.over(np.broadcast_to(np.array(pal[0], float), c.rgb.shape), vm * 0.75)


def gold_cap(c, pal):
    """A forged finial: a spearhead with petals rolled outward, a collar set
    with a ruby over the groove's end, and two claws that grip its lips."""
    spear = profile([(1.0, 0), (5.0, 3.2), (9.4, 5.2), (13.0, 3.6), (16.0, 1.8), (19.0, 1.8)], cx=16)
    parts = [spear]
    for sgn in (1, -1):
        X = lambda x: 16 + sgn * (x - 16)
        petal = scroll_path(bez((X(18.0), 18.2), (X(22.0), 15.0), (X(26.0), 9.0), (X(28.6), 9.4)), 2.4, sgn * 0.85, 0.4)
        parts += pieces_of(tapered(petal, 1.5, 0.7))
        claw = bez((X(21.4), 22.4), (X(23.2), 28.0), (X(23.0), 38.0), (X(20.6), 43.6), n=40)
        claw = np.vstack([claw, bez((X(20.6), 43.6), (X(19.8), 45.4), (X(18.8), 45.8), (X(17.6), 45.0), n=14)[1:]])
        parts.append(ribbon(claw, np.concatenate([np.linspace(1.6, 1.1, 40), np.linspace(1.1, 0.15, 13)])))
    collar = [(9.6, 17.6), (22.4, 17.6), (23.6, 20.4), (22.4, 23.2), (9.6, 23.2), (8.4, 20.4)]
    forged(c, parts, pal, bevel=1.0)
    forged(c, [collar], pal, bevel=0.9)
    rib = profile([(3.0, 0), (8.0, 0.45), (14.6, 0.45)], cx=16)
    c.metal(umask(c, [rib]), pal, bevel=0.3 * U, outline=0, shadow=False, gloss=0.9, sheen=False)
    c.gem(16 * U, 20.4 * U, 1.9 * U, RUBY)


# --- the joints: the divider (y 16) meeting the groove (x 44..52) -------------

def iron_joint(c, pal):
    """Blizzard's iron divider ends under a collar (x 20..25); a bar runs on to
    the groove, where scrolls roll up and down along both its lips."""
    parts = [[(20, 11.2), (25, 11.2), (25, 20.8), (20, 20.8)], ribbon([(24, 16), (56, 16)], 1.3)]
    for side in (1, -1):
        x = 41.6 if side == 1 else 54.4
        for up in (1, -1):
            lead = bez((x, 16), (x, 16 - up * 3.0), (x + 0.2 * side, 16 - up * 5.0), (x - 0.6 * side, 16 - up * 7.4), n=20)
            path = scroll_path(lead, 2.2, side * up * -0.85, 0.42)
            parts += pieces_of(tapered(path, 1.25, 0.7))
    parts.append(ribbon([(54.4, 16), (60, 16)], 1.1))
    parts.append((60.2, 16, 1.6))
    forged(c, parts, pal, bevel=0.9)
    for x in (21.4, 23.6):  # the collar's two rings
        c.metal(umask(c, [[(x - 0.55, 11.6), (x + 0.55, 11.6), (x + 0.55, 20.4), (x - 0.55, 20.4)]]), pal,
                bevel=0.3 * U, outline=0, shadow=False, gloss=0.8, sheen=False)


def vine_joint(c, pal):
    """The vine runs in and wraps the groove: a tendril curls up the near lip,
    a leaf hangs below it, and it passes behind the groove to come out past
    the far lip in a curl."""
    stem = ribbon([(-10, 16), (55, 16.6)], 1.05)
    up = scroll_path(bez((40.4, 16), (41.8, 15.4), (42.2, 12), (41.6, 8.6), n=20), 1.9, 0.85, 0.42)
    far = scroll_path(bez((54.0, 17.4), (54.6, 15.6), (55.0, 12.4), (56.6, 10.2), n=20), 1.7, 0.85, 0.42)
    far2 = bez((54.0, 17.4), (54.4, 20.0), (55.6, 21.6), (57.4, 22.4), n=20)
    parts = [stem] + pieces_of(tapered(up, 1.0, 0.55)) + pieces_of(tapered(far, 0.9, 0.5)) + pieces_of(tapered(far2, 0.9, 0.5))
    forged(c, parts, WOOD, bevel=0.75)
    for base, tip, w in (((40.0, 16.8), (36.4, 25.4), 4.4), ((28.0, 16.4), (24.2, 10.8), 3.2), ((57.4, 22.4), (61.6, 27.0), 3.6)):
        forged(c, [leaf_poly(base, tip, w)], pal, bevel=0.8)


def gold_joint(c, pal):
    """The gold rod ends in a beaded collar; claws reach from it to grip the
    groove's near lip above and below, and a pair grips the far lip."""
    parts = [ribbon([(-10, 16), (58, 16)], 1.0)]
    for side, x0 in ((1, 39.6), (-1, 56.4)):
        for up in (1, -1):
            claw = bez((x0 - side * 1.2, 16), (x0, 16 - up * 2.0), (x0 + side * 0.4, 16 - up * 6.0), (x0 + side * 2.6, 16 - up * 8.8), n=30)
            claw = np.vstack([claw, bez((x0 + side * 2.6, 16 - up * 8.8), (x0 + side * 3.2, 16 - up * 9.6), (x0 + side * 4.6, 16 - up * 9.4), (x0 + side * 4.4, 16 - up * 8.6), n=10)[1:]])
            parts.append(ribbon(claw, np.concatenate([np.linspace(1.3, 0.9, 30), np.linspace(0.9, 0.15, 9)])))
    parts.append(ribbon([(56.4, 16), (60.4, 16)], 1.0))
    parts.append((60.6, 16, 1.5))
    parts.append([(35.4, 12.4), (40.4, 12.4), (41.4, 16), (40.4, 19.6), (35.4, 19.6), (34.4, 16)])
    forged(c, parts, pal, bevel=0.9)
    c.gem(37.9 * U, 16 * U, 1.5 * U, RUBY)


# --- our own dividers: the left end, the line, the middle (line at y 8) ------

def vine_rules(c, piece, pal):
    if piece == "Mid":
        forged(c, [ribbon([(-10, 8), (42, 8)], 1.05)], WOOD, bevel=0.75)
        return
    if piece == "Left":
        lead = bez((42, 8), (20, 8), (10.0, 8.2), (7.0, 6.2), n=40)
        forged(c, pieces_of(tapered(scroll_path(lead, 2.4, -0.9, 0.4), 1.05, 0.55)), WOOD, bevel=0.75)
        for base, tip, w in (((13.0, 8.6), (17.6, 14.2), 3.6), ((19.0, 7.6), (23.2, 2.4), 3.2)):
            forged(c, [leaf_poly(base, tip, w)], pal, bevel=0.8)
        return
    forged(c, [ribbon([(-10, 8), (42, 8)], 1.05)], WOOD, bevel=0.75)  # the knot: a bud and a leaf pair
    for base, tip, w in (((15.4, 7.6), (9.0, 2.2), 4.0), ((16.6, 8.4), (23.0, 13.8), 4.0)):
        forged(c, [leaf_poly(base, tip, w)], pal, bevel=0.85)
    forged(c, [(16, 8, 1.8)], pal, bevel=0.8)


def gold_rules(c, piece, pal):
    if piece == "Mid":
        forged(c, [ribbon([(-10, 8), (42, 8)], 1.0)], pal, bevel=0.8)
        return
    if piece == "Left":
        tip = profile([(1.0, 0), (3.6, 2.4), (6.4, 3.0), (8.4, 1.4), (9.6, 0.9)], cx=8)
        tip = [(y, x) for x, y in tip]  # pointing left
        forged(c, [ribbon([(9.0, 8), (42, 8)], 1.0), tip, [(9.2, 5.2), (11.4, 5.2), (11.4, 10.8), (9.2, 10.8)]], pal, bevel=0.8)
        return
    forged(c, [ribbon([(-10, 8), (42, 8)], 1.0), [(16, 2.4), (21.0, 8), (16, 13.6), (11.0, 8)]], pal, bevel=0.9)
    c.gem(16 * U, 8 * U, 2.0 * U, RUBY)


ORNATE = {
    # name: (cap, joint, rules or None for Blizzard's divider, palette)
    "Iron": (iron_cap, iron_joint, None, IRON),
    "Vine": (vine_cap, vine_joint, vine_rules, LEAF),
    "Finial": (gold_cap, gold_joint, gold_rules, GOLD),
}


def ornate_cap(name, down, mode):
    """A cap in one state, the down cap drawn as the up one flipped with its
    light kept (the ornament is drawn on a flipped canvas, then shaded)."""
    cap, _, _, pal = ORNATE[name]
    c = ucanvas(32, 64)
    if mode != "Glow":
        carve4(c, groove_mask(c, GROOVE_TOP, 80, round_top=GROOVE_TOP) if not down else groove_mask(c, -16, 64 - GROOVE_TOP, round_bottom=64 - GROOVE_TOP))
    o = ucanvas(32, 64)
    if mode == "Pushed":
        pal = dim(pal, 0.62)
    elif mode == "Disabled":
        pal = GREY
    draw_flipped(o, cap, pal, down, 64, nudge=1.0 if mode == "Pushed" else 0)
    if mode == "Pushed":
        o.rgb *= 0.85
    if mode == "Disabled":
        g = o.rgb @ np.array([0.3, 0.59, 0.11]); o.rgb = np.repeat(g[..., None], 3, -1) * 0.8
    c.over(o.rgb, o.a)
    return c.final()


def draw_flipped(o, fn, pal, down, h, nudge=0):
    """Draw fn's up shape, flipped for down, by remapping umask's units."""
    global umask
    base = umask

    def mapped(c, polys=(), circles=()):
        f = (lambda y: h - y + nudge) if down else (lambda y: y + nudge)
        return base(c, [[(x, f(y)) for x, y in p] for p in polys], [(x, f(y), r) for x, y, r in circles])
    umask = mapped
    gem = o.gem
    if down or nudge:
        o.gem = lambda cx, cy, r, p, bezel=None: gem(cx, ((h * U - cy) if down else cy) + nudge * U, r, p, bezel)
    try:
        fn(o, pal)
    finally:
        umask = base
        o.gem = gem


def dim(pal, k):
    return tuple(tuple(int(x * k) for x in col) for col in pal)


GREY = ((22, 22, 22), (88, 88, 88), (160, 160, 160))


def glow(inlay):
    """The highlight, drawn for ADD: a warm rim round the ornament."""
    a = inlay[..., 3] / 255
    halo = np.clip(ndimage.gaussian_filter(a, U * 0.8) * 1.8, 0, 1)
    inner = ndimage.gaussian_filter(ndimage.minimum_filter(a, size=int(U * 1.4) | 1), U * 0.4)
    hl = np.zeros_like(inlay)
    hl[..., 0], hl[..., 1], hl[..., 2] = 255, 196, 90
    hl[..., 3] = halo * (1 - inner * 0.6) * 0.85 * 255
    return hl


def ornate_joint(name):
    _, joint, _, pal = ORNATE[name]
    c = ucanvas(64, 32)
    joint(c, pal)  # its bar runs on behind the groove, cut over it
    carve4(c, umask(c, [[(44, -16), (52, -16), (52, 48), (44, 48)]]))
    return c.final()


def render4_one(name):
    out = {}
    for down in (False, True):
        d = "Down" if down else "Up"
        for mode in ("Normal", "Pushed", "Disabled"):
            out["Scroll-%s-%s-%s" % (name, d, mode)] = ornate_cap(name, down, mode)
        c = ucanvas(32, 64)
        draw_flipped(c, ORNATE[name][0], ORNATE[name][3], down, 64)
        out["Scroll-%s-%s-Highlight" % (name, d)] = glow(c.final())
    c = ucanvas(32, 8)
    carve4(c, groove_mask(c, -16, 24))
    out["Scroll-%s-Mid" % name] = c.final()
    out["Scroll-%s-Joint" % name] = ornate_joint(name)
    rules = ORNATE[name][2]
    if rules:
        for piece in ("Left", "Mid", "Knot"):
            c = ucanvas(32, 16)
            rules(c, piece, ORNATE[name][3])
            out["Scroll-%s-%s" % (name, "Knot" if piece == "Knot" else "Rule" + piece)] = c.final()
    return out


# --- the comparison sheet ---------------------------------------------------

def blizzard_divider():
    """QuestLog-frame-devider as the game drew it at 2x on magenta
    (target/div-crop.png, grabbed in game), unmixed to RGBA."""
    im = np.asarray(Image.open(os.path.join(ROOT, "target", "div-crop.png")).convert("RGB"), float)[18:72, 18:353]
    a = np.clip(1 - (im[..., 0] - im[..., 1]) / 255, 0, 1)
    rgb = np.where(a[..., None] > 0.02, (im - (1 - a[..., None]) * np.array([255, 0, 255])) / np.maximum(a[..., None], 0.02), 0)
    out = np.dstack([np.clip(rgb, 0, 255), a * 255 * 0.8])  # the chat draws it at alpha 0.8
    return Image.fromarray(out.astype(np.uint8), "RGBA")


def sheet4(art):
    """Each candidate as a gallery pane: three dividers meeting the groove,
    at the game's 4K size (2.8 px per unit, measured from round 3's panes) and
    4x; then every cap state at 4x, Highlight added over Normal as the game
    does. The thumb is Blizzard's minimal thumb as the game drew it."""
    slate = np.asarray(Image.open(os.path.join(ROOT, "addon", "WowCompanion", "Art", "SlateLight-6.tga")).convert("RGB"), float)
    bliz = blizzard_divider()
    thumb = Image.open(os.path.join(ROOT, "target", "minimal-thumb.png"))
    tw = thumb.width

    def img(stem):
        return Image.fromarray(art[stem].astype(np.uint8), "RGBA")

    def put(base, im, x, y, w, h, u):
        t = im.resize((max(1, round(w * u)), max(1, round(h * u))), Image.LANCZOS)
        base.alpha_composite(t, (round(x * u), round(y * u)))

    def stone(w, h, k=1.0):
        reps = (h // 256 + 1, w // 256 + 1, 1)
        return Image.fromarray((np.tile(slate, reps)[:h, :w] * k).astype(np.uint8)).convert("RGBA")

    def pane(name, u, W=170, H=330):
        col = W - 32
        base = stone(int(W * u), int(H * u))
        dark = stone(int(col * u), int(H * u), 0.8)
        lines = (70, 150, 236)
        for i, y in enumerate(lines):  # the player's turns on the darker stone
            if i % 2 == 0:
                base.alpha_composite(dark.crop((0, 0, int(col * u), int((lines[i + 1] if i + 1 < len(lines) else H) * u - y * u))), (0, round(y * u)))
        for y in lines:
            if ORNATE[name][2]:
                put(base, img("Scroll-%s-RuleLeft" % name), 0, y - 8, 32, 16, u)
                put(base, img("Scroll-%s-RuleMid" % name), 32, y - 8, col - 64, 16, u)
                put(base, img("Scroll-%s-Knot" % name), col / 2 - 16, y - 8, 32, 16, u)
            else:
                put(base, bliz, 0, y - 7.5, col - 10, 15, u)
        tops = [64] + [y + 16 for y in lines]
        bottoms = [y - 16 for y in lines] + [H - 64]
        for t, b in zip(tops, bottoms):
            put(base, img("Scroll-%s-Mid" % name), col, t, 32, b - t, u)
        for y in lines:
            put(base, img("Scroll-%s-Joint" % name), col - 32, y - 16, 64, 32, u)
        put(base, img("Scroll-%s-Up-Normal" % name), col, 0, 32, 64, u)
        put(base, img("Scroll-%s-Down-Normal" % name), col, H - 64, 32, 64, u)
        ty, th = 90, 80
        put(base, thumb.crop((0, 0, tw, tw)), col + 12, ty, 8, 8, u)
        put(base, thumb.crop((0, tw, tw, thumb.height - tw)), col + 12, ty + 8, 8, th - 16, u)
        put(base, thumb.crop((0, thumb.height - tw, tw, thumb.height)), col + 12, ty + th - 8, 8, 8, u)
        return base

    def row(cells, gap=12):
        r = Image.new("RGBA", (sum(c.width for c in cells) + gap * len(cells), max(c.height for c in cells)), (0, 0, 0, 255))
        x = 0
        for c in cells:
            r.paste(c, (x, 0)); x += c.width + gap
        return r

    big = [pane(n, 4 * 2.8 / 2) for n in ORNATE]  # 2x the game's 4K size, to see
    big = [b.crop((b.width - round(110 * 5.6), 0, b.width, round(180 * 5.6))) for b in big]
    rows = [row([pane(n, 2.8) for n in ORNATE]), row(big)]
    for n in ORNATE:
        cells = []
        for d in ("Up", "Down"):
            for s in ("Normal", "Pushed", "Highlight", "Disabled"):
                cell = stone(128, 256)
                if s == "Highlight":
                    cell.alpha_composite(img("Scroll-%s-%s-Normal" % (n, d)).resize((128, 256), Image.LANCZOS))
                    hl = np.asarray(img("Scroll-%s-%s-Highlight" % (n, d)).resize((128, 256), Image.LANCZOS), float)
                    c = np.asarray(cell, float)
                    c[..., :3] = np.clip(c[..., :3] + hl[..., :3] * hl[..., 3:] / 255, 0, 255)
                    cell = Image.fromarray(c.astype(np.uint8), "RGBA")
                else:
                    cell.alpha_composite(img("Scroll-%s-%s-%s" % (n, d, s)).resize((128, 256), Image.LANCZOS))
                cells.append(cell)
        rows.append(row(cells, 4))
    W = max(r.width for r in rows)
    out = Image.new("RGBA", (W, sum(r.height + 12 for r in rows)), (0, 0, 0, 255))
    y = 0
    for r in rows:
        out.paste(r, (0, y)); y += r.height + 12
    path = os.path.join(ROOT, "target", "scrollbar-sheet-4.png")
    out.convert("RGB").save(path)
    return path


def main():
    from concurrent.futures import ProcessPoolExecutor
    with ProcessPoolExecutor() as pool:  # every design at once
        spear = pool.submit(render)
        art4 = {}
        for part in pool.map(render4_one, ORNATE):
            art4.update(part)
        art = spear.result()
    for old in glob.glob(os.path.join(OUT, "Scroll-*.tga")):
        os.remove(old)
    for stem, rgba in art.items():
        write_tga(os.path.join(OUT, "%s-%d.tga" % (stem, VERSION)), rgba)
    for stem, rgba in art4.items():
        write_tga(os.path.join(OUT, "%s-%d.tga" % (stem, VERSION4)), rgba)
    print(len(art) + len(art4), "textures;", sheet4(art4))


if __name__ == "__main__":
    main()
