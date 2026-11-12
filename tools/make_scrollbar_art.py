"""The chat's scroll bar candidates (the Scroll bars tab, ScrollGallery.lua),
drawn here as vector shapes, bevelled and lit from the top left, at 16x and
averaged down, never Blizzard's art.

    python tools/make_scrollbar_art.py   writes addon/WowCompanion_Agent/Art/Scroll-*-<v>.tga
                                         and target/scrollbar-sheet-3.png (the comparison sheet)

The game keeps a texture for the session under its path, so a change bumps
the version (VERSION for the spearhead, VERSION3 for the carved ones, and
ScrollGallery.lua's art()); older files are deleted.

The spearhead (round 1, kept): an up and a down arrow in four states (Normal,
Pushed, Highlight drawn for ADD blending, Disabled), 32x32 shown at 16x16, set
over Blizzard's slim bar; a rod tile (RuleMid, 16x32, shown 8 wide, repeated
down), its caps (RuleTop, RuleBottom, 16x16) and the joint where a divider
meets it (Joint, 32x32). The down arrow is drawn mirrored, not flipped, so its
light still comes from the top left. Round 3's carved grooves: see below.
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
    """A w x h picture in final pixels, drawn at S times with `pad` pixels of
    room on every side (shapes running off the edge, such as a rod, continue
    into it so they get no bevel where they are cut)."""

    def __init__(self, w, h, pad=6):
        self.w, self.h, self.pad = w, h, pad
        self.W, self.H = (w + 2 * pad) * S, (h + 2 * pad) * S
        self.rgb = np.zeros((self.H, self.W, 3))
        self.a = np.zeros((self.H, self.W))

    def xy(self, pts):
        return [((x + self.pad) * S, (y + self.pad) * S) for x, y in pts]

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
            sh = ndimage.shift(ndimage.gaussian_filter(m, S * 0.7), (S * 0.9, S * 0.6), order=1)
            self.over(np.zeros_like(self.rgb), sh * 0.55)
        if outline:
            o = ndimage.gaussian_filter(ndimage.maximum_filter(m, size=int(outline * 2 * S) | 1), S * 0.25)
            self.over(np.broadcast_to(np.array(OUTLINE, float), self.rgb.shape), o * 0.95)
        d = ndimage.distance_transform_edt(inside) / S
        if dome:
            r = d / max(d.max(), 1e-6)
            hgt = np.sqrt(np.clip(1 - (1 - r) ** 2, 0, 1)) * d.max()
        else:
            t = np.clip(d / bevel, 0, 1)
            hgt = (1 - (1 - t) ** 2) * bevel
        hgt = ndimage.gaussian_filter(hgt, S * 0.18)
        gy, gx = np.gradient(hgt * S)
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
        p = self.pad * S
        rgb = self.rgb[p:self.H - p, p:self.W - p]
        a = self.a[p:self.H - p, p:self.W - p]
        h, w = self.h, self.w
        pre = (rgb * a[..., None]).reshape(h, S, w, S, 3).mean((1, 3))
        al = a.reshape(h, S, w, S).mean((1, 3))
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




# --- round 3: the bar carved into the panel ----------------------------------
#
# A recess, not an object: Blizzard's MinimalScrollBar track measured in game
# is black at alpha 0.84 with a faint light rim; here its inner walls are
# shaded from a depth field under the same top-left light (the top wall in
# shadow, the bottom wall and the stone's bottom lip lit). Every piece of a
# design is one mask shaded once: the groove, its arrow-pointed ends, and
# where a divider runs into it. In UI units, V px each; the column is 20
# wide, the groove 8 (x 6..14); the thumb is Blizzard's own.
#   <Up|Down>-<state> 20x40: the groove's end, its recess and the arrow inlaid in it
#     (the button); the groove runs on out of its far edge
#   Mid 20x5: the groove alone, the same on every row (stretched)
#   Joint 40x20: where a divider meets the groove, centred on the column's
#     left edge (x 20) and the divider's line (y 10); the groove runs through
#   RuleLeft 20x10, RuleMid 20x10: our own divider's left end and its line

VERSION3 = 3
V = 3.2
GROOVE_HW = 4.0
GREY = ((22, 22, 22), (78, 78, 78), (150, 150, 150))


def v(pts):
    return [(x * V, y * V) for x, y in pts]


def vcanvas(w, h, pad=10):
    return Canvas(round(w * V), round(h * V), pad)


def profile(pts, cx=10):
    """A shape symmetric about x = cx from (y, half-width) knots, smoothed."""
    from scipy.interpolate import PchipInterpolator
    ys = np.array([p[0] for p in pts], float)
    f = PchipInterpolator(ys, [p[1] for p in pts])
    yy = np.linspace(ys[0], ys[-1], 200)
    hw = np.maximum(f(yy), 0)
    return [(cx + w, y) for y, w in zip(yy, hw)] + [(cx - w, y) for y, w in zip(yy[::-1], hw[::-1])]


def stroke(path, hw):
    """A polyline (units) as a polygon `hw` wide either side, joints mitred."""
    p = np.array(path, float)
    left, right = [], []
    for i in range(len(p)):
        a, b = p[max(i - 1, 0)], p[min(i + 1, len(p) - 1)]
        d = b - a
        n = np.array([-d[1], d[0]]) / np.linalg.norm(d)
        if 0 < i < len(p) - 1:
            d1, d2 = p[i] - p[i - 1], p[i + 1] - p[i]
            n1 = np.array([-d1[1], d1[0]]) / np.linalg.norm(d1)
            n2 = np.array([-d2[1], d2[0]]) / np.linalg.norm(d2)
            n = (n1 + n2) / np.linalg.norm(n1 + n2)
            n = n / max(np.dot(n, n1), 0.5)
        left.append(tuple(p[i] + n * hw))
        right.append(tuple(p[i] - n * hw))
    return left + right[::-1]


def carve(c, m, depth=1.0, floor=0.84):
    """A recess cut in the stone where `m` is: dark floor, walls shaded from a
    depth field (top-left light), a faint light rim and the lit bottom lip."""
    k = V * S  # supersampled px per unit
    inside = m > 0.5
    du = ndimage.distance_transform_edt(inside) / k
    t = np.clip(du / depth, 0, 1)
    h = -(1 - (1 - t) ** 2) * depth * V * 1.3
    h = ndimage.gaussian_filter(h, k * 0.18, mode="nearest")
    gy, gx = np.gradient(h * S)
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


def leaf(c, mask, pal):
    """Metal laid flat in an engraving: no shadow of its own."""
    c.metal(mask, pal, bevel=0.35 * V, outline=0, shadow=False, sheen=False, gloss=0.5)


def dim(pal, k):
    return tuple(tuple(int(x * k) for x in col) for col in pal)


# Each design: its recess as (y, half-width) knots, up orientation (the tip
# at the top), and its inlay drawn by a function (canvas, placement, palette,
# drop shadow).

def recess_lancet():
    return profile([(1.6, 0), (4.5, 2.4), (8.5, 4.6), (12.0, 6.0), (14.2, 5.7), (16.0, 4.5), (17.6, GROOVE_HW), (60, GROOVE_HW)])


def inlay_lancet(c, f, pal, sh):
    """Option 1's bronze spearhead, set into a leaf-shaped recess."""
    blade = profile([(3.4, 0), (6.0, 1.7), (9.4, 3.4), (12.0, 4.3), (13.6, 3.4), (15.4, 0.9)])
    c.metal(c.mask([v(f(blade))]), pal, bevel=0.75 * V, outline=0.5, shadow=sh, sheen=False)
    rib = profile([(5.0, 0), (9.0, 0.35), (14.4, 0.35)])
    c.metal(c.mask([v(f(rib))]), pal, bevel=0.3 * V, outline=0, shadow=False, gloss=0.9, sheen=False)


