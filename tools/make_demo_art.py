"""A design sheet's art, for now: slot floors and button faces to choose from,
each drawn whole in tools/make_control_art.py's stadium and bark border. Goes
when one is chosen.

    python tools/make_demo_art.py   writes addon/WowCompanion/Art/Demo-R<ROUND>-*.tga

The game keeps a texture for the session under its path, so each round of
candidates bumps ROUND (and ControlTrials.lua's ART).

A button reads as raised and unpressed by its value against the wall (a
material the slate is not, lighter or glossier), its light falling from the
top lip to a dark lower body, a lit bevel top left, a shaded one bottom right,
and its shadow cast down on the stone. Pressed: the face sunk a unit, lit
from below, darker, no shadow cast. A floor reads as a recess by being
darker than the wall, the stone still in it (never a flat fill), the top wall's
shadow falling over its upper part and the light caught on its bottom lip.
"""
import glob
import os
import sys

import numpy as np
from scipy import ndimage

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_control_art as ctl  # noqa: E402
import make_scrollbar_art as sb  # noqa: E402
import make_tab_art as tab  # noqa: E402
from make_frame_art import BRONZE as RIM_BRONZE  # noqa: E402

U = sb.U
ROUND = 2


def grid(c):
    """Every canvas pixel's position in units."""
    yy = (np.arange(c.H)[:, None] / c.s - c.pad) / U
    xx = (np.arange(c.W)[None, :] / c.s - c.pad) / U
    return yy + 0 * xx, xx + 0 * yy


def ramp(t, stops):
    """A colour down the face: stops are (t, rgb), t from 0 (top) to 1."""
    t = np.clip(t, 0, 1)
    ts = [s[0] for s in stops]
    return np.stack([np.interp(t, ts, [s[1][i] for s in stops]) for i in range(3)], -1)


