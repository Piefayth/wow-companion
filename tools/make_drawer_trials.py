"""Drawer trials, temporary: ways the conversation menu's drawer
(ConvMenu.lua) could hook into the Companion window's rim, shown side by side
on a "Drawers" tab (DrawerTrials.lua, the text on top). Goes when the player
has picked one.

    python tools/make_drawer_trials.py   writes addon/WowCompanion_Agent/Art/DrawerTrial-Cell-<n>-<v>.tga
                                         and target/drawer-trials.png (all of them, text mocked)

Round 7 (rounds 1-6: d5d8e49, 4c49c05, beb6100, 5ed179c, 4cdd7e2, fd928d7).
Drafted, not sculpted: every member is a centreline with a radius (the
window's rim, the drawer's rims, the legend's rule, each scroll), its metal
the signed depth inside it (r - distance to the centreline). Members join by
max, a crisp crossing, except at named joints, where a smooth union of a
stated radius forges them into one with fillets. The height is a round bar's
over that one field, so every bar has one centred ridge of light and a joint
carries it on unbroken: no second profile blended in (round 6's smeared
highlight and the split bars came from mixing the frame's beaded rim with a
second ridge), no blur, no point left sticking out. The drawer's rim ends
in the window's rim; joints differ by how they forge (fillet radius, the
sweep) and by the scrollwork rooted in them.

Drawn at 2.7 screen pixels a unit (the window's scale at 4K), a texel a pixel;
each cell one picture. The stones are the window's own (Style.lua's Slate and
SlateLight), the metal make_frame_art.py's bronze.
"""
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage
from scipy.spatial import cKDTree

import artout
from make_frame_art import grid, rim_metal, Layers, fit, brushed, streaks, BRONZE, LINE, BAND
from make_scrollbar_art import write_tga, Wire

VERSION = 7  # DrawerTrials.lua's
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "addon", "WowCompanion_Agent", "Art")
STONE = os.path.join(ROOT, "addon", "WowCompanion", "Art", "%s-6.tga")
K = 10  # samples a unit
PX = 2.7  # screen px a unit

# a cell, in units (DrawerTrials.lua's): the window's outer right edge at X0,
# its rim RIM wide inside it; the drawer out to XR, DT to DB; its rows from
# ROWS, ROW tall; the legend's panel LEG
CW, CH = 172.0, 180.0
RIM = 6.0
R = RIM / 2  # a rim's radius
X0 = 16.0
XR = 170.0
DT = 46.0
ROWS, ROW = DT + 12.0, 24.0
LEG = (DT + 62.0, DT + 87.0)
DB = LEG[1] + RIM
RULE_R = 1.3  # the legend rule's radius
FADE = 8.0  # the slice's cut edges fade over this
TEX = 512

xx, yy = grid(CW, CH, K)
xx, yy = xx.astype(np.float32), yy.astype(np.float32)
W_PX, H_PX = int(round(CW * PX)), int(round(CH * PX))
WX = X0 - R  # the window rim's centreline
CROSS = [(WX, DT + R), (WX, DB - R)]  # where the drawer's rims meet it


def smoothstep(t):
    t = np.clip(t, 0, 1)
    return t * t * (3 - 2 * t)


