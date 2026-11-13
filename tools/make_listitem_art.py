"""A scrolling list's items (Core's Style.lua, WC.Style.ListItem), the looks on
trial (WC.Style.ListItemStyle): the pieces that are not already the stones or
the vines. In the vines' bark and wire (make_scrollbar_art's Wire, raised and
painted as the junctions are), at U texels a unit, transparent round them.

    python tools/make_listitem_art.py           writes addon/WowCompanion/Art/ListItem-*-<VERSION>.tga
    python tools/make_listitem_art.py --sheet   and target/errand-list-options.png: every look
                                                on the Errands tab's list, from the 4K shot

Pieces, in units:
  Slab-Edge 32x32, a nine-slice (corners 8): a slab of stone standing out of
    the well, its face clear (the stone shows), lit along its top and left,
    shaded along its bottom and right, a dark edge and a shadow cast down and
    right; the slab 4 in from each side of the texture
  Slab-Rim 32x32, the same nine-slice: the chosen slab's bark rim, round
    cornered, the medium vine's weight
  Curl-TL, Curl-TR, Curl-BL, Curl-BR 32x32: a medium vine's end curling into a
    volute toward the row (a top vine curls down, a bottom one up), the vine
    along y 16 and out past the piece's inner edge, so Vine-Mid meets it
  Stem-T 32x32: a medium vine down x 16, an arm leaving right along y 16,
    welded with round fillets (the stem's plain joint)
  Stem-Tendril 32x32: the same stem, a wire sprouting right at y 16 and
    curling up and back over itself (an idle row's mark)

The game keeps a texture for the session under its path, so a change bumps
VERSION (and Style.lua's LIST_ITEM_VERSION); older files are deleted.
"""
import glob
import os
import artout
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_scrollbar_art as M  # noqa: E402
from make_scrollbar_art import Pen, Wire, U, WEIGHTS, LIGHT, ucanvas, raised, ribbon, write_tga  # noqa: E402

VERSION = 1
OUT = M.CORE_OUT
HW, PAL = WEIGHTS[""]  # the medium vine's half-width and bark
BEVEL = 0.5 * HW / 0.55  # as vine() bevels it


def rounded(x0, y0, x1, y1, r, n=12):
    """A rounded rectangle's outline as a polygon, in units."""
    pts = []
    for cx, cy, a0 in ((x1 - r, y0 + r, -90), (x1 - r, y1 - r, 0), (x0 + r, y1 - r, 90), (x0 + r, y0 + r, 180)):
        for a in np.radians(np.linspace(a0, a0 + 90, n)):
            pts.append((cx + r * np.cos(a), cy + r * np.sin(a)))
    return pts


def nine(img, margin=8):
    """A nine-slice's middle rows and columns made the same along their stretch."""
    p = margin * U
    out = img.copy()
    out[p:-p, :] = out[p:-p, :].mean(0, keepdims=True)
    out[:, p:-p] = out[:, p:-p].mean(1, keepdims=True)
    return out


def cast(c, m, k):
    """M.shadow's soft shadow of m, down and right, only outside m (a slab's face stays clear)."""
    s = U * c.s
    sh = ndimage.shift(ndimage.gaussian_filter(m, s * 0.5), (s * 0.6, s * 0.4), order=1)
    c.over(np.zeros_like(c.rgb), np.clip(sh, 0, 1) * (1 - m) * k)


def slab_edge():
    n = 32
    c = ucanvas(n, n)
    pen = Pen(c, n)
    m = pen.mask([rounded(4, 4, 28, 28, 3)])
    cast(c, m, 0.8)
    s = U * c.s  # canvas pixels a unit
    edge = ndimage.gaussian_filter(ndimage.maximum_filter(m, size=int(0.9 * 2 * s) | 1), s * 0.25) * (1 - m)
    c.over(np.broadcast_to(np.array((8, 7, 6), float), c.rgb.shape), edge * 0.85)
    d = ndimage.distance_transform_edt(m > 0.5) / s
    bevel = 1.4
    t = np.clip(d / bevel, 0, 1)
    hgt = ndimage.gaussian_filter((1 - (1 - t) ** 2) * bevel * s, s * 0.15)
    gy, gx = np.gradient(hgt)
    nrm = np.stack([-gx, -gy, np.ones_like(gx)], -1)
    nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True)
    k = nrm @ LIGHT - LIGHT[2]
    lit = np.clip(k * 1.6, 0, 1) * m
    dark = np.clip(-k * 1.6, 0, 1) * m
    c.over(np.broadcast_to(np.array((236, 214, 176), float), c.rgb.shape), lit * 0.32)
    c.over(np.zeros_like(c.rgb), dark * 0.55)
    return nine(c.final())


