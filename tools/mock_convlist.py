"""The conversation list's looks (addon/WowCompanion_Agent/ConvLooks.lua) drawn
over a 4K screenshot of the Companion window, at true size, to compare them
side by side before the player picks one in game. A trial's tool: it goes
with the looks not picked.

ConvLooks.lua itself lays each look out (run here under LuaJIT, as the game
runs it), and every texture is the addon's own file, turned and cut by the
same texcoords the game is given. What the game draws itself comes from the
screenshots: the stone, the names and state words (the round 2 shot, rows on
bare stone, the names scaled to the normal font) and the pad's glyphs (the
round 4 shot, glyphs in sockets). Blizzard's voice chat mic (not in our files)
is drawn here in its shape.

    python tools/mock_convlist.py     writes target/tmp/convlist8/<look>.png and all.png (--offer: each with the offered button too)
"""
import os
import re
import sys

import numpy as np
from lupa import luajit21
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
TMP = os.path.join(ROOT, "target", "tmp", "convlist8")
SHOTS = os.path.join(os.environ.get("LOCALAPPDATA", ""), "wow-companion", "shots")
SHOT = os.path.join(SHOTS, "convlist5-full.png")  # 3840 x 2160, the window open on Chat, round 4's brass rows
WORDS = os.path.join(SHOTS, "convlist4-full.png")  # the same window, round 2's rows: names on bare stone
WELL = (1695.0, 297.0, 1542.0, 2045.0)  # the list well's left, top, foot and right in the shots, px
W = 130
PX = (WELL[3] - WELL[0]) / W  # 2.69 px a unit
CROP = (1430, 236, 2112, 1640)  # each tile: the list, its frame, the chat's scroll bar and turns beside it
BARE = (1712, 1000, 2028, 1500)  # bare stone in the list well of SHOT
WALL_BAND = (1100, 1200)  # rows of SHOT whose walls nothing crosses
FLOOR = 3
LAYERS = {"BACKGROUND": 0, "BORDER": 1, "ARTWORK": 2, "OVERLAY": 3}

OPEN, POINTER = "l2", "r1"  # the row in view; the row the pad's cursor is on
STATES = {"l1": "new", "r1": "95s", "r2": "mic"}
NAME, NAME_HL, NAME_LIT = (199, 176, 135), (232, 214, 171), (250, 235, 199)
GOOD, GREY = (127, 208, 127), (176, 176, 176)
IDLE_GLYPH = 0.6
NAME_SCALE = 12 / 16  # the names: GameFontNormal; the shot's are GameFontNormalLarge


# --- the Lua --------------------------------------------------------------------

def looks():
    lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
    style = open(os.path.join(ROOT, "addon", "WowCompanion", "Style.lua"), encoding="utf-8").read()
    vine = re.search(r"local VINE_VERSION = (\d+)", style).group(1)
    control = re.search(r"local CONTROL_VERSION = (\d+)", style).group(1)
    core = r"Interface\\AddOns\\WowCompanion\\Art\\"
    lua.execute("""WC = { Style = {} }
        function WC.Style.Vine(p) return "%sVine-" .. p .. "-%s" end
        function WC.Style.Control(p) return "%sControl-" .. p .. "-%s" end""" % (core, vine, core, control))
    lua.execute(open(os.path.join(ROOT, "addon", "WowCompanion_Agent", "ConvLooks.lua"), encoding="utf-8").read())
    return lua, lua.globals().WC.ConvLooks


