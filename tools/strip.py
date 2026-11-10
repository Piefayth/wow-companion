"""Read the game's data strip (WowCompanion_Strip.Send) off the screen.

Usage:  python -I tools/strip.py            -> prints the payload, or why not
        python -I tools/strip.py --send "lua code that calls WowCompanion_Strip.Send(...)"
            sends the Lua through the companion's channel, waits, then reads.
Layout (see Companion.lua): 4 px cells, 256 per row, rows upward from the
screen's bottom-right corner; cells 0-1 magic, 2 length, 3-4 checksums, then
3 bytes a cell.
"""
import os, struct, subprocess, sys, tempfile, time

CELL, COLS = 4, 256
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ADDONS = r"S:/World of Warcraft/_forever_/Interface/AddOns"


def capture_gdi(height=256, width=CELL * COLS):
    """The corner's pixels, read in this process with GDI (BitBlt), as
    (w, h, BGRA rows top-down). Starting PowerShell and .NET for every look cost
    a second of CPU each, twice a second, and the game stuttered (2026-11-10)."""
    import ctypes
    from ctypes import wintypes as W
    u, g = ctypes.windll.user32, ctypes.windll.gdi32
    u.SetProcessDPIAware()  # real pixels, not 150%-scaled ones
    sw, sh = u.GetSystemMetrics(0), u.GetSystemMetrics(1)
    g.CreateCompatibleBitmap.restype = W.HBITMAP
    g.CreateCompatibleDC.restype = W.HDC
    u.GetDC.restype = W.HDC
    screen = u.GetDC(None)
    mem = g.CreateCompatibleDC(W.HDC(screen))
    bmp = g.CreateCompatibleBitmap(W.HDC(screen), width, height)
    old = g.SelectObject(W.HDC(mem), W.HGDIOBJ(bmp))
    try:
        g.BitBlt(W.HDC(mem), 0, 0, width, height, W.HDC(screen), sw - width, sh - height, 0x00CC0020)
        class BIH(ctypes.Structure):
            _fields_ = [("biSize", W.DWORD), ("biWidth", W.LONG), ("biHeight", W.LONG),
                        ("biPlanes", W.WORD), ("biBitCount", W.WORD), ("biCompression", W.DWORD),
                        ("biSizeImage", W.DWORD), ("biXPelsPerMeter", W.LONG), ("biYPelsPerMeter", W.LONG),
                        ("biClrUsed", W.DWORD), ("biClrImportant", W.DWORD)]
        bih = BIH(ctypes.sizeof(BIH), width, -height, 1, 32, 0, 0, 0, 0, 0, 0)
        buf = ctypes.create_string_buffer(width * height * 4)
        g.GetDIBits(W.HDC(mem), W.HBITMAP(bmp), 0, height, buf, ctypes.byref(bih), 0)
        return width, height, buf.raw
    finally:
        g.SelectObject(W.HDC(mem), W.HGDIOBJ(old))
        g.DeleteObject(W.HGDIOBJ(bmp))
        g.DeleteDC(W.HDC(mem))
        u.ReleaseDC(None, W.HDC(screen))


def capture(height=256):
    try:
        return capture_gdi(height)
    except Exception:
        return capture_ps(height)


def capture_ps(height=256):
    out = os.path.join(tempfile.gettempdir(), "wc_strip.bin")
    subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                    os.path.join(HERE, "strip_capture.ps1"), "-Out", out,
                    "-Width", str(CELL * COLS), "-Height", str(height)], check=True)
    raw = open(out, "rb").read()
    w, h = struct.unpack("<ii", raw[:8])
    return w, h, raw[8:]