def recess_chevron():
    return profile([(1.8, 0), (4.0, 2.6), (8.0, 5.4), (12.0, 6.4), (15.0, 5.8), (17.4, 4.6), (19.0, GROOVE_HW), (60, GROOVE_HW)])


def inlay_chevron(c, f, pal, sh):
    """A gold chevron laid in a pointed-arch recess, a gold drop under it."""
    c.metal(c.mask([v(f(stroke([(5.6, 11.6), (10, 5.6), (14.4, 11.6)], 1.3)))]), pal, bevel=0.6 * V, outline=0.5, shadow=sh, sheen=False)
    c.metal(c.mask([v(f([(10, 11.0), (11.4, 13.4), (10, 15.8), (8.6, 13.4)]))]), pal, bevel=0.45 * V, outline=0.4, shadow=sh, sheen=False)


def recess_socket():
    return profile([(1.8, 0), (3.6, 2.6), (6.2, 5.2), (9.6, 6.6), (13.0, 6.2), (16.0, 4.8), (18.4, GROOVE_HW), (60, GROOVE_HW)])


def inlay_socket(c, f, pal, sh):
    """A sapphire cut as an arrow, set in a teardrop socket."""
    c.metal(c.mask([v(f([(10, 4.4), (14.6, 13.6), (5.4, 13.6)]))]), pal, bevel=2.2 * V, outline=0.4, shadow=sh, gloss=1.0, sheen=False)


