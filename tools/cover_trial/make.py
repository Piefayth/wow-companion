"""A trial (the player, 2026-11-13): join round's option 1 in game. The thin
gusset sheet folded over the names panel's top-right and bottom-right corners,
the thick vine running on under it, the sheet pressed into a ridge over the
vine. wrap.py and join.py drew the concept sheets (the mock harness); this
renders option 1 on black and on white and takes the alpha from the
difference, so the game gets the metal alone:

    python tools/cover_trial/make.py   writes addon/WowCompanion/Art/Vine-ThickEndCover<Top|Bottom>-T4.tga

48 x 24 units at 4 texels each, the spine's middle at x 24 (1.5 right of the
panel's edge), the panel's edge at the texture's top (bottom). Removed with the
trial once one is picked (docs/looks.md).
"""
import os, sys
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wrap as w
import join as j
import make_scrollbar_art as sb

w.W = 100
SPINE = -1.5  # the spine's middle, units in from the panel's edge (outside it)
TW, TH_ = 48, 24


def scene(bg):
    w.rng = np.random.default_rng(3)
    sc = w.Scene(T=3.0, side="grad")
    sc.backdrop = lambda: np.full((w.H * w.K, w.W * w.K, 3), float(bg))
    img = sc.backdrop()
    for bot in (False, True):
        jj = j.J(sc, img, bot)
        path = [(SPINE, 60), (SPINE, 1.5)]
        jj.vine(path, clip=sc.out)
        cov = jj.sheet(j.gusset())
        jj.crimp(j.vpieces(path, j.TH), cov)
        jj.pins([(8, 4)])
        img = jj.img
    return sc, img


def main():
    sc, a = scene(0)
    _, b = scene(255)
    alpha = np.clip(1 - (b - a).mean(-1) / 255, 0, 1)
    rgb = np.where(alpha[..., None] > 1e-3, a / np.maximum(alpha[..., None], 1e-3), 0)
    K = w.K
    mx = sc.xr - SPINE  # the spine's middle, mock units
    x0 = int(round((mx - TW / 2) * K))
    out = os.path.join(sb.CORE_OUT)
    for name, ytop in (("Top", w.y0), ("Bottom", sc.yb - TH_)):
        y0 = int(round(ytop * K))
        tex = np.zeros((TH_ * K, TW * K, 4))
        tex[..., :3] = rgb[y0:y0 + TH_ * K, x0:x0 + TW * K]
        tex[..., 3] = alpha[y0:y0 + TH_ * K, x0:x0 + TW * K] * 255
        im = Image.fromarray(np.clip(tex, 0, 255).astype("uint8"), "RGBA").resize((TW * sb.U, TH_ * sb.U), Image.LANCZOS)
        sb.write_tga(os.path.join(out, "Vine-ThickEndCover%s-T4.tga" % name), np.asarray(im, float))
        im.save(os.path.join(os.environ.get("TEMP", "."), "cover%s.png" % name))
    print("2 textures")


if __name__ == "__main__":
    main()
