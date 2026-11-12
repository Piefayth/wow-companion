"""The Companion window's controller focus, in the window's own look, in place
of Blizzard's yellow: the glow round the focused window and the pointer left of
the chosen row. Drawn here as vector shapes, many samples to a pixel and
averaged down, never Blizzard's art.

    python tools/make_focus_art.py   writes addon/WowCompanion_Agent/Art/Focus-Glow[-<style>]-<v>.tga,
                                     Focus-Tab[-<style>]-<v>.tga, Focus-Pointer-<v>.tga,
                                     target/tmp/focus-mock-*.png (the glow and pointer
                                     pasted into the shot at true size, beside Blizzard's)
                                     and target/glow-styles-tabs.png (the window's top at
                                     4K in every style, make_frame_art.py's mock)

Both are drawn TX texels to a screen pixel at the window's scale in the shot
(1.33 px a unit: its rim, RIM units, is 8 px there).

The glow is a 9-slice: GLOW_SIZE square, every margin GLOW_MARGIN texels, its
edges the same all along, its centre empty. The rim's outer edge lies
GLOW_INSET texels in from the texture's edge, its corners cut by the rim's
chamfer; nothing is drawn inside it, so it may sit over the frame or under it.

The chosen tab's glow, Focus-Tab, is the same glow round the rim's top and
the chosen plaque (make_tab_art.py) as one outline: up the plaque's side,
over its head and back down to the rim. TAB_GLOW units, set TAB_GLOW_LEFT left
of the plaque's piece and TAB_GLOW_UP above it, at the 9-slice's texels a
unit; its foot is the top edge piece's, so FocusArt.lua cuts the rim's top
edge in two either side of it and the line runs on through.

STYLES are the glow's looks, the player's to pick (FocusArt.lua): each is
drawn on a Field, the distance out from the outline and the corners its
brackets stand off, so every style draws both pieces. "" is the first: a
bright line hugs the outline and a warm bronze halo fades out from it.

The pointer points right, its tip at POINTER_TIP (texels): a faceted bronze
blade lit from the top left, a dark outline and a soft shadow so it reads on the
dark window and on bright ground alike.

The game keeps a texture for the session under its path, so a change bumps
VERSION; older files are deleted.
"""
import glob
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage
from make_scrollbar_art import write_tga, LIGHT, HALF
from make_frame_art import RIM, CHAMFER, LINE, octagon_depth
import make_frame_art as frame_art
import make_tab_art as tabs

VERSION = 1
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "addon", "WowCompanion_Agent", "Art")
TMP = os.path.join(ROOT, "target", "tmp")
K = 16  # samples a screen pixel
TX = 2  # texels a screen pixel
PX_UNIT = 8 / RIM  # screen px a unit in the shot

# --- the glow ---------------------------------------------------------------------

GLOW_SIZE = 128
GLOW_MARGIN = 48
GLOW_INSET = 32  # texels from the texture's edge to the rim's outer edge
GLOW_REACH = 13.0  # screen px the halo fades out over
CREAM = np.array((244, 222, 178.0))  # the line: bronze in full light, never yellow
HALO = np.array((224, 180, 120.0))  # the halo: washed bronze, warm
EMBER = np.array((180, 128, 72.0))  # its far edge, deeper


def smooth(t):
    t = np.clip(t, 0, 1)
    return t * t * (3 - 2 * t)


class Field:
    """Where a glow is drawn, supersampled K a screen px: dm, the distance out
    from the outline (px, negative inside); u, v, how far into the box of the
    nearest bracketed corner (px, negative outside); cut, that corner's cut
    as u + v meets it on the diagonal."""

    def __init__(self, dm, u, v, cut):
        self.dm, self.u, self.v, self.cut = dm, u, v, cut


