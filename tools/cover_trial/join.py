"""The real vine (make_scrollbar_art's raised bark) meeting the thin folded covers 14 and 15."""
import sys, math, numpy as np
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
import wrap as w
from wrap import Scene, mask, lay, erode, dilate, K, H, W, FACE, LIGHT, EDGE, bz, rect
from scipy import ndimage as nd
from PIL import Image, ImageDraw, ImageFont
sb = w.sb
TH, TPAL = sb.WEIGHTS["Thick"]; MH, MPAL = sb.WEIGHTS[""]
SHEET = ((40, 33, 24), (116, 99, 77), (196, 178, 144))
TANG = np.array((96, 74, 50.))
CR = 44  # units of each corner shown
SU = 2.4  # the spine's centre, units in from the top face's edge


def ribbon(a, b, hw): return sb.ribbon([a, b], hw)


def vpieces(path, hw, ends=()):
    out = [ribbon(path[i], path[i + 1], hw) for i in range(len(path) - 1)]
    out += [(p[0], p[1], hw) for p in path[1:-1]] + [(p[0], p[1], hw) for p in ends]
    return out


class J:
    def __init__(s, sc, img, bot): s.sc, s.img, s.bot = sc, img, bot; s.oy = H - CR - 2 if bot else 0

    def gp(s, pieces):
        polys, circ = [], []
        for p in pieces:
            if isinstance(p, tuple): (x, y), = s.sc.g([p[:2]], s.bot); circ.append((x, y, p[2]))
            else: polys.append(s.sc.g(p, s.bot))
        return polys, circ

    def m(s, pieces): return mask(*s.gp(pieces))

    def raised(s, pieces, pal, bevel, cast=0.45, clip=None, gloss=0.35, outline=2.2):
        polys, circ = s.gp(pieces)
        c = sb.Canvas(60 * K, (CR + 2) * K, pad=0, s=2)
        P = lambda x, y: ((x - 20) * K, (y - s.oy) * K)
        m = c.mask([[P(x, y) for x, y in p] for p in polys], circles=[(*P(x, y), r * K) for x, y, r in circ])
        c.metal(m, pal, bevel=bevel * K, outline=outline, shadow=False, sheen=False, paint=True, gloss=gloss, grain=False)
        rgba = c.final(); a = rgba[..., 3] / 255
        sl = (slice(s.oy * K, (s.oy + CR + 2) * K), slice(20 * K, 80 * K))
        cl = s.sc.top[sl] if clip is None else clip[sl]
        a = a * cl
        reg = s.img[sl]
        sh = nd.shift(nd.gaussian_filter(a, K * 0.4), (K * 0.5, K * 0.35), order=1)
        reg = lay(reg, sh * cast * (1 - a), np.zeros(3))
        s.img[sl] = reg * (1 - a[..., None]) + rgba[..., :3] * a[..., None]

    def vine(s, path, hw=TH, pal=TPAL, ends=(), clip=None):
        s.raised(vpieces(path, hw, ends), pal, 0.5 * hw / 0.55, clip=clip)

    def sheet(s, polys, fold=True):
        cover = mask([s.sc.g(p, s.bot) for p in polys]) * s.sc.top
        s.img = s.sc.metal(s.img, cover, cover if fold else None, fold=fold)
        return cover

    def crimp(s, vp, cover, k=0.9):
        """the sheet lifted over the vine under it: a soft ridge lit top-left"""
        vm = s.m(vp)
        h = nd.gaussian_filter(vm, K * 0.55)
        gy, gx = np.gradient(h)
        sh = (gx + gy) / max(1e-6, np.abs(gx + gy).max())
        inner = erode(erode(cover))
        a = inner * np.clip(sh, 0, 1) * k; b = inner * np.clip(-sh, 0, 1) * k
        s.img = lay(s.img, a, LIGHT); s.img = lay(s.img, b * 0.8, EDGE)
        # the gap under the lifted cut edge beside the vine
        edge = np.clip(dilate(dilate(cover)) - cover, 0, 1) * s.sc.top
        ring = nd.gaussian_filter(vm, K * 0.9) * (1 - vm)
        s.img = lay(s.img, edge * np.clip(ring * 2.5, 0, 1) * 0.8, np.array((3, 3, 4.)))

    def sleeve(s, axis, r, extent=None, clip=None):
        """a band of the thin sheet bent round the vine: a half cylinder of radius r about the
        axis (a polyline), cut square by `extent` (local polys; default the whole axis)"""
        ax = s.sc.g(axis, s.bot)
        im = Image.new("L", (W * K, H * K), 0); ImageDraw.Draw(im).line([(x * K, y * K) for x, y in ax], fill=255, width=1)
        d, ind = nd.distance_transform_edt(np.asarray(im) == 0, return_indices=True)
        R = r * K
        hgt = nd.gaussian_filter(np.sqrt(np.clip(R * R - d * d, 0, None)), 1.5)
        gy, gx = np.gradient(hgt)
        n = np.stack([-gx, -gy, np.ones_like(gx)], -1); n /= np.linalg.norm(n, axis=-1, keepdims=True)
        diff = np.clip(n @ sb.LIGHT, 0, 1)
        spec = np.clip(n @ sb.HALF, 0, 1) ** 14 * 0.35
        lo, mid, hi = (np.array(c, float) for c in SHEET)
        k = diff[..., None]; f = 0.6
        col = np.where(k < f, lo + (mid - lo) * k / f, mid + (hi - mid) * (k - f) / (1 - f)) + spec[..., None] * 200
        m = np.clip(r * K - d + 0.5, 0, 1)
        if extent is not None: m = m * mask([s.sc.g(p, s.bot) for p in extent])
        m = m * (s.sc.top if clip is None else clip)
        sh = nd.shift(nd.gaussian_filter(m, K * 0.4), (K * 0.5, K * 0.35), order=1)
        s.img = lay(s.img, sh * 0.4 * (1 - m), np.zeros(3))
        ring = np.clip(m - erode(m), 0, 1)
        s.img = lay(s.img, m, col)
        s.img = lay(s.img, ring * 0.7, EDGE * 0.5)

    def tang(s, polys):
        old = w.FACE; w.FACE = TANG
        m = mask([s.sc.g(p, s.bot) for p in polys]) * s.sc.top
        s.img = s.sc.metal(s.img, m, None, sheen=0.1, contact=0.6)
        w.FACE = old

    def pins(s, pts): s.img = s.sc.rivets(s.img, [s.sc.g([p], s.bot)[0] for p in pts])

    def score(s, pts): s.img = s.sc.score(s.img, s.sc.g(pts, s.bot))