def lay(lua, C, key, H, offered):
    out = C.Lay(key, H, offered, OPEN)
    pieces = []
    for i in range(1, len(out.pieces) + 1):
        d = out.pieces[i]
        p = {k: d[k] for k in ("tex", "stone", "shade", "grad", "from", "to", "light", "x", "y", "w", "h", "layer", "sub",
                                 "add", "alpha", "shadow")}
        p["coords"] = None if d.stone or d.grad else C.Coords(d)
        p["i"] = i
        pieces.append(p)
    rows = {}
    for key_ in ("", "l1", "l2", "r1", "r2", "quick"):
        r = out.rows[key_]
        rows[key_] = dict(x=r.x, y=r.y, w=r.w, h=r.h, name=r.name, chord=r.chord)
    offer = [out.offer[i] for i in range(1, 5)] if out.offer else None
    return pieces, rows, offer, dict(bare=out.bare, x0=out.x0, x1=out.x1)


# --- the textures ---------------------------------------------------------------

_tex = {}


def texture(path):
    if path not in _tex:
        rel = path.replace("Interface\\AddOns\\", "addon\\").replace("\\", os.sep) + ".tga"
        img = np.asarray(Image.open(os.path.join(ROOT, rel)).convert("RGBA"), float)
        img[..., :3] *= img[..., 3:4] / 255  # premultiplied
        _tex[path] = img
    return _tex[path]


def resample(img, size):
    """A premultiplied RGBA array resized (LANCZOS each channel)."""
    w, h = max(1, int(round(size[0]))), max(1, int(round(size[1])))
    return np.stack([np.asarray(Image.fromarray(img[..., c].astype(np.float32), "F").resize((w, h), Image.LANCZOS))
                     for c in range(4)], -1)


def drawn(p, ow, oh):
    """The piece as the game draws it: the art at the size it is shown, turned
    and cut by its texcoords, out to its rectangle, ow x oh px."""
    src = texture(p["tex"])
    ulx, uly, llx, lly, urx, ury, lrx, lry = p["coords"]
    # a repeated art (texcoords past 1): the art laid that many times, the coords into it
    rs = int(np.ceil(max(ulx, llx, urx, lrx) - 1e-6))
    rt = int(np.ceil(max(uly, lly, ury, lry) - 1e-6))
    if rs > 1 or rt > 1:
        rs, rt = max(rs, 1), max(rt, 1)
        src = np.tile(src, (rt, rs, 1))
        ulx, llx, urx, lrx = (v / rs for v in (ulx, llx, urx, lrx))
        uly, lly, ury, lry = (v / rt for v in (uly, lly, ury, lry))
    # the whole art's size on screen, so it is filtered once at that scale
    span_s = np.hypot(urx - ulx, ury - uly)  # texcoord length along the drawn width
    span_t = np.hypot(llx - ulx, lly - uly)
    horiz = abs(urx - ulx) >= abs(ury - uly)  # the drawn width runs along the art's width
    full_w = ow / max(span_s, 1e-6)
    full_h = oh / max(span_t, 1e-6)
    sw, sh = (full_w, full_h) if horiz else (full_h, full_w)
    art = resample(src, (sw, sh))
    H_, W_ = art.shape[:2]
    quad = (ulx * W_, uly * H_, llx * W_, lly * H_, lrx * W_, lry * H_, urx * W_, ury * H_)
    size = (max(1, ow), max(1, oh))
    chans = [np.asarray(Image.fromarray(art[..., c].astype(np.float32), "F").transform(size, Image.QUAD, quad,
                                                                                         Image.BILINEAR))
             for c in range(4)]
    return np.stack(chans, -1)