def tile(stem, k=1.0):
    src = np.asarray(Image.open(STONE % stem).convert("RGB")).astype(float)
    reps = (H_PX // src.shape[0] + 1, W_PX // src.shape[1] + 1, 1)
    return np.tile(src, reps)[:H_PX, :W_PX] * k


def down(field):
    return np.asarray(Image.fromarray(np.asarray(field, np.float32), "F").resize((W_PX, H_PX), Image.BOX))


# --- members: a field of signed depth inside each (r - distance) ---------------

def segment(x0, y0, x1, y1, r):
    """A straight bar from (x0, y0) to (x1, y1), radius r, round ends."""
    px, py = xx - x0, yy - y0
    dx, dy = x1 - x0, y1 - y0
    t = np.clip((px * dx + py * dy) / max(dx * dx + dy * dy, 1e-9), 0, 1)
    return r - np.hypot(px - t * dx, py - t * dy), np.full(xx.shape, r, np.float32)


def rods(spec):
    """Round rods along centrelines, a radius at every point."""
    pts = np.concatenate([p for p, _ in spec])
    rad = np.concatenate([r for _, r in spec])
    tree = cKDTree(pts)
    dist, idx = tree.query(np.stack([xx.ravel(), yy.ravel()], 1), k=6, distance_upper_bound=float(rad.max()) + 6)
    ok = np.isfinite(dist)
    idx = np.where(ok, idx, 0)
    depth = np.where(ok, rad[idx] - dist, -1e3)
    best = depth.argmax(1)
    rows = np.arange(len(best))
    return depth[rows, best].reshape(xx.shape), rad[idx][rows, best].reshape(xx.shape)


def union(a, b, k):
    """Two fields joined: the deeper wins (a crisp joint) where k is 0; a
    smooth union of radius k (a fillet) where k is positive."""
    (fa, ra), (fb, rb) = a, b
    k = np.maximum(k, 1e-4)
    h = np.clip(0.5 + 0.5 * (fa - fb) / k, 0, 1)
    f = fa * h + fb * (1 - h) + k * h * (1 - h)
    return f, np.where(fa >= fb, ra, rb)


def near(points, reach, soft=3.0):
    """1 within reach of any point, 0 past reach + soft."""
    w = np.zeros(xx.shape, np.float32)
    for x, y in points:
        w = np.maximum(w, smoothstep((reach + soft - np.hypot(xx - x, yy - y)) / soft))
    return w


def frame(fillet, sweep=0.0):
    """The window's rim and the drawer's, forged at the two crossings with
    fillets of `fillet` (and `sweep`, a long fillet reaching out along the
    drawer's rim), the drawer's corners rounded, the legend's rule T'd in."""
    win = segment(WX, -20, WX, CH + 20, R)
    # the drawer's rims end in the window's (their round end at its middle),
    # so nothing of theirs shows past it and its outer edge stays straight
    top = segment(WX + R, DT + R, XR - R, DT + R, R)
    bottom = segment(WX + R, DB - R, XR - R, DB - R, R)
    right = segment(XR - R, DT + R, XR - R, DB - R, R)
    rule = segment(X0, LEG[0] + RULE_R, XR - R, LEG[0] + RULE_R, RULE_R)
    corners = near([(XR - R, DT + R), (XR - R, DB - R)], 0.5) * 2.0
    rule_ends = near([(X0, LEG[0] + RULE_R), (XR - R, LEG[0] + RULE_R)], 1.0) * 1.2
    f = union(top, right, corners)
    f = union(f, bottom, corners)
    f = union(f, rule, rule_ends)
    k = near(CROSS, R + fillet + 1.0) * fillet  # out past the T's inner corners
    if sweep:
        # a long fillet on the drawer's side only, easing out along its rim
        for cx, cy in CROSS:
            along = np.clip((xx - cx) / (sweep * 2), 0, 1)
            k = np.maximum(k, (1 - smoothstep(along)) * sweep * (xx > cx) * (np.abs(yy - cy) < sweep * 1.5))
    return union(f, win, k)


# --- the scrollwork: Wire's centrelines, as rods -----------------------------

def wires(*ws):
    """(wire, root radius, tip radius) as rods; a tip no heavier than its
    volute's last turn leaves room for, so every eye stays open."""
    out = []
    for w, w0, w1 in ws:
        w1 = min(w1, (getattr(w, "pitch", 99) - 1.0) / 2)
        p = np.array(w.pts)
        s = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(p, axis=0), axis=1))])
        t = s / max(s[-1], 1e-9)
        out.append((p, w0 + (w1 - w0) * t + 0.15 * w0 * np.sin(np.pi * np.clip(t / 0.66, 0, 1)) * (1 - t)))
    return out


def both(spec):
    """The top joint's rods and their mirror about the drawer's middle."""
    return list(spec) + [(np.stack([p[:, 0], DT + DB - p[:, 1]], 1), r) for p, r in spec]


CX, CY = CROSS[0]


def sprig():
    stem = Wire((CX, CY), -45).volute((X0 + 20, 22), 9.0, 180, 1, 2.0, eye=2.2, out=0.5, inn=0.45)
    return wires((stem, 1.6, 0.9))


def cascade():
    stem = Wire((CX, CY), -45).volute((X0 + 24, 20), 9.0, 180, 1, 2.0, eye=2.2, out=0.45, inn=0.4)
    a = stem.fork(0.16, 35).volute((X0 + 17, 35), 5.6, 0, -1, 1.0, eye=1.9, out=0.5, inn=0.5)
    b = stem.fork(0.30, -55).volute((X0 + 7, 13), 5.6, 0, -1, 1.0, eye=1.9, out=0.5, inn=0.5)
    return wires((stem, 1.6, 0.9), (a, 1.4, 0.9), (b, 1.4, 0.9))


