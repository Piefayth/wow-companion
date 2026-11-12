"""Ornate scroll arrows and the divider edge for the chat's slim bar (the
Scroll bars tab, ScrollGallery.lua): drawn here as vector shapes, bevelled and
lit from the top left, at 16x and averaged down, never Blizzard's art.

    python tools/make_scrollbar_art.py   writes addon/WowCompanion_Agent/Art/Scroll-*-<v>.tga
                                         and target/scrollbar-sheet.png (the comparison sheet)

The game keeps a texture for the session under its path, so a change bumps
VERSION (and ScrollGallery.lua's ART_VERSION); older files are deleted.

Each design: an up and a down arrow in four states (Normal, Pushed, Highlight
drawn for ADD blending, Disabled), 32x32 shown at 16x16; and its edge: a
vertical rod tile (RuleMid, 16x32, shown 8 wide, repeated down), its caps
(RuleTop, RuleBottom, 16x16) and the joint where a divider meets it (Joint,
32x32). The down arrow is drawn mirrored, not flipped, so its light still
comes from the top left.
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

    def metal(self, m, pal, bevel=1.6, outline=0.8, shadow=True, dome=False, gloss=0.55, sheen=True):
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
        if dome:  # light caught inside the stone, bottom right
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

def arrow_gilded(c, down):
    f = (lambda p: mirror(p)) if down else (lambda p: p)
    y = (lambda v: 32 - v) if down else (lambda v: v)
    chevron = f([(16, 4.5), (27.5, 16), (27.5, 21.5), (16, 11), (4.5, 21.5), (4.5, 16)])
    c.metal(c.mask([chevron]), GOLD, bevel=1.7)
    c.gem(16, y(11.6), 2.1, EMERALD, bezel=GOLD)


def arrow_spear(c, down):
    f = (lambda p: mirror(p)) if down else (lambda p: p)
    leaf = f(sym([(16, 2.5), (18.6, 6.5), (21.6, 11.5), (23, 15.5), (21.2, 19), (17.6, 20.5)]))
    collar = f([(9.5, 21), (22.5, 21), (23.5, 22.6), (22.5, 24.2), (9.5, 24.2), (8.5, 22.6)])
    c.metal(c.mask([leaf]), BRONZE, bevel=1.5)
    rib = f(sym([(16, 4.5), (16.9, 12), (16.9, 19.5)]))
    c.metal(c.mask([rib]), BRONZE, bevel=0.7, outline=0, shadow=False, gloss=0.9)
    c.metal(c.mask([collar]), BRONZE, bevel=1.0)


def arrow_fleur(c, down):
    f = (lambda p: mirror(p)) if down else (lambda p: p)
    y = (lambda v: 32 - v) if down else (lambda v: v)
    petal = f(sym([(16, 2.5), (18.2, 6), (19.6, 10.5), (19.2, 15), (17.2, 19.5)]))
    leaf_r = [(19, 19), (21, 14.5), (24.5, 12.5), (27.6, 13.4), (28.4, 16.4), (26.6, 18.6), (25.4, 16.4),
              (23.6, 16.6), (22.2, 19.4)]
    leaf_l = [(32 - x, yy) for x, yy in leaf_r]
    band = [(8.5, 19.2), (23.5, 19.2), (24.5, 21.2), (23.5, 23.2), (8.5, 23.2), (7.5, 21.2)]
    stem = sym([(16, 23), (17.6, 23), (17, 27.5), (16, 28.6)])
    c.metal(c.mask([f(leaf_r), f(leaf_l)]), GOLD, bevel=1.1)
    c.metal(c.mask([petal, f(stem)]), GOLD, bevel=1.5)
    c.metal(c.mask([f(band)]), GOLD, bevel=0.9)
    c.gem(16, y(12.2), 3.0, SAPPHIRE)


def arrow_ember(c, down):
    f = (lambda p: mirror(p)) if down else (lambda p: p)
    y = (lambda v: 32 - v) if down else (lambda v: v)
    tri = f([(16, 4), (27.5, 22.5), (4.5, 22.5)])
    m = c.mask([tri])
    m = ndimage.gaussian_filter(m, S * 0.6) > 0.5  # rounded corners
    c.metal(m.astype(float), GOLD, bevel=1.0)
    inner = ndimage.binary_erosion(m, iterations=int(2.0 * S))
    c.metal(inner.astype(float), IRON, bevel=1.6, outline=0, shadow=False, gloss=0.35)
    line = ndimage.binary_erosion(m, iterations=int(3.4 * S)) & ~ndimage.binary_erosion(m, iterations=int(4.2 * S))
    c.metal(line.astype(float), GOLD, bevel=0.4, outline=0, shadow=False)
    c.metal(c.mask(circles=[(16, y(3.6), 1.8), (4.6, y(22.4), 1.8), (27.4, y(22.4), 1.8)]), GOLD, bevel=0.9)
    c.gem(16, y(16.4), 2.6, SAPPHIRE, bezel=GOLD)


# --- the edges: a rod down the column's left side, its caps, the joint -----

def rod(c, pal, x=8, w=4.4, y0=-10, y1=None):
    y1 = c.h + 10 if y1 is None else y1
    c.metal(c.mask([[(x - w / 2, y0), (x + w / 2, y0), (x + w / 2, y1), (x - w / 2, y1)]]), pal,
            bevel=w / 2, outline=0.5, shadow=False, gloss=0.4, sheen=False)


def inlaid_rod(c, x=8, y0=-10, y1=None):
    rod(c, IRON, x, 5.0, y0, y1)
    y1 = c.h + 10 if y1 is None else y1
    c.metal(c.mask([[(x - 0.7, y0), (x + 0.7, y0), (x + 0.7, y1), (x - 0.7, y1)]]), GOLD,
            bevel=0.5, outline=0, shadow=False, sheen=False)


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


def joint_stud(c):
    ferrule(c)
    c.metal(c.mask(circles=[(16, 16, 6.2)]), GOLD, bevel=1.4)
    c.gem(16, 16, 3.0, EMERALD)


def joint_lozenge(c):
    ferrule(c, BRONZE, 10)
    c.metal(c.mask([[(16, 6.5), (23.5, 16), (16, 25.5), (8.5, 16)]]), BRONZE, bevel=1.6)
    c.gem(16, 16, 2.6, EMERALD)


def joint_bud(c):
    """For the fleur: no rod; each divider ends in a gold bud with a sapphire,
    the deliberate end the slim bar lacks."""
    ferrule(c, GOLD, 9)
    leaf = [(8, 15), (10.5, 11.4), (13, 9), (15, 9.6), (13.6, 11.2), (12.4, 13.4), (11, 15.4)]
    c.metal(c.mask([leaf, [(x, 32 - y) for x, y in leaf]]), GOLD, bevel=0.9)
    bud = [(7.5, 14.8), (13, 13.2), (17.5, 13.6), (21, 16), (17.5, 18.4), (13, 18.8), (7.5, 17.2)]
    c.metal(c.mask([bud]), GOLD, bevel=1.4)
    c.gem(14.2, 16, 2.4, SAPPHIRE)


def joint_ring(c):
    ferrule(c)
    c.metal(c.mask(circles=[(16, 16, 6.6)]), IRON, bevel=1.3, gloss=0.4)
    c.metal(c.mask(circles=[(16, 16, 5.2)], holes=[(16, 16, 4.2)]), GOLD, bevel=0.5, outline=0, shadow=False)
    c.gem(16, 16, 3.6, SAPPHIRE)


DESIGNS = {
    # name: (arrow, rod tile, caps, joint)
    "Gilded": (arrow_gilded, lambda c: rod(c, GOLD), lambda c, t: cap_iron(c, t, GOLD), joint_stud),
    "Spear": (arrow_spear, lambda c: rod(c, BRONZE), lambda c, t: cap_iron(c, t, BRONZE, BRONZE), joint_lozenge),
    "Fleur": (arrow_fleur, None, None, joint_bud),
    "Ember": (arrow_ember, lambda c: inlaid_rod(c), lambda c, t: (inlaid_rod(c, y0=9 if t else -10, y1=26 if t else 7), cap_iron(c, t, IRON, GOLD)), joint_ring),
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


# --- the comparison sheet ---------------------------------------------------

def sheet(art):
    """Each design on the player's stone with a divider, a slim grey bar and
    its arrows, at on-screen size (1.8 px per unit, as at 4K) and at 4x."""
    slate = np.asarray(Image.open(os.path.join(OUT, "SlateLight-6.tga")).convert("RGB"), float)

    def img(stem):
        return Image.fromarray(art[stem].astype(np.uint8), "RGBA")

    def pane(scale):
        u = 1.8 * scale  # px per UI unit
        W, H = int(150 * u), int(150 * u)
        reps = (H // 256 + 1, W // 256 + 1, 1)
        base = Image.fromarray(np.tile(slate, reps)[:H, :W].astype(np.uint8)).convert("RGBA")
        return base, u

    def put(base, stem, x, y, w, h, u):
        t = img(stem).resize((max(1, round(w * u)), max(1, round(h * u))), Image.LANCZOS)
        base.alpha_composite(t, (round(x * u - t.width / 2), round(y * u - t.height / 2)))

    def divider(base, x1, y, u):
        # the quest log divider's rod as drawn: dark, lit along its top
        d = ImageDraw.Draw(base)
        d.rectangle([0, (y - 1.2) * u, x1 * u, (y + 1.2) * u], fill=(16, 13, 10, 230))
        d.rectangle([0, (y - 1.2) * u, x1 * u, (y - 0.5) * u], fill=(84, 74, 56, 230))

    def bar(base, cx, y0, y1, u):
        d = ImageDraw.Draw(base)
        d.rounded_rectangle([(cx - 4) * u, y0 * u, (cx + 4) * u, y1 * u], radius=3 * u, fill=(10, 10, 11, 255),
                            outline=(48, 46, 44, 255), width=max(1, round(0.6 * u)))
        d.rounded_rectangle([(cx - 4) * u, (y0 + 20) * u, (cx + 4) * u, (y0 + 50) * u], radius=3 * u,
                            fill=(92, 56, 28, 255), outline=(120, 90, 70, 255), width=max(1, round(0.5 * u)))

    rows = []
    for scale in (1, 4):
        cells = []
        for name, (_, tile, cap, _) in DESIGNS.items():
            base, u = pane(scale)
            edge, cx = 110, 120  # the column's left side, the bar's centre
            divider(base, edge, 60, u)
            if tile:
                t = img("Scroll-%s-RuleMid" % name)
                tw, th = round(8 * u), round(16 * u)
                t = t.resize((tw, th), Image.LANCZOS)
                for yy in range(round(12 * u), round(140 * u), th):
                    base.alpha_composite(t.crop((0, 0, tw, min(th, round(140 * u) - yy))), (round(edge * u - tw / 2), yy))
                put(base, "Scroll-%s-RuleTop" % name, edge, 8, 8, 8, u)
                put(base, "Scroll-%s-RuleBottom" % name, edge, 142, 8, 8, u)
            put(base, "Scroll-%s-Joint" % name, edge, 60, 16, 16, u)
            bar(base, cx, 22, 128, u)
            put(base, "Scroll-%s-Up-Normal" % name, cx, 12, 16, 16, u)
            put(base, "Scroll-%s-Down-Normal" % name, cx, 138, 16, 16, u)
            cells.append(base)
        row = Image.new("RGBA", (sum(c.width for c in cells) + 10 * len(cells), cells[0].height), (0, 0, 0, 255))
        x = 0
        for cl in cells:
            row.paste(cl, (x, 0)); x += cl.width + 10
        rows.append(row)
    # the four states of each up arrow at 4x
    st = Image.new("RGBA", (4 * 4 * 64 + 40, 70), (20, 20, 22, 255))
    x = 0
    for name in DESIGNS:
        for s in ("Normal", "Pushed", "Highlight", "Disabled"):
            t = img("Scroll-%s-Up-%s" % (name, s)).resize((64, 64), Image.LANCZOS)
            st.alpha_composite(t, (x, 3)); x += 64
        x += 10
    W = max(r.width for r in rows)
    out = Image.new("RGBA", (W, sum(r.height for r in rows) + st.height + 20), (0, 0, 0, 255))
    y = 0
    for r in rows + [st]:
        out.paste(r, (0, y)); y += r.height + 10
    path = os.path.join(ROOT, "target", "scrollbar-sheet.png")
    out.convert("RGB").save(path)
    return path


def main():
    art = render()
    for old in glob.glob(os.path.join(OUT, "Scroll-*.tga")):
        os.remove(old)
    for stem, rgba in art.items():
        write_tga(os.path.join(OUT, "%s-%d.tga" % (stem, VERSION)), rgba)
    print(len(art), "textures;", sheet(art))


if __name__ == "__main__":
    main()
