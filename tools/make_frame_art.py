"""The Companion window's frame (Window.lua: ButtonFrameTemplate's border,
title bar and close button) and its wells' borders (InsetFrameTemplate),
drawn here as vector shapes, bevelled and lit from the top left, many samples
to a pixel and averaged down, never Blizzard's art.

    python tools/make_frame_art.py   writes addon/WowCompanion_Agent/Art/Frame-*-<v>.tga,
                                     Inset-*-<v>.tga, Close-*-<v>.tga and
                                     target/frame-sheet-<v>.png (the comparison sheet)

The frame replaces its NineSlice region by region: four corners, four edges
stretched between them (each edge is the same all along its length, so it
stretches without a seam). The top pieces hold the title bar: the rim, the
dark band the title sits in, the bronze rule under it and that rule's shadow.
The left edge casts a shadow onto the panel (the light is at the top left);
nothing is drawn outside the rim, and Window.lua places each piece. The
inset's border is a dark line, a shadow inside its top and left, a lit lip
inside its bottom and right.

Every measure is the game's window as target/companion-now.png has it (a 4K
screenshot halved: 1.406 px a unit): the rim stands 2 units inside the frame
on the left, 2 outside on the right, 4 above its top and 1 inside its bottom,
6 wide; the title band runs to 19.2 under the frame's top, the rule to 21.4.
The game keeps a texture for the session under its path, so a change bumps
VERSION (and Window.lua's FRAME_ART); older files are deleted.
"""
import glob
import os
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage
from make_scrollbar_art import write_tga, LIGHT, HALF

VERSION = 1
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "addon", "WowCompanion_Agent", "Art")
K = 32  # px a unit drawn; every piece is averaged down from this

# the frame, in units from the rim's outer edge
RIM = 6.0  # the rim's width
CHAMFER = 4.0  # its corners cut at 45 degrees
RULE = (22.6, 25.6)  # the rule under the title band
TOP_H = 28.0  # the top pieces' height: rim, band, rule and its shadow
CORNER = 12.0  # every corner's width, and the bottom corners' height
LEFT_W = 8.0  # the left edge: its rim and the shadow it casts
N = 60.0  # the drawn frame's side, the pieces cut from it

BRONZE = (np.array((28, 16, 4.0)), np.array((72, 46, 16.0)), np.array((196, 154, 98.0)))
LINE = np.array((14, 9, 4.0))
BAND = np.array((33, 19, 10.0))
GOLD = (np.array((120, 72, 0.0)), np.array((236, 186, 16.0)), np.array((255, 238, 110.0)))
RED = (np.array((46, 3, 2.0)), np.array((126, 12, 8.0)), np.array((214, 58, 38.0)))


def grid(w, h, k=K):
    yy, xx = np.mgrid[0:int(round(h * k)), 0:int(round(w * k))]
    return (xx + 0.5) / k, (yy + 0.5) / k


