"""The "chord" glyph: both shoulder buttons, no letters on them, for prompts that
mean "hold any conversation's chord" (the Companion window's Chord+R3 Switch).
The game's own prompt icons are lettered per controller (L1, LB); this one fits
any. Drawn to sit beside them: the textured prompt set Blizzard's legends use
(gamepad-ps-triggerl1 and kin), a dark brown face in a bronze rim, lit from
above, a soft shadow under.

    python tools/make_chord_glyph.py    writes addon/WowCompanion/Art/Chord-<v>.tga

The game keeps a loaded texture for the session under its path, so each
version gets a new file name: bump VERSION here and the number in Style.lua's
CHORD, run this, reload. Older versions are deleted.

64 x 64, 32-bit uncompressed TGA, drawn 4x oversampled and averaged down.
"""
import glob
import os
import artout
import struct
import numpy as np

VERSION = 6
SIZE = 64
OVER = 4
OUT = os.path.join(os.path.dirname(__file__), "..", "addon", "WowCompanion", "Art")


def rounded_box(x, y, cx, cy, hw, hh, r):
    """Signed distance to a rounded rectangle (negative inside)."""
    qx = np.abs(x - cx) - hw + r
    qy = np.abs(y - cy) - hh + r
    return np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - r


def one_bumper(x, y, inset, cx, cy, angle, drop):
    """One shoulder button: a short pill, its top a little rounder than its
    bottom, turned `angle` degrees about its centre."""
    a = np.radians(angle)
    u = np.cos(a) * (x - cx) + np.sin(a) * (y - cy - drop)
    v = -np.sin(a) * (x - cx) + np.cos(a) * (y - cy - drop)
    hw, hh = 14.5 - inset, 10.5 - inset
    body = rounded_box(u, v, 0, 0, hw, hh, max(9 - inset, 1)) <= 0
    # the top bulges: an arch over the pill
    arch = v >= -hh - 2.5 * (1 - (u / max(hw, 1)) ** 2)
    top = rounded_box(u, v + 1.5, 0, 0, hw, hh + 1.5, max(9 - inset, 1)) <= 0
    return (body | top) & arch


def bumper(x, y, inset, drop=0.0):
    """Both shoulders, as on the top edge of a controller: two bumpers side by
    side, their outer ends dipping, filling the canvas's width: inline it is
    cut to the rows Style.lua's CHORD names, as wide as the trimmed R3."""
    left = one_bumper(x, y, inset, 16, 32, -12, drop)
    right = one_bumper(x, y, inset, 48, 32, 12, drop)
    return left | right


def main():
    n = SIZE * OVER
    c = (np.arange(n) + 0.5) / OVER
    x, y = np.meshgrid(c, c)
    cx, cy, hh = 32, 33, 9
    rim_w = 2.6
    shape = bumper(x, y, 0).astype(float)
    face = bumper(x, y, rim_w).astype(float)
    rim = shape - face
    shadow_shape = bumper(x, y, -1.5, drop=3).astype(float)
    # light from above: the rim runs from pale bronze at the top to dark below
    t = np.clip((y - (cy - hh - 9)) / (2 * hh + 9), 0, 1)
    # muted bronze, matched against gamepad-ps-triggerl1 side by side
    rim_rgb = np.stack([178 - 70 * t, 152 - 62 * t, 114 - 48 * t], axis=-1)
    # a dark line just inside the rim, as theirs have
    ring = (bumper(x, y, rim_w) & ~bumper(x, y, rim_w + 1.0)).astype(float)
    # the face: dark brown, a little lighter toward the top centre
    dist = np.hypot((x - cx) / 27, (y - (cy - hh)) / (hh + 9))
    k = np.clip(1 - dist, 0, 1)
    face_rgb = np.stack([26 + 18 * k, 22 + 15 * k, 18 + 11 * k], axis=-1)
    face_rgb *= (1 - ring[..., None] * 0.55)
    rgb = rim[..., None] * rim_rgb + face[..., None] * face_rgb
    alpha = shape
    # the soft shadow, under the shape, offset down
    shadow = shadow_shape * 0.5
    alpha_all = alpha + shadow * (1 - alpha)
    rgb_all = rgb  # the shadow is black

    def down(a):
        if a.ndim == 3:
            return a.reshape(SIZE, OVER, SIZE, OVER, a.shape[2]).mean(axis=(1, 3))
        return a.reshape(SIZE, OVER, SIZE, OVER).mean(axis=(1, 3))

    a = down(alpha_all)
    premul = down(rgb_all * alpha[..., None])
    colour = premul / np.maximum(a[..., None], 1e-6)
    rgba = np.concatenate([colour, a[..., None] * 255], axis=-1)

    os.makedirs(OUT, exist_ok=True)
    artout.clear(OUT, "Chord-*.tga")
    path = os.path.join(OUT, "Chord-%d.tga" % VERSION)
    bgra = np.clip(rgba[..., [2, 1, 0, 3]], 0, 255).astype(np.uint8)
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 8 | 0x20)
    with open(path, "wb") as f:
        f.write(header)
        f.write(bgra.tobytes())
    print(path)


if __name__ == "__main__":
    main()
