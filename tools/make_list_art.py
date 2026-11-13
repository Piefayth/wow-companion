"""The Companion window's conversation list: a crest over its first row, a
tailpiece closing it, and a hollow lozenge at the left of each name, idle and
lit. Wire scrollwork in the vines' bark (make_scrollbar_art's Wire, raised and
painted as the junctions are), at U texels a unit, transparent round it.

    python tools/make_list_art.py            writes addon/WowCompanion_Agent/Art/List-*-<VERSION>.tga
    python tools/make_list_art.py --mock     and target/tmp/listart/list-1x.png (the list at
                                             1.333 px a unit over the slate), list-4x.png

Each texture is drawn at its canvas's size in units (SIZES), the art centred
in it; the game keeps a texture for the session under its path, so a change
bumps VERSION; older files are deleted.
"""
import glob
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_scrollbar_art as M  # noqa: E402
from make_scrollbar_art import Pen, Wire, U, WEIGHTS, BARK, ucanvas, raised, carve, dim, write_tga  # noqa: E402

VERSION = 1
OUT = os.path.join(M.ROOT, "addon", "WowCompanion_Agent", "Art")
TMP = os.path.join(M.ROOT, "target", "tmp", "listart")
SIZES = {"Head": (128, 32), "Tail": (128, 16), "Mark-Idle": (16, 16), "Mark-Lit": (16, 16)}
METAL = WEIGHTS[""][1]  # the medium vine's bark, as the open entry's rules


def mirrored_x(wire, x):
    """The wire mirrored about the line x (points moved, so the light stays the frame's)."""
    w = Wire((0, 0), 0)
    w.pts = [np.array([2 * x - p[0], p[1]]) for p in wire.pts]
    w.hs = [np.pi - h for h in wire.hs]
    return w


def symmetric(cx, wires):
    """Each (wire, root half-width, tip half-width) and its mirror about x = cx, as metal."""
    return [q for wire, w0, w1 in wires for v in (wire, mirrored_x(wire, cx)) for q in v.pieces(w0, w1)]


def point(cx, y, heading, hw):
    """The heart's point: the lobes leave (cx, y) along +-heading, hw wide;
    their square ends cross there, leaving a notch this fills and draws on
    to a point below."""
    a = np.radians(heading)
    dx, dy = -np.sin(a) * hw, np.cos(a) * hw
    return [(cx - dx, y + dy), (cx, y - 0.2), (cx + dx, y + dy), (cx, y + dy + hw * 0.9)]


def head():
    """The crest: a heart of two volutes, point down, at the middle, a stem
    rising from its cusp and parting into two curls; from each lobe's outside
    an arm sweeps out, dipping, and curls up at its end, a satellite budding
    off it on the way."""
    w, h = SIZES["Head"]
    cx = w / 2
    lobe = Wire((cx, 28.6), -62).volute((cx + 5.6, 15.0), 5.6, 0, -1, 1.0, eye=1.9, out=0.45, inn=0.5)
    stem = M.ribbon([(cx, 14.0), (cx, 8.0)], 1.3)
    crown = Wire((cx, 9.0), -90).volute((cx + 4.4, 5.6), 3.4, 180, 1, 0.62, eye=1.5, out=0.4, inn=0.5)
    arm = lobe.fork(0.24, 50).to((cx + 18, 25.0), 0, out=0.5, inn=0.45) \
        .volute((cx + 46, 17.5), 5.4, 75, -1, 1.0, eye=1.8, out=0.45, inn=0.5)
    sat = arm.fork(0.30, -50).volute((cx + 29, 15.0), 4.0, 215, 1, 0.8, eye=1.4, out=0.4, inn=0.5)
    c = ucanvas(w, h)
    raised(Pen(c, h, dy=-0.5), symmetric(cx, [(lobe, 1.6, 1.15), (crown, 1.25, 0.85), (arm, 1.55, 1.1), (sat, 1.3, 0.95)])
           + [stem, point(cx, 28.6, -62, 1.6)], METAL, bevel=1.0, cast=0.45, grain=False)
    return c.final()


def tail():
    """The tailpiece: a smaller heart, point down, and an S of wire each way
    ending in a curl."""
    w, h = SIZES["Tail"]
    cx = w / 2
    lobe = Wire((cx, 13.9), -60).volute((cx + 4.4, 6.4), 4.2, 0, -1, 0.85, eye=1.3, out=0.45, inn=0.5)
    arm = lobe.fork(0.25, 50).to((cx + 17, 11.0), 0, out=0.5, inn=0.5) \
        .volute((cx + 31, 7.0), 4.0, 90, -1, 0.85, eye=1.3, out=0.45, inn=0.5)
    c = ucanvas(w, h)
    raised(Pen(c, h, dy=-0.8), symmetric(cx, [(lobe, 1.4, 1.0), (arm, 1.4, 1.0)]) + [point(cx, 13.9, -60, 1.4)],
           METAL, bevel=0.9, cast=0.45, grain=False)
    return c.final()


SLATE_DARK = (19, 20, 23)  # the lozenge's centre: the window's slate, a shade darker
LIT = ((34, 24, 14), (112, 84, 54), (196, 162, 116))  # the bark brightened, still washed


