"""The Companion window's tabs (Window.lua's makeTab), drawn here as vector
shapes at 4x and averaged down, never Blizzard's art.

    python tools/make_tab_art.py   writes addon/WowCompanion_Agent/Art/Tab-<Part>[-Active]-<v>.tga
                                   and target/tab-sheet-<v>.png (the comparison sheet: the
                                   row as the screenshot has it, ours beside it, then zoomed)

PanelTopTabButtonTemplate has three pieces per state, Left and Right caps and a
Middle stretched between them; the open tab's (Active) is taller and gold,
the others' dark with a bronze rim, and the highlight is the unselected art
added at 0.4, as Blizzard's is. Every piece is drawn 36 UI units tall, its foot
on the tab's bottom edge; the caps 36 wide (their two widths are the tab's
least width, PanelTemplates_TabResize, so the row keeps its 72-unit tabs), the
middle a 4.5-unit slice. 256 px for 36 units: 7.1 px a unit, 2.5x a 4K screen's 2.8.

Every measure is the game's own row read off target/tabs-ref.png (a 4K
screenshot halved: 1.406 px a unit): where each rim stands in its cap, its
height, the corner's radius, the colours and the open tab's gradient.
The game keeps a texture for the session under its path, so a change bumps
VERSION (and Window.lua's TAB_ART); older files are deleted.
"""
import glob
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from make_scrollbar_art import write_tga, LIGHT

VERSION = 1
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "addon", "WowCompanion_Agent", "Art")
P = 256 / 36  # texture px per UI unit
SS = 4  # supersampling
H = 36  # every piece's height in units, its foot at y = H
CAP = 36  # a cap's width in units
MID = 4.5  # the middle slice's width in units (32 px)
RADIUS = 3.5  # the rim's outer corner

# (rim's outer left in the Left cap, its outer right short of the Right cap's
# far edge, its top) in units: the caps hang -3/+7 off the button (Active
# -1/+8), and the rim stands 2.7/1.6 inside it (Active 4.4/1.8)
GEOM = {False: (5.7, 8.6, H - 19.45), True: (5.4, 9.8, H - 23.6)}

# the open tab's fill down from under its rim to its foot, as measured
ACTIVE_STOPS = [(0.0, (146, 113, 17)), (0.25, (127, 92, 20)), (0.43, (111, 75, 21)),
                (0.61, (89, 59, 22)), (0.79, (65, 45, 24)), (1.0, (38, 33, 27))]
GOLD_RIM = np.array((236, 201, 46), float)
GOLD_LIT = np.array((253, 218, 52), float)
GOLD_INNER = np.array((168, 124, 16), float)
GOLD_HALO = np.array((70, 58, 16), float)
BRONZE_RIM = np.array((80, 64, 43), float)
BRONZE_LIT = np.array((124, 97, 64), float)
EDGE = np.array((16, 14, 12), float)
SLATE = np.array((35, 33, 28), float)


def gradient(t):
    t = np.clip(t, 0, 1)
    ts = [s[0] for s in ACTIVE_STOPS]
    return np.stack([np.interp(t, ts, [s[1][k] for s in ACTIVE_STOPS]) for k in range(3)], -1)


