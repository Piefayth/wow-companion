"""Drawer trials, temporary: ways the conversation menu's drawer
(ConvMenu.lua) could hook into the Companion window's rim, shown side by side
on a "Drawers" tab (DrawerTrials.lua, the text on top). Goes when the player
has picked one.

    python tools/make_drawer_trials.py   writes addon/WowCompanion_Agent/Art/DrawerTrial-Cell-<n>-<v>.tga
                                         and target/drawer-trials.png (all of them, text mocked)

Round 9 (rounds 1-8: d5d8e49, 4c49c05, beb6100, 5ed179c, 4cdd7e2, fd928d7, ab6ad52, aef9e9f).
The window's rim is not a bar with a middle: it is a profile by depth inside
the window's outline (make_frame_art.py frame(): a dark line, a bead on its
outer half, a lower inner half, a dark lip), and its corners are where two
depths meet. So the drawer is drawn by the same rule, its rim the window's
exact profile:
  - one outline (1-3): window and drawer one shape, the rim run round it by
    depth from that outline; the joint is an inside corner of it, sharp or
    rounded, worked out as the window's own corners are;
  - rim between (4-6): the window's rim whole, the drawer's own rim (depth
    inside the drawer's outline) running over the window rim's outer shoulder
    and under its bead, as the title rule meets the rim in the window today.
The legend's rule is the title rule's make, meeting the rims the same way.
Ornament is wire (round rods, no taper), a bracket in the corner outside the
joint, its ends run into both rims.

Drawn at 2.7 screen pixels a unit (the window's scale at 4K), a texel a pixel;
each cell one picture. The stones are the window's own (Style.lua's Slate and
SlateLight), the metal make_frame_art.py's bronze.
"""
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage

import artout
from make_frame_art import grid, bar, bead, rim_metal, Layers, fit, brushed, streaks, BRONZE, LINE, BAND, CHAMFER, RULE
from make_scrollbar_art import write_tga

VERSION = 9  # DrawerTrials.lua's
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "addon", "WowCompanion_Agent", "Art")
STONE = os.path.join(ROOT, "addon", "WowCompanion", "Art", "%s-6.tga")
K = 16  # samples a unit
PX = 2.7  # screen px a unit

# a cell, in units (DrawerTrials.lua's): the window's outer right edge at X0,
# its rim RIM wide inside it; the drawer out to XR, DT to DB; its rows from
# ROWS, ROW tall; the legend's panel LEG
CW, CH = 172.0, 180.0
RIM = 6.0
X0 = 16.0
XR = 170.0
DT = 46.0
ROWS, ROW = DT + 12.0, 24.0
LEG = (DT + 62.0, DT + 87.0)
DB = LEG[1] + RIM
RULE_W = RULE[1] - RULE[0]  # the title rule's width
FADE = 8.0  # the slice's cut edges fade over this
TEX = 512
PAD = 24.0  # the window and drawer go on past the cell's cut edges

xx, yy = grid(CW, CH, K)
xx, yy = xx.astype(np.float32), yy.astype(np.float32)
W_PX, H_PX = int(round(CW * PX)), int(round(CH * PX))


def smoothstep(t):
    t = np.clip(t, 0, 1)
    return t * t * (3 - 2 * t)


