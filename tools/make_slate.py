"""The Companion window's turn backings: dark fine-grained stone, generated
(docs/proposals/companion-chat-look.md, option C). Blizzard's tiles were tried
first: marble too busy and near black, rock flat grey, the neutral tile read as
wooden planks. Two tiles of one stone at two values, since owners differ by
value, never by hue.

    python tools/make_slate.py      writes addon/WowCompanion_Agent/Art/Slate*-<v>.tga

The game keeps a loaded texture for the session under its path, so each version
gets new file names (no restart to see a change): bump STONE_VERSION in
Transcript.lua, run this, reload. Older versions are deleted.

256 x 256, 32-bit uncompressed TGA (what the game loads besides BLP), the noise
periodic in both axes so the tile repeats without a seam.
"""
import glob
import os
import re
import struct
import numpy as np

SIZE = 256
OUT = os.path.join(os.path.dirname(__file__), "..", "addon", "WowCompanion_Agent", "Art")


def periodic_noise(rng, period):
    """Smooth value noise that wraps at SIZE: a lattice every `period` pixels,
    cosine-interpolated, the lattice itself wrapping."""
    cells = SIZE // period
    lattice = rng.uniform(-1, 1, (cells, cells))
    t = (np.arange(SIZE) % period) / period
    w = (1 - np.cos(t * np.pi)) / 2
    i0 = np.arange(SIZE) // period
    i1 = (i0 + 1) % cells
    a = lattice[np.ix_(i0, i0)]
    b = lattice[np.ix_(i0, i1)]
    c = lattice[np.ix_(i1, i0)]
    d = lattice[np.ix_(i1, i1)]
    wy, wx = w[:, None], w[None, :]
    return (a * (1 - wx) + b * wx) * (1 - wy) + (c * (1 - wx) + d * wx) * wy


def stone(seed, base):
    rng = np.random.default_rng(seed)
    v = periodic_noise(rng, 64) * 5 + periodic_noise(rng, 32) * 4 + periodic_noise(rng, 8) * 2.5
    v += rng.normal(0, 1.2, (SIZE, SIZE))  # fine grain
    specks = rng.random((SIZE, SIZE)) < 0.004
    v[specks] += 9
    rgb = np.stack([base[k] + v for k in range(3)], axis=-1)
    return np.clip(np.rint(rgb), 0, 255).astype(np.uint8)


def write_tga(path, rgb):
    h, w, _ = rgb.shape
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 8 | 0x20)
    bgra = np.dstack([rgb[..., 2], rgb[..., 1], rgb[..., 0], np.full((h, w), 255, np.uint8)])
    with open(path, "wb") as f:
        f.write(header)
        f.write(bgra.tobytes())


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    lua = open(os.path.join(OUT, "..", "Transcript.lua"), encoding="utf-8").read()
    v = re.search(r"local STONE_VERSION = (\d+)", lua).group(1)
    for old in glob.glob(os.path.join(OUT, "Slate*.tga")):
        os.remove(old)
    # Two tiles of one stone, each its own (the player, 2026-11-11: two real
    # textures, variants, not one with a lighter wash): the same recipe from
    # different seeds, so the grain differs, at two values; a cool charcoal,
    # warmth left to the gold dividers and headers
    write_tga(os.path.join(OUT, "Slate-%s.tga" % v), stone(7, (26, 27, 30)))
    write_tga(os.path.join(OUT, "SlateLight-%s.tga" % v), stone(23, (54, 55, 60)))
    print("wrote", os.path.abspath(OUT))
