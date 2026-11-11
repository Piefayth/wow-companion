"""Property tests for the window's model (addon/WowCompanion_Agent/JobsModel.lua).

    python tools/test_jobs.py [runs] [seed]      (needs `pip install lupa`)

The model runs under Lua 5.1 (LuaJIT, as the game's). A simulated PC plays the
companion's rules (src/jobs.rs, docs/proposals/ledger.md): a clip let go is a
job at once, named to the game by `heard`; clips let go within 1.5 s join;
Whisper takes 0.3-12 s; one request runs per conversation and queued ones run
together; cancels race replies; every conversation line is numbered. The
channel to the game delays (0.3-4 s), reorders and repeats every message; the
strip back to the PC delays and drops commands.

After each random schedule runs to quiet, these must hold:
  1. converged: every job the window knows has the PC's state
  2. nothing still shown as being heard
  3. a cancel hits only its own job: every job the PC cancelled was one you
     cancelled
  4. each numbered line is applied exactly once
"""
import os
import random
import sys

from lupa import luajit21

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL = os.path.join(HERE, "..", "addon", "WowCompanion_Agent", "JobsModel.lua")
RANK = {"hearing": 0, "queued": 1, "running": 2, "answered": 3, "cancelled": 3, "failed": 3}


class Sim:
    def __init__(self, rng):
        self.rng = rng
        self.t = 0.0
        self.events = []
        self.seq = 0
        self.jobs = {}
        self.next_id = 1_000_000
        self.numbers = {}  # slot -> last line number
        self.applied = {}  # (slot, n) -> times applied
        self.asked = set()  # jobs you cancelled
        self.problems = []
        self.lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute("WC = {}")
        model = self.lua.execute(open(MODEL, encoding="utf-8").read())
        sim = self

        def command(verb, slot, ident):
            sim.later(sim.rng.uniform(500, 2000), lambda: sim.pc_command(verb, slot, int(ident)), drop=0.25)

        deps = self.lua.table_from({"now": lambda: sim.t, "wall": lambda: 1.79e12 + sim.t,
                                    "command": command,
                                    "store": self.lua.table(), "lines": self.lua.table(),
                                    "changed": lambda: None})
        self.m = model.new(deps)

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

    # PC -> game: delayed, reordered, sometimes repeated, never lost
    def send(self, msg):
        for _ in range(2 if self.rng.random() < 0.15 else 1):
            self.later(self.rng.uniform(300, 4000), lambda msg=msg: self.game_receive(msg))

    def line(self, slot, **fields):
        self.numbers[slot] = self.numbers.get(slot, 0) + 1
        msg = dict(kind="log", slot=slot, n=self.numbers[slot], **fields)
        self.send(msg)

    def game_receive(self, msg):
        t = self.lua.table_from({k: (self.lua.table_from([self.lua.table_from(e) for e in v]) if k == "list" else v)
                                 for k, v in msg.items()})
        if msg["kind"] == "log" and not self.m.Hold(self.m, msg["slot"], msg["n"]):
            return
        if msg["kind"] == "log":
            key = (msg["slot"], msg["n"])
            self.applied[key] = self.applied.get(key, 0) + 1
        self.m.Apply(self.m, t)

    def new_id(self):
        self.next_id = max(self.next_id + 1, int(self.t))
        return self.next_id

    def speak(self, slot):
        join = [j for j in self.jobs.values() if j["slot"] == slot and j["state"] == "hearing"
                and self.t - j["last"] <= 1500]
        if join:
            job = join[0]
        else:
            jid = self.new_id()
            job = {"id": jid, "slot": slot, "state": "hearing", "clips": 0, "last": self.t}
            self.jobs[jid] = job
            self.send({"kind": "heard", "job": jid, "slot": slot, "state": "hearing"})
        job["clips"] += 1
        job["last"] = self.t
        self.later(self.rng.uniform(300, 12000), lambda: self.words(job))

    def words(self, job):
        job["clips"] -= 1
        if job["state"] != "hearing" or job["clips"] > 0:
            return
        self.later(500, lambda: self.gathered(job))

    def gathered(self, job):
        if job["state"] != "hearing" or job["clips"] > 0:
            return
        running = any(j["state"] == "running" and j["slot"] == job["slot"] for j in self.jobs.values())
        job["state"] = "queued" if running else "running"
        self.line(job["slot"], who="you", job=job["id"], state=job["state"])
        if not running:
            self.start([job])

    def start(self, batch):
        for j in batch:
            j["state"] = "running"
            self.send({"kind": "progress", "slot": j["slot"], "job": j["id"], "state": "running"})
        self.later(self.rng.uniform(2000, 15000), lambda: self.answer(batch[0]["slot"], [j["id"] for j in batch]))

    def answer(self, slot, ids):
        live = [i for i in ids if self.jobs[i]["state"] == "running"]
        for i in live:
            self.jobs[i]["state"] = "answered"
        if live:
            self.line(slot, who="claude", job=live[0], state="answered",
                      list=[{"job": i, "slot": slot, "state": "answered"} for i in live])
        self.next_run(slot)

    def next_run(self, slot):
        queued = [j for j in self.jobs.values() if j["slot"] == slot and j["state"] == "queued"]
        if queued and not any(j["state"] == "running" and j["slot"] == slot for j in self.jobs.values()):
            self.start(sorted(queued, key=lambda j: j["id"]))

    def pc_command(self, verb, slot, ident):
        job = self.jobs.get(ident)
        if verb != "cancel" or not job:
            return
        if RANK[job["state"]] < 3:
            job["state"] = "cancelled"
            job["cancelled"] = True
        self.send({"kind": "stopped", "slot": slot, "list": [{"job": ident, "slot": slot, "state": job["state"]}]})
        self.next_run(slot)

    # the player presses X on something the window shows as live
    def press_cancel(self):
        live = [j for j in self.m.Ordered(self.m).values() if j.state in ("hearing", "queued", "running") and not j.cancel]
        if not live:
            return
        j = self.rng.choice(live)
        self.asked.add(int(j.id))
        self.m.CancelJob(self.m, j.id)

    def check(self):
        p = self.problems
        for jid, job in self.jobs.items():
            g = self.m.Job(self.m, jid)
            if g is not None and g.state != job["state"]:
                p.append(f"1 job {jid}: window {g.state}, PC {job['state']}")
        for slot in ("", "l1"):
            n = len(list(self.m.Hearing(self.m, slot).values()))
            if n:
                p.append(f"2 {n} job(s) still shown as heard in {slot or 'main'}")
        for jid, job in self.jobs.items():
            if job.get("cancelled") and jid not in self.asked:
                p.append(f"3 job {jid} cancelled but never pressed")
        for key, n in self.applied.items():
            if n != 1:
                p.append(f"4 line {key} applied {n} times")
        for slot, top in self.numbers.items():
            for n in range(1, top + 1):
                if (slot, n) not in self.applied:
                    p.append(f"4 line {(slot, n)} never applied")
        return p


def one(seed):
    rng = random.Random(seed)
    s = Sim(rng)
    t = 0.0
    for _ in range(rng.randint(2, 7)):
        t += rng.choice([rng.uniform(300, 1400), rng.uniform(1600, 4000), rng.uniform(4000, 20000)])
        slot = rng.choice(["", "", "l1"])
        s.later(t - s.t, lambda slot=slot: s.speak(slot))
        if rng.random() < 0.5:
            s.later(t - s.t + rng.uniform(100, 6000), s.press_cancel)
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
