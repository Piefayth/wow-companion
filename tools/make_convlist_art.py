"""The Companion window's conversation list, in looks to choose from at true
size (ConvList.lua, WC.Companion.ConvLook(key)). Each look is a whole design:
its resting rows, the open one (the same row, lit), and how the kept crests
(Crest-Head, Crest-Foot: the player's, never redrawn here) hold the list.
Every row shows its chord, the pad buttons that talk to it (the game's own
glyphs, drawn by the game), in a place of its own, and its live state ("12s",
"new", "talking") there or beside it.

  heartwood  heartwood plaques in the pad's groups (Main; L1 L2; R1 R2; Quick)
             spread down the well between vines, a window carved at the right
             for the chord or the state; open: the plaque under a lamp, its
             window's rim and its vines lit
  brass      bronze nameplates stacked under the head crest, the foot crest
             hung under the last; the chord in a stamped socket; open: the
             plate polished bright, its name in dark ink
  spine      a book's spine: leather panels between raised bands, each tooled
             with a frame round the name and a compartment for the chord;
             open: its tooling in gilt and its leather warmed
  cloisonne  bronze wire cells filled with navy enamel, laid out as the pad is:
             Main across the top, L1 R1 and L2 R2 side by side as the shoulders
             sit, Quick across the foot; the chord in a cell of black enamel;
             open: its enamel lit from within, its wire bright
  lantern    blackened iron rails, each with a lantern pane at its left holding
             the chord; open: the pane glows amber and its light washes along
             the rail
  stem       one heavy vine stem down the well from crest to crest, each
             conversation a black lacquer sign hung on a scrolled bracket off
             it, in the pad's groups; open: the lacquer's red shows under the
             light, its bracket and rim lit

Wire and rims are the vines' bark (make_scrollbar_art), at U texels a unit.

    python tools/make_convlist_art.py          writes addon/WowCompanion_Agent/Art/Conv-<look>-<piece>-<VERSION>.tga
    python tools/make_convlist_art.py --mock   only the mocks, in target/tmp/convlist4/: each look's well over
                                               the 4K shot (<look>.png) and all of them side by side (all.png)

The game keeps a texture for the session under its path, so a change bumps
VERSION (and ConvList.lua's); older files are cleared through artout.
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import artout  # noqa: E402
import make_scrollbar_art as M  # noqa: E402
from make_scrollbar_art import Pen, Wire, U, WEIGHTS, dim, ucanvas, raised, ribbon, vine, write_tga  # noqa: E402
from make_control_art import stadium  # noqa: E402

VERSION = 3
OUT = os.path.join(M.ROOT, "addon", "WowCompanion_Agent", "Art")
TMP = os.path.join(M.ROOT, "target", "tmp", "convlist4")

W, INSET = 130, 4  # the well's width (Window.lua's WELL) and its walls
RW = W - 2 * INSET  # a row's width: wall to wall
HEAD_H, HEAD_RULE = 37, 32  # Crest-Head: its thick rule's centre
FOOT_H, FOOT_RULE = 28, 4  # Crest-Foot
BARK = WEIGHTS[""][1]
THICK = WEIGHTS["Thick"]
LIT_BARK = ((34, 24, 14), (112, 84, 54), (205, 168, 120))  # the bark brightened, still washed
LIT = {"": dim(LIT_BARK, 0.88), "Thick": dim(LIT_BARK, 0.8)}
GOLD = ((96, 66, 28), (206, 162, 88), (250, 222, 150))  # gilt and polished brass


# --- the painter's helpers -----------------------------------------------------

def grid(c):
    """Each canvas pixel's y and x in units."""
    ys = (np.arange(c.H) / c.s - c.pad) / U
    xs = (np.arange(c.W) / c.s - c.pad) / U
    return ys[:, None] + 0 * xs[None, :], xs[None, :] + 0 * ys[:, None]


def inside(c, m):
    """Distance in units from each pixel of m to its edge."""
    return ndimage.distance_transform_edt(m > 0.5) / (U * c.s)


def field(c, sy, sx, seed):
    """Smooth noise at sy x sx units, about -1..1 (a material's figure: broad,
    never fine streaks, which read as noise at true size)."""
    rng = np.random.default_rng(seed)
    h, w = c.H // c.s, c.W // c.s
    g = ndimage.gaussian_filter(rng.standard_normal((h, w)), (sy * U, sx * U), mode="wrap")
    g /= g.std() + 1e-9
    return ndimage.zoom(g, c.s, order=1)[:c.H, :c.W] / 2.5