C = []


def c(name, **kw):
    def f(fn): C.append((name, kw, fn)); return fn
    return f


def gusset(tip=(4.6, 21)):
    u, v = tip
    sweep = bz((u, v), (u + 0.4, v * 0.5), (u + 4, 3), (16, 0))
    return [[(0, 0), (16, 0)] + sweep[::-1] + [(0, v)]]


# ---- 14: the gusset
G14 = dict(T=3.0, side="grad")


@c("14 Vine runs on under the gusset; sheet crimped over it", **G14)
def _(j):
    j.vine([(SU, 60), (SU, 1.5)])
    cov = j.sheet(gusset()); j.crimp(vpieces([(SU, 60), (SU, 1.5)], TH), cov)
    j.pins([(8, 4)])


@c("14 The gusset's tip rolled round the vine as a sleeve", **G14)
def _(j):
    j.vine([(SU, 60), (SU, 18)])
    j.sheet(gusset((4.6, 19)))
    j.sleeve([(SU, 15), (SU, 40)], 2.1, extent=[rect(-1, 17.5, 6, 23.5)])
    j.pins([(8, 4)])


@c("14 The gusset's inner edge rolled into a tube; vine runs out of it", **G14)
def _(j):
    path = bz((SU, 26), (SU, 10), (SU + 4, 2.4), (16, 2.0), n=40)
    j.vine([(SU, 60), (SU, 20)])
    plate = [(0, 0), (16, 0), (16, 2.0)] + [tuple(p) for p in path[::-1] if p[1] <= 22.5] + [(0, 22.5)]
    j.sheet([plate])
    j.sleeve([tuple(p) for p in path], 1.95, extent=[rect(-3, -1, 15, 22.5)])
    


@c("14 Vine flattens to a tang, pinned on the gusset", **G14)
def _(j):
    j.vine([(SU, 60), (SU, 24)])
    j.sheet(gusset((2.6, 18)))
    tang = [(SU - TH, 26), (SU + TH, 26), (SU + 2.0, 20), (SU + 2.0, 9)] + w.arc(SU, 9, 2.0, 0, -180, 12)[1:-1] + [(SU - 2.0, 9), (SU - 2.0, 20)]
    j.tang([tang]); j.pins([(SU, 11.5)])


@c("14 Vine under the gusset tip; a saddle clip folded over the edge", **G14)
def _(j):
    j.vine([(SU, 60), (SU, 14)])
    cov = j.sheet(gusset()); j.crimp(vpieces([(SU, 60), (SU, 14)], TH), cov)
    j.sheet([rect(0, 26, 8.2, 29.6)])
    clip = mask([j.sc.g(rect(0, 26, 8.2, 29.6), j.bot)]) * j.sc.top
    j.sleeve([(SU, 20), (SU, 40)], 2.0, extent=[rect(-1, 26, 9, 29.6)], clip=clip)
    j.pins([(6.6, 27.8), (8, 4)])


