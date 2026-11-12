"""The Companion window's corner grip (Window.lua): three diagonal grooves cut
into the panel's rock, bevelled and lit from the top left, drawn as a height
field at 32x and averaged down to 64x64 (shown at 16x16).

    python tools/make_resize_grip_art.py      writes addon/WowCompanion_Agent/Art/ResizeGrip.tga,
                                              ResizeGrip-Highlight.tga (the lit walls only, added on hover)
                                              and target/tmp/grip-preview.png (1x, 2x, 4x over rock)

The texture is black (the floor and the shaded wall) and a warm pale grey (the
lit wall), both partly transparent so the rock shows through.
"""
import os
import struct
import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "addon", "WowCompanion_Agent", "Art")
PREVIEW = os.path.join(ROOT, "target", "tmp", "grip-preview.png")

UI = 16          # the grip's size in UI pixels
TEX = 64         # the texture's size
S = 32           # drawn at S times per UI pixel
CENTRES = (6.0, 10.0, 14.0)  # each groove's line: right + bottom distance, in UI pixels
END = 2.0        # how near the right and bottom edges a groove's round end comes
WALL_SHADED, WALL_LIT = 1.15, 0.7  # the groove's width on each side of its deepest line, in UI pixels
DEPTH = 1.0
SOFT = 0.32      # the blur on the carving, in UI pixels
LIGHT = np.array([-1.0, -1.0, 1.3]); LIGHT /= np.linalg.norm(LIGHT)  # x right, y down
FLOOR, SHADE, LIT = 0.4, 0.5, 0.6  # alpha of the floor's darkness, the shaded wall, the lit wall
LIT_HOVER = 0.4
PALE = (214, 204, 184)


def write_tga(path, rgba):
    h, w = rgba.shape[:2]
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 8 | 0x20)
    with open(path, "wb") as f:
        f.write(header + rgba[:, :, [2, 1, 0, 3]].astype(np.uint8).tobytes())


def grid():
    """Each drawn point's distance from the right and bottom edges, in UI pixels."""
    c = (np.arange(UI * S) + 0.5) / S
    x, y = np.meshgrid(c, c)
    return UI - x, UI - y


def segment(r, b, ax, ay, bx, by):
    """Distance from the segment (ax, ay)-(bx, by), in the same corner coordinates."""
    t = np.clip(((r - ax) * (bx - ax) + (b - ay) * (by - ay)) / ((bx - ax) ** 2 + (by - ay) ** 2), 0, 1)
    return np.hypot(r - (ax + t * (bx - ax)), b - (ay + t * (by - ay)))


def heights():
    r, b = grid()
    h = np.zeros_like(r)
    for k in CENTRES:
        d = segment(r, b, k - END, END, END, k - END)
        # the upper-left wall slopes gently into shadow, the lower-right one is steep
        w = np.where(r + b > k, WALL_SHADED, WALL_LIT)
        h = np.minimum(h, -DEPTH * np.clip(1 - (d / w) ** 2, 0, 1))
    return ndimage.gaussian_filter(h, SOFT * S, mode="nearest")


def render():
    h = heights()
    gy, gx = np.gradient(h * S)
    nrm = np.stack([-gx, -gy, np.ones_like(gx)], -1)
    nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True)
    shade = nrm @ LIGHT - LIGHT[2]  # 0 on the flat rock, below 0 facing away
    dark = np.clip(FLOOR * -h / DEPTH + SHADE * np.clip(-shade * 2.2, 0, 1), 0, 1)
    lit = np.clip(shade * 1.6, 0, 1)
    return dark, lit


def down(a):
    k = UI * S // TEX
    return a.reshape(TEX, k, TEX, k).mean(axis=(1, 3))


def rgba(dark, light, pale=PALE):
    """Black at `dark`, then the pale grey at `light` over it."""
    a = light + dark * (1 - light)
    rgb = np.array(pale)[None, None, :] * (light / np.maximum(a, 1e-6))[:, :, None]
    return np.dstack([rgb, a * 255]).round().clip(0, 255)


def rock(n, seed=3):
    rng = np.random.default_rng(seed)
    v = sum(ndimage.gaussian_filter(rng.normal(size=(n, n)), s, mode="wrap") * w
            for s, w in ((0.6, 6), (2, 10), (6, 14)))
    base = np.array((44, 39, 34), float)
    return np.clip(base[None, None, :] + v[:, :, None] * np.array((1.0, 0.95, 0.85)), 0, 255)


def over(bg, tex, add=None):
    a = tex[:, :, 3:] / 255
    out = bg * (1 - a) + tex[:, :, :3] * a
    if add is not None:
        out = out + add[:, :, :3] * add[:, :, 3:] / 255
    return out.clip(0, 255)


def lines():
    """The grip it replaces, for the preview: 1px lines, a dark one and a pale lip per groove."""
    r, b = grid()
    dark, lip = np.zeros_like(r), np.zeros_like(r)
    for d in (4, 8, 12):
        dark = np.maximum(dark, (segment(r, b, d + 1, 2, 2, d + 1) <= 0.5) * 0.6)
        lip = np.maximum(lip, (segment(r, b, d, 1, 1, d) <= 0.5) * 0.28)
    lip, dark = down(lip), down(dark)
    return rgba(dark * (1 - lip), lip, (153, 145, 128))


def preview(rows):
    """One row per texture (each a texture and what is added over it), at 1x,
    2x and 4x over rock, the whole sheet then magnified 3 times so the 1x shows."""
    out = []
    for tex, add in rows:
        tiles = []
        for zoom in (1, 2, 4):
            px = UI * zoom
            size = lambda t: np.asarray(Image.fromarray(t.astype(np.uint8)).resize((px, px), Image.LANCZOS), float)
            tile = rock(px * 2 + px // 2)
            o = px * 2
            tile[o - px:o, o - px:o] = over(tile[o - px:o, o - px:o], size(tex), add if add is None else size(add))
            tiles.append(tile)
        h = tiles[-1].shape[0]
        tiles = [np.vstack([t, np.full((h - t.shape[0], t.shape[1], 3), 20.0)]) for t in tiles]
        out.append(np.hstack([c for t in tiles for c in (t, np.full((h, 4, 3), 20.0))]))
        out.append(np.full((4, out[-1].shape[1], 3), 20.0))
    sheet = Image.fromarray(np.vstack(out).astype(np.uint8))
    os.makedirs(os.path.dirname(PREVIEW), exist_ok=True)
    sheet.resize((sheet.width * 3, sheet.height * 3), Image.NEAREST).save(PREVIEW)


def main():
    dark, lit = render()
    dark, lit = down(dark), down(lit)
    normal = rgba(dark, LIT * lit)
    hover = rgba(np.zeros_like(lit), LIT_HOVER * lit)
    write_tga(os.path.join(OUT, "ResizeGrip.tga"), normal)
    write_tga(os.path.join(OUT, "ResizeGrip-Highlight.tga"), hover)
    preview([(lines(), None), (normal, None), (normal, hover)])


if __name__ == "__main__":
    main()