def light(c, hgt):
    """The diffuse light on a height field in units (1 on the flat) and the
    half-vector term for speculars."""
    k = U * c.s
    gy, gx = np.gradient(ndimage.gaussian_filter(hgt, c.s * 0.5) * k)
    n = np.stack([-gx, -gy, np.ones_like(gx)], -1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    return np.clip(n @ M.LIGHT, 0, None) / M.LIGHT[2], np.clip(n @ M.HALF, 0, 1)


def bevel(d, width, height=1.0):
    """A bevel's height from the distance inside its edge."""
    t = np.clip(d / width, 0, 1)
    return (1 - (1 - t) ** 2) * height


def ramp(pal, diff):
    """Metal's colour for the light: shadow to mid to light (Canvas.metal's)."""
    sh, mid, li = (np.array(p, float) for p in pal)
    t = diff[..., None]
    return np.where(t < 1, sh + (mid - sh) * np.clip(t, 0, 1), mid + (li - mid) * np.clip((t - 1) / 0.45, 0, 1))


def paint(c, rgb, m):
    c.over(np.clip(rgb, 0, 255), np.clip(m, 0, 1))


def shade_top(c, depth, k):
    """The shadow a rule over the piece casts on its top."""
    y, _ = grid(c)
    g = np.clip(1 - y / depth, 0, 1) ** 2 * k * (y >= 0)
    c.over(np.zeros_like(c.rgb), g)


def rect(x0, y0, x1, y1, cut=0.0):
    """A rectangle, its corners cut at 45 degrees by `cut`."""
    if not cut:
        return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    return [(x0 + cut, y0), (x1 - cut, y0), (x1, y0 + cut), (x1, y1 - cut), (x1 - cut, y1), (x0 + cut, y1),
            (x0, y1 - cut), (x0, y0 + cut)]


def rounded(x0, y0, x1, y1, r, n=12):
    """A rectangle with round corners of radius r."""
    pts = []
    for cx, cy, a0 in ((x1 - r, y0 + r, -90), (x1 - r, y1 - r, 0), (x0 + r, y1 - r, 90), (x0 + r, y0 + r, 180)):
        for a in np.radians(np.linspace(a0, a0 + 90, n)):
            pts.append((cx + r * np.cos(a), cy + r * np.sin(a)))
    return pts


def frame_wire(x0, y0, x1, y1, r, hw):
    """A closed wire round a rounded rectangle: its outer and inner outlines' masks are subtracted."""
    return rounded(x0 - hw, y0 - hw, x1 + hw, y1 + hw, r + hw), rounded(x0 + hw, y0 + hw, x1 - hw, y1 - hw, max(r - hw, 0.1))


def ring_mask(pen, outer, inner):
    return np.clip(pen.mask([outer]) - pen.mask([inner]), 0, 1)


def wire_metal(c, m, pal, hw=1.0, cast=0.45):
    """m as the vines' bark: their bevel, their cast shadow."""
    M.shadow(c, m, cast)
    c.metal(m, pal, bevel=0.5 * hw / 0.55 * U, outline=1.1, shadow=False, sheen=False, paint=True, gloss=0.35,
            grain=False)


def recess(c, m, floor, depth=1.6, lip=(120, 94, 64), lip_k=0.4):
    """A recess cut where m is: its floor, its top wall in shadow, a little
    light caught on its lower lip."""
    d = inside(c, m)
    y, _ = grid(c)
    paint(c, np.broadcast_to(np.array(floor, float), c.rgb.shape), m)
    ys = np.where(m > 0.5, y, np.nan)
    top, bot = np.nanmin(ys) if np.isfinite(ys).any() else 0, np.nanmax(ys) if np.isfinite(ys).any() else 1
    yn = np.clip((y - top) / max(bot - top, 1e-6), 0, 1)
    c.over(np.zeros_like(c.rgb), m * np.clip(1 - d / depth, 0, 1) ** 1.4 * (1 - 0.7 * yn) * 0.85)
    edge = np.clip(1 - np.abs(d - 0.6) / 0.6, 0, 1) * np.clip((yn - 0.6) / 0.4, 0, 1)
    c.over(np.broadcast_to(np.array(lip, float), c.rgb.shape), m * edge * lip_k)


# --- heartwood (the previous round's plaque, its window baked in) ---------------

WOOD_ROW = 40
WOOD = {False: (50, 35, 26), True: (112, 82, 56)}  # heartwood (the scroll thumb's), in shadow and lit
WIN_W, WIN_H, WIN_R = 54, 26, 10.0  # the state's window; its round ends' radius at its rim's middle
WIN_X = RW - 6 - WIN_W  # its left, in the row
RIM_HW = 0.9


def heartwood_row(lit):
    h = WOOD_ROW
    c = ucanvas(RW, h)
    y, x = grid(c)
    g = 0.6 * field(c, 2.2, 40, 11) + 0.4 * field(c, 6, 70, 12)
    yn, xn = y / h, x / RW
    k = 1 + 0.07 * g + 0.08 * np.sin(np.pi * np.clip(yn * 1.25, 0, 1)) - 0.05
    if lit:
        k = k + 0.22 * np.exp(-((xn - 0.25) / 0.45) ** 2) * np.sin(np.pi * np.clip(yn, 0, 1)) ** 0.7
    full = Pen(c, h).mask([rect(-2, 0, RW + 2, h)])
    paint(c, np.array(WOOD[lit], float) * k[..., None], full)
    shade_top(c, 10, 0.45)
    window(c, h, lit)
    return c.final()


def window(c, h, lit):
    """The window carved in the wood, rimmed in the vine's bark."""
    pen = Pen(c, h)
    cy, x0, x1 = h / 2, WIN_X + WIN_R + 1, WIN_X + WIN_W - WIN_R - 1
    floor = pen.mask([stadium(x0, x1, cy, WIN_R - RIM_HW + 0.2)])
    recess(c, floor, (40, 29, 21) if lit else (28, 20, 15), depth=2.4,
           lip=LIT_BARK[2] if lit else (120, 94, 64), lip_k=0.45)
    rim = ring_mask(pen, stadium(x0, x1, cy, WIN_R + RIM_HW), stadium(x0, x1, cy, WIN_R - RIM_HW))
    wire_metal(c, rim, LIT[""] if lit else BARK, RIM_HW)


def rule_tile(weight, pal):
    """A weight's vine as Core's Vine-<weight>Mid is made, in pal."""
    c = ucanvas(64, 16)
    vine(c, 16, [((-12, 8), (76, 8))], (), None, WEIGHTS[weight][0], pal)
    img = c.final()
    return np.repeat(img.mean(1, keepdims=True), img.shape[1], 1)


# --- brass: bronze nameplates ---------------------------------------------------

BRASS_ROW = 34
PATINA = ((18, 16, 12), (50, 44, 33), (104, 90, 64))  # dark bronze under its patina
POLISH = ((92, 64, 32), (186, 146, 90), (244, 214, 156))  # the same bronze polished
SOCKET_W = 46  # the chord's socket


def brass_row(lit):
    h = BRASS_ROW
    c = ucanvas(RW, h)
    pen = Pen(c, h)
    y, x = grid(c)
    plate = pen.mask([rect(2, 0.5, RW - 2, h - 0.5, cut=3.5)])
    d = inside(c, plate)
    # a raised rim, 3 wide, round a field sunk half a unit
    hgt = bevel(d, 1.6, 1.0) - 0.5 * np.clip((d - 3.2) / 0.9, 0, 1)
    diff, spec = light(c, hgt)
    if lit:  # polished: a broad sheen along it, brightest a third of the way down
        diff = diff * (1 + 0.18 * np.exp(-((y / h - 0.35) / 0.3) ** 2))
        col = ramp(POLISH, diff) + spec[..., None] ** 30 * 150
    else:  # patina: broad mottling, a little green in the dark
        mott = field(c, 5, 14, 21)
        col = ramp(PATINA, diff * (1 + 0.12 * mott)) * np.array((0.97, 1.0, 0.96)) + spec[..., None] ** 20 * 30
    M.shadow(c, plate, 0.5)
    o = ndimage.gaussian_filter(ndimage.maximum_filter(plate, size=int(1.0 * U * c.s) | 1), c.s * 0.4)
    c.over(np.broadcast_to(np.array((14, 10, 6), float), c.rgb.shape), o * 0.9)
    paint(c, col, plate)
    # the socket, stamped into the plate at its right
    sx1 = RW - 2 - 6
    sock = pen.mask([stadium(sx1 - SOCKET_W + 10, sx1 - 10, h / 2, 10)])
    recess(c, sock, (40, 28, 16) if lit else (14, 12, 9), depth=2.0,
           lip=(250, 226, 170) if lit else (120, 100, 70), lip_k=0.55)
    return c.final()


# --- spine: tooled leather between raised bands ---------------------------------

SPINE_ROW = 38
BAND_H = 10
LEATHER = {False: (62, 38, 28), True: (104, 66, 44)}
TOOL = 5.0  # the tooled frame's inset
DIVIDE = RW - TOOL - 46  # the chord's compartment's left line


def leather(c, base, k=1.0):
    g = 0.55 * field(c, 3.0, 3.0, 31) + 0.45 * field(c, 9, 16, 32)
    return np.array(base, float) * (1 + 0.10 * g)[..., None] * k


def spine_row(lit):
    h = SPINE_ROW
    c = ucanvas(RW, h)
    pen = Pen(c, h)
    y, x = grid(c)
    full = pen.mask([rect(-2, -2, RW + 2, h + 2)])
    lamp = 1 + (0.18 * np.exp(-((x / RW - 0.3) / 0.5) ** 2) if lit else 0)
    base = leather(c, LEATHER[lit])
    base = base * np.asarray(lamp)[..., None] if lit else base
    # the tooling: a frame round the name, a compartment for the chord
    hw = 0.75
    t0, t1 = TOOL, h - TOOL
    lines = [ribbon([(TOOL, t0), (RW - TOOL, t0)], hw), ribbon([(RW - TOOL, t0), (RW - TOOL, t1)], hw),
             ribbon([(RW - TOOL, t1), (TOOL, t1)], hw), ribbon([(TOOL, t1), (TOOL, t0)], hw),
             ribbon([(DIVIDE, t0), (DIVIDE, t1)], hw)]
    corners = [(px, py, hw) for px in (TOOL, RW - TOOL) for py in (t0, t1)]
    tool = pen.mask(lines + corners)
    # pressed in: a groove in the height field
    hgt = -0.8 * ndimage.gaussian_filter(tool, c.s * 1.2)
    diff, spec = light(c, hgt)
    col = base * (0.55 + 0.45 * diff)[..., None] + spec[..., None] ** 16 * 18
    paint(c, col, full)
    if lit:  # gilt laid in the impression
        g = ramp(GOLD, 0.6 + 0.7 * diff) + spec[..., None] ** 30 * 120
        paint(c, g, tool)
    else:  # blind: the impression darkened
        c.over(np.broadcast_to(np.array((16, 9, 6), float), c.rgb.shape), tool * 0.55)
    return c.final()


def spine_band():
    """A raised band across the spine, leather over a cord."""
    h = BAND_H
    c = ucanvas(RW, h)
    pen = Pen(c, h)
    y, x = grid(c)
    m = pen.mask([rect(-2, 1.5, RW + 2, h - 1.5)])
    r = np.clip(1 - ((y - h / 2) / (h / 2 - 1.5)) ** 2, 0, 1)
    hgt = np.sqrt(r) * 2.4
    diff, spec = light(c, hgt)
    base = leather(c, (52, 32, 24))
    M.shadow(c, m, 0.6)
    col = base * (0.3 + 0.7 * diff)[..., None] + spec[..., None] ** 18 * 40
    paint(c, col, m)
    return c.final()


# --- cloisonne: enamel in bronze wire, laid out as the pad ----------------------

CELL_H = 54
HALF_W = (RW + 2) // 2  # two cells side by side, their wires one over the other
CL_HW = 1.1
ENAMEL = {False: ((18, 24, 44), (30, 42, 72)), True: ((40, 70, 108), (84, 132, 170))}  # (edge, heart)
NAME_CY, BADGE = 15.0, (27.0, 50.0)  # the name's centre; the chord's cell's top and foot


def cloisonne_cell(w, lit):
    h = CELL_H
    c = ucanvas(w, h)
    pen = Pen(c, h)
    y, x = grid(c)
    b = 1.0  # the wire's centre from the cell's edge: neighbours overlap by 2 so theirs coincide
    cell = pen.mask([rounded(b, b, w - b, h - b, 3)])
    d = inside(c, cell)
    edge, heart = (np.array(v, float) for v in ENAMEL[lit])
    # glassy: deep at the wire, brighter toward its heart, a soft dome catching the light
    r = np.clip(d / 12, 0, 1)
    glass = edge + (heart - edge) * (r ** 0.8)[..., None]
    if lit:
        glow = np.exp(-(((x - w / 2) / (w * 0.45)) ** 2 + ((y - NAME_CY) / 22) ** 2))
        glass = glass + glow[..., None] * np.array((34, 38, 30))
    glass = glass * (1 + 0.06 * field(c, 6, 18, 41))[..., None]
    hgt = bevel(d, 5, 0.9)
    diff, spec = light(c, hgt)
    col = glass * (0.8 + 0.2 * diff)[..., None] + spec[..., None] ** 40 * (90 if lit else 60)
    paint(c, col, cell)
    # the chord's cell: black enamel in its own wire
    bw = 40 if w < RW else 52  # a half's: "talking" fits, and the right cell's pointer clears it
    bx0, bx1 = w / 2 - bw / 2, w / 2 + bw / 2
    badge = pen.mask([rounded(bx0, BADGE[0], bx1, BADGE[1], 3)])
    bd = inside(c, badge)
    bdiff, bspec = light(c, bevel(bd, 4, 0.7))
    paint(c, np.array((12, 12, 16), float) * (0.8 + 0.2 * bdiff)[..., None] + bspec[..., None] ** 40 * 50, badge)
    pal = LIT[""] if lit else BARK
    wires = ring_mask(pen, *frame_wire(b, b, w - b, h - b, 3, CL_HW))
    wires = np.maximum(wires, ring_mask(pen, *frame_wire(bx0, BADGE[0], bx1, BADGE[1], 3, 0.85)))
    wire_metal(c, wires, pal, CL_HW, cast=0.35)
    return c.final()


# --- lantern: iron rails and their panes ----------------------------------------

LANT_ROW = 36
RAIL = 3.0  # the rail along each row's top
PANE = (4.0, 7.0, 50.0, 33.0)  # the pane's frame, wide enough for Quick's two glyphs: x0, y0, x1, y1
IRON = (40, 40, 43)


def lantern_row(lit):
    h = LANT_ROW
    c = ucanvas(RW, h)
    pen = Pen(c, h)
    y, x = grid(c)
    full = pen.mask([rect(-2, 0, RW + 2, h + 2)])
    rail = pen.mask([rect(-2, 0, RW + 2, RAIL)])
    px0, py0, px1, py1 = PANE
    pane = pen.mask([rect(px0, py0, px1, py1, cut=1.5)])
    glass = pen.mask([rect(px0 + 2.2, py0 + 2.2, px1 - 2.2, py1 - 2.2)])
    hammer = 0.35 * field(c, 4, 4, 51) + 0.2 * field(c, 10, 30, 52)
    hgt = 0.6 * hammer + 1.2 * bevel(inside(c, rail), 1.2) * rail + 1.0 * bevel(inside(c, pane), 1.2) * pane
    hgt = hgt - 1.2 * glass
    diff, spec = light(c, hgt)
    iron = np.array(IRON, float) * (1 + 0.08 * field(c, 8, 20, 53))[..., None]
    col = iron * (0.5 + 0.5 * diff)[..., None] + spec[..., None] ** 24 * 45
    if lit:  # the pane's light washing along the rail and the iron
        cx, cy = (px0 + px1) / 2, (py0 + py1) / 2
        wash = np.exp(-np.clip(x - cx, 0, None) / 45) * np.exp(-((y - cy) / 16) ** 2) * (x > px0)
        col = col + wash[..., None] * np.array((150, 96, 44)) * (0.4 + 0.6 * diff)[..., None]
    paint(c, col, full)
    shade_top(c, 6, 0.25)
    # the glass
    g_in = inside(c, glass)
    gx, gy = (px0 + px1) / 2, (py0 + py1) / 2
    rr = np.hypot((x - gx) / ((px1 - px0) / 2), (y - gy) / ((py1 - py0) / 2))
    if lit:
        gl = np.array((246, 186, 96), float) + (np.array((176, 98, 40), float) - (246, 186, 96)) * np.clip(rr, 0, 1)[..., None] ** 1.5
    else:
        gl = np.array((36, 28, 20), float) + 10 * np.clip(1 - rr, 0, 1)[..., None]
        streak = np.exp(-(((x - gx) + (y - gy) * 1.2 + 4) / 2.2) ** 2) * 28  # a reflection across it
        gl = gl + streak[..., None]
    gl = gl * (1 - 0.35 * np.clip(1 - g_in / 1.8, 0, 1))[..., None]  # the frame's shadow on its edge
    paint(c, gl, glass)
    return c.final()


# --- stem: lacquer signs on scrolled brackets -----------------------------------

STEM_ROW = 32
STEM_HW = 2.6  # the stem: heavier than the thick vine, the list's spine
STEM_X = 9.0  # the stem's centre, from the row's left
SIGN = (21.0, 3.0, RW - 2.0, STEM_ROW - 3.0)  # the sign's x0, y0, x1, y1
SIGN_R = 6.0
LACQUER = {False: (20, 15, 14), True: (112, 38, 28)}


def bracket():
    """The arm from the stem to the sign and the scroll that holds it up from
    below, as a sign bracket is forged: the arm straight out at the sign's
    middle, the scroll leaving the stem under it and curling up into the arm."""
    cy = STEM_ROW / 2
    arm = ribbon([(STEM_X, cy - 4.5), (SIGN[0] + 2, cy - 4.5)], 1.4)
    sc = Wire((STEM_X, cy + 12), 0).volute((STEM_X + 6.5, cy + 0.5), 5.8, 90, -1, 1.0, eye=2.0, out=0.4, inn=0.5)
    return [arm] + sc.pieces(1.45, 1.1)


def stem_row(lit):
    h = STEM_ROW
    c = ucanvas(RW, h)
    pen = Pen(c, h)
    y, x = grid(c)
    x0, y0, x1, y1 = SIGN
    sign = pen.mask([rounded(x0, y0, x1, y1, SIGN_R)])
    d = inside(c, sign)
    hgt = bevel(d, 3.5, 0.8)
    diff, spec = light(c, hgt)
    base = np.array(LACQUER[lit], float)
    # lacquer: deep, a broad gloss along its top third, a soft one along its foot
    gloss = np.exp(-((y - (y0 + 0.28 * (y1 - y0))) / 2.6) ** 2) * np.clip((x - x0) / 10, 0, 1) * np.clip((x1 - x) / 10, 0, 1)
    col = base * (0.7 + 0.3 * diff)[..., None] + gloss[..., None] * (np.array((90, 60, 50)) if lit else np.array((46, 40, 38)))
    col = col + spec[..., None] ** 40 * 90
    M.shadow(c, sign, 0.5)
    paint(c, col, sign)
    pal = LIT[""] if lit else BARK
    rim = ring_mask(pen, *frame_wire(x0, y0, x1, y1, SIGN_R, 0.9))
    br = pen.mask(bracket())
    wire_metal(c, np.maximum(rim, br), pal, 1.0)
    # the stem, unlit always: the list's spine, which the open sign's light does not reach
    stem = pen.mask([ribbon([(STEM_X, -12), (STEM_X, h + 12)], STEM_HW)])
    wire_metal(c, stem, THICK[1], STEM_HW, cast=0.4)
    return c.final()


def stem_tile():
    """The stem alone, stretched down the gaps between signs."""
    c = ucanvas(24, 16)
    stem = Pen(c, 16).mask([ribbon([(STEM_X, -12), (STEM_X, 28)], STEM_HW)])
    wire_metal(c, stem, THICK[1], STEM_HW, cast=0.4)
    img = c.final()
    return np.repeat(img.mean(0, keepdims=True), img.shape[0], 0)


def render():
    art = {}
    for lit in (False, True):
        s = "-Lit" if lit else ""
        art["heartwood-Row" + s] = heartwood_row(lit)
        art["brass-Row" + s] = brass_row(lit)
        art["spine-Row" + s] = spine_row(lit)
        art["cloisonne-Wide" + s] = cloisonne_cell(RW, lit)
        art["cloisonne-Half" + s] = cloisonne_cell(HALF_W, lit)
        art["lantern-Row" + s] = lantern_row(lit)
        art["stem-Row" + s] = stem_row(lit)
    art["spine-Band"] = spine_band()
    art["stem-Stem"] = stem_tile()
    return art


# --- the layout, as ConvList.lua lays it out -----------------------------------

GROUPS = [["Main"], ["L1", "L2"], ["R1", "R2"], ["Quick"]]  # the pad's: talk alone, left, right, both triggers
PAD_BANDS = [["Main"], ["L1", "R1"], ["L2", "R2"], ["Quick"]]  # as the shoulders sit
OFFER = 36  # an offered button's cell
GAP_MIN = 10  # the least stone between two groups of a spread look
# each look: its row height, how its rows group, what lies between them, and
# where its chord and state show (units in the row; "slot": one place for both)
LOOKS = {
    "heartwood": dict(row=WOOD_ROW, grouped=True, spread=True, rules="vine", name_x=10,
                      chord=("right", 6 + WIN_W / 2), slot=True),
    "brass": dict(row=BRASS_ROW, pad=1, name_x=12, chord=("right", 8 + SOCKET_W / 2), slot=True, ink=True),
    "spine": dict(row=SPINE_ROW, rules="band", pad=BAND_H / 2, name_x=13, chord=("right", TOOL + 23), slot=True),
    "cloisonne": dict(row=CELL_H, grid=True, seam=-2, pad=1, centred=True, slot=True),
    "lantern": dict(row=LANT_ROW, name_x=PANE[2] + 7, chord=("left", (PANE[0] + PANE[2]) / 2),
                    state_x=8, chord_y=(PANE[1] + PANE[3]) / 2 - LANT_ROW / 2 + 0, name_y=RAIL / 2),
    "stem": dict(row=STEM_ROW, grouped=True, spread=True, seam=4, stem=True, name_x=SIGN[0] + 9,
                 chord=("right", 2 + 22), slot=True),
}
ORDER = ["heartwood", "brass", "spine", "cloisonne", "lantern", "stem"]


def bands_of(L):
    if L.get("grid"):
        return [PAD_BANDS]
    groups = [[[k] for k in g] for g in GROUPS]
    return groups if L.get("grouped") else [[b for g in groups for b in g]]


def layout(name, H, offered=False):
    """ConvList.lua's place(): each row's (key, x, y, w, h), the rules' ys,
    the head and foot crests' rule ys (None: too short for them), the offer's
    cell and the last row's foot, in units from the well's top left."""
    L = LOOKS[name]
    groups = bands_of(L)
    row, seam, pad = L["row"], L.get("seam", 0), L.get("pad", 0)
    nb, ng = sum(len(g) for g in groups), len(groups)
    off = OFFER if offered else 0
    top, gap = HEAD_RULE + pad, 0
    if L.get("spread"):
        bottom = H - (FOOT_H - FOOT_RULE) - pad - off
        gap = (bottom - top - nb * row - (nb - ng) * seam) / max(ng - 1, 1)
        ornate = gap >= GAP_MIN
    else:
        ornate = top + nb * row + (nb - 1) * seam + off + pad + FOOT_H - FOOT_RULE <= H
    if not ornate:
        top = 6 + pad
        fin = H - 6 - pad - off
        least = GAP_MIN if L.get("spread") else 0
        row = min(row, (fin - top - (ng - 1) * least - (nb - ng) * seam) / nb)
        if L.get("spread"):
            gap = (fin - top - nb * row - (nb - ng) * seam) / max(ng - 1, 1)
    rows, rules, y = [], [], top
    for gi, g in enumerate(groups):
        if gi:
            y += gap
        for bi, band in enumerate(g):
            if bi:
                y += seam
            if not rules or rules[-1] != y:
                rules.append(y)
            w = RW if len(band) == 1 else HALF_W
            for j, key in enumerate(band):
                rows.append((key, j * (RW - w), y, w, row))
            y += row
            rules.append(y)
    foot = H - (FOOT_H - FOOT_RULE) if L.get("spread") and ornate else y + off + pad
    return dict(rows=rows, rules=rules, head=HEAD_RULE if ornate else None, foot=foot if ornate else None,
                offer=(y + 6, y + off - 6) if offered else None, last=y)


# --- the mock: each look's well over the 4K shot ------------------------------

SHOTS = os.path.join(os.environ.get("LOCALAPPDATA", ""), "wow-companion", "shots")
SHOT = os.path.join(SHOTS, "convlist4-full.png")  # 3840 x 2160, the window open on Chat (2026-11-12)
STONE_SHOT = os.path.join(SHOTS, "convlist2.png")  # the well's bare slate, before it held anything
CROP = (1640, 240, 2100, 1600)  # the list's part of the shot
WELL = (1695.0, 297.0, 1542.0, 2045.0)  # the well's left edge, top, foot and right edge in the shot, px
PX = (WELL[3] - WELL[0]) / W  # the shot's px a unit: 2.69 (measured)
PBOX = (1676, 452, 1712, 494)  # the pointer in the shot, by Main
WALL_BAND = (800, 900)  # rows of the shot whose walls no vine crosses
FLOOR = 3
STATES = {"L1": ("new", (127, 208, 127)), "R1": ("5s", (176, 176, 176)), "R2": ("475s", (176, 176, 176))}
# each conversation's chord: stand-ins for the pad's glyphs (the game draws its own)
CHORDS = {"Main": ["-"], "L1": ["L1"], "L2": ["L2"], "R1": ["R1"], "R2": ["R2"], "Quick": ["L2", "R2"]}
GLYPH = 20  # units: Style.lua's GLYPH_SIZE
IDLE_GLYPH = 0.6  # a resting row's glyphs, sunk
OPEN, POINTER = "L2", "R1"
NAME, NAME_HL, NAME_LIT, INK = (199, 176, 135), (232, 214, 171), (250, 235, 199), (44, 30, 16)
NAME_SIZE, STATE_SIZE = 16, 12  # units: GameFontNormalLarge, GameFontNormal
FONT = r"C:\Windows\Fonts\pala.ttf"  # Friz Quadrata's stand-in
CREST_DIR = OUT


def small(img, k, size=None):
    """An RGBA piece at U texels a unit, at k px a unit (or stretched to size px), premultiplied."""
    h, w = img.shape[:2]
    im = Image.fromarray(img.astype(np.uint8), "RGBA")
    pre = Image.fromarray((img[..., :3] * img[..., 3:4] / 255).astype(np.uint8), "RGB")
    size = size or (max(1, round(w * k / U)), max(1, round(h * k / U)))
    a = np.asarray(im.getchannel("A").resize(size, Image.LANCZOS), float)
    rgb = np.asarray(pre.resize(size, Image.LANCZOS), float)
    return rgb, np.clip(a / 255, 0, 1)


def over(dst, rgb, a, x, y, clip=None):
    x, y = int(round(x)), int(round(y))
    h, w = a.shape
    x0, x1 = (0, dst.shape[1]) if clip is None else clip
    sx0, sx1 = max(x, x0) - x, min(x + w, x1) - x
    sy0 = max(0, -y)
    if sx1 <= sx0:
        return
    sl = dst[y + sy0:y + h, x + sx0:x + sx1]
    sl[:] = rgb[sy0:sy0 + sl.shape[0], sx0:sx1] + sl * (1 - a[sy0:sy0 + sl.shape[0], sx0:sx1, None])


def stone_like(sample, h, w):
    reps = (h // sample.shape[0] + 2, w // sample.shape[1] + 2)
    col = np.concatenate([sample if i % 2 == 0 else sample[::-1] for i in range(reps[0])], 0)
    return np.concatenate([col if j % 2 == 0 else col[:, ::-1] for j in range(reps[1])], 1)[:h, :w].copy()


def text(dst, s, size, colour, x, cy, k, align="left", alpha=1.0):
    font = ImageFont.truetype(FONT, int(round(size * k * 1.02)))
    _, t, _, b = font.getbbox("H")
    w = font.getbbox(s)[2]
    im = Image.new("L", (int(w + 8), int((b + 8) * 1.4)), 0)
    ImageDraw.Draw(im).text((4, 4), s, font=font, fill=255)
    a = np.asarray(im, float) / 255 * alpha
    x0 = {"left": x - 4, "right": x - w - 4, "centre": x - w / 2 - 4}[align]
    over(dst, a[..., None] * np.array(colour, float), a, x0, cy - (t + b) / 2 - 4)


def glyph(dst, key, cx, cy, k, alpha):
    """A stand-in for the pad's glyph: as the game's, a dark key in a bronze
    outline, its letters light."""
    w, h = (GLYPH * 0.95, GLYPH * 0.7) if len(key) > 1 else (GLYPH * 0.7, GLYPH * 0.5)
    s = 4
    W_, H_ = int(w * k * s), int(h * k * s)
    rr = int(h * k * s * 0.3)
    outer = Image.new("L", (W_, H_), 0)
    ImageDraw.Draw(outer).rounded_rectangle([0, 0, W_ - 1, H_ - 1], radius=rr, fill=255)
    inner = Image.new("L", (W_, H_), 0)
    e = int(1.4 * k * s)
    ImageDraw.Draw(inner).rounded_rectangle([e, e, W_ - 1 - e, H_ - 1 - e], radius=max(rr - e, 1), fill=255)
    ao = np.asarray(outer.resize((int(w * k), int(h * k)), Image.LANCZOS), float) / 255 * alpha
    ai = np.asarray(inner.resize((int(w * k), int(h * k)), Image.LANCZOS), float) / 255
    col = np.array((170, 140, 98), float) * (1 - ai[..., None]) + np.array((30, 24, 20), float) * ai[..., None]
    over(dst, col * ao[..., None], ao, cx - w * k / 2, cy - h * k / 2)
    if key != "-":
        text(dst, key, GLYPH * 0.4, (236, 228, 214), cx, cy, k, "centre", alpha)
    else:
        text(dst, "-", GLYPH * 0.5, (236, 228, 214), cx, cy - 1, k, "centre", alpha)


def mock(name, art, offered=False):
    L = LOOKS[name]
    shot = np.asarray(Image.open(SHOT).convert("RGB"), float)
    sample = np.asarray(Image.open(STONE_SHOT).convert("RGB"), float)[600:1260, 72:388]
    p = shot[PBOX[1]:PBOX[3], PBOX[0]:PBOX[2]].copy()
    pa = np.clip((p.max(-1) - 40) / 40, 0, 1) * (np.arange(p.shape[1])[None, :] < WELL[0] - PBOX[0] + 4)
    ys_, xs_ = np.nonzero(pa > 0.5)
    tip = (xs_.max(), int(np.median(ys_[xs_ >= xs_.max() - 2])))
    shot[PBOX[1]:PBOX[3], PBOX[0]:int(WELL[0])] = shot[PBOX[1] + 60:PBOX[3] + 60, PBOX[0]:int(WELL[0])]
    img = shot.copy()
    left, top, foot, _ = WELL
    H = (foot - top) / PX
    X = lambda u: left + u * PX  # noqa: E731
    Y = lambda u: top + u * PX  # noqa: E731
    walls = (int(round(X(INSET))), int(round(X(W - INSET))))
    fl = (int(X(FLOOR)), int(Y(FLOOR)), int(X(W - FLOOR)), int(Y(H - FLOOR)))
    img[fl[1]:fl[3], fl[0]:fl[2]] = stone_like(sample, fl[3] - fl[1], fl[2] - fl[0])
    for x0, x1 in ((int(left), walls[0]), (walls[1], int(left + W * PX) + 1)):
        band = shot[WALL_BAND[0]:WALL_BAND[1], x0:x1]
        img[int(top) + 40:int(foot) - 40, x0:x1] = np.tile(band, (30, 1, 1))[:int(foot) - 40 - int(top) - 40]
    for y0, y1 in ((int(top), int(round(Y(INSET)))), (int(round(Y(H - INSET))), int(foot) + 1)):
        img[y0:y1, walls[0]:walls[1]] = shot[y0:y1, walls[0]:walls[1]]
    lay = layout(name, H, offered)
    crest = {n: np.asarray(Image.open(os.path.join(CREST_DIR, "Crest-%s.tga" % n)).convert("RGBA"), float)
             for n in ("Head", "Head-Lit", "Foot", "Foot-Lit")}
    mids = {kind: np.asarray(Image.open(os.path.join(M.CORE_OUT, "Vine-%sMid-%d.tga" % (kind, M.VINE_VERSION)))
                             .convert("RGBA"), float) for kind in ("", "Thick")}
    lit_rows = [r for r in lay["rows"] if r[0] == OPEN]
    lit_y = [lit_rows[0][2], lit_rows[0][2] + lit_rows[0][4]] if lit_rows else []

    def put(piece, x, y, w=None, h=None):
        if w is None:
            rgb, a = small(piece, PX)
        else:
            rgb, a = small(piece, PX, (int(round(X(x + w))) - int(round(X(x))), int(round(Y(y + h))) - int(round(Y(y)))))
        over(img, rgb, a, X(x), Y(y), walls)

    if L.get("stem") and lay["head"] is not None:
        put(art["stem-Stem"], INSET, lay["head"], 24, lay["foot"] - lay["head"])
    elif L.get("stem"):
        put(art["stem-Stem"], INSET, 4, 24, H - 8)
    ordered = sorted(lay["rows"], key=lambda r: r[0] == OPEN)  # the open one over its neighbours' wire
    for key, x, y, w, h in ordered:
        lit = key == OPEN
        piece = {"cloisonne": "cloisonne-%s" % ("Wide" if w == RW else "Half")}.get(name, name + "-Row")
        put(art[piece + ("-Lit" if lit else "")], INSET + x, y, w, h)
    if L.get("rules") == "band":
        for y in lay["rules"]:
            put(art["spine-Band"], INSET, y - BAND_H / 2, RW, BAND_H)
    if L.get("rules") == "vine":
        for y in lay["rules"]:
            ends = any(e is not None and abs(y - e) < 0.01 for e in (lay["head"], lay["foot"]))
            if ends:
                continue  # the crest's rule
            lit = any(abs(y - e) < 0.01 for e in lit_y)
            weight = "Thick" if ends else ""
            tile = art.get("Rule%s-Lit" % weight) if lit else mids[weight]
            if tile is None:
                tile = rule_tile(weight, LIT[weight])
            rgb, a = small(np.repeat(tile[:, :1], W * U, 1), PX)
            over(img, rgb, a, X(0), Y(y - 8), walls)
    if lay["head"] is not None:
        first_lit = L.get("rules") == "vine" and lay["rows"][0][0] == OPEN
        put(crest["Head-Lit" if first_lit else "Head"], 0, lay["head"] - HEAD_RULE)
        last_lit = L.get("rules") == "vine" and lay["rows"][-1][0] == OPEN and not offered
        put(crest["Foot-Lit" if last_lit else "Foot"], 0, lay["foot"] - FOOT_RULE)
    ptr = None
    for key, x, y, w, h in lay["rows"]:
        lit = key == OPEN
        cy = y + h / 2
        colour = (INK if L.get("ink") else NAME_LIT) if lit else NAME_HL if key == POINTER else NAME
        state = STATES.get(key)
        keys = CHORDS[key]
        if L.get("centred"):
            text(img, key, NAME_SIZE, colour, X(INSET + x + w / 2), Y(y + NAME_CY), PX, "centre")
            gx, gy = w / 2, y + (BADGE[0] + BADGE[1]) / 2
        else:
            ny = cy + L.get("name_y", 0)
            text(img, key, NAME_SIZE, colour, X(INSET + x + L["name_x"]), Y(ny), PX)
            side, off = L["chord"]
            gx = off if side == "left" else w - off
            gy = cy + L.get("chord_y", 0)
        if state and L.get("slot"):
            text(img, state[0], STATE_SIZE, state[1], X(INSET + x + gx), Y(gy), PX, "centre")
        else:
            for j, k_ in enumerate(keys):
                cx = gx + (j - (len(keys) - 1) / 2) * (GLYPH + 1)
                glyph(img, k_, X(INSET + x + cx), Y(gy), PX, 1.0 if lit else IDLE_GLYPH)
            if state:
                text(img, state[0], STATE_SIZE, state[1], X(INSET + x + w - L["state_x"]), Y(cy + RAIL / 2), PX, "right")
        if key == POINTER:
            ptr = (X(INSET + x), Y(cy))
    if lay["offer"]:
        y0, y1 = lay["offer"]
        img[int(Y(y0)):int(Y(y1)), int(X(INSET + 6)):int(X(W - INSET - 6))] = (70, 52, 30)
        text(img, "Offered", 12, NAME_LIT, X(W / 2), Y((y0 + y1) / 2), PX, "centre")
    over(img, p * pa[..., None], pa, ptr[0] - tip[0], ptr[1] - tip[1])
    out = np.clip(img, 0, 255)[CROP[1]:CROP[3], CROP[0]:CROP[2]]
    return Image.fromarray(out.astype(np.uint8))


def write_mocks(art):
    os.makedirs(TMP, exist_ok=True)
    shot = Image.open(SHOT).convert("RGB").crop(CROP)
    tiles = [("now", shot)]
    for name in ORDER:
        im = mock(name, art)
        im.save(os.path.join(TMP, name + ".png"))
        tiles.append((name, im))
    mock("brass", art, offered=True).save(os.path.join(TMP, "brass-offer.png"))
    mock("heartwood", art, offered=True).save(os.path.join(TMP, "heartwood-offer.png"))
    tw, th = shot.width, shot.height
    allim = Image.new("RGB", (len(tiles) * (tw + 16), th + 70), (24, 24, 24))
    d = ImageDraw.Draw(allim)
    font = ImageFont.truetype(FONT, 44)
    for i, (n, im) in enumerate(tiles):
        allim.paste(im, (i * (tw + 16), 70))
        d.text((i * (tw + 16) + 12, 10), n, font=font, fill=(230, 214, 180))
    allim.save(os.path.join(TMP, "all.png"))
    allim.resize((allim.width // 3, allim.height // 3), Image.LANCZOS).save(os.path.join(TMP, "all-small.png"))


def main():
    art = render()
    art["Rule-Lit"] = rule_tile("", LIT[""])
    art["RuleThick-Lit"] = rule_tile("Thick", LIT["Thick"])
    if "--mock" in sys.argv:
        write_mocks(art)
        return
    artout.clear(OUT, "Conv-*.tga")
    for stem, rgba in art.items():
        if stem.startswith("Rule"):
            continue  # the lit vines are ConvVine-*, kept with the crests
        write_tga(os.path.join(OUT, "Conv-%s-%d.tga" % (stem, VERSION)), rgba)
    print(len(art) - 2, "textures")


if __name__ == "__main__":
    main()