CARVED = {
    # name: (recess, inlay, inlay palette, divider)
    "Lancet": (recess_lancet, inlay_lancet, BRONZE, "blizzard"),
    "Chevron": (recess_chevron, inlay_chevron, GOLD, "engraved"),
    "Socket": (recess_socket, inlay_socket, SAPPHIRE, "inlaid"),
}


def carved_cap(name, down, mode):
    """A cap in one state; the down cap is drawn mirrored, its light kept.
    Pushed sinks the inlay (darker, no shadow, nudged); Glow is the inlay
    alone, for the highlight."""
    recess, inlay, pal, _ = CARVED[name]

    def f(p):
        return [(x, 40 - y) for x, y in p] if down else list(p)
    c = vcanvas(20, 40)
    if mode != "Glow":
        carve(c, c.mask([v(f(recess()))]))
    if mode == "Pushed":
        inlay(c, lambda p: [(x + 0.4, y + 1.0) for x, y in f(p)], dim(pal, 0.6), False)
    elif mode == "Disabled":
        inlay(c, f, GREY, True)
    else:
        inlay(c, f, pal, mode == "Normal")
    return c.final()


def glow(inlay):
    """The highlight, drawn for ADD: a warm rim round the inlay."""
    a = inlay[..., 3] / 255
    halo = np.clip(ndimage.gaussian_filter(a, V * 0.7) * 1.8, 0, 1)
    inner = ndimage.gaussian_filter(ndimage.minimum_filter(a, size=int(V * 1.2) | 1), V * 0.4)
    hl = np.zeros_like(inlay)
    hl[..., 0], hl[..., 1], hl[..., 2] = 255, 196, 90
    hl[..., 3] = halo * (1 - inner * 0.7) * 0.85 * 255
    return hl


def groove_poly(x0=6, y0=-20, y1=60):
    return [(x0, y0), (x0 + 2 * GROOVE_HW, y0), (x0 + 2 * GROOVE_HW, y1), (x0, y1)]


def rod_inlay(c, x0, x1, y, round_left=False, round_right=True):
    """A bronze rod laid in a channel, its top flush with the stone."""
    circles = [(x * V, y * V, 0.8 * V) for x, r in ((x0, round_left), (x1, round_right)) if r]
    c.metal(c.mask([v([(x0, y - 0.8), (x1, y - 0.8), (x1, y + 0.8), (x0, y + 0.8)])], circles=circles),
            BRONZE, bevel=0.55 * V, outline=0.3, shadow=True, sheen=False, gloss=0.6)


def channel_hw(kind):
    return {"engraved": 0.75, "inlaid": 1.4, "blizzard": 2.6}[kind]


def carved_joint(name):
    """The groove (x 26..34) with the divider's way into it, one mask."""
    kind = CARVED[name][3]
    c = vcanvas(40, 20)
    groove = c.mask([v(groove_poly(26))])
    # the divider's line runs on as a channel and flares into the groove's
    # wall with a curved mouth; Blizzard's divider ends at x 20, its curl
    # lying in the channel's rounded end, so nothing stops at a straight cut
    start = 12 if kind == "blizzard" else -10
    # the channel flares into the groove's wall with a curved mouth
    xs = np.linspace(start, 26.5, 80)
    flare = channel_hw(kind) + 1.8 * np.clip((xs - 20.5) / 6, 0, 1) ** 2
    mouth = [(x, 10 - w) for x, w in zip(xs, flare)] + [(x, 10 + w) for x, w in zip(xs[::-1], flare[::-1])]
    end = [(start * V, 10 * V, channel_hw(kind) * V)] if kind == "blizzard" else []
    carve(c, np.maximum(groove, c.mask([v(mouth)], circles=end)))
    if kind == "blizzard":
        return c.final()
    if kind == "engraved":
        leaf(c, c.mask([v([(-10, 9.62), (24.2, 9.62), (24.2, 10.38), (-10, 10.38)])]), GOLD)
    else:
        rod_inlay(c, -10, 24.6, 10)
    return c.final()


