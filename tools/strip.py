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


def capture(height=256):
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


def watch(seconds, out):
    """Poll the corner for up to `seconds`; write the payload (or the last
    error) to `out`. Run detached, beside an answer whose lua step draws it."""
    end = time.time() + seconds
    err = "nothing seen"
    while time.time() < end:
        payload, err = decode(*capture())
        if payload is not None:
            open(out, "wb").write(payload)
            return 0
        time.sleep(0.5)
    open(out, "w", encoding="utf-8").write("STRIP FAILED: " + err)
    return 1


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["--watch"]:
        sys.exit(watch(float(args[1]), args[2]))
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