def nine_field():
    """The 9-slice's: round the rim, its four corners cut by the chamfer."""
    n = GLOW_SIZE / TX  # screen px
    yy, xx = np.mgrid[0:int(n * K), 0:int(n * K)]
    xx, yy = (xx + 0.5) / K, (yy + 0.5) / K
    e = GLOW_INSET / TX
    c = CHAMFER * PX_UNIT
    dm = -octagon_depth(xx, yy, e, e, n - e, n - e, c)  # mitered: the offsets keep the rim's 45-degree corners
    return Field(dm, np.minimum(xx, n - xx) - e, np.minimum(yy, n - yy) - e, c)


TAB_GLOW = (96, 48)  # units: 256 x 128 texels
TAB_GLOW_LEFT, TAB_GLOW_UP = 8, 12  # from the plaque piece's top left
UNIT_TX = GLOW_MARGIN / 18  # the 9-slice's texels a unit (FocusArt.lua's M is 18 units)


def tab_field():
    """Focus-Tab's: round the rim's top and the chosen plaque as one outline,
    the plaque's two head corners bracketed."""
    w, h = TAB_GLOW
    k = PX_UNIT * K  # samples a unit
    yy, xx = np.mgrid[0:round(h * k), 0:round(w * k)]
    # in the plaque piece's units
    xx, yy = (xx + 0.5) / k - TAB_GLOW_LEFT, (yy + 0.5) / k - TAB_GLOW_UP
    m = Image.new("L", (xx.shape[1], xx.shape[0]), 0)
    head = tabs.HEADS["Chosen"]
    ImageDraw.Draw(m).polygon([((x + TAB_GLOW_LEFT) * k, (y + TAB_GLOW_UP) * k)
                               for x, y in tabs.outline(head)], fill=255)
    plaque = ndimage.distance_transform_edt(np.asarray(m) < 128) / k <= tabs.EDGE
    inside = plaque | (yy >= tabs.PLAQUE_UP)
    dm = (ndimage.distance_transform_edt(~inside) - ndimage.distance_transform_edt(inside)) / K
    # the plaque's box, its outer edge EDGE out; its round corners, as a cut
    x0, x1, y0 = tabs.X0 - tabs.EDGE, tabs.X1 + tabs.EDGE, head - tabs.EDGE
    r = (tabs.R + tabs.EDGE) * PX_UNIT
    return Field(dm, np.minimum(xx - x0, x1 - xx) * PX_UNIT, (yy - y0) * PX_UNIT, 2 * r * (1 - 1 / np.sqrt(2)))


def halo(f):
    """The first glow: a bright line on the outline, a warm bronze halo
    fading out from it."""
    d = ndimage.distance_transform_edt(~(f.dm <= 0)) / K  # px out
    line = np.exp(-((np.maximum(d - 0.5, 0)) / 1.1) ** 2)  # about 1.5 px, its peak just off the edge
    fade = (1 - smooth((d - 1.5) / (GLOW_REACH - 1.5))) ** 1.3
    a = np.clip(line + fade * 0.92, 0, 1)
    tcol = np.clip(d / GLOW_REACH, 0, 1)[..., None]
    halo_c = HALO + (EMBER - HALO) * tcol
    w = (line / np.maximum(a, 1e-6))[..., None]
    rgb = halo_c + (CREAM - halo_c) * np.clip(w, 0, 1)
    return rgb, np.where(f.dm <= 0, 0, a)


GILT = (np.array((74, 54, 34.0)), np.array((156, 124, 86.0)), np.array((230, 204, 160.0)))  # washed bronze, a step above the rim's
SLATE_NAVY = np.array((30, 36, 52.0))
EDGE_LIGHT = np.array((246, 230, 196.0))
COOL = np.array((150, 172, 206.0))


def between(dm, a, b):
    return ((dm >= a) & (dm < b)).astype(float)


def bevel(dm, a, b, slope=1.0, cap=1.2):
    """A raised band from a to b px out: its height, sloped at each side."""
    return ndimage.gaussian_filter(np.clip(np.minimum(dm - a, b - dm) * slope, 0, cap), K * 0.15)


