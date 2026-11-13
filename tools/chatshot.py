"""A picture for the Companion window's chat: a screenshot (or a crop of one)
written where the game can draw it, and the line that shows it.

    python tools/chatshot.py <image> <name> [x0 y0 x1 y1] [--max W]

writes addon/WowCompanion_Agent/Shots/<name>.tga (padded to powers of two;
gitignored, these are a conversation's, not the addon's) and the same file into
the installed addon, and prints the markdown line to put in `say`:

    ![caption](shot:<name>:<w>x<h>)

The game reads a new texture file only after a /reload, so an answer showing
one offers the Reload. The crop is in the image's own pixels; --max scales it
down to at most W pixels wide (a 4K crop is often wider than the chat).
"""
import os
import sys

from PIL import Image

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SHOTS = os.path.join("WowCompanion_Agent", "Shots")
ADDONS = r"S:\World of Warcraft\_forever_\Interface\AddOns"


def pow2(n):
    p = 1
    while p < n:
        p *= 2
    return p


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    most = None
    if "--max" in argv:
        most = int(argv[argv.index("--max") + 1])
        args.remove(str(most))
    src, name = args[0], args[1]
    im = Image.open(src).convert("RGBA")
    if len(args) >= 6:
        im = im.crop(tuple(int(v) for v in args[2:6]))
    if most and im.width > most:
        im = im.resize((most, round(im.height * most / im.width)), Image.LANCZOS)
    w, h = im.size
    if max(w, h) > 2048:
        raise SystemExit("too big for one texture: %dx%d (crop it, or --max)" % (w, h))
    tex = Image.new("RGBA", (pow2(w), pow2(h)), (0, 0, 0, 0))
    tex.paste(im, (0, 0))
    for base in (os.path.join(ROOT, "addon"), ADDONS):
        folder = os.path.join(base, SHOTS)
        if os.path.isdir(os.path.dirname(folder)):
            os.makedirs(folder, exist_ok=True)
            tex.save(os.path.join(folder, name + ".tga"))
    print("![%s](shot:%s:%dx%d)" % (name, name, w, h))


if __name__ == "__main__":
    main(sys.argv[1:])