def stone_like(sample, h, w):
    reps = (h // sample.shape[0] + 2, w // sample.shape[1] + 2)
    col = np.concatenate([sample if i % 2 == 0 else sample[::-1] for i in range(reps[0])], 0)
    return np.concatenate([col if j % 2 == 0 else col[:, ::-1] for j in range(reps[1])], 1)[:h, :w].copy()


def composite(dst, rgba, x, y, alpha=1.0, add=False, clip=None):
    x, y = int(round(x)), int(round(y))
    h, w = rgba.shape[:2]
    x0, x1 = clip
    sx0, sx1 = max(x, x0) - x, min(x + w, x1) - x
    if sx1 <= sx0:
        return
    sl = dst[y:y + h, x + sx0:x + sx1]
    src = rgba[:sl.shape[0], sx0:sx1]
    if add:
        sl += src[..., :3] * alpha
    else:
        sl[:] = src[..., :3] * alpha + sl * (1 - src[..., 3:4] / 255 * alpha)


# --- what the game draws: words and glyphs, cut from the shots -------------------

def word_masks():
    """Each name and state word of round 2's rows as an alpha mask (the stone
    under it taken out)."""
    shot = np.asarray(Image.open(WORDS).convert("RGB"), float)
    lum = shot.max(-1)
    out = {}
    names = ["", "l1", "l2", "r1", "r2", "quick"]
    ys = [470, 660, 834, 1016, 1200, 1384]
    for key, y in zip(names, ys):
        out["name:" + key] = cut(lum, 1715, y - 34, 1900, y + 34)
    out["state:495s"] = cut(lum, 1900, 660 - 30, 2035, 660 + 30)
    out["state:95s"] = cut(lum, 1900, 1016 - 30, 2035, 1016 + 30)
    out["state:new"] = cut(lum, 1900, 1200 - 30, 2035, 1200 + 30)
    return out


def cut(lum, x0, y0, x1, y1):
    reg = lum[y0:y1, x0:x1]
    bg = np.median(reg)
    m = reg > bg + 25
    ys, xs = np.nonzero(m)
    by0, by1, bx0, bx1 = ys.min() - 3, ys.max() + 4, xs.min() - 3, xs.max() + 4
    reg = reg[by0:by1, bx0:bx1]
    peak = np.percentile(reg[reg > bg + 25], 90)
    return np.clip((reg - bg) / (peak - bg), 0, 1)


def glyphs():
    """The pad's glyphs as the game drew them in round 4's sockets: each
    unmixed from the socket under it (idle ones were drawn at 0.6)."""
    shot = np.asarray(Image.open(SHOT).convert("RGB"), float)
    boxes = {"talk": (1924, 404, 1978, 458, IDLE_GLYPH), "L1": (1924, 497, 1978, 551, IDLE_GLYPH),
             "L2": (1924, 589, 1978, 643, IDLE_GLYPH), "R2": (1929, 774, 1972, 821, 1.0)}
    out = {}
    for name, (x0, y0, x1, y1, a0) in boxes.items():
        reg = shot[y0:y1, x0:x1]
        edge = np.concatenate([reg[0], reg[-1], reg[:, 0], reg[:, -1]])
        bg = np.median(edge, 0)
        # a lit socket's floor varies more; the talk key is a light pill on the socket's dark floor
        m = reg.max(-1) > 70 if name == "talk" else np.abs(reg - bg).max(-1) > (7 if a0 < 1 else 40)
        m = ndimage.binary_fill_holes(ndimage.binary_closing(m, iterations=2))
        m = ndimage.binary_opening(m, iterations=1)
        lab, n = ndimage.label(m)
        m = lab == 1 + np.argmax(ndimage.sum(m, lab, range(1, n + 1)))  # the key, not a speck of the socket
        ys, xs = np.nonzero(m)
        sl = (slice(ys.min(), ys.max() + 1), slice(xs.min(), xs.max() + 1))
        a = ndimage.gaussian_filter(m.astype(float), 0.6)[sl]
        rgb = np.clip((reg[sl] - (1 - a0) * bg) / a0, 0, 255)
        out[name] = (rgb, a)
    # R1: R2's key, its "2" taken out and L1's "1" set in its place
    rgb, a = (v.copy() for v in out["R2"])
    l1rgb, _ = out["L1"]

    def letters(img):
        lab, n = ndimage.label(img.max(-1) > 150)
        sizes = ndimage.sum(np.ones(lab.shape), lab, range(1, n + 1))
        two = np.argsort(sizes)[-2:] + 1  # the two letters: the biggest bright parts
        boxes = ndimage.find_objects(lab)
        return sorted(((boxes[i - 1], lab == i) for i in two), key=lambda e: e[0][1].start)
    two_box, two = letters(rgb)[-1]
    one_box, one = letters(l1rgb)[-1]
    grown = ndimage.binary_dilation(two, iterations=2)
    rgb[grown] = np.median(rgb[(a > 0.9) & ~grown & (rgb.max(-1) < 70)], 0)
    dy, dx = two_box[0].stop - one_box[0].stop, two_box[1].start - one_box[1].start
    for y, x in zip(*np.nonzero(ndimage.binary_dilation(one, iterations=1))):
        if 0 <= y + dy < rgb.shape[0] and 0 <= x + dx < rgb.shape[1]:
            rgb[y + dy, x + dx] = l1rgb[y, x]
    out["R1"] = (rgb, a)
    return out


def mic():
    """Blizzard's voice chat mic (|A:voicechat-icon-mic:16:16|a) in its shape:
    a capsule in a cradle on a stem and foot, 16 units tall."""
    s = 8
    side = round(16 * PX * s)
    im = Image.new("L", (side, side), 0)
    d = ImageDraw.Draw(im)
    u = side / 16
    d.rounded_rectangle((5.2 * u, 0.6 * u, 10.8 * u, 10 * u), radius=2.6 * u, fill=255)
    d.arc((3.2 * u, 3.4 * u, 12.8 * u, 12.6 * u), 0, 180, fill=255, width=round(1.3 * u))
    d.rectangle((7.35 * u, 12.4 * u, 8.65 * u, 14.6 * u), fill=255)
    d.rounded_rectangle((4.8 * u, 14.2 * u, 11.2 * u, 15.6 * u), radius=0.6 * u, fill=255)
    small = im.resize((side // s, side // s), Image.LANCZOS)
    return np.asarray(small, float) / 255


CHORDS = {"": ["talk"], "l1": ["L1"], "l2": ["L2"], "r1": ["R1"], "r2": ["R2"], "quick": ["L2", "R2"]}


def put_mask(img, mask, colour, x, cy, align="left", alpha=1.0):
    h, w = mask.shape
    x0 = {"left": x, "right": x - w, "centre": x - w / 2}[align]
    rgba = np.zeros((h, w, 4))
    a = mask * 255
    rgba[..., :3] = mask[..., None] * np.array(colour, float)
    rgba[..., 3] = a
    composite(img, rgba, x0, cy - h / 2, alpha, clip=(0, img.shape[1]))


def put_glyph(img, g, cx, cy, alpha):
    rgb, a = g
    rgba = np.concatenate([rgb * a[..., None], a[..., None] * 255], -1)
    composite(img, rgba, cx - a.shape[1] / 2, cy - a.shape[0] / 2, alpha, clip=(0, img.shape[1]))


# --- a look, over the shot -----------------------------------------------------

def well_floor(shot):
    """The shot with the list well's floor bare: its stone, its walls, the pad's pointer gone."""
    img = shot.copy()
    left, top, foot, right = WELL
    sample = shot[BARE[1]:BARE[3], BARE[0]:BARE[2]]
    X = lambda u: left + u * PX  # noqa: E731
    fl = (int(X(FLOOR)), int(top + FLOOR * PX), int(X(W - FLOOR)), int(foot - FLOOR * PX))
    img[fl[1]:fl[3], fl[0]:fl[2]] = stone_like(sample, fl[3] - fl[1], fl[2] - fl[0])
    walls = (int(round(X(4))), int(round(X(W - 4))))
    for x0, x1 in ((int(left), walls[0]), (walls[1], int(right) + 1)):
        band = shot[WALL_BAND[0]:WALL_BAND[1], x0:x1]
        img[int(top) + 40:int(foot) - 40, x0:x1] = np.tile(band, (20, 1, 1))[:int(foot) - 80 - int(top)]
    for y0, y1 in ((int(top), int(round(top + 4 * PX))), (int(round(foot - 4 * PX)), int(foot) + 1)):
        img[y0:y1, walls[0]:walls[1]] = shot[y0:y1, walls[0]:walls[1]]
    # the shot's pointer (by L2): the gutter from further down over it
    img[585:640, 1668:int(left)] = shot[1085:1140, 1668:int(left)]
    return img, sample


def pointer():
    shot = np.asarray(Image.open(WORDS).convert("RGB"), float)
    box = (1676, 452, 1712, 494)
    p = shot[box[1]:box[3], box[0]:box[2]]
    pa = np.clip((p.max(-1) - 40) / 40, 0, 1) * (np.arange(p.shape[1])[None, :] < WELL[0] - box[0] + 4)
    ys, xs = np.nonzero(pa > 0.5)
    tip = (xs.max(), int(np.median(ys[xs >= xs.max() - 2])))
    return p * pa[..., None], pa, tip


def light_ratio():
    core = os.path.join(ROOT, "addon", "WowCompanion", "Art")
    dark = np.asarray(Image.open(os.path.join(core, "Slate-6.tga")).convert("RGB"), float).mean((0, 1))
    lit = np.asarray(Image.open(os.path.join(core, "SlateLight-6.tga")).convert("RGB"), float).mean((0, 1))
    return lit / dark


def mock(lua, C, key, base, sample, words, gl, ptr, offered=False):
    img = base.copy()
    left, top, foot, right = WELL
    H = (foot - top) / PX
    X = lambda u: left + u * PX  # noqa: E731
    Y = lambda u: top + u * PX  # noqa: E731
    pieces, rows, offer, how = lay(lua, C, key, H, offered)
    if how["bare"]:  # the well hidden: the window's own stone (Window.lua's frame.Bg, the dark stone at 0.72)
        x0, x1 = int(round(left)), int(round(right)) + 1
        img[int(top):int(foot) + 1, x0:x1] = stone_like(sample, int(foot) + 1 - int(top), x1 - x0) * 0.72
        clip = (int(round(X(how["x0"]))), int(round(X(how["x1"]))))
    else:
        clip = (int(round(X(4))), int(round(X(W - 4))))  # the walls cover the rest
    ratio = light_ratio()
    pieces.sort(key=lambda p: (LAYERS[p["layer"]], p["sub"], p["i"]))
    for p in pieces:
        # each edge rounded to the pixel, so pieces that meet leave no gap
        x, y = round(X(p["x"])), round(Y(p["y"]))
        w, h = round(X(p["x"] + p["w"])) - x, round(Y(p["y"] + p["h"])) - y
        if w <= 0 or h <= 0:
            continue
        if p["stone"]:
            st = stone_like(sample, h, w) * (ratio if p["stone"] == "claude" else 1) * (p["shade"] or 1)
            composite(img, np.concatenate([st, np.full((h, w, 1), 255.0)], -1), x, y, p["alpha"] or 1, bool(p["add"]),
                      clip=clip)
        elif p["grad"]:  # a colour ramp: from at the bottom (VERTICAL) or the left (HORIZONTAL)
            n = h if p["grad"] == "VERTICAL" else w
            a = np.linspace(p["to"], p["from"], n) if p["grad"] == "VERTICAL" else np.linspace(p["from"], p["to"], n)
            a = a[:, None, None] * np.ones((1, w, 1)) if p["grad"] == "VERTICAL" else a[None, :, None] * np.ones((h, 1, 1))
            c = 255.0 if p["light"] else 0.0
            composite(img, np.concatenate([np.full((h, w, 3), c) * a, a * 255], -1), x, y, 1, bool(p["light"]), clip=clip)
        elif p["shadow"]:  # Blizzard's ShadowOverlay (not in our files): a soft fall-off
            n = h if p["shadow"] == "Top" else w
            t = np.linspace(0, 1, n)
            t = t[:, None, None] * np.ones((1, w, 1)) if p["shadow"] == "Top" else t[None, :, None] * np.ones((h, 1, 1))
            a = (1 - t) ** 2 * 255
            composite(img, np.concatenate([np.zeros((h, w, 3)), a], -1), x, y, p["alpha"] or 1, clip=clip)
        else:
            composite(img, drawn(p, w, h), x, y, p["alpha"] or 1, bool(p["add"]), clip=clip)
    for k, r in rows.items():
        cy = Y(r["y"] + r["h"] / 2)
        lit = k == OPEN
        colour = NAME_LIT if lit else NAME_HL if k == POINTER else NAME
        mask = words["name:" + k]
        mask = np.asarray(Image.fromarray(mask.astype(np.float32), "F").resize(
            (round(mask.shape[1] * NAME_SCALE), round(mask.shape[0] * NAME_SCALE)), Image.LANCZOS)).clip(0, 1)
        put_mask(img, mask, colour, X(r["x"] + r["name"]), cy)
        state = STATES.get(k)
        if state == "mic":
            put_mask(img, mic(), (226, 226, 226), X(r["x"] + r["chord"]), cy, "centre")
        elif state:
            put_mask(img, words["state:" + state], GOOD if state == "new" else GREY, X(r["x"] + r["chord"]), cy, "centre")
        else:
            keys = CHORDS[k]
            for j, g in enumerate(keys):
                cx = r["chord"] + (j - (len(keys) - 1) / 2) * 25  # ConvLooks.lua's GLYPH_STEP
                put_glyph(img, gl[g], X(r["x"] + cx), cy, 1.0 if lit else IDLE_GLYPH)
        if k == POINTER:
            prgb, pa, tip = ptr
            rgba = np.concatenate([prgb, pa[..., None] * 255], -1)
            composite(img, rgba, X(r["x"]) - tip[0], cy - tip[1], clip=(0, img.shape[1]))
    if offer:
        ox, oy, ow, oh = offer
        img[int(Y(oy)):int(Y(oy + oh)), int(X(ox)):int(X(ox + ow))] = (96, 26, 18)
    out = np.clip(img, 0, 255)[CROP[1]:CROP[3], CROP[0]:CROP[2]]
    return Image.fromarray(out.astype(np.uint8))


def main():
    os.makedirs(TMP, exist_ok=True)
    lua, C = looks()
    shot = np.asarray(Image.open(SHOT).convert("RGB"), float)
    base, sample = well_floor(shot)
    words, gl, ptr = word_masks(), glyphs(), pointer()
    order = [C.ORDER[i] for i in range(1, len(C.ORDER) + 1)]
    tiles = []
    for key in order:
        im = mock(lua, C, key, base, sample, words, gl, ptr)
        im.save(os.path.join(TMP, key + ".png"))
        tiles.append((key, im))
        if "--offer" in sys.argv:
            mock(lua, C, key, base, sample, words, gl, ptr, True).save(os.path.join(TMP, key + "-offer.png"))
    tw, th = tiles[0][1].size
    allim = Image.new("RGB", (len(tiles) * (tw + 16), th + 70), (24, 24, 24))
    d = ImageDraw.Draw(allim)
    font = ImageFont.truetype(r"C:\Windows\Fonts\pala.ttf", 44)
    for i, (n, im) in enumerate(tiles):
        allim.paste(im, (i * (tw + 16), 70))
        d.text((i * (tw + 16) + 12, 10), n, font=font, fill=(230, 214, 180))
    allim.save(os.path.join(TMP, "all.png"))
    allim.resize((allim.width // 3, allim.height // 3), Image.LANCZOS).save(os.path.join(TMP, "all-small.png"))


if __name__ == "__main__":
    main()
