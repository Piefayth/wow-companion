"""The tab gallery's art (addon/WowCompanion_Agent/TabGallery.lua), round two:
the candidates the player's verdict on round one left open
(docs/proposals/companion-tabs.md), painted with the chat's own painters
(make_scrollbar_art.py: bark, wire, carving) on the chat's slate.

    python tools/make_tab_options_art.py   writes Art/TabOpt<id>-<piece>-2.tga

Every piece is one tab's, the same for every tab (the names are the game's),
drawn in UI units on a canvas of U texels a unit, at its rect in TabGallery.lua.
Ornament is wire scrollwork in the vine's bark, weighty, never thinning to a
hairline, never a ball or boss (player/profile.md, "The look").

    1-Fleur            the fleur, hung in front of the chat's vine by a wire bail
    1b-<Idle|Chosen>   a slate lens under a name, wire-rimmed, curled at its points
    3a-...             a slate escutcheon on two wire hooks from the title rule
    3b-...             a slate cartouche, its wire frame scrolled at both ends,
                       hung on one stem crowned on the rule
    3c-...             a slate plaque in a broad bevelled bronze frame, hung as a
                       picture is from one point on the rule
    4a-...             a slate plaque rising from under the window's top rim
    4b-...             the same hanging from under its bottom rim

Chosen pieces: the lighter slate, the bark lit, and further out or lower.
Temporary: goes with the gallery.
"""
import os

import numpy as np
from PIL import Image
from scipy import ndimage

import make_scrollbar_art as sb
from make_scrollbar_art import BARK, U, Pen, bez, dim, glint, raised, ribbon, scroll, shadow, write_tga

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "addon", "WowCompanion_Agent", "Art")
SLATE = os.path.join(ROOT, "addon", "WowCompanion", "Art", "%s-6.tga")
VERSION = 2
PX_4K = 2.7  # 4K pixels a UI unit: the game tiles the slate a texel a pixel
LIT = tuple(tuple(min(255, int(x * 1.18)) for x in col) for col in BARK)
DULL = dim(BARK, 0.82)
WIRE = 0.75  # the wire's half-width: weighty, as the vine's junction work


def pot(n):
    p = 1
    while p < n:
        p *= 2
    return p


def save(stem, rgba):
    """Stretched to power-of-two sides (the game draws it at its rect)."""
    img = Image.fromarray(np.clip(rgba, 0, 255).astype(np.uint8), "RGBA")
    img = img.resize((pot(img.width), pot(img.height)), Image.LANCZOS)
    write_tga(os.path.join(OUT, "TabOpt%s-%d.tga" % (stem, VERSION)), np.asarray(img))


# --- painting helpers

_slate = {}