def slab_rim():
    n = 32
    c = ucanvas(n, n)
    pen = Pen(c, n)
    outer = pen.mask([rounded(4, 4, 28, 28, 3.2)])
    cast(c, outer, 0.8)  # the chosen slab stands out too
    ring = np.clip(outer - pen.mask([rounded(4 + 2 * HW, 4 + 2 * HW, 28 - 2 * HW, 28 - 2 * HW, 3.2 - HW)]), 0, 1)
    M.shadow(c, ring, 0.4)
    c.metal(ring, PAL, bevel=BEVEL * U, outline=1.1, shadow=False, sheen=False, paint=True, gloss=0.35, grain=False)
    return nine(c.final())


def mirrored_x(wire, x):
    w = Wire((0, 0), 0)
    w.pts = [np.array([2 * x - p[0], p[1]]) for p in wire.pts]
    w.hs = [np.pi - h for h in wire.hs]
    return w


def curl(top, left):
    """A vine's end curling toward the row: drawn for the top left, mirrored
    by moving points (the light stays the frame's)."""
    w = Wire((44, 16), 180).volute((9.5, 21.5), 5.5, -90, -1, 1.05, eye=1.7, out=0.3, inn=0.3)
    if not top:
        w = w.mirrored(16)
    if not left:
        w = mirrored_x(w, 16)
    c = ucanvas(32, 32)
    raised(Pen(c, 32), w.pieces(HW, 0.8, swell=1.0), PAL, bevel=BEVEL, cast=0.4, grain=False)
    return c.final()


def stem(work=()):
    """The stem down x 16, through the piece, and `work` forged with it."""
    c = ucanvas(32, 32)
    raised(Pen(c, 32), [ribbon([(16, -12), (16, 44)], HW)] + list(work), PAL, bevel=BEVEL, cast=0.4, grain=False)
    return c.final()


def stem_t():
    xs = np.arange(16, 44, 0.05)
    r = 1.8
    dd = np.clip(xs - (16 + HW), 0, r)
    hw = HW + r - np.sqrt(np.maximum(r * r - (r - dd) ** 2, 0))
    arm = ribbon(np.stack([xs, np.full_like(xs, 16.0)], 1), hw)
    return stem([arm])


def stem_tendril():
    w = Wire((16, 18), -8).volute((24.6, 11.2), 5.4, 90, -1, 1.2, eye=1.7, out=0.4, inn=0.45)
    return stem(w.pieces(0.95, 0.75, swell=1.1))


def render():
    out = {"Slab-Edge": slab_edge(), "Slab-Rim": slab_rim(), "Stem-T": stem_t(), "Stem-Tendril": stem_tendril()}
    for top in (True, False):
        for left in (True, False):
            out["Curl-%s%s" % ("T" if top else "B", "L" if left else "R")] = curl(top, left)
    return out


# --- the sheet: every look on the Errands tab's list, laid out as Style.lua and
# Errands.lua lay it out, over the live 4K shot of the tab (2026-11-12)

SHOT = os.path.join(os.environ.get("LOCALAPPDATA", ""), "wow-companion", "shots", "errands2.png")
SHEET = os.path.join(M.ROOT, "target", "errand-list-options.png")
PX = 2.72  # screen pixels a unit at 4K
# the list well in the shot: its left edge (the floor) and the spine's middle,
# the first row's top, the well's foot
WELL_X0, SPINE_X, ROW_Y0, WELL_Y1 = 72, 676, 413, 1545
BAR_X0 = 610  # the scroll bar column's art, kept from the shot
ROW_W = 189  # units: the row's width in the well, clear of the bar
PAD, GAP = 8, 2  # the row's text inset top and bottom, between its lines
STEM = 10  # Branch: the stem's x in the row
NAME, NAME_LIT = (199, 176, 135), (250, 235, 199)
DETAIL = (143, 200, 255)
ERRANDS = [("Half Pendant of Aquatic Endurance", "19 min away"), ("Wrathtail Heads for Lady Sylvanas", "3/20  ·  2.1 km"),
           ("Train Skinning to 150", "Undercity"), ("Bristleback Quilboar Tusks", "On route, step 4"),
           ("Visit the Apothecarium", "640 yd"), ("Reach Moonglade", "41 min away"), ("Sell the green bracers", "")]
