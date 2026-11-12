"""Junction trials, temporary: three directions of scroll ornament for where
the vine dividers meet at right angles, for the Junctions tab (addon/
WowCompanion_Agent/JunctionTrials.lua) while the player chooses. Goes when one
is chosen.

    python tools/make_junction_trials.py            writes Art/Try-<direction>-<Big|Small>-3.tga
    python tools/make_junction_trials.py --preview  and target/junctions-real.png, -3x.png:
                                                    each at its size on screen, and 3x

All keep the forged join (make_scrollbar_art.forge) and draw their ornament
with make_scrollbar_art.Wire by the rules written above its junction; Cascade
is the settings page's (make_scrollbar_art.junction).
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_scrollbar_art as M  # noqa: E402
from make_scrollbar_art import Wire, forge, mirror_pair, write_tga, WEIGHTS  # noqa: E402

OUT = os.path.join(M.ROOT, "addon", "WowCompanion_Agent", "Art")
TRIAL_VERSION = 3
R = WEIGHTS["Thick"][0]


def lance(base, y, L):
    """The fleur's lance lying on its side, its base at x `base`, its point L
    to the left."""
    from scipy.interpolate import PchipInterpolator
    knots = [(0, 1.5), (L * 0.22, 2.4), (L * 0.45, 2.64), (L * 0.72, 2.0), (L * 0.92, 0.9), (L, 0.45)]
    f = PchipInterpolator([q[0] for q in knots], [q[1] for q in knots])
    t = np.linspace(0, L, 120)
    hw = f(t)
    return [(base - u, y - w) for u, w in zip(t, hw)] + [(base - u, y + w) for u, w in zip(t[::-1], hw[::-1])]


# --- A. Lyre (the fleur-de-lis grown ornate): the arm runs through the run
# into a lance; two horns drop from it into big volutes, and off the bottom
# of each an S satellite turns the other way
def lyre(N, big):
    m = N / 2
    if big:
        x0 = m - R - 3
        horn = Wire((x0, m + 1.0), 125).volute((m - 21, m + 14), 9.0, 0, 1, 2.0, eye=2.1, out=0.5, inn=0.5)
        sat = horn.fork(0.34).volute((m - 34, m + 23), 5.0, 270, -1, 1.0, eye=1.9)
        return forge(N, True, mirror_pair(m, [(horn, 1.45, 0.95), (sat, 1.15, 0.85)]) + [lance(x0, m, 28)], arm_from=x0 - 1)
    x0 = m + R + 1.5
    horn = Wire((x0, m + 1.0), 70).volute((m + 15, m + 12), 7.5, 270, 1, 1.5, eye=2.0)
    sat = horn.fork(0.42).volute((m + 28, m + 16), 5.0, 180, -1, 1.0, eye=1.8)
    return forge(N, False, mirror_pair(m, [(horn, 1.2, 0.85), (sat, 1.0, 0.8)]))


# --- B. Cascade (Victorian filigree, the swirl flourish): the settings page's
def cascade(N, big):
    return M.junction(big)


# --- C. Triskele (Celtic spirals): three volutes a side, the one by the run
# and the one beyond it of opposite hands, linked by an S, a third hanging
# from the first between them
def triskele(N, big):
    m = N / 2
    if big:
        x0 = m - R - 3
        a = Wire((x0, m + 0.6), 175).volute((m - 14, m + 10), 8.0, 270, -1, 1.75, eye=2.1)
        b = a.fork(0.2).volute((m - 34, m + 11), 7.5, 90, 1, 1.75, eye=2.0)
        c = a.fork(0.3).volute((m - 27.5, m + 22), 5.2, 0, 1, 1.0, eye=1.9)
        return forge(N, True, mirror_pair(m, [(a, 1.4, 0.95), (b, 1.25, 0.9), (c, 1.05, 0.8)]), arm_from=x0 - 1)
    x0 = m + R + 1.5
    a = Wire((x0, m + 1.0), 30).volute((m + 11, m + 11), 7.5, 270, 1, 1.5, eye=2.0)
    b = a.fork(0.3).volute((m + 27, m + 11), 5.5, 90, -1, 1.25, eye=1.8)
    return forge(N, False, mirror_pair(m, [(a, 1.2, 0.85), (b, 1.05, 0.8)]))


DIRECTIONS = {"Lyre": lyre, "Cascade": cascade, "Triskele": triskele}  # JunctionTrials.lua's order


def main():
    made = {}
    for name, draw in DIRECTIONS.items():
        for big in (True, False):
            img = draw(M.JOIN_SIZE[big], big)
            made[name, big] = img
            write_tga(os.path.join(OUT, "Try-%s-%s-%d.tga" % (name, "Big" if big else "Small", TRIAL_VERSION)), img)
    made_names = {"Try-%s-%s-%d.tga" % (name, "Big" if big else "Small", TRIAL_VERSION) for name, big in made}
    for old in os.listdir(OUT):
        if old.startswith("Try-") and old not in made_names:
            os.remove(os.path.join(OUT, old))
    if "--preview" in sys.argv:
        preview(made)


# --- previews at the size the game draws them: the settings page measured on
# the player's 4K screen (target/settings-crop.png: dividers 96 units apart
# are 260 px, so 2.71 px a unit)
PX = 260 / 96


def preview(made):
    from PIL import Image
    slate = Image.open(os.path.join(M.CORE_OUT, "Slate-6.tga")).convert("RGB")
    vm = {k: Image.open(os.path.join(M.CORE_OUT, "Vine-%s-%d.tga" % (k, M.VINE_VERSION))).convert("RGBA")
          for k in ("ThickVMid", "ThickMid", "Mid")}
    cell = 120  # units
    cols = list(DIRECTIONS)
    old = os.path.join(M.ROOT, "target", "scratch")  # last round's Fleur, kept there for comparison
    if os.path.exists(os.path.join(old, "fleur-big.tga")):
        cols.append("Fleur")
        for big in (True, False):
            made["Fleur", big] = np.asarray(Image.open(os.path.join(old, "fleur-%s.tga" % ("big" if big else "small"))).convert("RGBA"), float)

    def scene(img, big):
        """A cell as the page draws it: the spine down, the arm right, the joint over them."""
        k = 4  # px a unit while composing (the art's own U)
        W = cell * k
        bg = Image.new("RGB", (W, W))
        for x in range(0, W, slate.width):
            for y in range(0, W, slate.height):
                bg.paste(slate, (x, y))
        cx = W // 2 + 8 * k if big else W // 2 - 30 * k
        bg.paste(vm["ThickVMid"].resize((16 * k, W)), (cx - 8 * k, 0), vm["ThickVMid"].resize((16 * k, W)))
        arm = vm["ThickMid" if big else "Mid"].resize((W - cx, 16 * k))
        bg.paste(arm, (cx, W // 2 - 8 * k), arm)
        j = Image.fromarray(img.astype(np.uint8), "RGBA")
        bg.paste(j, (cx - j.width // 2, W // 2 - j.height // 2), j)
        return bg
    W = cell * 4
    sheet = Image.new("RGB", (W * len(cols), W * 2))
    for r, big in enumerate((True, False)):
        for c, name in enumerate(cols):
            sheet.paste(scene(made[name, big], big), (c * W, r * W))
    real = sheet.resize((round(sheet.width * PX / 4), round(sheet.height * PX / 4)), Image.LANCZOS)
    real.save(os.path.join(M.ROOT, "target", "junctions-real.png"))
    real.resize((real.width * 3, real.height * 3), Image.LANCZOS).save(os.path.join(M.ROOT, "target", "junctions-3x.png"))


if __name__ == "__main__":
    main()