def stone(c, m, lit):
    """The chat's slate where m is, at the game's own scale: the lighter one
    for the chosen tab."""
    stem, k = ("SlateLight", 1.45) if lit else ("Slate", 1.0)
    key = (stem, c.s)
    if key not in _slate:
        src = Image.open(SLATE % stem).convert("RGB")
        n = int(round(src.width * U * c.s / PX_4K))
        _slate[key] = np.asarray(src.resize((n, n), Image.BICUBIC), float)
    t = _slate[key]
    reps = (c.H // t.shape[0] + 1, c.W // t.shape[1] + 1, 1)
    c.over(np.tile(t, reps)[:c.H, :c.W] * k, m)


def metal(pen, m, pal, bevel, cast=0.45):
    """A raised bronze piece from a mask (raised() takes polygons)."""
    if cast:
        shadow(pen.c, m, cast)
    pen.c.metal(m, pal, bevel=bevel * U, outline=1.1, shadow=False, sheen=False, paint=True, gloss=0.35, grain=False)


def wire(pen, paths, pal, hw=WIRE):
    """Wire along each path, its weight held to its ends (never a hairline)."""
    pieces = [ribbon(p, hw * np.linspace(1.0, 0.8, len(p))) for p in paths]
    raised(pen, pieces, pal, bevel=0.45, cast=0.45)


def ring(pen, outline, hw):
    """A band hw either side of a closed outline, as a mask (a ribbon round a
    closed path overlaps itself where it starts, and the overlap drops out)."""
    m = pen.mask([outline]) > 0.5
    k = U * pen.c.s
    dist = np.where(m, ndimage.distance_transform_edt(m), ndimage.distance_transform_edt(~m))
    return np.clip(hw * k - dist + 0.5, 0, 1)


def arc(cx, cy, r, a0, a1, n=16):
    t = np.radians(np.linspace(a0, a1, n))
    return [(cx + r * np.cos(a), cy + r * np.sin(a)) for a in t]


def notched(x0, y0, x1, y1, r, dip=0.0):
    """A rectangle with its corners cut in quarter circles, its foot drawn
    down to a soft point `dip` below its middle (an escutcheon)."""
    cx = (x0 + x1) / 2
    pts = arc(x0, y0, r, 90, 0) + arc(x1, y0, r, 180, 90) + arc(x1, y1, r, 270, 180)
    if dip:
        w = (x1 - x0) / 2 - r
        pts += [tuple(p) for p in bez((x1 - r, y1), (x1 - r - w * 0.55, y1), (cx + w * 0.3, y1 + dip), (cx, y1 + dip), n=20)][1:]
        pts += [tuple(p) for p in bez((cx, y1 + dip), (cx - w * 0.3, y1 + dip), (x0 + r + w * 0.55, y1), (x0 + r, y1), n=20)][1:]
    return pts + arc(x0, y1, r, 360, 270)


def rounded(x0, y0, x1, y1, r, top=True, bottom=True):
    """A rectangle, its top and/or bottom corners rounded."""
    pts = arc(x0 + r, y0 + r, r, 180, 270) + arc(x1 - r, y0 + r, r, 270, 360) if top else [(x0, y0), (x1, y0)]
    pts += arc(x1 - r, y1 - r, r, 0, 90) + arc(x0 + r, y1 - r, r, 90, 180) if bottom else [(x1, y1), (x0, y1)]
    return pts


def capsule(x0, y0, x1, y1):
    r = (y1 - y0) / 2
    return arc(x1 - r, y0 + r, r, -90, 90, 24) + arc(x0 + r, y0 + r, r, 90, 270, 24)


def lens(x0, x1, cy, h, n=48):
    """Pointed at both ends, full in the middle."""
    t = np.linspace(0, 1, n)
    x = x0 + (x1 - x0) * t
    y = h / 2 * np.sin(np.pi * t) ** 0.55
    return list(zip(x, cy - y)) + list(zip(x[::-1], cy + y[::-1]))


def plate(pen, outline, lit, rim=0.8):
    """Slate in `outline`, its shadow on what is under it, a bark rim round it."""
    m = pen.mask([outline])
    shadow(pen.c, m, 0.7)
    stone(pen.c, m, lit)
    metal(pen, ring(pen, outline, rim), LIT if lit else DULL, bevel=0.55, cast=0.4)
    return m


# --- the pieces: name -> (w, h, painter(c, h, lit))

def fleur(c, h, lit):
    """The fleur (the scroll bar's arrow, pointing down) hung by a bail of two
    wire hooks over the vine (its line at y 13.2), in front of it."""
    f = sb.ucanvas(32, 32)
    sb.fleur_cap(f, True, "Bare")
    pen = Pen(c, h)
    lead = [bez((16, 17.6), (16, 15.2), (16 + s * 0.4, 10.9), (16 + s * 2.6, 10.5), n=24) for s in (1, -1)]
    wire(pen, [scroll(lead[0], 1.35, 0.9), scroll(lead[1], 1.35, -0.9)], BARK, hw=0.72)
    bail = c.final()
    out = np.zeros_like(bail)
    out[4 * U:4 * U + 32 * U] = f.final()
    return over(bail, out)


def over(top, bottom):
    ta, ba = top[..., 3:] / 255, bottom[..., 3:] / 255
    a = ta + ba * (1 - ta)
    rgb = np.where(a > 0, (top[..., :3] * ta + bottom[..., :3] * ba * (1 - ta)) / np.maximum(a, 1e-6), 0)
    return np.concatenate([rgb, a * 255], -1)


def backing(c, h, lit):
    """1b: a slate lens under a name, wire-rimmed, a wire curl off each point."""
    pen = Pen(c, h)
    cy = h / 2
    plate(pen, lens(7, 89, cy, 15), lit, rim=0.7)
    curls = []
    for s in (1, -1):
        x = 48 + s * 41
        lead = bez((x - s * 0.5, cy), (x + s * 1.2, cy), (x + s * 2.4, cy - 0.6), (x + s * 3.0, cy - 2.0), n=16)
        curls.append(scroll(lead, 1.0, -s * 0.8))
    wire(pen, curls, LIT if lit else DULL, hw=0.65)
    if lit:
        glint(c, pen, 24, cy - 6.0, 2.2, 0.35)


# the hung plaques' art: its top at the window's y 20, so the title rule's
# middle is at the art's y 3.7 and its foot at 5.4
RULE_Y, RULE_FOOT = 3.7, 5.4


def escutcheon(c, h, lit):
    """3a: notched slate on two wire hooks caught over the rule."""
    pen = Pen(c, h)
    top = 14 if lit else 11
    plate(pen, notched(7, top, 77, top + 20, 3.2, dip=3.0), lit)
    hooks = []
    for x, s in ((18, -1), (66, 1)):
        lead = bez((x, top + 0.2), (x, top - 3.0), (x + s * 2.0, 8.6), (x + s * 2.0, 5.0), n=24)
        hooks.append(scroll(lead, 1.6, -s * 0.8))
    wire(pen, hooks, LIT if lit else BARK)
    if lit:
        glint(c, pen, 14, top, 2.4, 0.4)


def cartouche(c, h, lit):
    """3b: a slate capsule framed in wire scrolled back at both ends, on one
    stem from the rule, crowned there by two curls along it."""
    pen = Pen(c, h)
    top = 15 if lit else 12
    cy = top + 9
    m = pen.mask([capsule(16, top, 76, top + 18)])
    shadow(c, m, 0.7)
    stone(c, m, lit)
    pal = LIT if lit else DULL
    metal(pen, ring(pen, capsule(16, top, 76, top + 18), WIRE), pal, bevel=0.45)
    frame = []
    for side in (1, -1):  # 1: the right end, drawn mirrored for the left
        X = (lambda x: x) if side == 1 else (lambda x: 92 - x)
        for sy in (1, -1):
            lead = bez((X(72), cy + sy * 7.0), (X(77.5), cy + sy * 9.8), (X(84.5), cy + sy * 9.0), (X(85.4), cy + sy * 3.4), n=24)
            frame.append(scroll(lead, 1.75, side * sy * 0.95))
    wire(pen, frame, pal)
    crown = [np.array([(46, RULE_Y), (46, top + 0.4)])]
    for s in (1, -1):
        lead = bez((46, 8.0), (46, 6.2), (46 + s * 1.6, RULE_FOOT - 0.2), (46 + s * 3.8, RULE_FOOT - 0.3), n=20)
        crown.append(scroll(lead, 1.1, -s * 0.85))
    wire(pen, crown, LIT if lit else BARK)
    if lit:
        glint(c, pen, 24, top, 2.4, 0.4)


def framed(c, h, lit):
    """3c: slate in a broad bevelled bronze frame, hung as a picture is: two
    wires from its top corners to one point on the rule, crowned there."""
    pen = Pen(c, h)
    top = 16 if lit else 13
    outer = rounded(8, top, 76, top + 22, 2.6)
    inner = rounded(10.8, top + 2.8, 73.2, top + 19.2, 1.0)
    mo, mi = pen.mask([outer]), pen.mask([inner])
    shadow(c, mo, 0.7)
    stone(c, mi, lit)
    metal(pen, np.clip(mo - mi, 0, 1), LIT if lit else DULL, bevel=1.3, cast=0.5)
    work = [bez((x, top + 1.2), (x, top - 3.0), (42 + (x - 42) * 0.35, RULE_FOOT + 1.0), (42, RULE_Y), n=30) for x in (15, 69)]
    for s in (1, -1):
        lead = bez((42, 8.0), (42, 6.2), (42 + s * 1.6, RULE_FOOT - 0.2), (42 + s * 3.8, RULE_FOOT - 0.3), n=20)
        work.append(scroll(lead, 1.1, -s * 0.85))
    wire(pen, work, LIT if lit else BARK)
    if lit:
        glint(c, pen, 12, top + 1.4, 2.6, 0.45)


def rim_plaque(c, h, lit, down):
    """4a (down False): slate rising from under the top rim (its foot runs
    off the piece's bottom, under the rim), bark trim on the three sides
    that show; 4b (down True): hanging from under the bottom rim."""
    pen = Pen(c, h)
    if down:
        foot = 30 if lit else 24
        shape = rounded(3, -10, 77, foot, 4.5, top=False)
        trim = [(3, -10)] + arc(7.5, foot - 4.5, 4.5, 180, 90) + arc(72.5, foot - 4.5, 4.5, 90, 0) + [(77, -10)]
    else:
        head = 2 if lit else 8
        shape = rounded(3, head, 77, h + 10, 4.5, bottom=False)
        trim = [(3, h + 10)] + arc(7.5, head + 4.5, 4.5, 180, 270) + arc(72.5, head + 4.5, 4.5, 270, 360) + [(77, h + 10)]
    m = pen.mask([shape])
    shadow(c, m, 0.7)
    stone(c, m, lit)
    path = np.array(trim, float)
    raised(pen, [ribbon(path, 0.85)], LIT if lit else DULL, bevel=0.55, cast=0.4, grain=False)
    if lit:
        glint(c, pen, *((3, 6) if down else (4.3, head + 1.3)), 2.6, 0.4)


PIECES = {
    "1-Fleur": (32, 36, fleur),
    "1b": (96, 20, backing),
    "3a": (84, 40, escutcheon),
    "3b": (92, 40, cartouche),
    "3c": (84, 42, framed),
    "4a": (80, 32, lambda c, h, lit: rim_plaque(c, h, lit, False)),
    "4b": (80, 32, lambda c, h, lit: rim_plaque(c, h, lit, True)),
}


def render():
    """name -> RGBA array (U texels a unit)."""
    out = {}
    for name, (w, h, paint) in PIECES.items():
        for lit in ((None,) if name == "1-Fleur" else (False, True)):
            c = sb.ucanvas(w, h)
            img = paint(c, h, lit)
            key = name if lit is None else "%s-%s" % (name, "Chosen" if lit else "Idle")
            out[key] = img if img is not None else c.final()
    return out


def main():
    for old in os.listdir(OUT):
        if old.startswith("TabOpt"):
            os.remove(os.path.join(OUT, old))
    art = render()
    for stem, rgba in art.items():
        save(stem, rgba)
    print(len(art), "textures")


if __name__ == "__main__":
    main()
