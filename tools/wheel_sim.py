"""Simulates our radial wheel's pick (addon/WowCompanion_Wheel/Wheel.lua).

The secure code learns the right stick only as four keys, each on while its
axis is past 0.5, plus a snapshot of the stick (GetGamePadState) read when a
key changes. This plays thumb gestures (flicks out from the centre, sweeps along
the rim, releases that spring back) through that model, runs each pick rule on
the events alone, and scores it against eight equal slices of where the thumb
was aimed when it let go.

The snapshot is not taken at the crossing but some milliseconds after: the
player's releases read at 0.0-0.5 (most 0.0) although the key let go at 0.5, so
a snapshot here is the stick at a delay after the edge, with some jitter.

    python -I tools/wheel_sim.py [gestures]
"""

import math
import random
import sys

FRAME = 1 / 120
THRESHOLD = 0.5
KEYS = ("UP", "DOWN", "LEFT", "RIGHT")
SLOTS = [(math.cos(math.radians(90 - 45 * i)), math.sin(math.radians(90 - 45 * i))) for i in range(8)]


def slice_of(angle_deg):
    """Slot 0..7 clockwise from up, equal 45-degree slices."""
    return int(((90 - angle_deg) % 360 + 22.5) // 45) % 8


def keys_of(x, y):
    return {"UP": y > THRESHOLD, "DOWN": y < -THRESHOLD, "LEFT": x < -THRESHOLD, "RIGHT": x > THRESHOLD}


# ---- gestures: a path is a function of time -> (x, y), and the aimed angle

def ease(u):
    u = min(max(u, 0.0), 1.0)
    return u * u * (3 - 2 * u)


def gesture(rng, kind):
    a0 = rng.uniform(0, 360)
    t_out = rng.uniform(0.025, 0.07)
    bend = rng.gauss(0, 8)  # a flick starts off its line and comes onto it
    rim = rng.uniform(0.92, 1.0)
    hold = rng.uniform(0.12, 0.4)
    if kind == "flick":
        a1, t_sweep = a0, 0.0
    else:  # a sweep along the rim to a neighbour, or further
        a1 = a0 + rng.choice((-1, 1)) * rng.uniform(20, 100)
        t_sweep = rng.uniform(0.12, 0.35)
    t_in = rng.uniform(0.010, 0.025)
    drift = rng.gauss(0, 10)  # a spring back is not quite straight
    t1 = t_out + hold / 2
    t2 = t1 + t_sweep
    t3 = t2 + hold / 2
    end = t3 + t_in

    def at(t):
        if t < t_out:
            u = ease(t / t_out)
            r, a = rim * u, a0 + bend * (1 - u)
        elif t < t1:
            r, a = rim, a0
        elif t < t2:
            r, a = rim, a0 + (a1 - a0) * ease((t - t1) / t_sweep)
        elif t < t3:
            r, a = rim, a1
        elif t < end:
            u = (t - t3) / t_in
            r, a = rim * (1 - u), a1 + drift * u
        else:
            r, a = 0.0, a1
        return r * math.cos(math.radians(a)), r * math.sin(math.radians(a))

    return at, a1 % 360, end + 0.05


def events(rng, at, length, delay):
    """The key edges the game delivers, each with its snapshot of the stick."""
    out, held, t = [], keys_of(0, 0), 0.0
    while t < length:
        t += FRAME
        now = keys_of(*at(t))
        changed = [k for k in KEYS if now[k] != held[k]]
        rng.shuffle(changed)
        for k in changed:
            s = at(t + max(0.0, delay + rng.uniform(-0.003, 0.003)))
            out.append((k, now[k], s))
        held = now
    return out


# ---- the pick rules, on events alone

def key_pick(held):
    dx = (1 if held["RIGHT"] else 0) - (1 if held["LEFT"] else 0)
    dy = (1 if held["UP"] else 0) - (1 if held["DOWN"] else 0)
    if dx == 0 and dy == 0:
        return None
    return max(range(8), key=lambda i: dx * SLOTS[i][0] + dy * SLOTS[i][1])


def angle_pick(s):
    return slice_of(math.degrees(math.atan2(s[1], s[0])))


def run(rule, evs):
    held = dict.fromkeys(KEYS, False)
    sticky = None
    for k, down, s in evs:
        before = any(held.values())
        held[k] = down
        sticky, used = rule(held, k, down, s, sticky, before)
        if used is not None:
            return used
    return None


def current(held, k, down, s, sticky, before):
    pick = key_pick(held)
    if down:
        return pick, None
    if pick is not None:
        return (pick if math.hypot(*s) >= 0.5 else sticky), None
    return sticky, sticky


def every_edge_angle(held, k, down, s, sticky, before):
    sticky, used = current(held, k, down, s, sticky, before)
    if used is None and any(held.values()) and math.hypot(*s) >= 0.5:
        sticky = angle_pick(s)
    return sticky, used


def flick_angle(held, k, down, s, sticky, before):
    """The first key out of the centre takes the angle; the rim keeps keys."""
    if down and not before and math.hypot(*s) >= 0.3:
        return angle_pick(s), None
    return current(held, k, down, s, sticky, before)


def flick_and_release(held, k, down, s, sticky, before):
    sticky, used = flick_angle(held, k, down, s, sticky, before)
    if used is not None and 0.1 <= math.hypot(*s) < 0.5:
        used = angle_pick(s)
    return sticky, used


RULES = {"now (keys)": current, "angle at every edge": every_edge_angle,
         "flick takes angle": flick_angle, "flick + release angle": flick_and_release}


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
    rng = random.Random(1)
    for delay in (0.003, 0.008, 0.014):
        print(f"snapshot {delay * 1000:.0f} ms after the edge")
        for kind in ("flick", "sweep"):
            score = dict.fromkeys(RULES, 0)
            near = dict.fromkeys(RULES, 0)
            n_near = 0
            for _ in range(n):
                at, aimed, length = gesture(rng, kind)
                evs = events(rng, at, length, delay)
                want = slice_of(aimed)
                edge = abs(((90 - aimed) % 45) - 22.5) < 7.5  # within 7.5 of a slice line
                n_near += edge
                for name, rule in RULES.items():
                    ok = run(rule, evs) == want
                    score[name] += ok
                    near[name] += ok and edge
            for name in RULES:
                print(f"  {kind:5} {name:22} {100 * score[name] / n:5.1f}%"
                      f"   near a line {100 * near[name] / max(1, n_near):5.1f}%")


if __name__ == "__main__":
    main()