def carved_rules(name):
    """Our own divider: its line (Mid, stretched) and its left end."""
    kind = CARVED[name][3]
    hw = channel_hw(kind)
    out = {}
    c = vcanvas(20, 10)
    carve(c, c.mask([v([(-10, 5 - hw), (30, 5 - hw), (30, 5 + hw), (-10, 5 + hw)])]))
    if kind == "engraved":
        leaf(c, c.mask([v([(-10, 4.62), (30, 4.62), (30, 5.38), (-10, 5.38)])]), GOLD)
    else:
        rod_inlay(c, -10, 30, 5, round_right=False)
    out["Mid"] = c.final()
    c = vcanvas(20, 10)
    line = c.mask([v([(6, 5 - hw), (30, 5 - hw), (30, 5 + hw), (6, 5 + hw)])])
    if kind == "engraved":  # the line ends in an engraved lozenge, gold in it
        carve(c, np.maximum(c.mask([v([(1.0, 5), (4.6, 1.6), (8.2, 5), (4.6, 8.4)])]), line))
        leaf(c, c.mask([v([(2.4, 5), (4.6, 2.9), (6.8, 5), (4.6, 7.1)])]), GOLD)
        leaf(c, c.mask([v([(6.6, 4.62), (30, 4.62), (30, 5.38), (6.6, 5.38)])]), GOLD)
    else:  # the channel ends in a round socket holding a sapphire
        carve(c, np.maximum(c.mask(circles=[(4.2 * V, 5 * V, 3.0 * V)]), line))
        rod_inlay(c, 6.6, 30, 5, round_left=True, round_right=False)
        c.metal(c.mask(circles=[(4.2 * V, 5 * V, 2.0 * V)]), SAPPHIRE, outline=0.4, shadow=True, dome=True, gloss=1.0, sheen=False)
    out["Left"] = c.final()
    return out


def render3():
    from concurrent.futures import ProcessPoolExecutor
    out = {}
    with ProcessPoolExecutor() as pool:
        for part in pool.map(render3_one, CARVED):
            out.update(part)
    return out


def render3_one(name):
    """One design's textures (render3 draws the designs side by side)."""
    out = {}
    for down in (False, True):
        d = "Down" if down else "Up"
        for mode in ("Normal", "Pushed", "Disabled"):
            out["Scroll-%s-%s-%s" % (name, d, mode)] = carved_cap(name, down, mode)
        out["Scroll-%s-%s-Highlight" % (name, d)] = glow(carved_cap(name, down, "Glow"))
    c = vcanvas(20, 5)
    carve(c, c.mask([v(groove_poly())]))
    out["Scroll-%s-Mid" % name] = c.final()
    out["Scroll-%s-Joint" % name] = carved_joint(name)
    if CARVED[name][3] != "blizzard":
        for k, img in carved_rules(name).items():
            out["Scroll-%s-Rule%s" % (name, k)] = img
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