def broad(c, scale, seed, stretch=1.0):
    """Soft variation a few units across, never finer (fine noise reads as
    dirt at true size): unit variance, stretched sideways by `stretch`."""
    rng = np.random.default_rng(seed)
    small = (c.H // (c.s * U) + 2, c.W // (c.s * U) + 2)
    g = ndimage.gaussian_filter(rng.standard_normal(small), (scale, scale * stretch), mode="wrap")
    g /= g.std()
    return ndimage.zoom(g, c.s * U, order=3)[:c.H, :c.W]


def normals(c, m, bevel, pillow=0.0, top=2.2, bottom=25.8):
    """The face's normal from its bevel (`bevel` units round the edge) and a
    swell across it (`pillow` units high in the middle)."""
    k = U * c.s
    d = ndimage.distance_transform_edt(m > 0.5) / k
    t = np.clip(d / bevel, 0, 1)
    hgt = (1 - (1 - t) ** 2) * bevel
    yy, _ = grid(c)
    v = np.clip((yy - top) / (bottom - top) * 2 - 1, -1, 1)
    hgt = hgt + pillow * (1 - v ** 2) * t
    hgt = ndimage.gaussian_filter(hgt, k * 0.2)
    gy, gx = np.gradient(hgt * k)
    n = np.stack([-gx, -gy, np.ones_like(gx)], -1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    return n, d


def cast(c, m, k, dy=0.9, blur=0.7):
    """The button's shadow on the stone, down and a little right."""
    s = U * c.s
    sh = ndimage.shift(ndimage.gaussian_filter(m, s * blur), (s * dy, s * dy * 0.4), order=1)
    c.over(np.zeros_like(c.rgb), np.clip(sh, 0, 1) * k)


def lit_face(c, m, body, hi, lo, bevel=2.2, pillow=0.0, gloss=0.0, power=24, pressed=False, top=2.2, bottom=25.8):
    """The face where m is: `body` the material's colour per pixel, lit from
    the top left by its bevel (toward `hi` on the lit side, `lo` on the turned
    one); `gloss` a specular on the bevel and swell only, never a wash over
    the flat face. Pressed: lit from below, as a face sunk in its border is."""
    n, d = normals(c, m, bevel, pillow, top, bottom)
    if pressed:
        n = n * np.array([-1, -1, 1])
    lam = n @ sb.LIGHT / sb.LIGHT[2]  # 1 on the flat face
    up = np.clip(lam - 1, 0, None)[..., None]
    down = np.clip(1 - lam, 0, 1)[..., None]
    col = body + (np.array(hi, float) - body) * np.clip(up * 2.2, 0, 1)
    col = col + (np.array(lo, float) - col) * np.clip(down * 1.6, 0, 1)
    if gloss:
        flat = (np.array([0, 0, 1.0]) @ sb.HALF) ** power
        spec = np.clip(np.clip(n @ sb.HALF, 0, 1) ** power - flat, 0, None) / (1 - flat)
        col = col + spec[..., None] * np.array(hi, float) * gloss
    c.over(np.clip(col, 0, 255), m)
    return d


def rim(c, pen, w, h, pal=sb.BARK):
    r = h / 2 - 2.2
    hw = sb.BORDER_HW
    border = ctl.ring(pen, ctl.stadium(2.2 + r, w - 2.2 - r, h / 2, r + hw), ctl.stadium(2.2 + r, w - 2.2 - r, h / 2, r - hw))
    sb.shadow(c, border, 0.4)
    c.metal(border, pal, bevel=0.6 * U, outline=1.1, shadow=False, sheen=False, paint=True, grain=False, gloss=0.35)


def inner(pen, w, h):
    r = h / 2 - 2.2
    return pen.mask([ctl.stadium(2.2 + r, w - 2.2 - r, h / 2, r)])


# --- buttons, 128 x 28

BW, BH = 128, 28


def bronze_body(c, yn, pressed):
    """Cast bronze, darkened with age: warm and fairly rich in its middle (the
    rims' washed bronze is its worn edge), mottled broadly as old metal is."""
    body = ramp(yn, [(0, (142, 106, 62)), (0.35, (104, 74, 42)), (1, (46, 31, 17))])
    body = body * (1 + 0.035 * broad(c, 4, 3, 3.0))[..., None]
    return body * (0.72 if pressed else 1)


def wood_body(c, yn, pressed):
    """Polished heartwood: a deep red-brown, its grain long and lying along
    the button, the varnish lighter toward the top."""
    g = broad(c, 0.7, 11, 14.0) * 0.7 + broad(c, 2.0, 12, 6.0) * 0.3
    body = ramp(yn, [(0, (104, 64, 43)), (0.4, (74, 42, 28)), (1, (34, 18, 11))])
    body = body * (1 + 0.07 * g)[..., None]
    return body * (0.72 if pressed else 1)


def lacquer_body(c, yn, pressed):
    """Black lacquer over the slate's own cool: near black, lifting a little
    toward the top as a polished surface takes the room's light."""
    body = ramp(yn, [(0, (58, 60, 70)), (0.45, (22, 23, 29)), (1, (9, 9, 12))])
    return body * (0.8 if pressed else 1)


def brass_body(c, yn, pressed):
    """Old brass, the light metal: bright at the top, falling to a dark warm
    foot, so dark words stand on it as on a plaque."""
    body = ramp(yn, [(0, (196, 160, 104)), (0.4, (150, 118, 72)), (1, (70, 50, 28))])
    body = body * (1 + 0.04 * broad(c, 2.5, 5, 2.0))[..., None]
    return body * (0.72 if pressed else 1)


BUTTONS = {
    # name: body, lit bevel, turned bevel, gloss, swell, rim
    "Bronze": (bronze_body, (222, 184, 124), (24, 15, 8), 0.5, 0.0, sb.BARK),
    "Wood": (wood_body, (196, 136, 92), (18, 9, 5), 0.6, 0.0, sb.BARK),
    "Lacquer": (lacquer_body, (150, 156, 172), (4, 4, 6), 0.9, 0.0, RIM_BRONZE),
    "Brass": (brass_body, (248, 222, 168), (40, 26, 12), 0.5, 0.0, sb.BARK),
}


def button(kind, pressed=False):
    body_fn, hi, lo, gloss, pillow, pal = BUTTONS[kind]
    c = sb.ucanvas(BW, BH)
    pen = sb.Pen(c, BH)
    m = inner(pen, BW, BH)
    if not pressed:
        cast(c, m, 0.8)
    yy, _ = grid(c)
    drop = 1.0 if pressed else 0.0
    yn = (yy - 2.2 - drop) / (BH - 4.4)
    lit_face(c, m, body_fn(c, yn, pressed), hi, lo, gloss=gloss, pillow=pillow, pressed=pressed)
    if kind == "Lacquer" and not pressed:
        # the window's light lying on the lacquer: a soft pale sheet over its
        # upper part, fading well before the middle
        sheet = ndimage.gaussian_filter(pen.mask([ctl.stadium(14, BW - 14, 8.2, 3.6)]), U * c.s * 1.6)
        c.over(np.broadcast_to(np.array((170, 176, 190), float), c.rgb.shape), sheet * m * 0.16)
    if pressed:
        # the border's own shadow falling on the sunk face's top
        k = U * c.s
        d = ndimage.distance_transform_edt(m > 0.5) / k
        top = np.clip(1 - (yy - 2.2) / 6, 0, 1)
        c.over(np.zeros_like(c.rgb), m * np.clip(1 - d / 2.5, 0, 1) * (0.35 + 0.4 * top))
    rim(c, pen, BW, BH, pal)
    return c.final()


# --- floors, 240 x 32

FW, FH = 240, 32
FLOORS = {
    # name: the floor's middle, its lit lip, the bronze light in its foot
    "Slate": ((19, 20, 23), (120, 116, 112), False),
    "Ink": ((9, 12, 21), (160, 132, 90), False),
    "Lamplit": ((17, 17, 19), (176, 142, 96), True),
}


def floor(kind):
    c = sb.ucanvas(FW, FH)
    pen = sb.Pen(c, FH)
    m = inner(pen, FW, FH)
    k = U * c.s
    yy, _ = grid(c)
    yn = np.clip((yy - 2.2) / (FH - 4.4), 0, 1)
    d = ndimage.distance_transform_edt(m > 0.5) / k
    tab.stone(c, m, False)
    # the stone kept, its marbling drawn up so the floor is stone, not a fill
    mean = np.array((16.3, 17.3, 19.3))
    vein = (c.rgb - mean) * 1.4
    base, lip_rgb, warm = FLOORS[kind]
    # in shade under the top wall, the floor coming up toward the light below
    fall = ramp(yn, [(0, (0.3,) * 3), (0.45, (0.8,) * 3), (1, (1.15,) * 3)])
    rgb = (np.array(base, float) + vein) * fall
    if warm:  # the rim's bronze light thrown down into the lower floor, smooth over the stone
        foot = (np.clip((yn - 0.3) / 0.7, 0, 1) ** 1.5)[..., None]
        rgb = rgb * (1 - 0.5 * foot) + np.array((34, 22, 11.0)) * foot
    c.rgb = np.where(m[..., None] > 0, np.clip(rgb, 0, 255), c.rgb)
    edge = np.clip(1 - d / 2.4, 0, 1) ** 1.5 * (1 - 0.5 * yn)
    c.over(np.zeros_like(c.rgb), m * edge * 0.6)
    # the light caught on the bottom lip, where the floor turns up to meet the border
    lip = np.clip(1 - np.abs(d - 0.7) / 0.7, 0, 1) * np.clip((yn - 0.6) / 0.4, 0, 1) ** 1.3
    c.over(np.broadcast_to(np.array(lip_rgb, float), c.rgb.shape), m * lip * 0.8)
    rim(c, pen, FW, FH)
    return c.final()




def main():
    out = {}
    for kind in FLOORS:
        out["Floor-" + kind] = floor(kind)
    for kind in BUTTONS:
        out["Button-" + kind] = button(kind)
        out["Button-%s-Pushed" % kind] = button(kind, True)
    for old in glob.glob(os.path.join(ctl.OUT, "Demo-*.tga")):
        os.remove(old)
    for stem, rgba in out.items():
        sb.write_tga(os.path.join(ctl.OUT, "Demo-R%d-%s.tga" % (ROUND, stem)), np.clip(rgba, 0, 255))
    print(len(out), "textures")


if __name__ == "__main__":
    main()