def facing(dm):
    """How much each point's outward side faces the light, 0 to 1."""
    gy, gx = np.gradient(dm)
    g = np.hypot(gx, gy) + 1e-9
    return np.clip((gx * -LIGHT[0] + gy * -LIGHT[1]) / g / np.hypot(LIGHT[0], LIGHT[1]) * 0.5 + 0.5, 0, 1)


def style_inlay(f):
    """A second raised bronze band outside the outline, a dark gap between."""
    dm = f.dm
    rgb, a = np.zeros(dm.shape + (3,)), np.zeros(dm.shape)
    rgb, a = over(rgb, a, LINE, between(dm, 0, 1.3) * 0.9 + between(dm, 4.8, 5.8) * 0.85)
    rgb, a = over(rgb, a, np.zeros(3), between(dm, 5.8, 7.3) * 0.3)
    return over(rgb, a, lit(bevel(dm, 1.3, 4.8), GILT, gloss=0.5), between(dm, 1.3, 4.8))


def style_lit_edge(f):
    """No halo: a crisp warm line on the outline, strongest facing the light,
    and a faint cool bloom past it."""
    dm = f.dm
    rgb, a = np.zeros(dm.shape + (3,)), np.zeros(dm.shape)
    t = np.clip((dm - 1.2) / 2.8, 0, 1)
    rgb, a = over(rgb, a, COOL, (dm >= 1.2) * (1 - t) ** 2 * 0.6)
    return over(rgb, a, EDGE_LIGHT, between(dm, 0, 1.2) * (0.7 + 0.3 * facing(dm)))


BRACKET = (5.0, 4.0, 3.0)  # px: the bracket's midline out from its box, its width, its own small chamfer
BRACKET_REACH = 7.0  # px into the box the arms end (in the 9-slice, inside the corner pieces)


def style_brackets(f):
    """Raised bronze L brackets standing off the corners only (the window's
    four, the chosen plaque's two), a lozenge in the hollow between each and
    the corner's cut; the edges clear."""
    off, w, cut = BRACKET
    db = np.abs(np.minimum.reduce([f.u + off, f.v + off, (f.u + f.v + 2 * off - cut) / np.sqrt(2)]))  # from its midline
    reach = np.maximum(f.u, f.v) + db  # the arms' ends cut to a point
    arms = (db < w / 2) * (reach < BRACKET_REACH)
    edge = (db < w / 2 + 0.9) * (reach < BRACKET_REACH + 1.0)
    # the lozenge: midway between the bracket's inner corner and the box's cut
    inner = 2 * (w / 2 - off) + cut - (2 - np.sqrt(2)) * w / 2
    mid = (inner + f.cut) / 4
    l1 = np.abs(f.u - mid) + np.abs(f.v - mid)
    stud, stud_edge = (l1 < 3.0).astype(float), (l1 < 4.0).astype(float)
    rgb, a = np.zeros(f.dm.shape + (3,)), np.zeros(f.dm.shape)
    rgb, a = over(rgb, a, LINE, np.maximum(edge, stud_edge) * 0.9)
    hgt = np.maximum(ndimage.gaussian_filter(np.clip(w / 2 - db, 0, 1.2), K * 0.15) * arms,
                     ndimage.gaussian_filter(np.clip(3.0 - l1, 0, 3.0) * 0.7, K * 0.15) * stud)
    return over(rgb, a, lit(hgt, GILT, gloss=0.6), np.maximum(arms, stud))


