"""The Companion window's conversation list: six cells filling the well, one
under the next, each closed above and below by a vine running wall to wall:
the thick vine over the first and under the last, a crest forged into the one
and the same ornament hung under the other; the medium vine between cells.
The open conversation's cell is the same cell lit: the light stone, and its
two rules in the bark brightened. Wire scrollwork in the vines' bark
(make_scrollbar_art's Wire), at U texels a unit, transparent round it.

    python tools/make_convlist_art.py          writes addon/WowCompanion_Agent/Art/Conv-*-<VERSION>.tga
    python tools/make_convlist_art.py --mock   and target/tmp/convlist2/: the well over the 4K shot
                                               (mock-4k.png), at half that (mock-1080.png), beside
                                               the shot (compare.png), and the window sized down
                                               to its least, the rules plain (mock-4k-short.png)

Every piece is W units wide, the well's whole width, its rule running off both
ends so it passes under the well's walls. The idle rules between cells are
Core's medium vine (Vine-Mid); this draws the rest:
  Head, Head-Lit  W x HEAD_H, the thick rule at HEAD_RULE, the crest standing on it
  Foot, Foot-Lit  W x FOOT_H, the thick rule at FOOT_RULE, the crest hung under it
  Rule-Lit        64 x 16, the medium vine lit, stretched as Vine-Mid is
  RuleThick-Lit   64 x 16, the thick vine lit, stretched as Vine-ThickMid is
The plain head and foot are the thick rule alone (Vine-ThickMid, lit
RuleThick-Lit), where the well is too short for the crests. The game keeps a
texture for the session under its path, so a change bumps VERSION; older
files are deleted.
"""
import glob
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_scrollbar_art as M  # noqa: E402
from make_scrollbar_art import Pen, Wire, U, WEIGHTS, dim, ucanvas, raised, ribbon, vine, write_tga  # noqa: E402

VERSION = 1
OUT = os.path.join(M.ROOT, "addon", "WowCompanion_Agent", "Art")
TMP = os.path.join(M.ROOT, "target", "tmp", "convlist2")

W = 130  # the well's width (Window.lua's WELL)
HEAD_H, HEAD_RULE = 37, 32
FOOT_H, FOOT_RULE = 28, 4
HEAD_K, FOOT_K = 1.15, 0.8  # the crest's scale on each
LIT_BARK = ((34, 24, 14), (112, 84, 54), (205, 168, 120))  # the bark brightened, still washed
THICK = WEIGHTS["Thick"]  # (half-width, bark)
LIT = {"": dim(LIT_BARK, 0.88), "Thick": dim(LIT_BARK, 0.8)}  # each weight lit as its bark is dimmed


def mirrored_x(wire, x):
    """The wire mirrored about the line x (points moved, so the light stays the frame's)."""
    w = Wire((0, 0), 0)
    w.pts = [np.array([2 * x - p[0], p[1]]) for p in wire.pts]
    w.hs = [np.pi - h for h in wire.hs]
    w.pitch = getattr(wire, "pitch", np.inf)
    return w


def fillet(x, y, sx, sy, f):
    """The web filling the square corner at (x, y) between a face running
    away along sx and one along sy, rounded to radius f."""
    x, y, f = x - sx * 0.3, y - sy * 0.3, f + 0.3  # sunk into both faces, so no seam shows where they meet
    t = np.radians(np.linspace(0, 90, 16))
    arc = [(x + sx * f * (1 - np.sin(a)), y + sy * f * (1 - np.cos(a))) for a in t]
    return [(x, y)] + arc


def crest(r, k, down=False):
    """The ornament on the thick rule at y r, k its scale (hung under it
    when down): an Ionic capital in wire. A post rises from the rule into a
    flat bar, the highest thing, which rolls at each end into a big volute
    curling down and in to rest on the rule; from each volute's outer side a
    wing runs out along the rule and curls up. Its middle is the post, flat
    on top: never two scrolls meeting in a notch (that reads as a heart)."""
    cx = W / 2

    def P(dx, dy):
        return (cx + dx * k, r - dy * k)
    R, top = 9.5, 21.0
    bar, post = 1.9 * k, 1.5 * k
    vol = Wire(P(0, top), 0).volute(P(R + 1.5, top - R), R * k, 270, 1, 1.45, eye=max(2.0 * k, 1.5),
                                    out=0.4, inn=0.4)
    i = len(vol.pts) // 4  # the volute's outer side, heading down
    wing = Wire(vol.pts[i], np.degrees(vol.hs[i]) - 30).volute(P(2 * R + 16, 6.5), 5.5 * k, 90, -1, 1.0,
                                                               eye=max(1.8 * k, 1.4), out=0.5, inn=0.5)
    y_bar, y_rule = r - (top * k - bar), r - THICK[0]
    polys = [ribbon([P(0, 0), P(0, top)], post)]
    for sx in (1, -1):  # the post's webs, under the bar and over the rule
        polys.append(fillet(cx + sx * post, y_bar, sx, 1, 1.8 * k))
        polys.append(fillet(cx + sx * post, y_rule, sx, -1, 1.8 * k))
    wires = [(vol, bar, 1.3 * k), (wing, 1.6 * k, 1.15 * k)]
    if down:  # turned over the rule: points moved, so the light stays the frame's
        wires = [(w.mirrored(r), a, b) for w, a, b in wires]
        polys = [[(x, 2 * r - y) for x, y in p] for p in polys]
    return [q for w, a, b in wires for v in (w, mirrored_x(w, cx)) for q in v.pieces(a, b)] + polys