def fork():
    up = Wire((CX, CY), -55).volute((X0 + 13, 12), 7.0, 180, 1, 1.5, eye=2.0, out=0.5, inn=0.45)
    along = Wire((CX, CY), -32).volute((X0 + 30, 26), 7.5, 90, -1, 1.0, eye=2.4, out=0.5, inn=0.45)
    return wires((up, 1.6, 0.9), (along, 1.6, 0.9))


def with_rods(f, spec, weld=1.2):
    """Rods joined to the frame: welded (a fillet of radius weld) only at each
    rod's root, crisp elsewhere."""
    rf = rods(spec)
    k = near([tuple(p[0]) for p, _ in spec], 2.5) * weld
    return union(f, rf, k)


def designs():
    return [
        (1, "Forged T: the rims one metal, small fillets", frame(3.0)),
        (2, "Sweep: deep fillets running out along the drawer", frame(2.0, sweep=5.0)),
        (3, "Crisp: the rims meet square, no fillet", frame(0.0)),
        (4, "Sprig: a rod from the joint into a big volute", with_rods(frame(2.4), both(sprig()))),
        (5, "Cascade: a big volute, two scrolls budding off", with_rods(frame(2.4), both(cascade()))),
        (6, "Fork: one rod up the rim, one out over the drawer", with_rods(frame(2.4), both(fork()))),
    ]


# --- painting -------------------------------------------------------------------

def metal(field):
    """The metal from the one field: a round bar's height over its depth (one
    centred ridge, carried unbroken through every joint), lit from the top
    left in the rim's bronze, a dark line at its edge, its cast shadow."""
    f, r = field
    m = f > 0
    d = np.clip(f, 0, r)
    hgt = np.where(m, np.sqrt(np.clip(d * (2 * r - d), 0, None)) / r, 0) * 1.25
    col = rim_metal(hgt, BRONZE, K) * (1 + 0.06 * brushed(np.clip(f * 4, 0, 59)))[..., None]
    col = col + (LINE - col) * (np.clip(1 - f / 0.45, 0, 1) * 0.9)[..., None]
    cast = ndimage.gaussian_filter(ndimage.shift(m.astype(np.float32), (0.8 * K, 0.6 * K), order=0), K * 0.7)
    lay = Layers(xx.shape)
    lay.over(np.zeros(3), np.clip(cast, 0, 1) * 0.6 * ~m)
    lay.over(col, m.astype(float))
    return fit(lay.pre(), (W_PX, H_PX))


def fade():
    fx, fy = (np.arange(W_PX) + 0.5) / PX, (np.arange(H_PX) + 0.5) / PX
    f = smoothstep(fy / FADE)[:, None] * smoothstep((CH - fy) / FADE)[:, None] * smoothstep(fx / FADE)[None, :]
    return 1 - down(xx < X0) * (1 - f)


def rect(x0, y0, x1, y1):
    return (xx >= x0) & (xx < x1) & (yy >= y0) & (yy < y1)


def cell(field):
    """The window's slice and the drawer: their stones, the legend's band (the
    title band's dark leather under the rule), the lit row, the metal."""
    rgb, a = np.zeros((H_PX, W_PX, 3)), np.zeros((H_PX, W_PX))

    def stone(mask, stem, k):
        nonlocal rgb, a
        cov = down(mask)[..., None]
        rgb = rgb * (1 - cov) + tile(stem, k) * cov
        a = a * (1 - cov[..., 0]) + cov[..., 0]
    stone(xx < X0, "Slate", 0.72)
    body = rect(X0 - 1, DT + R, XR - R, DB - R)
    stone(body, "Slate", 0.72)
    stone(rect(X0, ROWS, XR - R, ROWS + ROW), "SlateLight", 1.0)
    band = rect(X0, LEG[0] + RULE_R, XR - R, DB - R)
    lay = Layers(xx.shape)
    col = BAND * (1 + 0.06 * streaks(yy))[..., None]
    occl = np.exp(-(yy - (LEG[0] + 2 * RULE_R)) / 1.4) * 0.45
    lay.over(col * (1 - np.clip(occl, 0, 0.8))[..., None], band.astype(float))
    for layer in (fit(lay.pre(), (W_PX, H_PX)), metal(field)):
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
    d.text(((XR - RIM - 8) * PX, ((LEG[0] + LEG[1]) / 2 + 1) * PX), "X Select    O Back", font=font, anchor="rm",
           fill=(230, 230, 230))
    return back


def main():
    # earlier rounds go (committed); this round's files are rewritten in place
    artout.clear(OUT, *("DrawerTrial-*-%d.tga" % v for v in range(1, VERSION)))
    cells = []
    for n, title, field in designs():
        img = cell(field)
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