def tight(core_c, near, far, core_w=0.8, sigma=3.0, end=4.5, body=0.95):
    """A short dense warm glow, a brighter core on the outline: core_c the
    core's colour, near and far the glow's colour at the edge and where it
    ends, core_w the core's width, sigma and end its reach in px, body the
    glow's strength under the core."""
    def style(f):
        d = np.maximum(f.dm, 0)
        core = np.exp(-(np.maximum(d - 0.6, 0) / core_w) ** 2)
        glow = np.exp(-(d / sigma) ** 2) * (1 - smooth((d - end) / 2.0))
        al = np.clip(core + glow * body, 0, 1)
        n, fa = np.array(near, float), np.array(far, float)
        warm = n + (fa - n) * np.clip(d / (end + 1.5), 0, 1)[..., None]
        w = np.clip(core / np.maximum(al, 1e-6), 0, 1)[..., None]
        return warm + (np.array(core_c, float) - warm) * w, al
    return style


# D, the player's near miss (2026-11-12: "a little too white, a little too
# bright, already pretty subtle"), and its round of variants: each less white
# without growing dimmer
style_tight = tight((240, 224, 192), (206, 174, 132), (168, 136, 98))
TIGHT_ROUND = {
    "D1": ("D, bronze core", tight((228, 200, 152), (206, 172, 124), (168, 132, 90))),
    "D2": ("D, amber", tight((236, 196, 128), (210, 164, 100), (166, 118, 66))),
    "D3": ("D, no white line", tight((214, 178, 124), (210, 172, 118), (170, 130, 84), core_w=0.6, body=1.0)),
    "D4": ("D, amber, wider", tight((236, 196, 128), (210, 164, 100), (166, 118, 66), sigma=3.6, end=5.5)),
    "D5": ("D, deep bronze", tight((216, 172, 112), (190, 146, 92), (150, 104, 60), core_w=0.9, body=1.0)),
    "D6": ("D3 at D4's width", tight((214, 178, 124), (210, 172, 118), (170, 130, 84), core_w=0.6, body=1.0, sigma=3.6, end=5.5)),
    "D7": ("D3, wider still", tight((214, 178, 124), (210, 172, 118), (170, 130, 84), core_w=0.6, body=1.0, sigma=4.2, end=6.5)),
}


def style_mat(f):
    """A navy slate mat round the outline between two fine bronze fillets, as
    a picture is mounted."""
    dm = f.dm
    rgb, a = np.zeros(dm.shape + (3,)), np.zeros(dm.shape)
    rgb, a = over(rgb, a, LINE, between(dm, 0, 7.6) * 0.95)
    shade = (0.85 + 0.3 * facing(dm))[..., None]  # the mat sits a little low: lit on its far side
    rgb, a = over(rgb, a, SLATE_NAVY * (2 - shade), between(dm, 2.0, 5.2))
    fil = between(dm, 0.6, 2.0) + between(dm, 5.2, 6.8)
    hgt = bevel(dm, 0.6, 2.0, cap=0.7) + bevel(dm, 5.2, 6.8, cap=0.8)
    return over(rgb, a, lit(hgt, GILT, gloss=0.5), fil)


STYLES = {"": ("first", halo), "A": ("inlay", style_inlay), "B": ("lit edge", style_lit_edge),
          "C": ("brackets", style_brackets), "D": ("tight glow", style_tight), "E": ("navy mat", style_mat),
          **TIGHT_ROUND}


def draw(style, f, size, per=None):
    """A style on a field, nothing inside the outline, down to size texels
    (per samples a texel)."""
    rgb, a = STYLES[style][1](f)
    return down(rgb, np.where(f.dm >= 0, a, 0), size, per)


def down(rgb, a, size, f=None):
    """Supersampled colour and alpha averaged down to size texels (a side, or
    w, h), f samples a texel."""
    w, h = (size, size) if np.isscalar(size) else size
    f = f or rgb.shape[0] // h
    pre = (rgb * a[..., None]).reshape(h, f, w, f, 3).mean((1, 3))
    al = a.reshape(h, f, w, f).mean((1, 3))
    out = np.zeros((h, w, 4))
    out[..., :3] = np.where(al[..., None] > 0, pre / np.maximum(al[..., None], 1e-6), 0)
    out[..., 3] = al * 255
    return np.clip(out, 0, 255)