def piece(h, r, k, down, pal):
    """The thick rule across the whole piece at y r, running off both ends,
    and the crest forged to it as one metal, on a W x h canvas."""
    c = ucanvas(W, h)
    pieces = [ribbon([(-12, r), (W + 12, r)], THICK[0])] + crest(r, k, down)
    raised(Pen(c, h), pieces, pal, bevel=0.5 * THICK[0] / 0.55, cast=0.4, grain=False)
    return c.final()


def rule_tile(weight, pal):
    """A weight's vine as Core's Vine-<weight>Mid is made, in pal."""
    c = ucanvas(64, 16)
    vine(c, 16, [((-12, 8), (76, 8))], (), None, WEIGHTS[weight][0], pal)
    img = c.final()
    return np.repeat(img.mean(1, keepdims=True), img.shape[1], 1)


def render():
    return {
        "Head": piece(HEAD_H, HEAD_RULE, HEAD_K, False, THICK[1]),
        "Head-Lit": piece(HEAD_H, HEAD_RULE, HEAD_K, False, LIT["Thick"]),
        "Foot": piece(FOOT_H, FOOT_RULE, FOOT_K, True, THICK[1]),
        "Foot-Lit": piece(FOOT_H, FOOT_RULE, FOOT_K, True, LIT["Thick"]),
        "Rule-Lit": rule_tile("", LIT[""]),
        "RuleThick-Lit": rule_tile("Thick", LIT["Thick"]),
    }


# --- the mock: the well as the window draws it, over the 4K shot ------------

SHOT = os.path.join(os.environ.get("LOCALAPPDATA", ""), "wow-companion", "shots", "convlist2.png")
WELL = (55.0, 37.0, 1282.0, 405.0)  # the well's left edge, top, foot and right edge in the shot, px
PX = (WELL[3] - WELL[0]) / W  # the shot's px a unit: 2.69 (the brief's 2.667, measured)
INSET, FLOOR = 4, 3
ROWS = [("Main", None, None), ("L1", "new", (127, 208, 127)), ("L2", None, None),
        ("R1", "5s", (176, 176, 176)), ("R2", "475s", (176, 176, 176)), ("Quick", None, None)]
OPEN, POINTER = 2, 3
NAME, NAME_HL, NAME_LIT = (199, 176, 135), (232, 214, 171), (250, 235, 199)
LIGHT_STONE = (28.7, 29.6, 32.5)  # the open plate's mean in the shot
NAME_SIZE, STATE_SIZE = 16, 12  # units: GameFontNormalLarge, GameFontNormal
NAME_X, STATE_R = 16, 10  # the name's left from the well's left; the state's right from its right
MIN_CELL = 32  # a cell's least height with the crests; below it the rules go plain
PLAIN_RULE = 8  # a plain top or foot rule's centre from the well's top or foot
SHADE, SHADE_A = 12, 0.5  # the shadows' reach in units, and darkness where they start
FONT = r"C:\Windows\Fonts\pala.ttf"  # Friz Quadrata's stand-in, lining figures as Friz has


def small(img, k):
    """An RGBA (0..255, float) piece at U texels a unit, at k px a unit."""
    h, w = img.shape[:2]
    im = Image.fromarray(img.astype(np.uint8), "RGBA")
    pre = Image.fromarray((img[..., :3] * img[..., 3:4] / 255).astype(np.uint8), "RGB")
    size = (max(1, round(w * k / U)), max(1, round(h * k / U)))
    a = np.asarray(im.getchannel("A").resize(size, Image.LANCZOS), float)
    rgb = np.asarray(pre.resize(size, Image.LANCZOS), float)
    return rgb, np.clip(a / 255, 0, 1)


