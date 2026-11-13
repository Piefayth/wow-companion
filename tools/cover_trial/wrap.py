"""Thin folded sheet-metal corner covers: flat face, 1px cut edges, a fold over the panel's side face."""
import sys, math, numpy as np
sys.path.insert(0, __import__("os").path.join(__import__("os").path.dirname(__import__("os").path.abspath(__file__)), ".."))
from PIL import Image, ImageDraw, ImageFont, ImageFilter
from scipy import ndimage as nd
import make_scrollbar_art as sb

K = 8; SS = 3                          # output px per unit; supersampling
W, H = 80, 130
x0, y0, x1, y1 = -40, 8, 62, 122       # the panel's outline (top face + side face)
HW = 1.0
FACE = np.array((116, 99, 77.)); LIGHT = np.array((206, 188, 152.)); EDGE = np.array((44, 33, 22.))
rng = np.random.default_rng(3)
L = np.array((-1., -1.)) / math.sqrt(2)  # toward the light, image coords

def stone(col, w, h, k):
    n = Image.fromarray((rng.random((h // 6 + 1, w // 6 + 1)) * 255).astype('uint8')).resize((w, h), Image.BICUBIC).filter(ImageFilter.GaussianBlur(4))
    n = np.asarray(n, float) / 255 - 0.5
    return np.clip(np.array(col, float)[None, None, :] * (1 + k * n[..., None]), 0, 255)

def mask(polys, circles=()):
    im = Image.new("L", (W * K * SS, H * K * SS), 0); d = ImageDraw.Draw(im)
    s = K * SS
    for p in polys: d.polygon([(x * s, y * s) for x, y in p], fill=255)
    for cx, cy, r in circles: d.ellipse([(cx - r) * s, (cy - r) * s, (cx + r) * s, (cy + r) * s], fill=255)
    return np.asarray(im.resize((W * K, H * K), Image.BOX), float) / 255

def shift(a, s):
    o = np.zeros_like(a)
    if s == 0: return a.copy()
    o[s:, s:] = a[:-s, :-s]; return o

def erode(m): return nd.grey_erosion(m, size=3)
def dilate(m): return nd.grey_dilation(m, size=3)

def rrect(a, b, c, d, r):
    """rect with the right two corners rounded by r"""
    if r <= 0: return [(a, b), (c, b), (c, d), (a, d)]
    tr = [(c - r + r * math.cos(t), b + r - r * math.sin(t)) for t in np.linspace(math.pi / 2, 0, 16)]
    br = [(c - r + r * math.cos(t), d - r + r * math.sin(t)) for t in np.linspace(0, math.pi / 2, 16)]
    return [(a, b)] + tr + br + [(a, d)]

def outward_dot(m):
    g = nd.gaussian_filter(m, 1.0); gy, gx = np.gradient(g)
    n = np.hypot(gx, gy) + 1e-9
    return (-gx * L[0] - gy * L[1]) / n      # outward normal . light

def lay(img, a, col):
    a = np.clip(a, 0, 1)[..., None]
    return img * (1 - a) + np.broadcast_to(col, img.shape) * a

class Scene:
    def __init__(s, T=2.0, r=0.0, side="dark"):
        s.T, s.r, s.side = T, r, side
        s.xr, s.yb = x1 - T, y1 - T
        s.top = mask([rrect(x0, y0, s.xr, s.yb, s.r)])
        n = int(round(T * K))
        sw = s.top.copy()
        for i in range(1, n + 1): sw = np.maximum(sw, shift(s.top, i))
        s.out = sw; s.sidem = np.clip(sw - s.top, 0, 1)
        s.n = n
        s.topring = np.clip(s.top - erode(s.top), 0, 1)

    def g(s, pts, bot):
        return [(s.xr - u, (s.yb - v) if bot else (y0 + v)) for u, v in pts]

    def backdrop(s):
        h, w = H * K, W * K
        bg = stone((31, 30, 32), w, h, 0.35); pn = stone((15, 16, 19), w, h, 0.5)
        big = np.pad(s.out, 80 * 2, mode='edge')
        sh = nd.gaussian_filter(big, 9 * 4)[160:-160, 160:-160]
        bg = bg * (1 - 0.6 * sh[..., None])
        img = bg * (1 - s.out[..., None]) + pn * s.out[..., None]
        base = {"dark": 1.15, "mid": 1.6, "arris": 1.4, "grad": 1.9}[s.side]
        d = s.depth(s.top)
        sidecol = pn * (base * (1.1 - 0.35 * d))[..., None]
        img = img * (1 - s.sidem[..., None]) + sidecol * s.sidem[..., None]
        outer = np.clip(s.out - erode(s.out), 0, 1) * s.sidem
        img = lay(img, outer * 0.5, np.array((5, 5, 6.)))
        ring = s.topring * dilate(s.sidem)
        a = {"dark": 0.9, "mid": 0.5, "arris": 1.0, "grad": 0.6}[s.side]
        img = lay(img, ring * a, np.array((48, 48, 54.)))
        return img

    def depth(s, src):
        """fraction along the fold for each side-face pixel swept from src"""
        d = np.ones(src.shape); cov = src > 0.5
        for i in range(1, s.n + 1):
            sh = shift(src, i) > 0.5
            new = sh & (d == 1) & ~cov
            d[new] = i / s.n
        return d

    def flap(s, cover):
        src = cover * s.topring
        f = src.copy()
        for i in range(1, s.n + 1): f = np.maximum(f, shift(src, i))
        return np.clip(f * s.sidem * 1.0, 0, 1), s.depth(src)

    def metal(s, img, m, fold_src=None, sheen=0.14, contact=0.45, fold=True):
        """a thin flat sheet: even face, slight sheen, 1px cut edges, hairline contact, fold over the side face"""
        h, w = m.shape
        yy, xx = np.mgrid[0:h, 0:w].astype(float)
        ys, xs = np.nonzero(m > 0.5)
        if len(xs) == 0: return img
        t = ((xx - xs.min()) + (yy - ys.min())) / max(1, (xs.max() - xs.min()) + (ys.max() - ys.min()))
        grain = nd.gaussian_filter(rng.standard_normal((h, w)), (0.4, 3)) * 0.05
        face = FACE[None, None] * (1 + sheen * (0.5 - t) + grain)[..., None]
        # hairline contact on the panel, only on the sides away from the light
        dot = outward_dot(m)
        ring_out = np.clip(dilate(m) - m, 0, 1) * (1 - s.sidem) * s.top
        img = lay(img, ring_out * contact * np.clip(-dot + 0.2, 0, 1), np.array((4, 4, 5.)))
        if fold_src is not None and fold:
            fl, d = s.flap(fold_src)
            fcol = FACE[None, None] * (0.62 - 0.24 * d)[..., None]
            fcol = np.where((d <= 1.5 / s.n)[..., None], FACE * 0.9, fcol)
            img = lay(img, fl, fcol)
            fr = np.clip(fl - erode(fl), 0, 1) * (1 - dilate(s.top))
            img = lay(img, fr * 0.6, EDGE * 0.6)
        img = lay(img, m, face)
        ring = np.clip(m - erode(m), 0, 1)
        if fold_src is not None:
            fr_ = ring * s.topring * fold_src
            ring = ring * (1 - s.topring * (fold_src > 0.5))
        lit = np.clip(dot, 0, 1); shd = np.clip(-dot, 0, 1)
        img = lay(img, ring * lit * 0.85, LIGHT)
        img = lay(img, ring * shd * 0.7, EDGE)
        if fold_src is not None and fold:
            img = lay(img, s.topring * fold_src * m, LIGHT * 1.0)
        return img

    def rivets(s, img, pts, r=0.55):
        for cx, cy in pts:
            m = mask([], [(cx, cy, r)])
            img = lay(img, m, FACE * 0.9)
            ring = np.clip(m - erode(m), 0, 1); dot = outward_dot(m)
            img = lay(img, ring * np.clip(-dot, 0, 1) * 0.8, EDGE)
            img = lay(img, ring * np.clip(dot, 0, 1) * 0.6, LIGHT)
        return img

    def score(s, img, pts):
        """an incised line: dark groove, a light lip below-right"""
        im = Image.new("L", (W * K, H * K), 0); d = ImageDraw.Draw(im)
        d.line([(x * K, y * K) for x, y in pts], fill=255, width=1)
        a = np.asarray(im, float) / 255
        img = lay(img, shift(a, 1) * 0.45, LIGHT)
        return lay(img, a * 0.75, EDGE * 0.7)

def rodV(v_from, length=60): return [[(0, v_from), (2 * HW, v_from), (2 * HW, length), (0, length)]]
def rodTop(u_from, length=60): return [[(u_from, 0), (length, 0), (length, 2 * HW), (u_from, 2 * HW)]]
def bz(*p, n=30): return [tuple(q) for q in sb.bez(*p, n=n)]
def arc(cx, cy, r, a0, a1, n=24): return [(cx + r * math.cos(math.radians(a)), cy + r * math.sin(math.radians(a))) for a in np.linspace(a0, a1, n)]
def rect(a, b, c, d): return [(a, b), (c, b), (c, d), (a, d)]
def rib(pts, hw): return sb.ribbon(np.array(pts), hw)

C = []
def c(name, **kw):
    def w(fn): C.append((name, kw, fn)); return fn
    return w

# Each concept returns a list of layers in local (u, v) coords:
#   ('rod', polys)                       the divider, lying on the top face
#   ('sheet', polys, holes, fold, merge) a sheet; fold=True wraps the panel edge; merge = rod polys joined into the sheet
#   ('rivets', [(u, v)...]); ('score', pts)

@c("Gusset, narrowing into the rod; folded over, dark side face", T=2.0, side="dark")
def _():
    sweep = bz((2, 24), (2, 12), (6, 3), (18, 0))
    return [('rod', rodV(20)), ('sheet', [[(0, 0), (18, 0)] + sweep[::-1] + [(0, 24)]], [], True, rodV(20, 30))]

@c("Gusset, rod tucked under its cut edge; two flush pins", T=2.5, side="arris")
def _():
    g = [(0, 0), (16, 0), (0, 16)]
    return [('rod', rodV(10)), ('sheet', [g], [], True, None), ('rivets', [(3.2, 3.2), (3.0, 10.5)])]

@c("Collar gusset: a thin band folded round the rod and the edge", T=2.0, side="dark")
def _():
    g = [(0, 0), (14, 0), (0, 14)]
    return [('rod', rodV(10)), ('sheet', [g], [], True, None),
            ('sheet', [rect(-1, 14.6, 3.4, 17.4)], [], True, None)]

@c("Book corner, concave arc; rods slide under both arms", T=2.0, side="mid")
def _():
    cc, R = 18.0, math.sqrt(16 ** 2 + 2.5 ** 2)
    a = math.degrees(math.atan2(2.5 - cc, 16 - cc)); b = math.degrees(math.atan2(16 - cc, 2.5 - cc))
    plate = [(0, 0)] + arc(cc, cc, R, a, b) + [(0, 18)]
    return [('rod', rodV(12) + rodTop(12)), ('sheet', [plate], [], True, None), ('rivets', [(3, 3)])]

@c("Book corner on a rounded panel corner, the sheet following it", T=2.0, side="grad", r=5)
def _():
    cc, R = 18.0, math.sqrt(16 ** 2 + 2.5 ** 2)
    a = math.degrees(math.atan2(2.5 - cc, 16 - cc)); b = math.degrees(math.atan2(16 - cc, 2.5 - cc))
    plate = [(-2, -2)] + arc(cc, cc, R, a, b) + [(-2, 18)]
    return [('rod', rodV(12) + rodTop(12)), ('sheet', [plate], [], True, None)]

@c("Mitred L: thin arms folded over, rods narrowing out of them", T=3.0, side="dark")
def _():
    a = 3.6
    plate = [(0, 0), (19, 0), (19, 2 * HW)] + bz((19, 2 * HW), (16, a), (15, a), (14, a))[1:] + [(a, a), (a, 14)] + bz((a, 14), (a, 15), (a, 16), (2 * HW, 19))[1:] + [(0, 19)]
    return [('rod', rodV(18) + rodTop(18)), ('sheet', [plate], [], True, rodV(18, 26) + rodTop(18, 26)), ('score', [(0.3, 0.3), (a, a)])]

@c("Sleeved L: two folded sleeves, rods running out of them", T=2.0, side="arris")
def _():
    t = 3.4
    return [('rod', rodV(12) + rodTop(12)),
            ('sheet', [rect(0, 0, t, 20), rect(0, 0, 20, t)], [], True, None),
            ('score', [(0, 18.4), (t, 18.4)]), ('score', [(18.4, 0), (18.4, t)])]

@c("Strap corner: straps taper to rod width, one sheet with the rod", T=2.0, side="mid")
def _():
    plate = [(0, 0), (24, 0), (24, 2), (9, 4.4), (4.4, 9), (2, 24), (0, 24)]
    return [('rod', rodV(20)), ('sheet', [plate], [], True, rodV(20, 32))]

@c("Pierced gusset: wire-scroll cut-outs through the sheet", T=2.0, side="dark")
def _():
    sweep = bz((2, 26), (2, 13), (7, 3), (21, 0))
    plate = [(0, 0), (21, 0)] + sweep[::-1] + [(0, 26)]
    s1 = arc(6.0, 6.0, 2.4, 200, 430, 30)
    s2 = bz((3.0, 10.5), (2.8, 13), (3.0, 15.5), (2.9, 17.5))
    s3 = bz((10.5, 3.0), (13, 2.8), (14.5, 2.4), (15.5, 1.9))
    return [('rod', rodV(22)), ('sheet', [plate], [rib(s1, 0.4), rib(s2, 0.32), arc(6.0, 6.0, 0.7, 0, 360, 12)], True, rodV(22, 32))]

@c("Pierced book corner: a scrolled cut, pins at the arms", T=2.5, side="grad")
def _():
    cc, R = 21.0, math.sqrt(19 ** 2 + 3 ** 2)
    a = math.degrees(math.atan2(3 - cc, 19 - cc)); b = math.degrees(math.atan2(19 - cc, 3 - cc))
    plate = [(0, 0)] + arc(cc, cc, R, a, b) + [(0, 21)]
    sc = rib(arc(6.2, 6.2, 2.5, 180, 450, 36), 0.38)
    dot = arc(6.2, 6.2, 0.75, 0, 360, 16)
    return [('rod', rodV(14) + rodTop(14)), ('sheet', [plate], [sc, dot], True, None), ('rivets', [(1.6, 15), (15, 1.6)])]

@c("Square cap, flat, pinned at three corners; rod under its edge", T=1.5, side="dark")
def _():
    s = 12
    return [('rod', rodV(8)), ('sheet', [rect(0, 0, s, s)], [], True, None), ('rivets', [(9.6, 2.4), (2.4, 9.6), (9.6, 9.6)])]

@c("Quarter disc, a scored ring; the rod under its rim", T=2.0, side="arris", r=4)
def _():
    disc = [(-2, -2)] + arc(0, 0, 14, 0, 90) + [(-2, 14)]
    return [('rod', rodV(10)), ('sheet', [disc], [], True, None), ('score', arc(0, 0, 11.6, 3, 87, 30))]

@c("Leaf cap: the rod widens into a leaf, a scored vein", T=2.0, side="mid")
def _():
    out = bz((2, 30), (2, 18), (14, 10), (16, 0))
    plate = [(0, 0)] + out[::-1] + [(0, 30)]
    return [('rod', rodV(24)), ('sheet', [plate], [], True, rodV(24, 34)), ('score', bz((1.4, 24), (1.6, 15), (6, 8), (9, 1.2)))]

@c("Gusset with a deep side face (3 units), flap darkening down it", T=3.0, side="grad")
def _():
    sweep = bz((2, 22), (2.5, 11), (7, 3), (17, 0))
    return [('rod', rodV(18)), ('sheet', [[(0, 0), (17, 0)] + sweep[::-1] + [(0, 22)]], [], True, rodV(18, 28)),
            ('rivets', [(3, 3)])]

@c("Strap folded straight across the corner, rod passing under it", T=2.0, side="dark")
def _():
    band = [(0, 9), (9, 0), (13, 0), (0, 13)]
    return [('rod', rodV(0) + rodTop(0)), ('sheet', [band], [], True, None), ('rivets', [(5.6, 5.6)])]

@c("Thin gusset, no fold: control for the fold's effect", T=2.0, side="dark")
def _():
    sweep = bz((2, 24), (2, 12), (6, 3), (18, 0))
    return [('rod', rodV(20)), ('sheet', [[(0, 0), (18, 0)] + sweep[::-1] + [(0, 24)]], [], False, rodV(20, 30))]


def render(kw, fn):
    sc = Scene(T=kw.get("T", 2.0), r=kw.get("r", 0), side=kw.get("side", "dark"))
    img = sc.backdrop()
    layers = fn()
    for bot in (False, True):
        g = lambda P: [sc.g(p, bot) for p in P]
        for ly in layers:
            if ly[0] == 'rod':
                m = mask(g(ly[1])) * sc.top
                img = sc.metal(img, m, None, sheen=0.0, contact=0.6)
        for ly in layers:
            if ly[0] == 'sheet':
                _, polys, holes, fold, merge = ly
                cover = mask(g(polys)) * sc.top
                if holes: cover = np.clip(cover - mask(g(holes)), 0, 1)
                m = np.clip(cover + (mask(g(merge)) * sc.top if merge else 0), 0, 1)
                img = sc.metal(img, m, cover if fold else None, fold=fold)
            elif ly[0] == 'rivets':
                img = sc.rivets(img, [sc.g([p], bot)[0] for p in ly[1]])
            elif ly[0] == 'score':
                img = sc.score(img, sc.g(ly[1], bot))
    im = Image.fromarray(np.clip(img, 0, 255).astype('uint8'))
    k = K
    cx0, cx1, sh = 20 * k, 80 * k, 38 * k
    top = im.crop((cx0, 0, cx1, sh)); bot = im.crop((cx0, H * k - sh, cx1, H * k))
    out = Image.new("RGB", (cx1 - cx0, 2 * sh + 6), (0, 0, 0)); out.paste(top, (0, 0)); out.paste(bot, (0, sh + 6))
    return out

if __name__ == "__main__":
    only = [int(a) for a in sys.argv[1:]]
    font = ImageFont.truetype("arialbd.ttf", 15)
    tiles = []
    for i, (name, kw, fn) in enumerate(C):
        tiles.append((name, render(kw, fn) if not only or (i // 4 + 1) in only else None))
    TW = 480; th = int(TW * (2 * 38 + 0.75) / 60); CAP = 22
    for s in range((len(tiles) + 3) // 4):
        if only and s + 1 not in only: continue
        out = Image.new("RGB", (2 * TW, 2 * (th + CAP)), (0, 0, 0)); d = ImageDraw.Draw(out)
        for i, (name, im) in enumerate(tiles[s * 4:s * 4 + 4]):
            x = (i % 2) * TW; y = (i // 2) * (th + CAP)
            out.paste(im.resize((TW - 4, th), Image.LANCZOS), (x + 2, y))
            d.text((x + 6, y + th + 3), "%d %s" % (s * 4 + i + 1, name[:60]), fill=(220, 200, 160), font=font)
        out.save(r"C:\Users\Sean\AppData\Local\Temp\mock\wrap%d.png" % (s + 1))
    print(len(C))
