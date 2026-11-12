"""The "chord" glyph: a shoulder button with no letter on it, for prompts that
mean "hold any conversation's chord" (the Companion window's Chord+R3 Switch).
The game's own glyphs are lettered per controller (L1, LB); this one fits any.

    python tools/make_chord_glyph.py    writes addon/WowCompanion/Art/Chord-<v>.tga

The game keeps a loaded texture for the session under its path, so each
version gets a new file name: bump VERSION here and the number in Style.lua's CHORD,
run this, reload. Older versions are deleted.

64 x 64, 32-bit uncompressed TGA, drawn 4x oversampled and averaged down for
smooth edges: a bumper's shape (a rounded bar, its top edge arched), dark fill,
light rim, as the game's controller glyphs are drawn.
"""
import glob
import os
import struct
import numpy as np

VERSION = 1
SIZE = 64
OVER = 4
OUT = os.path.join(os.path.dirname(__file__), "..", "addon", "WowCompanion", "Art")


def inside(x, y, inset):
    """The bumper, shrunk by `inset` pixels: a rounded bar whose top edge is
    arched (higher in the middle)."""
    cx, cy = 32, 32
    hw, hh = 27 - inset, 15 - inset
    r = max(9 - inset, 1)
    qx = np.abs(x - cx) - hw + r
    qy = np.abs(y - cy) - hh + r
    d = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - r
    # the arch: the top edge dips 8 px toward the sides
    top = cy - hh + 8 * ((x - cx) / (hw)) ** 2
    return (d <= 0) & (y >= top)


def main():
    n = SIZE * OVER
    c = (np.arange(n) + 0.5) / OVER
    x, y = np.meshgrid(c, c)
    outer = inside(x, y, 0).astype(float)
    inner = inside(x, y, 3.2).astype(float)
    rim = outer - inner

    def down(a):
        return a.reshape(SIZE, OVER, SIZE, OVER).mean(axis=(1, 3))

    rim, fill = down(rim), down(inner)
    alpha = np.clip(rim + fill, 0, 1)
    shade = np.where(alpha > 0, (rim * 215 + fill * 46) / np.maximum(alpha, 1e-6), 0)
    rgba = np.zeros((SIZE, SIZE, 4))
    rgba[..., 0] = shade
    rgba[..., 1] = shade
    rgba[..., 2] = shade * 1.02
    rgba[..., 3] = alpha * 255

    os.makedirs(OUT, exist_ok=True)
    for old in glob.glob(os.path.join(OUT, "Chord-*.tga")):
        os.remove(old)
    path = os.path.join(OUT, "Chord-%d.tga" % VERSION)
    bgra = np.clip(rgba[..., [2, 1, 0, 3]], 0, 255).astype(np.uint8)
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 8 | 0x20)
    with open(path, "wb") as f:
        f.write(header)
        f.write(bgra.tobytes())
    print(path)


if __name__ == "__main__":
    main()