# ---- 15: the strap
G15 = dict(T=2.0, side="dark")
L15 = [(SU, 60), (SU, SU), (60, SU)]
BAND = [(0, 9), (9, 0), (13, 0), (0, 13)]


@c("15 Vines meet under the strap; strap crimped over both", **G15)
def _(j):
    j.vine(L15); cov = j.sheet([BAND]); j.crimp(vpieces(L15, TH), cov); j.pins([(5.6, 5.6)])


@c("15 Two straps across the vines, crimped, pinned", **G15)
def _(j):
    B2 = [(0, 16.5), (16.5, 0), (19, 0), (0, 19)]
    j.vine(L15)
    for b in (BAND, B2):
        cov = j.sheet([b]); j.crimp(vpieces(L15, TH), cov)
    j.pins([(5.6, 5.6), (8.9, 8.9)])


@c("15 Vines flatten to tangs, mitred under the strap, pinned", **G15)
def _(j):
    j.vine([(SU, 60), (SU, 15)]); j.vine([(15, SU), (60, SU)])
    j.tang([[(SU - TH, 17), (SU + TH, 17), (SU + 2, 13), (SU + 2, SU - 2), (SU - 2, SU - 2), (SU - 2, 13)],
            [(17, SU - TH), (17, SU + TH), (13, SU + 2), (SU - 2, SU + 2), (SU - 2, SU - 2), (13, SU - 2)]])
    j.score([(SU - 2, SU - 2), (SU + 2, SU + 2)])
    j.sheet([BAND]); j.pins([(SU, SU), (5.6, 5.6)])


@c("15 Vine chamfers the corner, the strap rolled round it as a sleeve", **G15)
def _(j):
    a, b = (SU, 10.2), (10.2, SU)
    j.vine([(SU, 60), a, b, (60, SU)])
    j.sheet([[(0, 10.4), (10.4, 0), (14.4, 0), (0, 14.4)]])
    p = np.array(a); q = np.array(b)
    e = (q - p) / np.linalg.norm(q - p); nn = np.array((-e[1], e[0])) * 3
    a0, b0 = p + (q - p) * 0.14, p + (q - p) * 0.86
    j.sleeve([tuple(p - e * 4), tuple(q + e * 4)], 2.0, extent=[[tuple(a0 + nn), tuple(b0 + nn), tuple(b0 - nn), tuple(a0 - nn)]])


@c("15 Strap over the vines, and a clip folded over the spine", **G15)
def _(j):
    j.vine(L15); cov = j.sheet([BAND]); j.crimp(vpieces(L15, TH), cov)
    j.sheet([rect(0, 22, 7.6, 25.4)])
    clip = mask([j.sc.g(rect(0, 22, 7.6, 25.4), j.bot)]) * j.sc.top
    j.sleeve([(SU, 10), (SU, 40)], 2.0, extent=[rect(-1, 22, 9, 25.4)], clip=clip)
    j.pins([(5.6, 5.6), (6.0, 23.7)])


def render(kw, fn):
    sc = Scene(T=kw.get("T", 2.0), side=kw.get("side", "dark"))
    img = sc.backdrop()
    for bot in (False, True):
        j = J(sc, img, bot); fn(j); img = j.img
    im = Image.fromarray(np.clip(img, 0, 255).astype('uint8'))
    k = K; cx0, cx1, sh = 20 * k, 80 * k, CR * k
    top = im.crop((cx0, 0, cx1, sh)); bot = im.crop((cx0, H * k - sh, cx1, H * k))
    out = Image.new("RGB", (cx1 - cx0, 2 * sh + 6)); out.paste(top, (0, 0)); out.paste(bot, (0, sh + 6))
    return out


if __name__ == "__main__":
    only = [int(a) for a in sys.argv[1:]]
    font = ImageFont.truetype("arialbd.ttf", 15)
    TW = 480; th = int(TW * (2 * CR + 0.75) / 60); CAP = 22
    for s in range((len(C) + 3) // 4):
        if only and s + 1 not in only: continue
        out = Image.new("RGB", (2 * TW, 2 * (th + CAP))); d = ImageDraw.Draw(out)
        for i, (name, kw, fn) in enumerate(C[s * 4:s * 4 + 4]):
            x = (i % 2) * TW; y = (i // 2) * (th + CAP)
            out.paste(render(kw, fn).resize((TW - 4, th), Image.LANCZOS), (x + 2, y))
            d.text((x + 6, y + th + 3), "%d %s" % (s * 4 + i + 1, name[:62]), fill=(220, 200, 160), font=font)
        out.save(r"C:\Users\Sean\AppData\Local\Temp\mock\join%d.png" % (s + 1))
    print(len(C))