def tile(stem, k=1.0):
    src = np.asarray(Image.open(STONE % stem).convert("RGB")).astype(float)
    reps = (H_PX // src.shape[0] + 1, W_PX // src.shape[1] + 1, 1)
    return np.tile(src, reps)[:H_PX, :W_PX] * k


def down(field):
    return np.asarray(Image.fromarray(np.asarray(field, np.float32), "F").resize((W_PX, H_PX), Image.BOX))


def rect(x0, y0, x1, y1):
    return (xx >= x0) & (xx < x1) & (yy >= y0) & (yy < y1)


# --- outlines and depth -----------------------------------------------------------

P = int(PAD * K)


def padded(mask_fn):
    """A shape's mask over the cell and PAD past it on every side."""
    gy, gx = np.mgrid[-P:xx.shape[0] + P, -P:xx.shape[1] + P]
    return mask_fn((gx + 0.5) / K, (gy + 0.5) / K)


def depth(mask):
    """How far inside the shape each point is, in units (0 outside): the
    window's corners are made this way, two edges' depths meeting."""
    return (ndimage.distance_transform_edt(mask) / K)[P:-P, P:-P].astype(np.float32)


def window(x, y):
    return x < X0


def drawer(x, y, left=X0 - 30):
    """The drawer's box, its outer corners cut as the window's are."""
    inside = (x >= left) & (x < XR) & (y >= DT) & (y < DB)
    return inside & (XR - x + y - DT >= CHAMFER) & (XR - x + DB - y >= CHAMFER)


def round_inside(mask, rho):
    """The shape with its inside corners rounded to radius rho (a closing)."""
    if rho <= 0:
        return mask
    out = ndimage.distance_transform_edt(~mask) / K <= rho
    return ndimage.distance_transform_edt(out) / K > rho


# --- the rim's profile, make_frame_art.py frame()'s --------------------------------

def rim_height(s):
    return np.where((s >= 0.45) & (s < 5.35), bar(s - 0.45, 4.9) * 0.75 + 0.6 * bead(np.clip((s - 2.0) / 1.25, -1, 1)), 0)


def rim_dark(s):
    return np.clip(1 - s / 0.5, 0, 1) + np.clip((s - 5.35) / 0.5, 0, 1)


class Metal:
    """Members by height: where two overlap the higher shows, its own grain
    and dark lines with it (the window's rule meets its rim so)."""

    def __init__(self):
        self.h = np.zeros(xx.shape, np.float32)
        self.dark = np.zeros(xx.shape, np.float32)
        self.grain = np.zeros(xx.shape, np.float32)
        self.m = np.zeros(xx.shape, bool)
        self.shadow = 1.0

    def add(self, mask, h, dark, grain):
        win = mask & (~self.m | (h > self.h))
        self.h = np.where(win, h, self.h)
        self.dark = np.where(win, dark, self.dark)
        self.grain = np.where(win, grain, self.grain)
        self.m |= mask

    def rim(self, s, where=True):
        self.add((s > 0) & (s < RIM) & where, rim_height(s), rim_dark(s), brushed(s))

    def rule(self, u, where):
        """A bar of the title rule's make across u (0..RULE_W)."""
        ok = (u >= 0) & (u < RULE_W) & where
        h = bar(np.clip(u, 0, RULE_W), RULE_W) * 0.85
        self.add(ok, h,
                 np.clip(1 - np.minimum(u, RULE_W - u) / 0.4, 0, 1), brushed(u * 9, 5))

    def rods(self, pts, r):
        """Wire: round rods of radius r along the centrelines, no taper."""
        from scipy.spatial import cKDTree
        tree = cKDTree(np.concatenate(pts))
        dist, _ = tree.query(np.stack([xx.ravel(), yy.ravel()], 1), distance_upper_bound=r + 1)
        d = np.where(np.isfinite(dist), r - dist, -1).reshape(xx.shape)
        dd = np.clip(d, 0, r)
        h = np.sqrt(np.clip(dd * (2 * r - dd), 0, None)) / r * 1.05 + 0.25
        self.add(d > 0, h, np.clip(1 - d / 0.45, 0, 1), brushed(np.clip(d * 6, 0, 59), 9))

    def paint(self):
        hgt = ndimage.gaussian_filter(self.h, K * 0.1)
        col = rim_metal(hgt, BRONZE, K) * (1 + 0.09 * self.grain)[..., None]
        col = col + (LINE - col) * np.clip(self.dark, 0, 0.9)[..., None]
        col = col * np.asarray(self.shadow)[..., None] if np.ndim(self.shadow) else col
        cast = ndimage.gaussian_filter(ndimage.shift(self.m.astype(np.float32), (0.8 * K, 0.6 * K), order=0), K * 0.7)
        lay = Layers(xx.shape)
        lay.over(np.zeros(3), np.clip(cast, 0, 1) * 0.6 * ~self.m)
        lay.over(col, self.m.astype(float))
        return fit(lay.pre(), (W_PX, H_PX))


# --- the scrolls -------------------------------------------------------------------

WIRE = 1.4  # the scrolls' wire, its radius
BITE = 0.5  # how far a scroll's wire lies into the rim it bears on


def volute(cx, cy, r0, a0, hug, turns, shrink, sense=1, n=700):
    """A spiral from angle a0 at radius r0: r0 held for `hug` of a turn (where
    it bears on the rims), then closing in by shrink a turn."""
    t = np.linspace(0, turns, n)
    a = np.radians(a0) + sense * 2 * np.pi * t
    r = r0 - shrink * np.clip(t - hug, 0, None)
    return np.stack([cx + r * np.cos(a), cy + r * np.sin(a)], 1)


def nest(rad, top, cx=None, cy=None, turns=1.6):
    """A volute in the outside corner bearing on both rims: its outer turn
    lies into the drawer's rim, runs round against the window's, and rolls
    in. (cx, cy) its centre (default:
    touching both straight rims)."""
    s = 1 if top else -1
    jy = DT if top else DB
    if cx is None:
        cx = X0 + rad + WIRE - BITE
        cy = jy - s * (rad + WIRE - BITE)
    a0 = 90 if top else 270
    curl = volute(cx, cy, rad, a0, 0.3, turns, (rad - 1.6) / (turns - 0.3) * 0.75, sense=s)
    return [curl]


def pair(rad, top):
    """A big volute on the drawer's rim and a smaller one above it on the
    window's, stacked, each bearing on its rim and the other."""
    s = 1 if top else -1
    jy = DT if top else DB
    big = nest(rad, top)
    cx = X0 + rad + WIRE - BITE
    cy = jy - s * (rad + WIRE - BITE)
    small = rad * 0.62
    sx = X0 + small + WIRE - BITE
    sy = cy - s * np.sqrt(max((rad + small + 2 * WIRE - 0.8) ** 2 - (sx - cx) ** 2, 0))
    # the small one sits on the big one, its outer turn against the window's
    curl = volute(sx, sy, small, 90 if top else 270, 0.3, 1.5, (small - 1.4) / 1.2 * 0.75, sense=s)
    return big + [curl]


# --- the designs -------------------------------------------------------------------

def legend_rule(met, left, s):
    """The legend's rule, the title rule's make: across the drawer from
    `left`, into the rims as far as their beads (s, the depth it lies in)."""
    met.rule(yy - LEG[0], (xx >= left) & (s > 2.5))


def rim_between(rho=0.0, butt=False, scrolls=None):
    """The window's rim whole; the drawer's own rim on its three sides.
    rho: its rims bend into the window's (an elbow, radius rho), else they
    run over the window rim's outer shoulder and under its bead (round 8's
    4); butt: they stop at the window's edge, the window's rim over them with
    its shadow; scrolls: wire bearing on both rims in the outside corners."""
    sw = depth(padded(window))
    if rho:
        sd = depth(round_inside(padded(window) | padded(drawer), rho))
        inside = sw <= 0
    else:
        sd = depth(padded(drawer))
        inside = xx > (X0 if butt else X0 - 2.5)
    met = Metal()
    met.rim(sw)
    met.rim(sd, inside & (sd < RIM) & (sw < (0 if butt else 2.5)) if rho else inside)
    if butt:
        # the window's rim lies over the drawer's ends: its shadow on them
        met.shadow = 1 - 0.75 * np.clip(1 - (xx - X0) / 3.0, 0, 1) ** 1.5 * (xx >= X0)
    legend_rule(met, X0, sd)
    if scrolls:
        met.rods(scrolls(True) + scrolls(False), WIRE)
    body = ((sd >= RIM) & (xx >= X0)) | (sw >= RIM)
    return met, body


def designs():
    return [
        (1, "Elbow: the rims bend into the window's", rim_between(rho=5)),
        (2, "Wide elbow", rim_between(rho=11)),
        (3, "Butt: the window's rim lies over, its shadow", rim_between(butt=True)),
        (4, "Bearing scroll: a volute against both rims", rim_between(scrolls=lambda t: nest(7.0, t))),
        (5, "Stacked scrolls: big on the drawer, small on the window", rim_between(scrolls=lambda t: pair(7.0, t))),
        (6, "Wide elbow, a volute hugging it", rim_between(rho=11, scrolls=lambda t: nest(
            11 - WIRE - 0.4, t, X0 + 11, (DT - 11) if t else (DB + 11), turns=1.7))),
    ]


# --- painting -------------------------------------------------------------------

def fade():
    fx, fy = (np.arange(W_PX) + 0.5) / PX, (np.arange(H_PX) + 0.5) / PX
    f = smoothstep(fy / FADE)[:, None] * smoothstep((CH - fy) / FADE)[:, None] * smoothstep(fx / FADE)[None, :]
    return 1 - down(xx < X0) * (1 - f)


def cell(met, body):
    """The window's slice and the drawer: their stones, the legend's band (the
    title band's dark slate under the rule), the lit row, the metal."""
    rgb, a = np.zeros((H_PX, W_PX, 3)), np.zeros((H_PX, W_PX))

    def stone(mask, stem, k):
        nonlocal rgb, a
        cov = down(mask)[..., None]
        rgb = rgb * (1 - cov) + tile(stem, k) * cov
        a = a * (1 - cov[..., 0]) + cov[..., 0]
    stone(body | met.m, "Slate", 0.72)
    stone(rect(X0, ROWS, XR - RIM, ROWS + ROW), "SlateLight", 1.0)
    band = rect(X0, LEG[0] + RULE_W, XR - RIM, DB - RIM)
    lay = Layers(xx.shape)
    col = BAND * (1 + 0.06 * streaks(yy))[..., None]
    occl = np.exp(-(yy - (LEG[0] + RULE_W)) / 0.6) * 0.45
    lay.over(col * (1 - np.clip(occl, 0, 0.8))[..., None], band.astype(float))
    for layer in (fit(lay.pre(), (W_PX, H_PX)), met.paint()):
        ta = layer[..., 3:] / 255
        rgb = layer[..., :3] * ta + rgb * (1 - ta)
        a = ta[..., 0] + a * (1 - ta[..., 0])
    a = a * fade()
    return np.clip(np.concatenate([rgb, a[..., None] * 255], -1), 0, 255)


def mock(img):
    """A cell with the game's text, roughly (Arial for Friz Quadrata)."""
    im = Image.fromarray(img.astype(np.uint8), "RGBA")
    back = Image.new("RGBA", im.size, (40, 44, 40, 255))
    back.alpha_composite(im)
    d = ImageDraw.Draw(back)
    font = ImageFont.truetype("arial.ttf", int(12 * PX))
    for i, (t, lit) in enumerate((("Clear chat", True), ("Start over", False))):
        d.text(((X0 + 16) * PX, (ROWS + ROW * i + ROW / 2) * PX), t, font=font, anchor="lm",
               fill=(250, 235, 199) if lit else (199, 176, 135))
    d.text(((XR - RIM - 8) * PX, ((LEG[0] + RULE_W + DB - RIM) / 2) * PX), "X Select    O Back", font=font, anchor="rm",
           fill=(230, 230, 230))
    return back


def main():
    # earlier rounds go (committed); this round's files are rewritten in place
    artout.clear(OUT, *("DrawerTrial-*-%d.tga" % v for v in range(1, VERSION)))
    cells = []
    for n, title, (met, body) in designs():
        img = cell(met, body)
        tex = np.zeros((TEX, TEX, 4))
        tex[:img.shape[0], :img.shape[1]] = img
        write_tga(os.path.join(OUT, "DrawerTrial-Cell-%d-%d.tga" % (n, VERSION)), tex)
        cells.append(mock(img))
        print(n, title)
    w, h = cells[0].size
    sheet = Image.new("RGB", (w * 3 + 40, h * 2 + 30), (30, 30, 30))
    for i, c in enumerate(cells):
        sheet.paste(c.convert("RGB"), (10 + (i % 3) * (w + 10), 10 + (i // 3) * (h + 10)))
    path = os.path.join(ROOT, "target", "drawer-trials.png")
    sheet.save(path)
    print(path)


if __name__ == "__main__":
    main()