LOOKS = {
    "A": "Slab: each errand a raised slab of the medium stone; chosen, the light stone in a bark rim",
    "B": "Inlay: thin vines between errands; chosen, sunk light stone between vines ending in scrolls",
    "C": "Branch: a vine down the list, a tendril for each errand; chosen, a plate grown from it on T joints",
    "D": "Bands: the stones in turn, as Status's rows; thin vines between; chosen, medium vines round it",
}
INSET = {"A": 14, "B": 14, "C": 26, "D": 14}


def load(path):
    return np.asarray(Image.open(path).convert("RGBA"), float)


def art(stem_):
    return load(os.path.join(OUT, "%s.tga" % stem_))


def scaled(img, w, h):
    """img (RGBA) to w x h screen pixels."""
    im = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGBA")
    return np.asarray(im.resize((max(1, int(round(w))), max(1, int(round(h)))), Image.LANCZOS), float)


def paste(dst, img, x, y, alpha=1.0):
    """img (RGBA) over dst (RGB) with its top left at screen pixel (x, y), clipped."""
    x, y = int(round(x)), int(round(y))
    h, w = img.shape[:2]
    x0, y0, x1, y1 = max(x, 0), max(y, 0), min(x + w, dst.shape[1]), min(y + h, dst.shape[0])
    if x0 >= x1 or y0 >= y1:
        return
    src = img[y0 - y:y1 - y, x0 - x:x1 - x]
    a = src[..., 3:4] / 255 * alpha
    dst[y0:y1, x0:x1] = src[..., :3] * a + dst[y0:y1, x0:x1] * (1 - a)


