"""Junction trials, temporary: three directions for where the vine dividers
meet at right angles, for the Junctions tab (addon/WowCompanion_Agent/
JunctionTrials.lua) while the player chooses. Goes when one is chosen.

    python tools/make_junction_trials.py            writes Art/Try-<direction>-<Big|Small>-2.tga
    python tools/make_junction_trials.py --preview  and target/junctions-real.png, -3x.png:
                                                    each beside the game's crop, at its size on screen

Each is forged as one piece (make_scrollbar_art.forge): the run, the arm and
the ornament one metal, so nothing reads laid over the lines.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_scrollbar_art as M  # noqa: E402
from make_scrollbar_art import forge, spline, volute, write_tga, WEIGHTS  # noqa: E402

OUT = os.path.join(M.ROOT, "addon", "WowCompanion_Agent", "Art")
TRIAL_VERSION = 2
R, A_MED = WEIGHTS["Thick"][0], WEIGHTS[""][0]


# --- B. Whiplash (Guimard): the arm forks well out, its two branches whipping
# apart and running into the trunk along it, so the arm becomes the trunk;
# two trunks: through it, a long lyre of whiplash on the left, opening toward it
def whiplash(N, big):
    m = N / 2
    A = R if big else A_MED
    k = 1.25 if big else 1.0
    work = []
    for s in (-1, 1):  # the fork: tangent into the trunk's right face
        work.append(M.ribbon(spline([(m + R + 18 * k, m + s * 0.3), (m + R + 10 * k, m + s * 3 * k),
                                     (m + R + 3.2 * k, m + s * 9 * k), (m + R * 0.25, m + s * 17 * k)], 40), A * 0.85))
    if big:
        for s in (-1, 1):  # the lyre: out of the arm's end, sweeping wide, back to curl by the trunk
            work.append(volute([(m - R - 1, m + s * 1), (m - R - 12, m + s * 4), (m - R - 21, m + s * 13),
                                (m - R - 18, m + s * 24), (m - R - 8, m + s * 27)], 3.8, s * 1.1, 1.55, 1.1))
    return forge(N, big, work, arm_from=(m - R - 3) if big else None)


# --- C. Interlace: the arm parts at the trunk into two wires that pass behind
# it and cross each other, over and under, on its far side, each ending in a
# curl turned back toward the trunk
def interlace(N, big):
    m = N / 2
    w = 1.5 if big else 1.15
    reach = 24 if big else 16
    over, under = [], []
    for s in (-1, 1):
        path = [(m + R + 8, m + s * 0.5), (m + R + 1, m + s * 4.5), (m - R - 4, m + s * 6.5),
                (m - R - reach * 0.6, m - s * 3.5), (m - R - reach, m - s * 12), (m - R - reach * 0.5, m - s * 19)]
        (over if s < 0 else under).append(volute(path, 3.6 if big else 2.7, s * 1.1, w, w * 0.75))
    return forge(N, big, behind=[under, over])


def shipped(N, big):
    return M.junction(big)


DIRECTIONS = {"Fleur": shipped, "Whiplash": whiplash, "Interlace": interlace}  # JunctionTrials.lua's order


def main():
    made = {}
    for name, draw in DIRECTIONS.items():
        for big in (True, False):
            img = draw(M.JOIN_SIZE[big], big)
            made[name, big] = img
            write_tga(os.path.join(OUT, "Try-%s-%s-%d.tga" % (name, "Big" if big else "Small", TRIAL_VERSION)), img)
    for old in os.listdir(OUT):
        if old.startswith("Try-") and not old.endswith("-%d.tga" % TRIAL_VERSION):
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
    cell = 100  # units
    def scene(img, big):
        """A cell as the page draws it: the spine down, the arm right, the joint over them."""
        k = 4  # px a unit while composing (the art's own U)
        W = cell * k
        bg = Image.new("RGB", (W, W))
        for x in range(0, W, slate.width):
            for y in range(0, W, slate.height):
                bg.paste(slate, (x, y))
        cx = W // 2 - 12 * k
        bg.paste(vm["ThickVMid"].resize((16 * k, W)), (cx - 8 * k, 0), vm["ThickVMid"].resize((16 * k, W)))
        arm = vm["ThickMid" if big else "Mid"].resize((W - cx, 16 * k))
        bg.paste(arm, (cx, W // 2 - 8 * k), arm)
        j = Image.fromarray(img.astype(np.uint8), "RGBA")
        bg.paste(j, (cx - j.width // 2, W // 2 - j.height // 2), j)
        return bg
    rows = []
    for big in (True, False):
        rows.append([scene(made[name, big], big) for name in DIRECTIONS])
    W = rows[0][0].width
    sheet = Image.new("RGB", (W * len(DIRECTIONS), W * 2))
    for r, row in enumerate(rows):
        for c, im in enumerate(row):
            sheet.paste(im, (c * W, r * W))
    real = sheet.resize((round(sheet.width * PX / 4), round(sheet.height * PX / 4)), Image.LANCZOS)
    crop = Image.open(os.path.join(M.ROOT, "target", "settings-crop.png")).convert("RGB")
    out = Image.new("RGB", (real.width + crop.width + 10, max(real.height, crop.height)))
    out.paste(crop, (0, 0))
    out.paste(real, (crop.width + 10, 0))
    out.save(os.path.join(M.ROOT, "target", "junctions-real.png"))
    real.resize((real.width * 3, real.height * 3), Image.LANCZOS).save(os.path.join(M.ROOT, "target", "junctions-3x.png"))


if __name__ == "__main__":
    main()
