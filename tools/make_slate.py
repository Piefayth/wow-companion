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


def stone(seed, base, strata=0.0, calm=1.0):
    """Stone you can see from a couch: cloudy mottling at three scales, a fine
    grain, sparse pale flecks, and (strata > 0) faint horizontal layering, so
    the two tiles differ in kind as well as value. The first version, with
    about +-3 levels of grain, read as a flat fill on the TV."""
    rng = np.random.default_rng(seed)
    v = periodic_noise(rng, 128) * 9 + periodic_noise(rng, 32) * 7 + periodic_noise(rng, 8) * 4
    v += rng.normal(0, 2.5, (SIZE, SIZE))  # fine grain
    if strata:
        # layers along the rows: noise varying slowly down the tile, stretched
        # wide, still periodic both ways
        rows = periodic_noise(rng, 16)[:, :1] * np.ones((1, SIZE))
        wobble = periodic_noise(rng, 64) * 0.5
        v += (rows + wobble) * strata
    specks = rng.random((SIZE, SIZE)) < 0.006 * calm
    v[specks] += 16
    v *= calm
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
    # Calm by rule (the player, 2026-11-11: v3 "too busy", theirs "too
    # light"): behind text, the texture's own contrast stays a small fraction
    # of the text's, and only broad, soft variation survives; the game feel is
    # carried by the frame, dividers and headers, not the fill. The owners a
    # small value step apart, both dark.
    # the two darkest of three tried (the player, 2026-11-11): replies on the
    # former dark stone, the player's on a darker one still
    write_tga(os.path.join(OUT, "Slate-%s.tga" % v), stone(23, (17, 18, 20), calm=0.45))
    write_tga(os.path.join(OUT, "SlateLight-%s.tga" % v), stone(7, (22, 23, 26), calm=0.45))
    print("wrote", os.path.abspath(OUT))