class Panel:
    """The list well from the shot, its row cleared, to draw rows on."""

    def __init__(self, shot, stones):
        self.img = shot[:, :, :3].copy()
        self.stones = stones
        # the empty well under the old row, from just below it
        clean = self.img[ROW_Y0 + 120:ROW_Y0 + 240, WELL_X0 + 4:BAR_X0 - 6]
        for y in range(ROW_Y0 - 16, ROW_Y0 + 100, 120):
            hh = min(120, ROW_Y0 + 100 - y)
            self.img[y:y + hh, WELL_X0 + 4:BAR_X0 - 6] = clean[:hh]
        self.x0 = WELL_X0 + (9 + 2) * PX  # the content's left (the page's -BX) and the row's 2 in

    def u(self, ux, uy):
        return self.x0 + ux * PX, uy

    def stone(self, which, x, y, w, h, alpha=1.0):
        s = self.stones[which]
        hh, ww = int(round(h)), int(round(w))
        tile = np.tile(s, (hh // s.shape[0] + 1, ww // s.shape[1] + 1, 1))[:hh, :ww]
        tile = np.concatenate([tile, np.full(tile.shape[:2] + (1,), 255.0)], -1)
        paste(self.img, tile, x, y, alpha)

    def vine(self, x, y, w, weight="", caps=(True, True), joint_ends=None):
        """A horizontal vine centred on y from x, w pixels long."""
        left, mid, right = (art("Vine-%s%s-%d" % (weight, p, M.VINE_VERSION)) for p in ("Left", "Mid", "Right"))
        cap = 32 * PX
        a = x + (cap if caps[0] else 0)
        b = x + w - (cap if caps[1] else 0)
        if b > a:
            paste(self.img, scaled(mid, b - a, 16 * PX), a, y - 8 * PX)
        if caps[0]:
            paste(self.img, scaled(left, cap, 16 * PX), x, y - 8 * PX)
        if caps[1]:
            paste(self.img, scaled(right, cap, 16 * PX), x + w - cap, y - 8 * PX)

    def vvine(self, x, y0, y1, caps=(False, False)):
        top, mid, bottom = (art("Vine-%s-%d" % (p, M.VINE_VERSION)) for p in ("Top", "VMid", "Bottom"))
        cap = 32 * PX
        a = y0 + (cap if caps[0] else 0)
        b = y1 - (cap if caps[1] else 0)
        if b > a:
            paste(self.img, scaled(mid, 16 * PX, b - a), x - 8 * PX, a)
        if caps[0]:
            paste(self.img, scaled(top, 16 * PX, cap), x - 8 * PX, y0)
        if caps[1]:
            paste(self.img, scaled(bottom, 16 * PX, cap), x - 8 * PX, y1 - cap)

    def piece(self, name, cx, cy, size=32):
        paste(self.img, scaled(art("ListItem-%s-%d" % (name, VERSION)), size * PX, size * PX), cx - size * PX / 2, cy - size * PX / 2)

    def nine(self, name, x, y, w, h):
        """A nine-slice set out 4 units round the box (corners 8)."""
        img = art("ListItem-%s-%d" % (name, VERSION))
        q = img.shape[0] // 4
        o, k = 4 * PX, 8 * PX
        X, Y = [x - o, x - o + k, x + w + o - k, x + w + o], [y - o, y - o + k, y + h + o - k, y + h + o]
        cuts = [0, q, 3 * q, 4 * q]
        for r in range(3):
            for col in range(3):
                part = img[cuts[r]:cuts[r + 1], cuts[col]:cuts[col + 1]]
                paste(self.img, scaled(part, X[col + 1] - X[col], Y[r + 1] - Y[r]), X[col], Y[r])

    def sunk(self, x, y, w, h):
        """The well's inner shadow along the top and left, as Style.Well casts it."""
        sh = 12 * PX
        yy = np.linspace(1, 0, int(sh))[:, None, None] ** 1.6
        top = np.concatenate([np.zeros((int(sh), int(w), 3)), yy * np.ones((1, int(w), 1)) * 255 * 0.7], -1)
        paste(self.img, top, x, y)
        xx = np.linspace(1, 0, int(sh))[None, :, None] ** 1.6
        left = np.concatenate([np.zeros((int(h), int(sh), 3)), xx * np.ones((int(h), 1, 1)) * 255 * 0.7], -1)
        paste(self.img, left, x, y)


FONT = os.path.join(os.environ.get("WINDIR", "C:/Windows"), "Fonts", "georgia.ttf")  # the game's own is not a file


def text_img(text, size, colour, shadow=True):
    font = ImageFont.truetype(FONT, int(size))
    l, t, r, b = font.getbbox(text)
    w, h = r + 4, int(size * 1.35)
    a = Image.new("L", (w, h), 0)
    ImageDraw.Draw(a).text((0, 0), text, font=font, fill=255)
    a = np.asarray(a, float)
    out = np.zeros((h, w, 4))
    out[..., :3] = colour
    out[..., 3] = a
    if shadow:
        sh = np.zeros((h + 3, w + 3, 4))
        sh[3:, 3:, 3] = a * 0.9
        sh[:h, :w] = np.where(a[..., None] > 0, out, sh[:h, :w])
        sh[:h, :w, 3] = np.maximum(sh[:h, :w, 3], a)
        return sh
    return out


def wrap(text, width_px, size):
    font = ImageFont.truetype(FONT, int(size))
    words, lines, cur = text.split(), [], ""
    for wd in words:
        t = (cur + " " + wd).strip()
        if font.getlength(t) > width_px and cur:
            lines.append(cur)
            cur = wd
        else:
            cur = t
    lines.append(cur)
    return lines[:2]


NAME_PX, DETAIL_PX = 13.5 * PX, 11.5 * PX  # GameFontNormal and its Small at this scale


def row_height(look, name, detail):
    lines = wrap(name, (ROW_W - INSET[look] - 8) * PX, NAME_PX)
    h = PAD * 2 + 14 * len(lines) + (GAP + 12 if detail else 0)
    return h, lines


def draw_list(panel, look, items, chosen):
    """Rows flush one under the next from the well's first row, as Errands.lua stacks them."""
    y = ROW_Y0 + 6 * PX
    n = len(items)
    tops = []
    for i, (name, detail) in enumerate(items):
        h, lines = row_height(look, name, detail)
        tops.append((y, h * PX, lines, detail))
        y += h * PX
    x, w = panel.x0, ROW_W * PX
    # the row backs and their pieces
    for i, (ry, rh, lines, detail) in enumerate(tops):
        on = i == chosen
        if look == "A":
            if on:
                panel.stone("claude", x + 3 * PX, ry + 3 * PX, w - 6 * PX, rh - 6 * PX)
                panel.nine("Slab-Rim", x + 3 * PX, ry + 3 * PX, w - 6 * PX, rh - 6 * PX)
            else:
                panel.stone("you", x + 3 * PX, ry + 3 * PX, w - 6 * PX, rh - 6 * PX)
                panel.nine("Slab-Edge", x + 3 * PX, ry + 3 * PX, w - 6 * PX, rh - 6 * PX)
        elif look == "B":
            if on:
                panel.stone("claude", x, ry, w, rh)
                panel.sunk(x, ry, w, rh)
        elif look == "C":
            if on:
                panel.stone("claude", x + STEM * PX, ry, w - STEM * PX, rh)
        elif look == "D":
            panel.stone("claude" if i % 2 == 0 else "you", x, ry, w, rh)
    # the vines over them
    if look == "C":
        panel.vvine(x + STEM * PX, tops[0][0] - 6 * PX, tops[-1][0] + tops[-1][1] + 6 * PX, caps=(True, True))
    for i, (ry, rh, lines, detail) in enumerate(tops):
        on = i == chosen
        if look == "B":
            if on:
                for yy, top in ((ry, True), (ry + rh, False)):
                    panel.vine(x + 32 * PX, yy, w - 64 * PX, caps=(False, False))
                    panel.piece("Curl-%sL" % ("T" if top else "B"), x + 16 * PX, yy)
                    panel.piece("Curl-%sR" % ("T" if top else "B"), x + w - 16 * PX, yy)
            elif i > 0 and i - 1 != chosen:
                panel.vine(x + 6 * PX, ry, w - 12 * PX, "Thin")
        elif look == "C":
            sx = x + STEM * PX
            if on:
                for yy in (ry, ry + rh):
                    panel.vine(sx, yy, w - STEM * PX, caps=(False, True))
                    panel.piece("Stem-T", sx, yy)
            else:
                panel.piece("Stem-Tendril", sx, ry + (PAD + 7) * PX)
        elif look == "D":
            if on:
                for yy in (ry, ry + rh):
                    panel.vine(x, yy, w)
            elif i > 0 and i - 1 != chosen:
                panel.vine(x + 6 * PX, ry, w - 12 * PX, "Thin")
    # the words
    for i, (ry, rh, lines, detail) in enumerate(tops):
        on = i == chosen
        tx = x + INSET[look] * PX
        ty = ry + PAD * PX - 2
        for ln in lines:
            paste(panel.img, text_img(ln, NAME_PX, NAME_LIT if on else NAME), tx, ty)
            ty += 14 * PX
        if detail:
            paste(panel.img, text_img(detail, DETAIL_PX, DETAIL), tx, ty + GAP * PX)


def sheet():
    shot = load(SHOT)
    # the stones as the shot shows them: the light well's, and the list's
    # (the dark stone at DEEPER, 0.6) lifted back to the dark stone
    light = shot[960:1380, 800:1900, :3]  # under the notes, clear of words
    deep = shot[900:1300, 120:560, :3]
    stones = {"claude": light, "you": np.clip(deep / 0.6, 0, 255)}
    cols = []
    top, bottom = ROW_Y0 - 120, WELL_Y1 - 380
    for look in LOOKS:
        pair = []
        for items, chosen in ((ERRANDS[:1], 0), (ERRANDS, 2)):
            p = Panel(shot, stones)
            draw_list(p, look, items, chosen)
            crop = p.img[top:bottom, WELL_X0 - 20:SPINE_X + 30]
            pair.append(crop)
        cols.append(pair)
    ph, pw = cols[0][0].shape[:2]
    head = 110
    gap = 24
    out = np.zeros((head + 2 * ph + gap + 60, len(cols) * (pw + gap) + gap, 3)) + 12
    for k, (look, pair) in enumerate(zip(LOOKS, cols)):
        x = gap + k * (pw + gap)
        paste(out, text_img(look, 64, (232, 214, 176)), x, 14)
        paste(out, text_img(LOOKS[look].split(":")[0], 34, (199, 176, 135)), x + 70, 34)
        out[head:head + ph, x:x + pw] = pair[0]
        out[head + ph + gap:head + 2 * ph + gap, x:x + pw] = pair[1]
    Image.fromarray(np.clip(out, 0, 255).astype(np.uint8)).save(SHEET)
    print("sheet", SHEET, out.shape[1], "x", out.shape[0])


def main():
    if "--sheet-only" not in sys.argv:
        made = render()
        artout.clear(OUT, "ListItem-*.tga")
        for name, rgba in made.items():
            write_tga(os.path.join(OUT, "ListItem-%s-%d.tga" % (name, VERSION)), rgba)
        print(len(made), "textures")
    if "--sheet" in sys.argv or "--sheet-only" in sys.argv:
        sheet()


if __name__ == "__main__":
    main()
