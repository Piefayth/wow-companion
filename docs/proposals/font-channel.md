# PC to game through fonts: the trial (2026-11-11), ended

**Verdict: not a channel for us.** Stopped at 14:40 on the player's word; the
trial's tools are removed. Only the load test below goes on, for one question.

**Idea** ([wow-forever-codex](https://github.com/0xinuarashi/wow-forever-codex),
measured by its author on Forever 1.60.1): the game finds only files that existed
at launch, but reads a font's contents at its first load in the process, and
`GetUnboundedStringWidth` reads a glyph's advance exactly. A bank of names made
before launch is a bank of one-shot messages, each name once per game process
(cached through /reload), all reusable after a restart. The trial named each
second's font by the clock (`f<t % BANK>.ttf`), with no doorbell.

## What it measured

- **Fonts load here.** A name that existed at launch, written after it, loads:
  `SetFont` answers false the first time (the file is loading) and true on the
  next try, and only for text laid out on screen (alpha 0 is fine; off screen it
  never loads). A name made after launch is "file not found".
- **No message arrived whole.** 76 reads by 13:13: every written font came back
  5 or 6 bytes off (deviations up to half a step, at UI scale 0.64), and a blank
  font read as errors throughout. The cause was not found.
- **It cost play nothing felt** (the player): a read spread over about 9 frames
  (64 widths a frame), Wow.exe's memory flat at about 7.8 GB for an hour, no write
  ever refused.
- **Why it could not replace the slots even working:** 512 bytes a font, one a
  second, against a slot of any size taken within 0.1 s; and by the clock a bank
  of 16,384 names lasts 4.5 hours of play, then needs a game restart, where a
  reload refills the slots. With a bell as the doorbell instead of the clock it
  would only add capacity, and more slot folders do that more simply.

## Still running: the load test (one question)

3,584 load-on-demand folders like the slots' (`tools/loadtest.py`), so the launch
sees 4,096. Launch to login took 4.56 s (4.72 with 512), addons loading 1.88 s
(1.87): the launch pays nothing. But **the old UI's closing at a reload took
0.86 s, against 0.43 s before**, with the font trial running too. The next launch,
without the trial, tells whether the folders cost the reload
(`tools/loadtimes.py`, against `%LOCALAPPDATA%\wow-companion\loadtimes\baseline-512`).
If they do not, more slot folders are free and the reload offer becomes rare.
Then: `python -I tools/loadtest.py remove <AddOns>`.

Also seen once (12:48): the running client loaded a new addon folder at a
/reload, where CLAUDE.md says a new folder needs a restart. Worth repeating when
an install next adds a folder; it would change install's "fully restart" message.

The game folder still holds `WowCompanion_FontTrial` (16,384 font names and the
blanks) until the next reload has unloaded its reader (its code is already
deleted), and `WowCompanion_FontTrial.lua` in SavedVariables: both go then.
