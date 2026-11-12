"""The chat's scroll bar candidates (the Scroll bars tab, ScrollGallery.lua),
drawn here as vector shapes, bevelled and lit from the top left, at 16x and
averaged down, never Blizzard's art.

    python tools/make_scrollbar_art.py   writes addon/WowCompanion_Agent/Art/Scroll-*-<v>.tga
                                         and target/scrollbar-sheet-2.png (the comparison sheet)

The game keeps a texture for the session under its path, so a change bumps
the version (VERSION for the spearhead, VERSION2 for the rest, and
ScrollGallery.lua's art()); older files are deleted.

The spearhead (round 1, kept): an up and a down arrow in four states (Normal,
Pushed, Highlight drawn for ADD blending, Disabled), 32x32 shown at 16x16, set
over Blizzard's slim bar; a rod tile (RuleMid, 16x32, shown 8 wide, repeated
down), its caps (RuleTop, RuleBottom, 16x16) and the joint where a divider
meets it (Joint, 32x32). The down arrow is drawn mirrored, not flipped, so its
light still comes from the top left. Round 2's one-piece bars: see below.
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




# --- round 2: the bar as one object ------------------------------------------
#
# Drawn in UI units at U px each. The column is 20 wide; the bar 14 wide,
# centred: rails 2.5 wide either side of a 9-wide groove. A piece is one mask
# shaded once, so rails, caps and joints share one silhouette and one bevel.
#   Cap-Up/Down-<state> 16x16: the bar's end, its far half the arrow (the button)
#   Mid 16x4: rails and groove, the same on every row (stretched)
#   Thumb-Top/Mid/Bottom 8x4: the thumb riding in the groove
#   Joint 16x16: where a divider meets the left rail, its right edge on the
#     groove (canvas x 13.5..16 is the rail; the divider's line at y 8)
#   RuleLeft 16x8, RuleMid 16x8: a custom divider's left end and its line
#     (stretched), for the designs that draw their own

VERSION2 = 2
U = 4
BLACKIRON = ((6, 5, 4), (44, 40, 30), (126, 114, 84))  # the quest log divider's own iron
RUBY = ((60, 0, 8), (190, 24, 40), (255, 150, 160))
GROOVE = (13, 12, 11)


def u(pts):
    return [(x * U, y * U) for x, y in pts]


def ucanvas(w, h, pad=6):
    return Canvas(w * U, h * U, pad)


def groove(c, m, light):
    """A recess: dark, its top-left inner edge in shadow, its bottom-right
    inner edge catching the light."""
    d = 0.7 * U * S
    # 'nearest': a tile's top and bottom rows continue, so it stretches clean
    under = ndimage.gaussian_filter(ndimage.shift(m, (d, d), order=1, mode="nearest"), U * S * 0.35, mode="nearest")
    over = ndimage.gaussian_filter(ndimage.shift(m, (-d, -d), order=1, mode="nearest"), U * S * 0.35, mode="nearest")
    col = np.broadcast_to(np.array(GROOVE, float), c.rgb.shape).copy()
    col *= (1 - 0.8 * np.clip(1 - under, 0, 1))[..., None]
    col += np.clip(1 - over, 0, 1)[..., None] * np.array(light[1], float) * 0.35
    c.over(np.clip(col, 0, 255), m)


def profile(pts, cx=8):
    """A shape symmetric about x = cx from (y, half-width) pairs, far end first."""
    return [(cx + w, y) for y, w in pts] + [(cx - w, y) for y, w in reversed(pts)]


GROOVE_TOP = {"Sceptre": 11.5, "Blackiron": 12.5, "Onion": 13}


def body_sceptre():
    """Gold: the rails meet in a pointed arch with a ruby cut as an arrow."""
    arch = [(0.6, 0)] + [(10 - 9.4 * s, 7 * (1 - s ** 1.6)) for s in np.linspace(1, 0, 14)[1:]] + [(30, 7)]
    return [("metal", [profile(arch)], GOLD, dict(bevel=2.2 * U / 2)),
            ("gem_tri", [[(8, 3.2), (10.9, 9.2), (5.1, 9.2)]], RUBY, GOLD)]


def body_blackiron():
    """The divider's iron: the rails flare at a bronze-banded collar into a
    broad arrowhead, its barbs curled back like the divider's own ends, a
    bronze arrow raised on it."""
    head = [(0.7, 0), (2.5, 2.4), (5.5, 5.6), (7.4, 7.9), (8.4, 7.4), (9.0, 6.0), (9.6, 7.2), (10.6, 7.2), (30, 7)]
    return [("metal", [profile(head)], BLACKIRON, dict(bevel=1.8 * U / 2, gloss=0.35)),
            ("gem_tri", [[(8, 2.8), (11.0, 7.0), (5.0, 7.0)]], BRONZE, BRONZE)]


def body_onion():
    """Iron with a gold rim: the rails pinch at a neck and swell into an onion
    finial, a sapphire cut as an arrow at its heart."""
    onion = [(0.4, 0), (1.6, 1.6), (3.0, 3.9), (5.0, 6.4), (7.4, 7.6), (9.6, 7.2), (11.2, 6.1), (12.4, 7), (30, 7)]
    return [("metal", [profile(onion)], IRON, dict(bevel=1.8 * U / 2, gloss=0.4)),
            ("rim", [profile(onion)], GOLD),
            ("gem_tri", [[(8, 4.0), (10.7, 9.4), (5.3, 9.4)]], SAPPHIRE, GOLD)]


BODIES = {"Sceptre": (body_sceptre, GOLD, GOLD), "Blackiron": (body_blackiron, BLACKIRON, BRONZE),
          "Onion": (body_onion, IRON, GOLD)}


def draw_layers(c, layers, flip=False):
    f = (lambda m: np.flipud(m)) if flip else (lambda m: m)
    for layer in layers:
        kind = layer[0]
        if kind == "metal":
            c.metal(f(c.mask(polys=[u(p) for p in layer[1]])), layer[2], sheen=False, outline=1.6, **layer[3])
        elif kind == "groove":
            groove(c, f(layer[1]), layer[2])
        elif kind == "inlay":  # a thin raised line of another metal
            c.metal(f(c.mask(polys=[u(p) for p in layer[1]])), layer[2], bevel=1.2, outline=0.6, shadow=False, sheen=False)
        elif kind == "rim":  # a gold line inside the edge
            m = c.mask(polys=[u(p) for p in layer[1]]) > 0.5
            ring = (ndimage.binary_erosion(m, iterations=int(0.7 * U * S), border_value=1)
                    & ~ndimage.binary_erosion(m, iterations=int(1.15 * U * S), border_value=1))
            c.metal(f(ring.astype(float)), layer[2], bevel=0.9, outline=0, shadow=False, sheen=False)
        elif kind == "gem":
            (cx, cy, r), pal, bezel = layer[1], layer[2], layer[3]
            c.metal(f(c.mask(circles=[(cx * U, cy * U, (r + 0.9) * U)])), bezel, bevel=1.4, shadow=False, sheen=False)
            c.metal(f(c.mask(circles=[(cx * U, cy * U, r * U)])), pal, outline=0.6, shadow=False, dome=True, gloss=1.0, sheen=False)
        elif kind == "gem_tri":
            tri, pal, bezel = layer[1][0], layer[2], layer[3]
            m = c.mask(polys=[u(tri)]) > 0.5
            c.metal(f(ndimage.binary_dilation(m, iterations=int(0.8 * U * S)).astype(float)), bezel, bevel=1.4, shadow=False, sheen=False)
            c.metal(f(m.astype(float)), pal, outline=0.6, shadow=False, dome=True, gloss=1.0, sheen=False)


def rails_mask(c, y0=-10, y1=40):
    return c.mask(polys=[u([(1, y0), (15, y0), (15, y1), (1, y1)])])


def groove_mask(c, top):
    """The groove from `top` down past the canvas, its top end round."""
    m = Image.new("L", (c.W, c.H), 0)
    x0, y0 = c.xy([(3.5 * U, top * U)])[0]
    x1, y1 = c.xy([(12.5 * U, 40 * U)])[0]
    ImageDraw.Draw(m).rounded_rectangle([x0, y0, x1, y1], radius=4.4 * U * S, fill=255)
    return np.asarray(m, float) / 255


def cap_states(img):
    """The far end is the button: pushed darkens it, highlight glows round
    it, disabled greys it; each fades out toward the rails so the cap stays
    one piece with the bar. `img` is the up cap; the down cap is flipped after."""
    h = img.shape[0]
    w = np.clip((0.75 - np.arange(h) / h) / 0.35, 0, 1)[:, None]  # 1 at the tip
    rgb, a = img[..., :3], img[..., 3] / 255
    pushed = img.copy()
    pushed[..., :3] = rgb * (1 - 0.32 * w[..., None])
    halo = np.clip(ndimage.gaussian_filter(a, U * 0.9) * 1.8, 0, 1)
    inner = ndimage.gaussian_filter(ndimage.minimum_filter(a, size=U * 2 + 1), U * 0.5)
    hl = np.zeros_like(img)
    hl[..., 0], hl[..., 1], hl[..., 2] = 255, 196, 90
    hl[..., 3] = halo * (1 - inner * 0.7) * 0.85 * w * 255
    grey = (rgb @ np.array([0.3, 0.59, 0.11]))[..., None] * 0.55 + 14
    dis = img.copy()
    dis[..., :3] = rgb * (1 - w[..., None]) + grey * w[..., None]
    return {"Normal": img, "Pushed": pushed, "Highlight": hl, "Disabled": dis}


def render2():
    out = {}
    for name, (body, metal, thumb_metal) in BODIES.items():
        for down in (False, True):
            c = ucanvas(16, 16)
            layers = body()
            draw_layers(c, layers[:1], down)
            draw_layers(c, [("groove", groove_mask(c, GROOVE_TOP[name]), metal)], down)
            draw_layers(c, layers[1:], down)
            img = c.final()
            for state, s in cap_states(np.flipud(img) if down else img).items():
                out["Scroll-%s-Cap-%s-%s" % (name, "Down" if down else "Up", state)] = np.flipud(s) if down else s
        c = ucanvas(16, 4, pad=0)
        c.metal(rails_mask(c), metal, bevel=2.2 * U / 2 if name == "Sceptre" else 1.8 * U / 2, outline=1.6, sheen=False,
                gloss=0.55 if name == "Sceptre" else 0.4)
        groove(c, groove_mask(c, -40), metal)
        if name == "Onion":
            draw_layers(c, [("rim", [[(1, -10), (15, -10), (15, 40), (1, 40)]], GOLD)])
        out["Scroll-%s-Mid" % name] = c.final()
        # the thumb drawn once, a pill 16 tall, and cut: its ends, and a
        # middle slice (the same on every row) to stretch between them
        c = Canvas(8 * U, 16 * U)
        m = Image.new("L", (c.W, c.H), 0)
        (x0, y0), (x1, y1) = c.xy([(0.6 * U, 0.4 * U), (7.4 * U, 15.6 * U)])
        ImageDraw.Draw(m).rounded_rectangle([x0, y0, x1, y1], radius=3.3 * U * S, fill=255)
        c.metal(np.asarray(m, float) / 255, thumb_metal, dome=True, glow=False, gloss=0.8, outline=1.2, sheen=False)
        pill = c.final()
        out["Scroll-%s-Thumb-Top" % name] = pill[:4 * U]
        out["Scroll-%s-Thumb-Mid" % name] = pill[6 * U:10 * U]
        out["Scroll-%s-Thumb-Bottom" % name] = pill[12 * U:]
        out.update(dividers(name))
    return out


def rule_line(c, pal, y=4, x0=-10, x1=40, w=2.2):
    c.metal(c.mask(polys=[u([(x0, y - w / 2), (x1, y - w / 2), (x1, y + w / 2), (x0, y + w / 2)])]), pal,
            bevel=w * U / 2, outline=1.2, shadow=True, sheen=False, gloss=0.5)


def dividers(name):
    out = {}
    c = ucanvas(16, 16)
    if name == "Sceptre":  # the gold line flares into a collar round the rail, a ruby on it
        c.metal(c.mask(polys=[u([(-10, 6.9), (6, 6.9), (13.5, 4.2), (16, 4.2), (16, 11.8), (13.5, 11.8), (6, 9.1), (-10, 9.1)])]),
                GOLD, bevel=1.1 * U, outline=1.6, sheen=False)
        draw_layers(c, [("gem_tri", [[(12.2, 8), (9.6, 6.3), (9.6, 9.7)]], RUBY, GOLD)])
    elif name == "Blackiron":  # Blizzard's divider ends in a socket of its own iron
        c.metal(c.mask(polys=[u([(8.2, 1.4), (16, 0.4), (16, 15.6), (8.2, 14.6), (9.4, 8)])]), BLACKIRON,
                bevel=0.8 * U, outline=1.6, sheen=False, gloss=0.35)
        draw_layers(c, [("inlay", [[(9.4, 2.2), (10.4, 2.1), (11.4, 8), (10.4, 13.9), (9.4, 13.8), (10.4, 8)]], BRONZE),
                        ("gem", (13.2, 8, 1.4), BRONZE, BRONZE)])
    else:  # Onion: the iron line, gold-inlaid, held by a riveted strap round the rail
        rule_line(c, IRON, y=8, x1=12)
        c.metal(c.mask(polys=[u([(10.5, 5), (16, 5), (16, 11), (10.5, 11)])]), IRON, bevel=0.8 * U, outline=1.6, sheen=False, gloss=0.4)
        draw_layers(c, [("inlay", [[(-10, 7.75), (10.5, 7.75), (10.5, 8.25), (-10, 8.25)]], GOLD)])
        c.metal(c.mask(circles=[(12.3 * U, 8 * U, 1.0 * U), (14.8 * U, 8 * U, 1.0 * U)]), GOLD, bevel=0.8 * U, outline=0.8, shadow=False, sheen=False)
    out["Scroll-%s-Joint" % name] = c.final()
    if name == "Blackiron":
        return out
    pal = GOLD if name == "Sceptre" else IRON
    c = ucanvas(16, 8, pad=0)
    rule_line(c, pal, w=2.2)
    if name == "Onion":
        draw_layers(c, [("inlay", [[(-10, 3.75), (40, 3.75), (40, 4.25), (-10, 4.25)]], GOLD)])
    out["Scroll-%s-RuleMid" % name] = c.final()
    c = ucanvas(16, 8)
    if name == "Sceptre":  # the line ends in the cap's own pointed arch, turned left
        top = [(1 + 7 * s, 4 - 2.6 * (1 - (1 - s) ** 1.6)) for s in np.linspace(0, 1, 10)[1:]]
        bottom = [(x, 8 - y) for x, y in reversed(top)]
        c.metal(c.mask(polys=[u([(0.6, 4)] + top + [(8.6, 2.9), (30, 2.9), (30, 5.1), (8.6, 5.1)] + bottom)]), GOLD, bevel=0.9 * U, outline=1.6, sheen=False)
        draw_layers(c, [("gem_tri", [[(2.6, 4), (5.4, 2.6), (5.4, 5.4)]], RUBY, GOLD)])
    else:  # a small onion turned left, gold rimmed
        rule_line(c, IRON, x0=5, w=2.2)
        draw_layers(c, [("inlay", [[(5, 3.75), (40, 3.75), (40, 4.25), (5, 4.25)]], GOLD)])
        c.metal(c.mask(polys=[u([(0.4, 4), (2.2, 2.0), (4.4, 1.3), (6.2, 2.4), (6.2, 5.6), (4.4, 6.7), (2.2, 6.0)])]),
                IRON, bevel=0.8 * U, outline=1.6, sheen=False, gloss=0.4)
        c.metal(c.mask(circles=[(4.0 * U, 4 * U, 1.3 * U)]), GOLD, bevel=0.7 * U, outline=0.8, shadow=False, sheen=False)
    out["Scroll-%s-RuleLeft" % name] = c.final()
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


def sheet2(art):
    """Each candidate on the player's stone, a divider meeting the bar, at
    on-screen size (1.8 px per unit) and 4x; then every cap state at 4x."""
    slate = np.asarray(Image.open(os.path.join(ROOT, "addon", "WowCompanion", "Art", "SlateLight-6.tga")).convert("RGB"), float)
    bliz = blizzard_divider()

    def img(stem):
        return Image.fromarray(art[stem].astype(np.uint8), "RGBA")

    def put(base, stem, x, y, w, h, u, anchor="tl"):
        t = img(stem).resize((max(1, round(w * u)), max(1, round(h * u))), Image.LANCZOS)
        base.alpha_composite(t, (round(x * u), round(y * u)))

    def pane(name, u):
        W, H, col = 110, 150, 90  # the column from x 90 to 110
        reps = (int(H * u) // 256 + 1, int(W * u) // 256 + 1, 1)
        base = Image.fromarray(np.tile(slate, reps)[:int(H * u), :int(W * u)].astype(np.uint8)).convert("RGBA")
        for y in (50, 105):
            if name == "Blackiron":
                t = bliz.resize((round(col * u), round(15 * u)), Image.LANCZOS)
                base.alpha_composite(t, (0, round((y - 7.5) * u)))
            else:
                put(base, "Scroll-%s-RuleLeft" % name, 0, y - 4, 16, 8, u)
                put(base, "Scroll-%s-RuleMid" % name, 16, y - 4, col - 10.5 - 16 + 1, 8, u)
            put(base, "Scroll-%s-Joint" % name, col - 10.5, y - 8, 16, 16, u)
        x = col + 2
        put(base, "Scroll-%s-Mid" % name, x, 16, 16, H - 32, u)
        put(base, "Scroll-%s-Cap-Up-Normal" % name, x, 0, 16, 16, u)
        put(base, "Scroll-%s-Cap-Down-Normal" % name, x, H - 16, 16, 16, u)
        put(base, "Scroll-%s-Thumb-Top" % name, x + 4, 30, 8, 4, u)
        put(base, "Scroll-%s-Thumb-Mid" % name, x + 4, 34, 8, 32, u)
        put(base, "Scroll-%s-Thumb-Bottom" % name, x + 4, 66, 8, 4, u)
        return base

    def row(cells, gap=12):
        r = Image.new("RGBA", (sum(c.width for c in cells) + gap * len(cells), max(c.height for c in cells)), (0, 0, 0, 255))
        x = 0
        for c in cells:
            r.paste(c, (x, 0)); x += c.width + gap
        return r

    rows = [row([pane(n, 1.8) for n in BODIES]), row([pane(n, 7.2) for n in BODIES])]
    states = []
    for n in BODIES:
        for d in ("Up", "Down"):
            for s in ("Normal", "Pushed", "Highlight", "Disabled"):
                cell = Image.fromarray(np.tile(slate, (1, 1, 1))[:128, :128].astype(np.uint8)).convert("RGBA")
                if s == "Highlight":  # as the game shows it: normal, the highlight added
                    cell.alpha_composite(img("Scroll-%s-Cap-%s-Normal" % (n, d)).resize((128, 128), Image.LANCZOS))
                    hl = np.asarray(img("Scroll-%s-Cap-%s-Highlight" % (n, d)).resize((128, 128), Image.LANCZOS), float)
                    c = np.asarray(cell, float)
                    c[..., :3] = np.clip(c[..., :3] + hl[..., :3] * hl[..., 3:] / 255, 0, 255)
                    cell = Image.fromarray(c.astype(np.uint8), "RGBA")
                else:
                    cell.alpha_composite(img("Scroll-%s-Cap-%s-%s" % (n, d, s)).resize((128, 128), Image.LANCZOS))
                states.append(cell)
    rows.append(row(states[:8], 4))
    rows.append(row(states[8:16], 4))
    rows.append(row(states[16:], 4))
    W = max(r.width for r in rows)
    out = Image.new("RGBA", (W, sum(r.height + 12 for r in rows)), (0, 0, 0, 255))
    y = 0
    for r in rows:
        out.paste(r, (0, y)); y += r.height + 12
    path = os.path.join(ROOT, "target", "scrollbar-sheet-2.png")
    out.convert("RGB").save(path)
    return path


def main():
    art = render()
    art2 = render2()
    for old in glob.glob(os.path.join(OUT, "Scroll-*.tga")):
        os.remove(old)
    for stem, rgba in art.items():
        write_tga(os.path.join(OUT, "%s-%d.tga" % (stem, VERSION)), rgba)
    for stem, rgba in art2.items():
        write_tga(os.path.join(OUT, "%s-%d.tga" % (stem, VERSION2)), rgba)
    print(len(art) + len(art2), "textures;", sheet2(art2))


if __name__ == "__main__":
    main()
