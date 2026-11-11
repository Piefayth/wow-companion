"""The chat scroll bar's arrows, redrawn at 4x the classic art's resolution in
its own design (the player, 2026-11-11: "I quite like the arrows", "they look
like shit" at TV scale): a dark rounded tile, a gold hood pointing the way, a
red gem in it. Blizzard's own UI-ScrollBar-Scroll*Button art is a 32-px file
stretched to the button; its atlas twin crops differently and came out worse.

    python tools/make_arrows.py     writes addon/WowCompanion_Agent/Art/Arrow*-<v>.tga

Each version gets new file names (the game keeps a loaded texture for the
session under its path): bump ARROW_VERSION in Window.lua, run this, reload.
The drawing fills 64 x 56 of a 64 x 64 tile; Window.lua shows rows 4..60
(texcoords 0.0625..0.9375), the 18:16 shape of the button.
"""
import glob
import os
import re
import struct
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(__file__)
OUT = os.path.join(HERE, "..", "addon", "WowCompanion_Agent", "Art")
S = 4                 # supersampling
W = H = 64 * S


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def vertical_gradient(size, top, bottom):
    w, h = size
    im = Image.new("RGBA", size)
    px = im.load()
    for y in range(h):
        c = lerp(top, bottom, y / max(1, h - 1))
        for x in range(w):
            px[x, y] = c
    return im


def mask_draw(fn):
    m = Image.new("L", (W, H), 0)
    fn(ImageDraw.Draw(m))
    return m


def up_arrow(pressed=False):
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    o = S * (1 if pressed else 0)              # pressed art sits one pixel down-right
    # the tile: dark iron, a lighter rim top-left, darker bottom-right
    box = (2 * S + o, 5 * S + o, 62 * S + o, 59 * S + o)
    tile = mask_draw(lambda d: d.rounded_rectangle(box, radius=9 * S, fill=255))
    im.paste(vertical_gradient((W, H), (74, 72, 70, 255), (34, 33, 33, 255)), (0, 0), tile)
    inner = (box[0] + 3 * S, box[1] + 3 * S, box[2] - 3 * S, box[3] - 3 * S)
    face = mask_draw(lambda d: d.rounded_rectangle(inner, radius=7 * S, fill=255))
    im.paste(vertical_gradient((W, H), (52, 50, 49, 255), (26, 25, 25, 255)), (0, 0), face)
    # the gold hood: a thick chevron pointing up
    cx = 32 * S + o
    outer = [(cx, 13 * S + o), (cx + 21 * S, 44 * S + o), (cx - 21 * S, 44 * S + o)]
    cut = [(cx, 25 * S + o), (cx + 12 * S, 44 * S + o), (cx - 12 * S, 44 * S + o)]
    hood = mask_draw(lambda d: (d.polygon(outer, fill=255), d.polygon(cut, fill=0)))
    shadow = hood.filter(ImageFilter.GaussianBlur(2 * S))
    im.paste((0, 0, 0, 170), (S, 2 * S), shadow)
    im.paste(vertical_gradient((W, H), (255, 228, 120, 255), (150, 98, 22, 255)), (0, 0), hood)
    edge = hood.filter(ImageFilter.FIND_EDGES).point(lambda v: 255 if v > 40 else 0)
    im.paste((70, 40, 6, 255), (0, 0), edge)
    # the red gem in the hood's mouth
    gem_box = (cx - 8 * S, 31 * S + o, cx + 8 * S, 47 * S + o)
    gem = mask_draw(lambda d: d.ellipse(gem_box, fill=255))
    im.paste(vertical_gradient((W, H), (40, 6, 6, 255), (40, 6, 6, 255)), (0, 0), gem)
    core_box = (gem_box[0] + 3 * S, gem_box[1] + 3 * S, gem_box[2] - 3 * S, gem_box[3] - 3 * S)
    core = mask_draw(lambda d: d.ellipse(core_box, fill=255))
    im.paste(vertical_gradient((W, H), (210, 52, 40, 255), (96, 12, 10, 255)), (0, 0), core)
    glint = mask_draw(lambda d: d.ellipse((core_box[0] + 2 * S, core_box[1] + S,
                                           core_box[0] + 6 * S, core_box[1] + 4 * S), fill=255))
    im.paste((255, 210, 190, 230), (0, 0), glint.filter(ImageFilter.GaussianBlur(S)))
    return im.resize((64, 64), Image.LANCZOS)


def disabled(im):
    g = im.convert("LA").convert("RGBA")
    r, gch, b, a = g.split()
    return Image.merge("RGBA", (r.point(lambda v: v * 0.6), gch.point(lambda v: v * 0.6),
                                b.point(lambda v: v * 0.6), a))


def highlight():
    m = Image.new("L", (64, 64), 0)
    ImageDraw.Draw(m).rounded_rectangle((4, 7, 60, 57), radius=9, fill=150)
    m = m.filter(ImageFilter.GaussianBlur(4))
    im = Image.new("RGBA", (64, 64), (255, 214, 120, 0))
    im.putalpha(m)
    return im


def write_tga(path, im):
    w, h = im.size
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 8 | 0x20)
    data = bytearray()
    for r, g, b, a in im.getdata():
        data += bytes((b, g, r, a))
    with open(path, "wb") as f:
        f.write(header)
        f.write(data)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    lua = open(os.path.join(OUT, "..", "Window.lua"), encoding="utf-8").read()
    v = re.search(r"local ARROW_VERSION = (\d+)", lua).group(1)
    for old in glob.glob(os.path.join(OUT, "Arrow*.tga")):
        os.remove(old)
    up, pushed = up_arrow(), up_arrow(pressed=True)
    art = {"Up": up, "Pushed": pushed, "Disabled": disabled(up), "Highlight": highlight()}
    for state, im in art.items():
        write_tga(os.path.join(OUT, "ArrowUp%s-%s.tga" % (state, v)), im)
        write_tga(os.path.join(OUT, "ArrowDown%s-%s.tga" % (state, v)), im.transpose(Image.FLIP_TOP_BOTTOM))
    print("wrote", os.path.abspath(OUT))
