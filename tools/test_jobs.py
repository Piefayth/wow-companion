"""Property tests for the window's model (addon/WowCompanion/JobsModel.lua).

    python tools/test_jobs.py [runs] [seed]      (needs `pip install lupa`)

The model runs under Lua 5.1 (LuaJIT, as the game's). A simulated PC plays
the companion's rules (src/jobs.rs): clips join within 1.5 s, Whisper takes
0.3-12 s, one request runs per conversation and queued ones run together,
cancels race replies. The channel to the game delays (0.3-4 s), reorders and
repeats every message; the strip back to the PC delays and drops commands.
The game's clock is off the PC's by up to +-3 s (2.3 s measured 2026-11-10).

After each random schedule runs to quiet, these must hold:
  1. converged: every job the window knows has the PC's state
  2. no stuck prediction: no clip is still shown as being heard
  3. a cancel hits its own clip: every job the PC cancelled was one you
     cancelled, and every clip you cancelled in time was cancelled
  4. hidden only when cancelled: words are hidden only for a clip you cancelled
  5. shown once: each of your messages is shown exactly once
"""
import random
import sys
import os

from lupa import luajit21

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL = os.path.join(HERE, "..", "addon", "WowCompanion", "JobsModel.lua")
RANK = {"hearing": 0, "queued": 1, "running": 2, "answered": 3, "cancelled": 3, "failed": 3}