# --- the pointer ------------------------------------------------------------------

POINTER_SIZE = 64
# in screen px of its 32 px box: the tip, the blade's blunt back corners, its notch
TIP = (29.0, 16.0)
BLADE = [TIP, (11.0, 2.2), (7.0, 4.2), (15.0, 16.0), (7.0, 27.8), (11.0, 29.8)]
POINTER_TIP = (TIP[0] * TX, TIP[1] * TX)
METAL = (np.array((96, 68, 40.0)), np.array((172, 134, 88.0)), np.array((242, 212, 160.0)))


def poly_mask(n, polys=(), circles=()):
    m = Image.new("L", (n * K, n * K), 0)
    dr = ImageDraw.Draw(m)
    for p in polys:
        dr.polygon([(x * K, y * K) for x, y in p], fill=255)
    for cx, cy, r in circles:
        dr.ellipse([(cx - r) * K, (cy - r) * K, (cx + r) * K, (cy + r) * K], fill=255)
    return np.asarray(m, float) / 255


def lit(hgt, pal, gloss=0.4, power=16):
    gy, gx = np.gradient(hgt, 1 / K)
    nrm = np.stack([-gx, -gy, np.ones_like(gx)], -1)
    nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True)
    diff = np.clip(nrm @ LIGHT, 0, 1)[..., None]
    flat = LIGHT[2]
    sh, mid, li = pal
    col = np.where(diff < flat, sh + (mid - sh) * (diff / flat), mid + (li - mid) * ((diff - flat) / (1 - flat)))
    spec = np.clip(nrm @ HALF, 0, 1) ** power * gloss
    return np.clip(col + spec[..., None] * 255, 0, 255)


def over(rgb, a, col, al):
    al = np.clip(al, 0, 1)
    out = al + a * (1 - al)
    rgb = np.where(out[..., None] > 0, (col * al[..., None] + rgb * (a * (1 - al))[..., None]) / np.maximum(out, 1e-6)[..., None], 0)
    return rgb, out


def pointer():
    n = POINTER_SIZE // TX
    blade = poly_mask(n, [BLADE])
    shape = blade
    rgb, a = np.zeros(blade.shape + (3,)), np.zeros(blade.shape)
    # the shadow, down and right, then the outline a pixel round
    sh = ndimage.shift(ndimage.gaussian_filter(shape, K * 0.9), (K * 1.2, K * 0.8), order=1)
    rgb, a = over(rgb, a, np.zeros(3), sh * 0.6)
    ring = ndimage.gaussian_filter(ndimage.maximum_filter(shape, size=int(2.2 * K) | 1), K * 0.25)
    rgb, a = over(rgb, a, LINE, ring * 0.95)
    # the blade a hipped roof: its facets meet along the middle of each arm
    db = ndimage.distance_transform_edt(blade > 0.5) / K
    hgt = ndimage.gaussian_filter(np.minimum(db * 0.6, 1.5), K * 0.12)
    rgb, a = over(rgb, a, lit(hgt, METAL), blade)
    # the tip's one warm glint
    yy, xx = np.mgrid[0:blade.shape[0], 0:blade.shape[1]]
    g = np.clip(1 - np.hypot(xx / K - (TIP[0] - 4.5), yy / K - (TIP[1] - 1.5)) / 3.5, 0, 1) ** 2 * blade
    rgb, a = over(rgb, a, np.array((255, 226, 170.0)), g * 0.5)
    return down(rgb, a, POINTER_SIZE)


# --- the mock: both pasted into the shot at its own pixels ----------------------

SHOT = os.path.join(os.environ.get("LOCALAPPDATA", ""), "wow-companion", "shots", "now.png")
RIM_BOX = (14, 104, 1040, 806)  # the rim's outer edge in the shot, right and bottom exclusive
POINTER_AT = (862, 314)  # where Blizzard's pointer's tip is, by R1