def sheet3(art):
    """Each candidate on the player's stone, two dividers meeting the groove,
    at on-screen size (1.8 px per unit) and 4x; then every cap state at 4x,
    Highlight as the game adds it over Normal. The thumb is Blizzard's
    minimal thumb as the game drew it (target/minimal-thumb.png)."""
    slate = np.asarray(Image.open(os.path.join(ROOT, "addon", "WowCompanion", "Art", "SlateLight-6.tga")).convert("RGB"), float)
    bliz = blizzard_divider()
    thumb = Image.open(os.path.join(ROOT, "target", "minimal-thumb.png"))
    tw = thumb.width  # its ends are 8 units, as tall as it is wide

    def img(stem):
        return Image.fromarray(art[stem].astype(np.uint8), "RGBA")

    def put(base, im, x, y, w, h, u):
        t = im.resize((max(1, round(w * u)), max(1, round(h * u))), Image.LANCZOS)
        base.alpha_composite(t, (round(x * u), round(y * u)))

    def stone(w, h):
        reps = (h // 256 + 1, w // 256 + 1, 1)
        return Image.fromarray(np.tile(slate, reps)[:h, :w].astype(np.uint8)).convert("RGBA")

    def pane(name, u):
        W, H, col = 120, 170, 100  # the column from x 100 to 120
        base = stone(int(W * u), int(H * u))
        joints = (60, 118)
        # in the game's order: joints (the text frame's BORDER), dividers, the column
        for y in joints:
            put(base, img("Scroll-%s-Joint" % name), col - 20, y - 10, 40, 20, u)
        for y in joints:
            if CARVED[name][3] == "blizzard":
                put(base, bliz, 0, y - 7.5, col, 15, u)
            else:
                put(base, img("Scroll-%s-RuleLeft" % name), 0, y - 5, 20, 10, u)
                put(base, img("Scroll-%s-RuleMid" % name), 20, y - 5, col - 40, 10, u)
        tops = [40] + [y + 10 for y in joints]
        bottoms = [y - 10 for y in joints] + [H - 40]
        for t, b in zip(tops, bottoms):
            put(base, img("Scroll-%s-Mid" % name), col, t, 20, b - t, u)
        put(base, img("Scroll-%s-Up-Normal" % name), col, 0, 20, 40, u)
        put(base, img("Scroll-%s-Down-Normal" % name), col, H - 40, 20, 40, u)
        ty, th = 30, 40
        put(base, thumb.crop((0, 0, tw, tw)), col + 6, ty, 8, 8, u)
        put(base, thumb.crop((0, tw, tw, thumb.height - tw)), col + 6, ty + 8, 8, th - 16, u)
        put(base, thumb.crop((0, thumb.height - tw, tw, thumb.height)), col + 6, ty + th - 8, 8, 8, u)
        return base

    def row(cells, gap=12):
        r = Image.new("RGBA", (sum(c.width for c in cells) + gap * len(cells), max(c.height for c in cells)), (0, 0, 0, 255))
        x = 0
        for c in cells:
            r.paste(c, (x, 0)); x += c.width + gap
        return r

    rows = [row([pane(n, 1.8) for n in CARVED]), row([pane(n, 4 * 1.8) for n in CARVED])]
    for n in CARVED:
        cells = []
        for d in ("Up", "Down"):
            for s in ("Normal", "Pushed", "Highlight", "Disabled"):
                cell = stone(144, 288)
                if s == "Highlight":
                    cell.alpha_composite(img("Scroll-%s-%s-Normal" % (n, d)).resize((144, 288), Image.LANCZOS))
                    hl = np.asarray(img("Scroll-%s-%s-Highlight" % (n, d)).resize((144, 288), Image.LANCZOS), float)
                    c = np.asarray(cell, float)
                    c[..., :3] = np.clip(c[..., :3] + hl[..., :3] * hl[..., 3:] / 255, 0, 255)
                    cell = Image.fromarray(c.astype(np.uint8), "RGBA")
                else:
                    cell.alpha_composite(img("Scroll-%s-%s-%s" % (n, d, s)).resize((144, 288), Image.LANCZOS))
                cells.append(cell)
        rows.append(row(cells, 4))
    W = max(r.width for r in rows)
    out = Image.new("RGBA", (W, sum(r.height + 12 for r in rows)), (0, 0, 0, 255))
    y = 0
    for r in rows:
        out.paste(r, (0, y)); y += r.height + 12
    path = os.path.join(ROOT, "target", "scrollbar-sheet-3.png")
    out.convert("RGB").save(path)
    return path




def main():
    art = render()
    art3 = render3()
    for old in glob.glob(os.path.join(OUT, "Scroll-*.tga")):
        os.remove(old)
    for stem, rgba in art.items():
        write_tga(os.path.join(OUT, "%s-%d.tga" % (stem, VERSION)), rgba)
    for stem, rgba in art3.items():
        write_tga(os.path.join(OUT, "%s-%d.tga" % (stem, VERSION3)), rgba)
    print(len(art) + len(art3), "textures;", sheet3(art3))


if __name__ == "__main__":
    main()