class Sim:
    def __init__(self, rng):
        self.rng = rng
        self.t = 0.0  # PC clock, ms
        self.skew = rng.uniform(-3000, 3000)  # game clock = pc - skew
        self.events = []  # (time, seq, fn)
        self.seq = 0
        self.jobs = {}  # id -> dict(slot, state, released, clips, cancelled_by)
        self.next_id = 1_000_000
        self.shown = {}  # job -> "text" | "hidden" | "tombstone" (count in shown_count)
        self.shown_count = {}
        self.cancelled_clips = []  # (slot, game release) you cancelled
        self.clip_job = {}  # game release -> pc job id
        self.problems = []
        self.lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute("WC = {}")
        model = self.lua.execute(open(MODEL, encoding="utf-8").read())
        sim = self

        def now():
            return sim.t - sim.skew

        def command(verb, slot, ident):
            sim.later(sim.rng.uniform(500, 2000), lambda: sim.pc_command(verb, slot, ident), drop=0.25)

        def remember(text, slot, job, who=None):
            if job is not None:
                sim.show(int(job), "tombstone")

        deps = self.lua.table_from({"now": now, "command": command, "remember": remember,
                                    "store": self.lua.table(), "changed": lambda: None})
        self.m = model.new(deps)

    # scheduling
    def later(self, delay, fn, drop=0.0):
        if self.rng.random() < drop:
            return
        self.seq += 1
        self.events.append((self.t + delay, self.seq, fn))

    def run(self, until):
        while True:
            self.events.sort()
            if not self.events or self.events[0][0] > until:
                break
            t, _, fn = self.events.pop(0)
            self.t = max(self.t, t)
            fn()
        self.t = until

    def show(self, job, how):
        self.shown_count[job] = self.shown_count.get(job, 0) + 1
        self.shown[job] = how

    # PC -> game: delayed, reordered, sometimes repeated, never lost
    def send(self, inbox):
        for _ in range(2 if self.rng.random() < 0.15 else 1):
            self.later(self.rng.uniform(300, 4000), lambda inbox=inbox: self.game_receive(inbox))

    def game_receive(self, inbox):
        t = self.lua.table_from({k: (self.lua.table_from([self.lua.table_from(e) for e in v]) if k == "list" else v)
                                 for k, v in inbox.items()})
        kind = inbox["kind"]
        if kind == "log" and inbox.get("who") == "you":
            verdict = self.m.Claim(self.m, t, inbox["slot"])
            if verdict != "dup":
                self.show(inbox["job"], "hidden" if verdict == "hidden" else "text")
            self.m.Apply(self.m, t)
        elif kind == "stopped":
            self.m.Stopped(self.m, t)
        else:
            self.m.Apply(self.m, t)

    # the PC (src/jobs.rs, src/requests.rs, src/main.rs)
    def new_id(self):
        self.next_id = max(self.next_id + 1, int(self.t))
        return self.next_id

    def speak(self, slot):
        release = self.t
        self.m.Released(self.m, slot)
        joinable = [j for j in self.jobs.values() if j["slot"] == slot and j["state"] == "hearing"
                    and release - j["last"] <= 1500]
        if joinable:
            job = joinable[0]
        else:
            jid = self.new_id()
            job = {"id": jid, "slot": slot, "state": "hearing", "released": release, "clips": 0, "words": False}
            self.jobs[jid] = job
        job["clips"] += 1
        job["last"] = release
        self.clip_job[release - self.skew] = job["id"]
        self.later(self.rng.uniform(300, 12000), lambda: self.words(job))

    def words(self, job):
        job["clips"] -= 1
        if job["state"] != "hearing":
            return
        job["words"] = True
        if job["clips"] == 0:
            self.later(500, lambda: self.gathered(job))

    def gathered(self, job):
        if job["state"] != "hearing" or job["clips"] > 0:
            return
        running = any(j["state"] == "running" and j["slot"] == job["slot"] for j in self.jobs.values())
        job["state"] = "queued" if running else "running"
        self.send({"kind": "log", "who": "you", "slot": job["slot"], "job": job["id"], "state": job["state"]})
        if not running:
            self.start([job])

    def start(self, batch):
        for j in batch:
            j["state"] = "running"
            self.send({"kind": "progress", "slot": j["slot"], "job": j["id"], "state": "running"})
        lead = batch[0]
        self.later(self.rng.uniform(2000, 15000), lambda: self.answer(lead["slot"], [j["id"] for j in batch]))

    def answer(self, slot, ids):
        live = [i for i in ids if self.jobs[i]["state"] == "running"]
        for i in live:
            self.jobs[i]["state"] = "answered"
        if live:
            self.send({"kind": "log", "who": "claude", "slot": slot, "job": live[0], "state": "answered",
                       "list": [{"job": i, "slot": slot, "state": "answered"} for i in live]})
        queued = [j for j in self.jobs.values() if j["slot"] == slot and j["state"] == "queued"]
        if queued and not any(j["state"] == "running" and j["slot"] == slot for j in self.jobs.values()):
            self.start(sorted(queued, key=lambda j: j["id"]))

    def pc_command(self, verb, slot, ident):
        ident = float(ident)
        if verb == "hear":
            near = [j for j in self.jobs.values() if j["slot"] == slot and abs(j["released"] - ident) <= 5000]
            near.sort(key=lambda j: abs(j["released"] - ident))
            if not near:
                self.send({"kind": "stopped", "slot": slot, "hearing": True, "nothing": True, "list": []})
                return
            job = near[0]
            if RANK[job["state"]] < 3:
                job["state"] = "cancelled"
                job["cancelled_by"] = "hear"
            self.send({"kind": "stopped", "slot": slot, "hearing": True,
                       "list": [{"job": job["id"], "slot": slot, "state": job["state"]}]})
        elif verb == "cancel":
            job = self.jobs.get(int(ident))
            if job and RANK[job["state"]] < 3:
                job["state"] = "cancelled"
                job["cancelled_by"] = "cancel"
            if job:
                self.send({"kind": "stopped", "slot": slot,
                           "list": [{"job": job["id"], "slot": slot, "state": job["state"]}]})
            if job and job["state"] == "cancelled":
                queued = [j for j in self.jobs.values() if j["slot"] == slot and j["state"] == "queued"]
                if queued and not any(j["state"] == "running" and j["slot"] == slot for j in self.jobs.values()):
                    self.start(sorted(queued, key=lambda j: j["id"]))

    # the player
    def cancel_clip(self, slot):
        c = self.m.CancelClip(self.m, slot)
        if c:
            self.cancelled_clips.append((slot, c.release))

    def check(self):
        p = self.problems
        for jid, job in self.jobs.items():
            g = self.m.Job(self.m, jid)
            if g is not None and job["state"] != "hearing" and g.state != job["state"]:
                p.append(f"1 job {jid}: window {g.state}, PC {job['state']}")
        for slot in ("", "l1"):
            n = len(list(self.m.Clips(self.m, slot).values()))
            if n:
                p.append(f"2 {n} clip(s) still shown as heard in {slot or 'main'}")
        meant = {self.clip_job.get(r) for _, r in self.cancelled_clips}
        for jid, job in self.jobs.items():
            if job.get("cancelled_by") == "hear" and jid not in meant:
                p.append(f"3 job {jid} cancelled by a hearing cancel meant for another clip")
        for jid, how in self.shown.items():
            if how == "hidden" and jid not in meant:
                p.append(f"4 job {jid} hidden but its clip was not cancelled")
        for jid, n in self.shown_count.items():
            if n > 1:
                p.append(f"5 job {jid} shown {n} times")
        return p


def one(seed):
    rng = random.Random(seed)
    s = Sim(rng)
    # the window has used this clock before (the offset is kept in the save file)
    if rng.random() < 0.7:
        s.m.offset = s.skew
    t = 0.0
    for _ in range(rng.randint(2, 7)):
        t += rng.choice([rng.uniform(1600, 4000), rng.uniform(4000, 20000)])
        slot = rng.choice(["", "", "l1"])
        s.later(t - s.t, lambda slot=slot: s.speak(slot))
        if rng.random() < 0.4:
            s.later(t - s.t + rng.uniform(100, 3000), lambda slot=slot: s.cancel_clip(slot))
    step = 0.0
    while step < t + 90000:
        step += 200
        s.run(step)
        s.m.Tick(s.m)
    return s.check()


def main():
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 500
    base = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    failed = 0
    for seed in range(base, base + runs):
        problems = one(seed)
        if problems:
            failed += 1
            if failed <= 8:
                print(f"seed {seed}:")
                for line in problems:
                    print("   ", line)
    print(f"{runs - failed}/{runs} schedules held every invariant")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