def clean(shot):
    """The shot with Blizzard's glow and pointer taken away: the band round the
    rim filled from the open ground to the right, the pointer from the gap below."""
    a = np.asarray(shot).copy()
    x0, y0, x1, y1 = RIM_BOX
    H, W = a.shape[:2]
    yy, xx = np.mgrid[0:H, 0:W]
    band = ((xx < x0) | (xx >= x1) | (yy < y0) | (yy >= y1)) & (xx > x0 - 17) & (xx < x1 + 17) & (yy > y0 - 17) & (yy < y1 + 17)
    src = a[yy, 1100 + (xx % 540)]
    a[band] = src[band]
    a[290:340, 838:858] = a[370, 838:858]  # the gap runs the same all down
    a[290:340, 858:866] = a[290:340, 866:874]
    return a


def paste(base, rgba, x, y):
    im = Image.fromarray(base)
    im.paste(Image.fromarray(rgba.astype(np.uint8), "RGBA"), (x, y), Image.fromarray(rgba[..., 3].astype(np.uint8)))
    return np.asarray(im)


def nine_on(base, tex):
    """The glow set out round RIM_BOX as the game draws a 9-slice, TX texels a px."""
    half = np.asarray(Image.fromarray(tex.astype(np.uint8), "RGBA").resize((GLOW_SIZE // TX,) * 2, Image.BOX)).astype(float)
    m, e = GLOW_MARGIN // TX, GLOW_INSET // TX
    x0, y0, x1, y1 = RIM_BOX[0] - e, RIM_BOX[1] - e, RIM_BOX[2] + e, RIM_BOX[3] + e
    w, h = x1 - x0, y1 - y0
    s = GLOW_SIZE // TX
    full = np.zeros((h, w, 4))
    full[:m, :m] = half[:m, :m]
    full[:m, w - m:] = half[:m, s - m:]
    full[h - m:, :m] = half[s - m:, :m]
    full[h - m:, w - m:] = half[s - m:, s - m:]
    full[:m, m:w - m] = half[:m, s // 2:s // 2 + 1]
    full[h - m:, m:w - m] = half[s - m:, s // 2:s // 2 + 1]
    full[m:h - m, :m] = half[s // 2:s // 2 + 1, :m]
    full[m:h - m, w - m:] = half[s // 2:s // 2 + 1, s - m:]
    # off the screen's left edge: cut
    cx = max(0, -x0)
    return paste(base, full[:, cx:], x0 + cx, y0)


def pointer_on(base, tex, dx=0):
    small = np.asarray(Image.fromarray(tex.astype(np.uint8), "RGBA").resize((POINTER_SIZE // TX,) * 2, Image.BOX)).astype(float)
    return paste(base, small, POINTER_AT[0] - int(TIP[0]) + dx, POINTER_AT[1] - int(TIP[1]))


def label(im, text):
    out = Image.new("RGB", (im.width, im.height + 16), (52, 50, 46))
    out.paste(im, (0, 16))
    ImageDraw.Draw(out).text((4, 2), text, fill=(230, 230, 230))
    return out


def side(ims, path, gap=12):
    W = sum(i.width for i in ims) + gap * (len(ims) + 1)
    H = max(i.height for i in ims) + 2 * gap
    out = Image.new("RGB", (W, H), (52, 50, 46))
    x = gap
    for i in ims:
        out.paste(i, (x, gap))
        x += i.width + gap
    out.save(path)
    return path


def mocks(glow_tex, ptr_tex):
    shot = np.asarray(Image.open(SHOT).convert("RGB"))
    base = clean(shot)
    ours = pointer_on(nine_on(base, glow_tex), ptr_tex)
    bob = pointer_on(nine_on(base, glow_tex), ptr_tex, -4)
    old, new = Image.fromarray(shot), Image.fromarray(ours)
    up = lambda im, z: im.resize((im.width * z, im.height * z), Image.NEAREST)
    os.makedirs(TMP, exist_ok=True)
    new.save(os.path.join(TMP, "focus-mock-full.png"))
    paths = []
    for name, box in (("corner-tl", (0, 70, 200, 230)), ("corner-br", (900, 700, 1100, 860)),
                      ("pointer", (790, 270, 990, 360))):
        a, b = old.crop(box), new.crop(box)
        paths.append(side([label(a, "Blizzard 1x"), label(b, "ours 1x")], os.path.join(TMP, "focus-mock-%s-1x.png" % name)))
        paths.append(side([label(up(a, 2), "Blizzard 2x"), label(up(b, 2), "ours 2x")], os.path.join(TMP, "focus-mock-%s-2x.png" % name)))
    box = (790, 270, 990, 360)
    # and on the bright ground, where a window of another make may put it
    ground = Image.fromarray(paste(shot.copy(), np.asarray(Image.fromarray(ptr_tex.astype(np.uint8), "RGBA").resize(
        (POINTER_SIZE // TX,) * 2, Image.BOX)).astype(float), 1300, 500)).crop((1260, 470, 1360, 560))
    paths.append(side([label(Image.fromarray(bob).crop(box), "ours, bobbed -4"), label(ground, "on ground"),
                       label(up(ground, 2), "on ground 2x")], os.path.join(TMP, "focus-mock-pointer-bob.png")))
    # the whole window, halved, for the overall read
    paths.append(side([label(old.crop((0, 60, 1100, 860)), "Blizzard"), label(new.crop((0, 60, 1100, 860)), "ours")],
                      os.path.join(TMP, "focus-mock-window.png")))
    return paths


def styles_sheet():
    """The window's top at 4K (make_frame_art.py's mock, Settings chosen) in
    every style, each beside a 2x zoom of the chosen plaque."""
    stem = lambda path: os.path.basename(path).rsplit("-", 1)[0]
    art = {stem(p): frame_art.load(p) for pat in ("Frame-*", "Inset-*", "Close-*")
           for p in glob.glob(os.path.join(OUT, "%s-%d.tga" % (pat, frame_art.VERSION)))}
    back = frame_art.backdrop()
    font = ImageFont.truetype("arial.ttf", 30)
    x = int(frame_art.ORIGIN[0] + (frame_art.TABS_X + frame_art.STEP) * frame_art.PX)
    rows = []
    for key, (name, _) in STYLES.items():
        im = frame_art.mock(art, back, chosen=1, style=key and "-" + key)
        top = im.crop((0, 40, 1300, 400))
        ImageDraw.Draw(top).text((12, 8), "%s: %s" % (key or '""', name), font=font, fill=(255, 255, 255))
        zoom = im.crop((x - 60, 60, x + 280, 280))
        rows.append([top, zoom.resize((zoom.width * 2, zoom.height * 2), Image.NEAREST)])
    return frame_art.stack(rows, os.path.join(ROOT, "target", "glow-styles-tabs.png"))


def main():
    nine, tab = nine_field(), tab_field()
    art = {"Focus-Pointer": pointer()}
    for key in STYLES:
        name = key and "-" + key
        art["Focus-Glow" + name] = draw(key, nine, GLOW_SIZE)
        art["Focus-Tab" + name] = draw(key, tab, (round(TAB_GLOW[0] * UNIT_TX), round(TAB_GLOW[1] * UNIT_TX)),
                                       round(PX_UNIT * K / UNIT_TX))
    os.makedirs(OUT, exist_ok=True)
    for old in glob.glob(os.path.join(OUT, "Focus-*.tga")):
        os.remove(old)
    for stem, img in art.items():
        write_tga(os.path.join(OUT, "%s-%d.tga" % (stem, VERSION)), img)
    for p in mocks(art["Focus-Glow"], art["Focus-Pointer"]) + [styles_sheet()]:
        print(p)


if __name__ == "__main__":
    main()