def mark(pal):
    """A hollow lozenge 14 units across: a bark rim 2 units thick round a sunk slate centre."""
    n = SIZES["Mark-Idle"][0]
    c = ucanvas(n, n)
    pen = Pen(c, n)
    o, i = 7.0, 7.0 - 2.0 * np.sqrt(2)  # half-diagonals: the rim 2 units thick, measured square to its sides
    q = n / 2

    def diamond(r):
        return [(q, q - r), (q + r, q), (q, q + r), (q - r, q)]
    centre = pen.mask([diamond(i + 0.3)])
    c.over(np.broadcast_to(np.array(SLATE_DARK, float), c.rgb.shape), centre)
    carve(c, centre, depth=0.8)
    c.over(np.broadcast_to(np.array(SLATE_DARK, float), c.rgb.shape), centre * 0.55)
    ring = np.clip(pen.mask([diamond(o)]) - pen.mask([diamond(i)]), 0, 1)
    M.shadow(c, ring, 0.45)
    c.metal(ring, pal, bevel=0.8 * U, outline=1.1, shadow=False, sheen=False, paint=True, gloss=0.35, grain=False)
    return c.final()


def render():
    return {"Head": head(), "Tail": tail(), "Mark-Idle": mark(dim(BARK, 0.72)), "Mark-Lit": mark(LIT)}


# --- the mock: the list as the window draws it, at 1.333 px a unit

PX = 4 / 3  # screen px a unit
SLATE = (14, 14, 16)  # the list's slate (convlist.png)
PLATE = (27, 28, 31)  # the open entry's lighter stone
NAME, NAME_OPEN = (199, 176, 135), (232, 214, 176)
SHOT = r"C:\Users\Sean\AppData\Local\wow-companion\shots\convlist.png"
LIST_W, ROW = 122, 24
ROWS = [("Main", None), ("L1", None), ("L2", "161s"), ("R1", "7s"), ("R2", None), ("Quick", None)]
OPEN, LIT_ROWS = 2, {3}


def paste(dst, img, x, y):
    """img (RGBA, 0..255) over dst at texel (x, y)."""
    h, w = img.shape[:2]
    a = img[..., 3:4] / 255
    dst[y:y + h, x:x + w] = img[..., :3] * a + dst[y:y + h, x:x + w] * (1 - a)


def tga(name):
    return np.asarray(Image.open(os.path.join(M.CORE_OUT, name)).convert("RGBA"), float)


def rule(width):
    """A medium vine `width` units long with round ends, from Core's pieces."""
    left, mid, right = (tga("Vine-%s-%d.tga" % (p, M.VINE_VERSION)) for p in ("Left", "Mid", "Right"))
    mw = width * U - left.shape[1] - right.shape[1]
    return np.concatenate([left, np.repeat(mid[:, :1], mw, 1), right], 1)


def mock(art):
    pad, top = 15, 6
    W = 150
    H = top + 32 + len(ROWS) * ROW + 16 + 8
    H += (-H) % 3
    img = np.zeros((H * U, W * U, 3)) + SLATE
    x0 = pad
    cx = x0 + LIST_W / 2
    y = top
    paste(img, art["Head"], int((cx - 64) * U), y * U)
    y += 32 + 1
    font = ImageFont.truetype(r"C:\Windows\Fonts\georgia.ttf", 12 * U)
    ptr = pointer()
    for k, (name, extra) in enumerate(ROWS):
        ry = y + k * ROW
        if k == OPEN:
            img[ry * U:(ry + ROW) * U, x0 * U:(x0 + LIST_W) * U] = PLATE
            r = rule(LIST_W)
            for yy in (ry, ry + ROW):
                paste(img, r, x0 * U, (yy - 8) * U)
            paste(img, ptr, int((x0 - 13) * U), int((ry + ROW / 2) * U - ptr.shape[0] / 2))
        else:
            mk = art["Mark-Lit" if k in LIT_ROWS else "Mark-Idle"]
            paste(img, mk, (x0 + 3) * U, (ry + 4) * U)
        text = Image.new("L", (LIST_W * U, ROW * U), 0)
        d = ImageDraw.Draw(text)
        d.text((22 * U, ROW * U / 2), name + ("   " + extra if extra else ""), font=font, fill=255, anchor="lm")
        a = np.asarray(text, float)[..., None] / 255
        col = np.array(NAME_OPEN if k == OPEN else NAME, float)
        sl = img[ry * U:(ry + ROW) * U, x0 * U:(x0 + LIST_W) * U]
        sl[:] = col * a + sl * (1 - a)
    paste(img, art["Tail"], int((cx - 64) * U), (y + len(ROWS) * ROW + 1) * U)
    k = int(U / PX)
    small = img.reshape(H * U // k, k, W * U // k, k, 3).mean((1, 3))
    os.makedirs(TMP, exist_ok=True)
    one = Image.fromarray(np.clip(small, 0, 255).astype(np.uint8))
    one.save(os.path.join(TMP, "list-1x.png"))
    one.resize((one.width * 4, one.height * 4), Image.NEAREST).save(os.path.join(TMP, "list-4x.png"))


def pointer():
    """The controller's pointer cut from the shot (2.72 px a unit there), at U texels a unit."""
    shot = Image.open(SHOT).convert("RGB").crop((34, 220, 72, 258))
    k = U / 2.72
    shot = shot.resize((round(shot.width * k), round(shot.height * k)), Image.LANCZOS)
    rgb = np.asarray(shot, float)
    a = np.clip((rgb.max(-1) - 26) / 30, 0, 1)[..., None] * 255
    return np.concatenate([rgb, a], -1)


def main():
    art = render()
    for old in glob.glob(os.path.join(OUT, "List-*.tga")):
        os.remove(old)
    for stem, rgba in art.items():
        write_tga(os.path.join(OUT, "List-%s-%d.tga" % (stem, VERSION)), rgba)
    if "--mock" in sys.argv:
        mock(art)
    print(len(art), "textures")


if __name__ == "__main__":
    main()