def tab(active, width):
    """The whole tab `width` units wide (both caps and what lies between) as
    RGBA at P px a unit: the caps and the middle are cut from it, so they meet
    without a seam."""
    left, right, top = GEOM[active]
    w, h = int(round(width * P)) * SS, int(round(H * P)) * SS
    k = P * SS
    yy, xx = (np.mgrid[0:h, 0:w] + 0.5) / k  # units
    # the rim's outline: a rounded box from (left, top) to (width - right, below the foot)
    x0, x1, y0, y1 = left, width - right, top, H + 20
    cx = np.clip(xx, x0 + RADIUS, x1 - RADIUS)
    cy = np.clip(yy, y0 + RADIUS, y1 - RADIUS)
    dx, dy = xx - cx, yy - cy
    dist = np.hypot(dx, dy)
    d = dist - RADIUS  # signed: outside > 0
    d = np.where(dist > 0, d, -np.minimum.reduce([xx - x0, x1 - xx, yy - y0]))
    inside = -d
    # the light falling on the rim from the top left, by the outline's normal
    gy, gx = np.gradient(d)
    n = np.hypot(gx, gy) + 1e-9
    lit = np.clip(-(gx * LIGHT[0] + gy * LIGHT[1]) / n / np.hypot(LIGHT[0], LIGHT[1]), 0, 1)  # 1 facing the light
    corner = np.clip(1 - np.hypot(xx - (x0 + RADIUS * 0.7), yy - (y0 + RADIUS * 0.7)) / (RADIUS * 1.1), 0, 1) ** 1.5

    rgb = np.zeros((h, w, 3))
    a = np.zeros((h, w))

    def lay(col, alpha):
        alpha = np.clip(alpha, 0, 1)[..., None]
        nonlocal rgb, a
        out = alpha[..., 0] + a * (1 - alpha[..., 0])
        rgb = np.where(out[..., None] > 0, (col * alpha + rgb * a[..., None] * (1 - alpha)) / np.maximum(out, 1e-6)[..., None], 0)
        a = out

    if active:
        # a soft dark-gold halo, the bright rim, a deeper gold inside it, then
        # the bronze-to-dark gradient down to the foot
        lay(GOLD_HALO, (1 - np.clip(d / 2.0, 0, 1)) * 0.9 * (d > 0))
        t = (yy - (top + 1.5)) / (H - 1.7 - (top + 1.5))
        fill = gradient(t)
        fill = fill + (GOLD_INNER - fill) * np.exp(-np.clip(inside - 1.15, 0, None) / 0.75)[..., None] * 0.8
        rim = GOLD_RIM + (GOLD_LIT - GOLD_RIM) * np.maximum(lit * 0.5, corner)[..., None]
        body = np.where((inside < 1.15)[..., None], rim, fill)
        lay(body, (inside >= 0).astype(float))
    else:
        # a dark line outside, the bronze rim lit at its top left corner, and
        # the slate shaded in from the rim
        lay(EDGE, (d < 0.75) * 0.9)
        rim = BRONZE_RIM * (0.92 + 0.1 * lit[..., None]) + (BRONZE_LIT - BRONZE_RIM) * corner[..., None]
        u = np.clip(inside - 1.4, 0, None)
        fill = SLATE - (SLATE - np.array((18, 16, 13.0))) * np.exp(-u / 1.25)[..., None]
        body = np.where((inside < 1.4)[..., None], rim, fill)
        lay(body, (inside >= 0).astype(float))
    pre = (rgb * a[..., None]).reshape(h // SS, SS, w // SS, SS, 3).mean((1, 3))
    al = a.reshape(h // SS, SS, w // SS, SS).mean((1, 3))
    out = np.zeros((h // SS, w // SS, 4))
    out[..., :3] = np.where(al[..., None] > 0, pre / np.maximum(al[..., None], 1e-6), 0)
    out[..., 3] = al * 255
    return np.clip(out, 0, 255)


def render():
    """Every texture as {file stem: rgba array}."""
    out = {}
    cap = int(round(CAP * P))
    mid = int(round(MID * P))
    for active in (False, True):
        img = tab(active, 2 * CAP + 2 * MID)
        name = "Tab-%s" + ("-Active" if active else "")
        out[name % "Left"] = img[:, :cap]
        out[name % "Right"] = img[:, -cap:]
        c = img.shape[1] // 2
        out[name % "Middle"] = img[:, c - mid // 2:c - mid // 2 + mid]
    return out


# --- the comparison sheet ---------------------------------------------------
#
# The game's row as target/tabs-ref.png has it (4x nearest of a halved 4K
# shot: 1.406 px a unit), and ours composed the same way: each tab 72 units,
# the first's left 2.9 px in, their feet at 43.4 px, the labels where
# PanelTemplates_SelectTab and _DeselectTab centre them.

REF = os.path.join(ROOT, "target", "tabs-ref.png")
LABELS = ["Chat", "Settings", "Status", "Scroll bars", "Errands"]
W_TAB = 72
LIFT = 10  # rows of stone added above the shot


def compose(art, ref, upp, hl=None):
    """Our row over the ref's backdrop at `upp` px a unit (the ref's scale
    times an integer), the tab `hl` drawn highlighted."""
    z = upp / 1.40625
    zi = int(round(z))
    base = Image.fromarray(ref).resize((ref.shape[1] * zi, ref.shape[0] * zi), Image.NEAREST)
    bg = np.asarray(base, float).copy()
    foot = (43.4 + LIFT) * zi
    # the stone behind the tabs: the ref's darkest band above them, repeated
    top = int((42 + LIFT) * zi)
    bg[:top] = np.asarray(Image.fromarray(ref[LIFT + 2:LIFT + 6]).resize((bg.shape[1], top), Image.BILINEAR), float)
    canvas = Image.fromarray(bg.astype(np.uint8)).convert("RGBA")

    def piece(stem, x_units, w_units):
        img = Image.fromarray(art[stem].astype(np.uint8), "RGBA")
        x0, x1 = int(round(x_units * upp)), int(round((x_units + w_units) * upp))  # edges snapped as the game snaps them
        h = int(round(H * upp))
        return img.resize((max(1, x1 - x0), h), Image.LANCZOS), x0, int(round(foot - h))

    font = ImageFont.truetype("arialbd.ttf", max(8, int(round(9.6 * upp))))
    draw_list = []
    for i, label in enumerate(LABELS):
        bx = 2.9 / 1.40625 + W_TAB * i
        act = i == 0
        lo, ro = (-1, 8) if act else (-3, 7)
        sfx = "-Active" if act else ""
        parts = [("Tab-Left" + sfx, bx + lo, CAP), ("Tab-Right" + sfx, bx + W_TAB + ro - CAP, CAP),
                 ("Tab-Middle" + sfx, bx + lo + CAP, W_TAB + ro - lo - 2 * CAP)]
        for stem, x, w in parts:
            im, px, py = piece(stem, x, w)
            canvas.alpha_composite(im, (px, py))
            if hl == i and not act:  # ADD at 0.4, as the template's highlight
                arr = np.asarray(canvas, float)
                add = np.asarray(im, float)
                y1, x1 = py + add.shape[0], px + add.shape[1]
                arr[py:y1, px:x1, :3] += add[..., :3] * add[..., 3:] / 255 * 0.4
                canvas = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGBA")
        cy = foot - (12 if act else 8) * upp
        draw_list.append((bx + W_TAB / 2, cy, label, (255, 255, 255) if act else (255, 209, 0)))
    d = ImageDraw.Draw(canvas)
    for x, cy, label, col in draw_list:
        d.text((x * upp, cy), label, font=font, fill=col, anchor="mm")
    return canvas.convert("RGB")


def sheet(art):
    ref = np.asarray(Image.open(REF).convert("RGB"))[::4, ::4]
    ref = np.vstack([np.repeat(ref[2:3], LIFT, 0), ref])  # room above for the 36-unit pieces
    one = compose(art, ref, 1.40625)
    hi = compose(art, ref, 1.40625 * 2)  # a 4K screen's own pixels
    hl = compose(art, ref, 1.40625 * 2, hl=2)
    up = lambda im, k: im.resize((im.width * k, im.height * k), Image.NEAREST)
    rows = [("the game (halved shot), ours at the same scale", [Image.fromarray(ref), one]),
            ("zoomed 4x: the game, ours", [up(Image.fromarray(ref), 4), up(one, 4)]),
            ("ours at 4K's own pixels, zoomed 2x; Status highlighted", [up(hi, 2), up(hl, 2)])]
    pieces = [Image.fromarray(art[s].astype(np.uint8), "RGBA") for s in sorted(art)]
    W = max(sum(im.width for im in ims) + 12 * len(ims) for _, ims in rows)
    Ht = sum(max(im.height for im in ims) + 28 for _, ims in rows) + max(p.height for p in pieces) + 40
    out = Image.new("RGB", (W + 24, Ht), (52, 50, 46))
    d = ImageDraw.Draw(out)
    y = 8
    for title, ims in rows:
        d.text((12, y), title, fill=(220, 220, 220))
        y += 16
        x = 12
        for im in ims:
            out.paste(im, (x, y))
            x += im.width + 12
        y += max(im.height for im in ims) + 12
    d.text((12, y), "the textures: " + ", ".join(sorted(art)), fill=(220, 220, 220))
    y += 16
    x = 12
    for p in pieces:
        out.paste(p, (x, y), p)
        x += p.width + 8
    path = os.path.join(ROOT, "target", "tab-sheet-%d.png" % VERSION)
    out.save(path)
    return path


def main():
    art = render()
    os.makedirs(OUT, exist_ok=True)
    for old in glob.glob(os.path.join(OUT, "Tab-*.tga")):
        os.remove(old)
    for stem, img in art.items():
        write_tga(os.path.join(OUT, "%s-%d.tga" % (stem, VERSION)), img)
    print(len(art), "textures;", sheet(art))


if __name__ == "__main__":
    main()