def shade(hgt, pal, k=K, gloss=0.35, power=18):
    """A height field's colour lit from the top left: the palette's shadow,
    mid and light by how the surface faces the light, a highlight on top."""
    gy, gx = np.gradient(hgt, 1 / k)
    n = np.stack([-gx, -gy, np.ones_like(gx)], -1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    diff = np.clip(n @ LIGHT, 0, 1)[..., None]
    flat = LIGHT[2]
    sh, mid, li = pal
    col = np.where(diff < flat, sh + (mid - sh) * (diff / flat), mid + (li - mid) * ((diff - flat) / (1 - flat)))
    spec = np.clip(n @ HALF, 0, 1) ** power * gloss
    return np.clip(col + spec[..., None] * 255, 0, 255)


def bead(u):
    """A rounded bead's height across it, u -1..1."""
    return np.sqrt(np.clip(1 - u * u, 0, 1))


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


def frame():
    xx, yy = grid(N, N)
    s = octagon_depth(xx, yy, 0, 0, N, N, CHAMFER)  # into the rim from its outer edge
    lay = Layers(xx.shape)
    # the rim: a dark line, one broad bar with rounded shoulders (the one
    # toward the light lit), a dark lip down into the panel; the rule a
    # narrower bar of the same make, meeting the rim in a T. The metal is
    # brushed along its length: its grain a function of the depth alone, so
    # the edges stretch and the corners turn without a seam.
    def bar(u, w):
        """A bar's height across it, u from 0 to w: shoulders 1.1 wide, a
        slightly crowned top."""
        sh = np.clip(np.minimum(u, w - u) / 1.1, 0, 1)
        return (1 - (1 - sh) ** 2) * 0.9 + 0.15 * bead(np.clip(2 * u / w - 1, -1, 1))
    # the rim's bar carries a raised bead along its outer half, the lit
    # ridge the game's rim has, its inner half lower and darker
    hr = np.where((s >= 0.45) & (s < 5.35), bar(s - 0.45, 4.9) * 0.75 + 0.6 * bead(np.clip((s - 2.0) / 1.25, -1, 1)), 0)
    rc, rh = (RULE[0] + RULE[1]) / 2, (RULE[1] - RULE[0]) / 2
    hrule = np.where((np.abs(yy - rc) < rh) & (s > 2.5), bar(yy - RULE[0], RULE[1] - RULE[0]) * 0.85, 0)
    hrule = np.where(hrule > hr, hrule, 0)  # the rim's bar runs over the rule's end
    hgt = ndimage.gaussian_filter(np.maximum(hr, hrule), K * 0.1)
    metal = (s >= 0) & (s < RIM) | (hrule > 0)
    col = shade(hgt, BRONZE, gloss=0.22, power=14)
    col = col * (1 + 0.09 * brushed(s))[..., None]
    rule = hrule > 0
    col = np.where(rule[..., None], col * (1 + 0.07 * brushed(yy, 5))[..., None], col)
    # the dark line outside, the lip inside, and the rule's edges, deepened
    edge_r = np.minimum(np.abs(yy - RULE[0]), np.abs(yy - RULE[1]))
    dark = np.where(rule, np.clip(1 - edge_r / 0.4, 0, 1), np.clip(1 - s / 0.5, 0, 1) + np.clip((s - 5.35) / 0.5, 0, 1))
    col = col + (LINE - col) * np.clip(dark, 0, 0.9)[..., None]
    # the title band: dark wood, shadowed under the rim and over the rule
    band = (s >= RIM) & (yy < RULE[0])
    bcol = BAND * (1 + 0.06 * streaks(yy))[..., None]
    occl = np.maximum(np.exp(-(s - RIM) / 0.9) * 0.75, np.exp(-(RULE[0] - yy) / 0.6) * 0.45)
    bcol = bcol * (1 - np.clip(occl, 0, 0.8))[..., None]
    lay.over(np.where(band[..., None], bcol, col), (metal | band).astype(float))
    # the panel under the rule: only shadow, from the rule and the left rim
    panel = (s >= RIM) & (yy >= RULE[1])
    under = np.clip(1 - (yy - RULE[1]) / (TOP_H - RULE[1]), 0, 1) ** 2 * 0.7
    beside = np.clip(1 - (xx - RIM) / (LEFT_W - RIM), 0, 1) ** 2 * 0.55
    lay.over(np.zeros(3), np.where(panel & ~metal, np.maximum(under, beside), 0))
    return lay.pre()


def frame_pieces():
    pre = frame()
    k = K

    def cut(x0, y0, x1, y1):
        return pre[int(round(y0 * k)):int(round(y1 * k)), int(round(x0 * k)):int(round(x1 * k))]
    c, mid = CORNER, N / 2
    return {
        "Frame-TopLeftCorner": fit(cut(0, 0, c, TOP_H), (128, 256)),
        "Frame-TopRightCorner": fit(cut(N - c, 0, N, TOP_H), (128, 256)),
        "Frame-BottomLeftCorner": fit(cut(0, N - c, c, N), (128, 128)),
        "Frame-BottomRightCorner": fit(cut(N - c, N - c, N, N), (128, 128)),
        "Frame-TopEdge": fit(cut(mid - 1, 0, mid + 1, TOP_H), (16, 256)),
        "Frame-BottomEdge": fit(cut(mid - 1, N - RIM, mid + 1, N), (16, 64)),
        "Frame-LeftEdge": fit(cut(0, mid - 1, LEFT_W, mid + 1), (64, 16)),
        "Frame-RightEdge": fit(cut(N - RIM, mid - 1, N, mid + 1), (64, 16)),
    }


# --- the close button ----------------------------------------------------------

CLOSE = 26.0


def segment_dist(xx, yy, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    t = np.clip(((xx - ax) * dx + (yy - ay) * dy) / (dx * dx + dy * dy), 0, 1)
    return np.hypot(xx - ax - t * dx, yy - ay - t * dy)


def close(state):
    """The close button, 26 units: a bronze octagon set round a red stone,
    a gold cross on it. Pushed sinks the stone and the cross; Highlight is
    drawn for ADD blending; Disabled is greyed."""
    xx, yy = grid(CLOSE, CLOSE)
    lay = Layers(xx.shape)
    ring = octagon_depth(xx, yy, 0, 0, CLOSE, CLOSE, 4.0)
    if state == "Highlight":
        gem = octagon_depth(xx, yy, 2.8, 2.8, CLOSE - 2.8, CLOSE - 2.8, 2.6)
        glow = np.clip(gem / 1.0, 0, 1) * (0.12 + 0.25 * np.clip(1 - gem / 6, 0, 1))
        lay.over(np.array((255, 170, 90.0)), glow)
        return lay.pre()
    # the ring: a dark line, a bevelled bronze band
    sh = np.clip(np.minimum(ring - 0.45, 2.8 - ring) / 0.9, 0, 1)
    hring = (1 - (1 - sh) ** 2) * 0.9
    rcol = shade(ndimage.gaussian_filter(hring, K * 0.1), BRONZE, gloss=0.22, power=14) * (1 + 0.09 * brushed(ring))[..., None]
    lay.over(rcol, (ring >= 0).astype(float))
    lay.over(LINE, np.clip(1 - ring / 0.5, 0, 1) * (ring >= 0) * 0.85)
    # the stone, sunk in the ring, its face domed a little
    push = state == "Pushed"
    gem = octagon_depth(xx, yy, 2.8, 2.8, CLOSE - 2.8, CLOSE - 2.8, 2.6)
    hgem = np.minimum(gem, 1.4) * 0.9 + np.clip(gem - 1.4, 0, None) * 0.08
    red = shade(ndimage.gaussian_filter(hgem, K * 0.12), RED, gloss=0.3, power=20)
    # lighter toward the top, as a lit stone is
    red = red * (1.12 - 0.3 * (yy / CLOSE))[..., None]
    if push:
        red = red * 0.72
    lay.over(np.clip(red, 0, 255), (gem >= 0).astype(float))
    lay.over(np.zeros(3), np.clip(1 - gem / 0.6, 0, 1) * (gem >= 0) * 0.7)  # the seat's dark edge
    # the cross: two square-ended bars, bevelled, their outline and the
    # shadow they cast
    o = 0.6 if push else 0.0
    c0 = CLOSE / 2 + o
    half, reach = 2.0, 6.4

    def cross(x, y):
        """How far inside the cross a point is (negative outside)."""
        u, v = (x - c0 + y - c0) / np.sqrt(2), (x - c0 - (y - c0)) / np.sqrt(2)
        one = np.minimum(half - np.abs(v), reach - np.abs(u))
        two = np.minimum(half - np.abs(u), reach - np.abs(v))
        return np.maximum(one, two)
    d = cross(xx, yy)
    lay.over(np.zeros(3), np.clip((cross(xx - 0.6, yy - 0.8) + 0.9) / 0.9, 0, 1) * 0.55 * (gem > 0))
    lay.over(LINE, np.clip((d + 0.55) * 2, 0, 1))
    hx = np.clip(d / 0.9, 0, 1)
    hx = (1 - (1 - hx) ** 2) * 0.8
    gold = shade(ndimage.gaussian_filter(hx, K * 0.08), GOLD, gloss=0.3, power=16)
    if push:
        gold = gold * 0.85
    lay.over(gold, (d >= 0).astype(float))
    pre = lay.pre()
    if state == "Disabled":
        grey = (pre[..., :3] @ np.array([0.3, 0.59, 0.11]))[..., None] * 0.7
        pre = np.concatenate([np.repeat(grey, 3, -1), pre[..., 3:]], -1)
    return pre


# --- the inset ------------------------------------------------------------------

INSET = 4.0  # the inset's corners' side and its edges' width
SHADE = (8, 8, 9.0)
LIP = np.array((74, 71, 64.0))


def inset():
    """An inset's border in a 20-unit square: a dark line at its edge, a
    shadow inside its top and left, a lit lip inside its bottom and right."""
    n = 20.0
    xx, yy = grid(n, n)
    lay = Layers(xx.shape)
    top, left, bottom, right = yy, xx, n - yy, n - xx
    edge = np.minimum.reduce([top, left, bottom, right])
    shadow = np.maximum(np.clip(1 - (top - 0.6) / 3.0, 0, 1), np.clip(1 - (left - 0.6) / 3.0, 0, 1)) ** 2 * 0.6
    lay.over(np.zeros(3), shadow * (edge < INSET))
    lip = np.minimum(bottom, right)
    lay.over(LIP, ((lip >= 0.6) & (lip < 1.3) & (np.minimum(top, left) > 0.6)).astype(float) * 0.85)
    lay.over(np.array(SHADE), (edge < 0.6).astype(float))
    pre = lay.pre()
    k = K

    def cut(x0, y0, x1, y1):
        return pre[int(round(y0 * k)):int(round(y1 * k)), int(round(x0 * k)):int(round(x1 * k))]
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
    art.update(inset())
    for state in ("Normal", "Pushed", "Highlight", "Disabled"):
        art["Close-" + state] = fit(close(state), (256, 256))
    return art


# --- the comparison sheet ---------------------------------------------------------
#
# Our pieces laid over the game's window as Window.lua places them, on
# target/companion-now.png (the Settings tab: the page well) and
# target/companion-ref.png (the Chat tab: the chat well and the conversation
# list), each a halved 4K shot at 1.406 px a unit. The frames' rects, in
# those pixels, are read off the shots (the title's centre, the wells'
# edges, the close button).

UPP = 1.40625
SHOTS = {"now": ("companion-now.png", (16.5, 25.0, 1038.0, 728.9)),
         "ref": ("companion-ref.png", (-3.5, 5.0, 1018.0, 708.9))}


def place(canvas, img, x, y, w, h, upp):
    """img (RGBA) stretched over the rect at (x, y), w x h units, at upp px a unit."""
    x0, y0 = int(round(x * upp)), int(round(y * upp))
    x1, y1 = int(round((x + w) * upp)), int(round((y + h) * upp))
    if x1 <= x0 or y1 <= y0:
        return
    im = Image.fromarray(img.astype(np.uint8), "RGBA").resize((x1 - x0, y1 - y0), Image.LANCZOS)
    canvas.alpha_composite(im, (x0, y0)) if x0 >= 0 and y0 >= 0 else canvas.paste(im, (x0, y0), im)


def nine(canvas, art, prefix, rect, upp, layout):
    """A nine-slice laid out as Window.lua does: layout gives the corners'
    width, the top and bottom corners' heights, how far the pieces stand out
    past each side of the rect (left, top, right, bottom; negative is
    inside), and the left, right, bottom and top edges' widths."""
    l, t, r, b = rect
    cw, ch, cbh, ol, ot, orr, ob, lw, rw, bh, th = layout
    L, T, R, B = l - ol, t - ot, r + orr, b + ob
    place(canvas, art[prefix + "TopLeftCorner"], L, T, cw, ch, upp)
    place(canvas, art[prefix + "TopRightCorner"], R - cw, T, cw, ch, upp)
    place(canvas, art[prefix + "BottomLeftCorner"], L, B - cbh, cw, cbh, upp)
    place(canvas, art[prefix + "BottomRightCorner"], R - cw, B - cbh, cw, cbh, upp)
    place(canvas, art[prefix + "TopEdge"], L + cw, T, R - L - 2 * cw, th, upp)
    place(canvas, art[prefix + "BottomEdge"], L + cw, B - bh, R - L - 2 * cw, bh, upp)
    place(canvas, art[prefix + "LeftEdge"], L, T + ch, lw, B - cbh - T - ch, upp)
    place(canvas, art[prefix + "RightEdge"], R - rw, T + ch, rw, B - cbh - T - ch, upp)


# Window.lua's numbers: the frame's pieces stand 2 inside its left, 4 above
# its top, 2 past its right and 1 inside its bottom; the inset's are flush
FRAME_LAYOUT = (CORNER, TOP_H, CORNER, -2, 4, 2, -1, LEFT_W, RIM, RIM, TOP_H)
INSET_LAYOUT = (INSET, INSET, INSET, 0, 0, 0, 0, INSET, INSET, INSET, INSET)


def dress(shot, art, rect, wells, zoom):
    """The shot enlarged `zoom` times with our frame, close button and wells
    over it."""
    im = Image.open(os.path.join(ROOT, "target", shot)).convert("RGBA")
    im = im.resize((im.width * zoom, im.height * zoom), Image.LANCZOS)
    upp = UPP * zoom
    l, t, r, b = (v / UPP for v in rect)  # units
    for wl, wt, wr, wb in wells:
        nine(im, art, "Inset-", (l + wl, t + wt, r + wr, b + wb), upp, INSET_LAYOUT)
    nine(im, art, "Frame-", (l, t, r, b), upp, FRAME_LAYOUT)
    place(im, art["Close-Normal"], r + 2 - CLOSE, t - 4, CLOSE, CLOSE, upp)
    return im.convert("RGB")


def sheet(art):
    WELL = 130
    page = [(4, 60, -6, -26)]
    chat = [(4, 60, -(6 + WELL + 2), -26), (None, 60, -6, -26)]
    out_rows = []
    for key, wells in (("now", page), ("ref", chat)):
        shot, rect = SHOTS[key]
        l, t, r, b = (v / UPP for v in rect)
        ws = []
        for wl, wt, wr, wb in wells:
            if wl is None:  # the conversation list: WELL wide from the right
                wl = (r + wr - WELL) - l
            ws.append((wl, wt, wr, wb))
        old = Image.open(os.path.join(ROOT, "target", shot)).convert("RGB")
        new = dress(shot, art, rect, ws, 1)
        out_rows.append([old, new])
        # corners zoomed: the game's, then ours at 4K's own pixels
        big = dress(shot, art, rect, ws, 2)
        oldbig = old.resize((old.width * 2, old.height * 2), Image.LANCZOS)
        for (cx, cy) in ((0, 0), (1, 0), (0, 1), (1, 1)):
            x0 = 0 if cx == 0 else old.width - 160
            y0 = 0 if cy == 0 else old.height - 110
            box = (x0, y0, x0 + 160, y0 + 110)
            a = old.crop(box).resize((640, 440), Image.NEAREST)
            bb = big.crop(tuple(v * 2 for v in box)).resize((640, 440), Image.LANCZOS)
            out_rows.append([a, bb])
    W = max(sum(i.width for i in r) + 12 * len(r) for r in out_rows) + 12
    H = sum(max(i.height for i in r) + 12 for r in out_rows) + 12
    sheetim = Image.new("RGB", (W, H), (52, 50, 46))
    y = 12
    for r in out_rows:
        x = 12
        for i in r:
            sheetim.paste(i, (x, y))
            x += i.width + 12
        y += max(i.height for i in r) + 12
    path = os.path.join(ROOT, "target", "frame-sheet-%d.png" % VERSION)
    sheetim.save(path)
    # the pieces themselves, on grey
    pieces = [Image.fromarray(art[s].astype(np.uint8), "RGBA") for s in sorted(art)]
    pw = sum(p.width + 8 for p in pieces) + 8
    pim = Image.new("RGBA", (pw, max(p.height for p in pieces) + 16), (90, 90, 90, 255))
    x = 8
    for p in pieces:
        pim.alpha_composite(p, (x, 8))
        x += p.width + 8
    pim.convert("RGB").save(os.path.join(ROOT, "target", "frame-pieces-%d.png" % VERSION))
    return path


def main():
    art = render()
    os.makedirs(OUT, exist_ok=True)
    for pat in ("Frame-*.tga", "Inset-*.tga", "Close-*.tga"):
        for old in glob.glob(os.path.join(OUT, pat)):
            os.remove(old)
    for stem, img in art.items():
        write_tga(os.path.join(OUT, "%s-%d.tga" % (stem, VERSION)), img)
    print(len(art), "textures;", sheet(art))


if __name__ == "__main__":
    main()
