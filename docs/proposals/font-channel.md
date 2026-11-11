# PC to game through fonts: the trial (2026-11-11)

**Idea** ([wow-forever-codex](https://github.com/0xinuarashi/wow-forever-codex),
measured by its author on Forever 1.60.1): the game finds only files that existed
at launch, but reads a font's contents at its first load in the process, and
`GetUnboundedStringWidth` reads a glyph's advance exactly. A bank of names made
before launch is a bank of one-shot messages, each name once per game process
(cached through /reload), all reusable after a restart.

**No doorbell needed**: a load uses up the name whether or not it was written,
so the name is the clock: second `t` reads `f<t % BANK>.ttf`, and the PC writes
each second's font a few seconds ahead (same machine, same clock).

## Running now, beside the channel (never a slot, never a bell)

- `WowCompanion_FontTrial` in AddOns: 16,384 names (hard links to 32 blanks,
  4.2 MB), `Trial.lua` reading one font a second until 17:11 today, counting
  ok / blank / errors / noload, load and read times, the largest deviation from
  a whole byte. Results: `WowCompanionFontTrialDB`, at a reload.
- The writer (`tools/fonttrial/fonttrial.py write`, detached): its log, with
  Wow.exe's memory every minute and any name the game held open, is
  `%LOCALAPPDATA%\wow-companion\fonttrial\writer.log`. Memory at the start:
  7.8 GB private.
- With it, the load test: 3,584 load-on-demand folders like the slots'
  (`tools/loadtest.py`), so the launch sees 4,096. Timed by `tools/loadtimes.py`
  from the game's logs; the 512 baseline (launch to login 4.72 s, addons loading
  1.87 s, 1.84 to 1.92, over 26 world loads) is saved in
  `%LOCALAPPDATA%\wow-companion\loadtimes\baseline-512`.

## Measured so far (13:00)

- **Fonts load here.** A name that existed at launch, written after it, loads:
  `SetFont` answers false the first time (the file is loading) and true on
  the next try a moment later, and only for text laid out on screen (alpha 0
  is fine; off screen it never loads). The first trial broke both rules, and its
  fonts had no vertical metrics in OS/2. The widths came back as written:
  '!' to '"' measured 254.44 against 255 steps, at UI scale 0.64.
- **A name made after launch is "file not found"**, as wow-forever-codex found.
- **4,096 folders and 16,384 font names cost the launch nothing measurable**:
  launch to login 4.56 s (4.72 before), addons loading 1.88 s median (1.87).
  The old UI's closing at a reload took 0.86 s (0.43 before), cause unknown yet.
- The old client loaded the new trial addon's folder at a /reload (12:48): a new
  addon folder was found without a restart. Not yet repeated.

## What decides it

1. Do the fonts arrive (ok count, no errors) and how fast is a read?
2. Memory: 3,600 fonts an hour stay cached. A growth that matters ends the idea
   at this rate; reading only while something is expected would not need a font
   a second (the doorbell question again).
3. Launch and load times with 16,384 names and 4,096 folders against the
   baseline. If either costs, launch once more without the other to tell which.

Afterwards: `python -I tools/loadtest.py remove <AddOns>`,
`python tools/fonttrial/fonttrial.py remove <AddOns>`.