def over(dst, rgb, a, x, y, clip=None):
    """Premultiplied rgb with alpha a over dst at px (x, y), cut to clip (x0, x1) columns."""
    x, y = int(round(x)), int(round(y))
    h, w = a.shape
    x0, x1 = (0, dst.shape[1]) if clip is None else clip
    sx0, sx1 = max(x, x0) - x, min(x + w, x1) - x
    if sx1 <= sx0:
        return
    sl = dst[y:y + h, x + sx0:x + sx1]
    sl[:] = rgb[:, sx0:sx1] + sl * (1 - a[:, sx0:sx1, None])


def stone_like(sample, h, w, mean=None):
    """A field of the shot's stone, h x w px, mirror-tiled from sample, moved to mean."""
    reps = (h // sample.shape[0] + 2, w // sample.shape[1] + 2)
    rows = [sample if i % 2 == 0 else sample[::-1] for i in range(reps[0])]
    col = np.concatenate(rows, 0)
    cols = [col if j % 2 == 0 else col[:, ::-1] for j in range(reps[1])]
    out = np.concatenate(cols, 1)[:h, :w].copy()
    if mean is not None:
        out += np.array(mean) - sample.reshape(-1, 3).mean(0)
    return out


def pointer(shot):
    """The controller's pointer cut from the shot (by R1), its tip at (0, 0) of the returned offset."""
    box = (30, 345, 72, 400)
    p = shot[box[1]:box[3], box[0]:box[2]]
    a = np.clip((p.max(-1) - 34) / 40, 0, 1)
    ys, xs = np.nonzero(a > 0.5)
    tip = (box[0] + xs.max(), box[1] + int(np.median(ys[xs >= xs.max() - 2])))
    return p * a[..., None], a, (box[0] - tip[0], box[1] - tip[1])


def text(dst, s, size, colour, x, cy, k, right=False):
    """s at size units, its caps centred on cy, from x (or ending at x), at k px a unit."""
    font = ImageFont.truetype(FONT, int(round(size * k * 1.02)))
    l, t, r, b = font.getbbox("H")
    w = font.getbbox(s)[2]
    im = Image.new("L", (int(w + 8), int((b + 8) * 1.4)), 0)
    ImageDraw.Draw(im).text((4, 4), s, font=font, fill=255)
    a = np.asarray(im, float) / 255
    x0 = x - w - 4 if right else x - 4
    y0 = cy - (t + b) / 2 - 4
    over(dst, a[..., None] * np.array(colour, float), a, x0, y0)


def mock(art, cut=0):
    """The well over the shot; cut px taken out of the shot's middle make a
    shorter well (the window sized down)."""
    shot = np.asarray(Image.open(SHOT).convert("RGB"), float)
    sample = shot[600:1260, 72:388]
    shot = np.concatenate([shot[:400], shot[400 + cut:]], 0)  # the walls run on unchanged; the floor is redrawn
    img = shot.copy()
    left, top, foot, _ = WELL
    foot -= cut
    H = (foot - top) / PX  # the well's height in units
    head, tail = layout(H)  # the top and foot rules, and whether they carry the crests
    X = lambda u: left + u * PX  # noqa: E731
    Y = lambda u: top + u * PX  # noqa: E731
    floor = (int(X(FLOOR)), int(Y(FLOOR)), int(X(W - FLOOR)), int(Y(H - FLOOR)))
    walls = (int(round(X(INSET))), int(round(X(W - INSET))))
    img[floor[1]:floor[3], floor[0]:floor[2]] = stone_like(sample, floor[3] - floor[1], floor[2] - floor[0])
    # restore the walls over the floor's edges, as the well's border draws over its stone
    for x0, x1 in ((int(left), walls[0]), (walls[1], int(left + W * PX) + 1)):
        img[:, x0:x1] = shot[:, x0:x1]
    for y0, y1 in ((int(top), int(round(Y(INSET)))), (int(round(Y(H - INSET))), int(foot) + 1)):
        img[y0:y1, walls[0]:walls[1]] = shot[y0:y1, walls[0]:walls[1]]
    rules = [head + (tail - head) * i / 6 for i in range(7)]
    # the open cell's light stone, between its rules
    y0, y1 = int(Y(rules[OPEN])), int(Y(rules[OPEN + 1]))
    img[y0:y1, walls[0]:walls[1]] = stone_like(sample, y1 - y0, walls[1] - walls[0], LIGHT_STONE)
    # each cell sunk under its upper rule, and the well under its left wall:
    # soft shadows as Blizzard's ShadowOverlay-Top and -Left cast
    for i in range(6):
        ya = Y(rules[i])
        hgt = int(SHADE * PX)
        g = (1 - np.linspace(0, 1, hgt)) ** 2 * SHADE_A
        img[int(ya):int(ya) + hgt, walls[0]:walls[1]] *= (1 - g)[:, None, None]
    wid = int(SHADE * PX)
    g = (1 - np.linspace(0, 1, wid)) ** 2 * SHADE_A
    img[int(Y(INSET)):int(Y(H - INSET)), walls[0]:walls[0] + wid] *= (1 - g)[None, :, None]
    lit = {OPEN, OPEN + 1}
    vm = np.asarray(Image.open(os.path.join(M.CORE_OUT, "Vine-Mid-%d.tga" % M.VINE_VERSION)).convert("RGBA"), float)
    plain = head != HEAD_RULE
    tvm = np.asarray(Image.open(os.path.join(M.CORE_OUT, "Vine-ThickMid-%d.tga" % M.VINE_VERSION)).convert("RGBA"), float)
    for i in range(7):
        if 0 < i < 6 or plain:
            thick = i in (0, 6)
            tile = art["RuleThick-Lit" if thick else "Rule-Lit"] if i in lit else tvm if thick else vm
            rgb, a = small(np.repeat(tile[:, :1], W * U, 1), PX)
            over(img, rgb, a, X(0), Y(rules[i] - 8), walls)
    if not plain:
        rgb, a = small(art["Head-Lit" if 0 in lit else "Head"], PX)
        over(img, rgb, a, X(0), Y(0), walls)
        rgb, a = small(art["Foot-Lit" if 6 in lit else "Foot"], PX)
        over(img, rgb, a, X(0), Y(H - FOOT_H), walls)
    for i, (name, state, colour) in enumerate(ROWS):
        cy = Y((rules[i] + rules[i + 1]) / 2)
        col = NAME_LIT if i == OPEN else NAME_HL if i == POINTER else NAME
        text(img, name, NAME_SIZE, col, X(NAME_X), cy, PX)
        if state:
            text(img, state, STATE_SIZE, colour, X(W - STATE_R), cy, PX, right=True)
    # the pointer: Blizzard puts its tip on the row's left edge, at its middle
    prgb, pa, (dx, dy) = pointer(shot)
    # the old pointer's ground, from the gap below it
    img[345:400, 30:walls[0]] = shot[420:475, 30:walls[0]]
    cy = Y((rules[POINTER] + rules[POINTER + 1]) / 2)
    over(img, prgb, pa, X(INSET) + dx, cy + dy)
    return np.clip(img, 0, 255)


def layout(H):
    """The well's top and foot rules (units from its top) at height H: the
    crests' when every cell gets MIN_CELL, else the plain rules'."""
    head, tail = HEAD_RULE, H - FOOT_H + FOOT_RULE
    if (tail - head) / 6 < MIN_CELL:
        head, tail = PLAIN_RULE, H - PLAIN_RULE
    return head, tail


def write_mocks(art):
    os.makedirs(TMP, exist_ok=True)
    short = Image.fromarray(mock(art, cut=int((467 - 181) * PX)).astype(np.uint8))
    short.save(os.path.join(TMP, "mock-4k-short.png"))
    big = Image.fromarray(mock(art).astype(np.uint8))
    big.save(os.path.join(TMP, "mock-4k.png"))
    half = big.resize((big.width // 2, big.height // 2), Image.LANCZOS)
    half.save(os.path.join(TMP, "mock-1080.png"))
    shot = Image.open(SHOT).convert("RGB")
    both = Image.new("RGB", (shot.width * 2 + 20, shot.height), (40, 40, 40))
    both.paste(shot, (0, 0))
    both.paste(big, (shot.width + 20, 0))
    both.save(os.path.join(TMP, "compare.png"))
    for stem, rgba in art.items():
        bg = Image.new("RGBA", (rgba.shape[1], rgba.shape[0]), (18, 19, 22, 255))
        bg.alpha_composite(Image.fromarray(rgba.astype(np.uint8), "RGBA"))
        bg.convert("RGB").save(os.path.join(TMP, "tex-%s.png" % stem))


def main():
    art = render()
    for old in glob.glob(os.path.join(OUT, "Conv-*.tga")):
        os.remove(old)
    for stem, rgba in art.items():
        write_tga(os.path.join(OUT, "Conv-%s-%d.tga" % (stem, VERSION)), rgba)
    if "--mock" in sys.argv:
        write_mocks(art)
    print(len(art), "textures")


if __name__ == "__main__":
    main()