def decode(w, h, px):
    stride = w * 4

    def cell(i):
        col, row = i % COLS, i // COLS
        x = col * CELL + CELL // 2
        y = h - 1 - (row * CELL + CELL // 2)
        if y < 0:
            raise ValueError("strip taller than the capture")
        o = y * stride + x * 4
        b, g, r = px[o], px[o + 1], px[o + 2]
        return r, g, b

    m1, m2 = cell(0), cell(1)
    if m1 != (0xC0, 0xFF, 0xEE) or m2 != (0x12, 0x34, 0x56):
        return None, "no strip on screen (corner reads %s %s)" % (m1, m2)
    n = int.from_bytes(bytes(cell(2)), "big")
    want_a = int.from_bytes(bytes(cell(3)), "big")
    want_b = int.from_bytes(bytes(cell(4)), "big")
    out = bytearray()
    for k in range((n + 2) // 3):
        out += bytes(cell(5 + k))
    out = bytes(out[:n])
    a = bsum = 0
    for byte in out:
        a = (a + byte) % 16777216
        bsum = (bsum + a) % 16777216
    if (a, bsum) != (want_a, want_b):
        return None, "checksum mismatch: %d bytes read, sums %s vs %s" % (n, (a, bsum), (want_a, want_b))
    return out, None


def read(height=256, tries=3, wait=0.4):
    err = None
    for _ in range(tries):
        payload, err = decode(*capture(height))
        if payload is not None:
            return payload, None
        time.sleep(wait)
    return None, err


def send_lua(code):
    exe = os.path.join(ROOT, "target", "debug", "wow-companion.exe")
    subprocess.run([exe, "send", ADDONS, "lua", code], check=True,
                   stdout=subprocess.DEVNULL)


def follow_up(slot, out, ok):
    """Wake the conversation that started this watch (the player, 2026-11-10:
    the agent should remind itself, not wait to be asked): a typed request,
    which the running companion takes as if spoken into that slot."""
    import time as _t
    base = os.environ.get("LOCALAPPDATA")
    if not base:
        return
    d = os.path.join(base, "wow-companion", "typed")
    os.makedirs(d, exist_ok=True)
    slot = "" if slot.lower() in ("", "main") else slot.lower()
    what = "arrived" if ok else "failed"
    text = ("(automatic: the data strip you started has %s, in %s. Read it and "
            "finish what was asked; the player has not said anything new.)") % (what, out)
    stamp = int(_t.time() * 1000)
    part = os.path.join(d, "%d.part" % stamp)
    with open(part, "w", encoding="utf-8") as f:
        f.write(slot + "\n" + text + "\n")
    os.replace(part, os.path.join(d, "%d.txt" % stamp))


def watch(seconds, out, then=None):
    """Poll the corner for up to `seconds`; write the payload (or the last
    error) to `out`. Run detached, beside an answer whose lua step draws it.
    With `then` (a conversation: main, l1, l2, r1, r2, quick), that
    conversation is asked to carry on once the result is in."""
    end = time.time() + seconds
    err = "nothing seen"
    while time.time() < end:
        # a look at the bottom row only (1024x4) until the magic shows, then
        # one capture as tall as the strip says it is
        w, h, px = capture(CELL)
        o = (h - 1 - CELL // 2) * w * 4 + (CELL // 2) * 4
        if (px[o + 2], px[o + 1], px[o]) == (0xC0, 0xFF, 0xEE):
            payload, err = decode(*capture())
            if payload is not None and payload.startswith(b"WCCMD "):
                payload, err = None, "a command strip, not ours"
            if payload is not None:
                open(out, "wb").write(payload)
                if then is not None:
                    follow_up(then, out, True)
                return 0
        else:
            err = "nothing seen"
        time.sleep(1.0)
    open(out, "w", encoding="utf-8").write("STRIP FAILED: " + err)
    if then is not None:
        follow_up(then, out, False)
    return 1


def serve():
    """For the running companion: watch the corner for command strips (a line
    starting "WCCMD ", drawn when the player presses Stop in the window) and
    print each new one on stdout. Exits when the companion closes our stdin.
    A look at the bottom row twice a second; a full read only when the strip's
    first row changes."""
    import threading

    def parent_gone():
        try:
            sys.stdin.read()
        finally:
            os._exit(0)

    threading.Thread(target=parent_gone, daemon=True).start()
    seen, last_row = None, None
    while True:
        try:
            w, h, px = capture(CELL)
            o = (h - 1 - CELL // 2) * w * 4 + (CELL // 2) * 4
            if (px[o + 2], px[o + 1], px[o]) == (0xC0, 0xFF, 0xEE):
                row = bytes(px[(h - 1 - CELL // 2) * w * 4:(h - CELL // 2) * w * 4])
                if row != last_row:
                    payload, _ = decode(*capture())
                    if payload is not None:
                        last_row = row
                        if payload.startswith(b"WCCMD ") and payload != seen:
                            seen = payload
                            line = payload.decode("utf-8", "replace").replace("\n", " ")
                            sys.stdout.write(line + "\n")
                            sys.stdout.flush()
            else:
                last_row = None
        except Exception:
            pass
        time.sleep(0.5)


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["--serve"]:
        serve()
    if args[:1] == ["--watch"]:
        then = args[args.index("--then") + 1] if "--then" in args else None
        sys.exit(watch(float(args[1]), args[2], then))
    if args[:1] == ["--send"]:
        send_lua(args[1])
        time.sleep(float(args[2]) if len(args) > 2 else 2.5)
        payload, err = read(tries=12, wait=0.5)
    else:
        payload, err = read()
    if payload is None:
        print("strip: " + err, file=sys.stderr)
        sys.exit(1)
    sys.stdout.buffer.write(payload)
    sys.stdout.write("\n")
