# Bridge probe (2026-11-11)

The player approved a probe of two new channels and a timing of the strip, for
their next login. It runs beside today's channel and changes nothing in it
(CLAUDE.md, "Changing the channel"). Each finding is a measurement; nothing is
adopted from this probe alone.

## 1. Game to PC: `C_Log` into `Logs\General.log`

Blizzard's own Lua writes `[N][Lua] <text>` lines there through
`C_Log.LogMessage` (the "Switching to screen=..." lines), and the file is
written during play. If an addon's line reaches the file within milliseconds,
it replaces the strip: no drawing, no screen capture, no flash, no slot.

- **Game (L1):** for the first 60 s after login (once per session, out of
  combat or not), every 2 s: `C_Log.LogMessage("WCPROBE log <seq> <len> <text>")`
  where len cycles through 16, 256, 1024, 4096, 16384 bytes of printable text
  (the line's tail is a known pattern so the PC can check it arrived whole).
  Once each: the same through `LogErrorMessage` and `LogWarningMessage`.
  Record in `WowCompanionDB.bridgeProbe.log` what each call returned and any
  error.
- **PC:** tail General.log (opened for shared reading; the game keeps writing).
  For each `WCPROBE` line: the game's own timestamp at the line's start (local
  wall clock, ms) against the PC's clock when the line was read = the flush
  delay; whether the line came whole; the largest length that arrived; whether
  lines arrive one by one or in batches. A line that never arrives is reported.

## 2. PC to game: a font's letter widths

The game loads fonts from our folder at runtime (Fonts.lua) and measures text
exactly (`FontString:GetStringWidth`). If a font written after launch loads,
its letter widths can carry a message: no slots, no reload, and "does the next
file exist yet" as a doorbell that is not a sound.

- **Folder:** `addon/WowCompanion/Probe/` (installed with the addon, so it exists
  at launch; files appear in it later).
- **PC:** while the game runs, every 15 s writes `Probe\f<n>.ttf` (n = 1, 2...):
  a copy of `Fonts\RobotoCondensed.ttf` (OFL) whose `hmtx` advance widths for
  the 64 glyphs of `A-Z a-z 0-9 + /` are set to known values (a pattern derived
  from n, recorded in `%LOCALAPPDATA%\wow-companion\bridge-probe\f<n>.txt`).
  After writing f<n+1>, tries to delete f<n-1> and records whether the game
  held it open.
- **Game (L1):** every 1 s, tries `SetFont("Interface\\AddOns\\WowCompanion\\Probe\\f<next>.ttf", 64)`
  on a hidden FontString of ours; when it loads, for each of the 64 characters
  `SetText(c)` and `GetStringWidth()`, and records n, the 64 widths, the UI
  scale and the time it first loaded in `WowCompanionDB.bridgeProbe.font`.
  Stops after 5 fonts.
- **After the session:** the PC compares measured widths with written ones:
  exact, proportional (a scale to divide out), or useless; and the load delay.

## 3. Timing the strip as it is

The player feels a hitch at each agent data read. The suspects: drawing up to
~2,600 cells in one frame (Strip.lua), or the PC's screen grab.

- **Game (L1):** `debugprofilestop()` around `WowCompanion_Strip.Send`'s drawing,
  with the cell count, kept in `WowCompanionDB.bridgeProbe.strip` (last 20).
- **PC:** time each `capture()` in src/strip.rs (the 1024x4 look and the full
  grab) and log it.

## What the player does

Log in and play normally; one agent data read (ask something about chat) during
the session; reload once at the end. Nothing to press for the probe.

## Results, and the probe removed (2026-11-11)

1. **`C_Log` reaches `General.log`, but late**: the client flushes it in batches
   (10 to 36 s after the line, apparently when its buffer fills), and cuts a line
   at about 4,070 bytes. Too slow for a channel; kept for what it is good at, the
   Lua errors of our addons read after the fact (src/context.rs).
2. **A font file created after launch never loads**, but that is the filename,
   not the font: the game knows only the names that existed at launch.
   [wow-forever-codex](https://github.com/0xinuarashi/wow-forever-codex) (on
   this client, 1.60.1) writes into a name that existed at launch before its
   first use, and it loads: each name carries one font per game process (cached
   through /reload), reusable after a restart. Not a dead end; untested here.
3. **The strip**: drawing took about 2 ms; the GDI capture took 8 to 287 ms and was
   what made the game stutter, so the capture moved to DXGI Desktop Duplication
   (src/duplication.rs), about 2 ms.

With the results in, the probe's code was removed (PC: src/bridge_probe.rs and
its hooks; game: BridgeProbe.lua and the strip's timing).
