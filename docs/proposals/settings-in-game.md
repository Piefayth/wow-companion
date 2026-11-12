# Settings in game, the companion mirrors them

Status: proposal (2026-11-12), not built. The player likes it; the open
question is the complexity and the upkeep.

## Why

The player lives in WoW. The companion (the Rust app) is set up once and then
never looked at. Today the talk button is set in two places that can disagree:
the setup window (`ask=` in settings.toml, read from the pad over HID) and WoW's
Keybindings (`WOWCOMPANION_WINDOW` on the same button, for the tap that opens
the window). The chords live only in the companion's code, and the window's
keys (square, triangle, L3, R3 + chord) only in addon code.

## The rule

**A setting the player changes while playing lives in the game.** The
companion mirrors it. The setup window keeps only what is about the PC and is
set once: the AddOns path, the pad's identity, the models and their files.

## What moves

| setting | today | proposed home |
|---|---|---|
| talk button | settings.toml `ask=`, and WoW's Keybindings | our settings page; the addon writes the WoW binding with `SetBinding` (out of combat) |
| push-to-talk feedback (rumble/beep) | settings.toml `cue`/`feedback` | our settings page |
| speech engine (Whisper/streaming) | settings.toml `speech=` | our settings page |
| microphone | settings.toml `mic=` | our settings page, from a device list the companion sends (a `status`-like message) |
| conversation chords | fixed in crates/voice | unchanged for now; one source if they ever become settings |
| combat loot key | WoW's Keybindings | our settings page, written the same way |

WoW's Keybindings screen keeps only bindings the game itself fires, and our
page writes those, so the player never opens it.

## How the companion learns them

Three paths, all existing machinery:

1. **Live:** a change on the page draws a command strip (as Stop, cancel and
   send-now already do: `WCCMD ...`, read by `src/requests.rs` from the strip
   the companion always watches). A new verb, e.g. `WCCMD <nonce> set talk 9:0x10`.
   The companion applies it at once and writes its own copy.
2. **At reload, logout and exit:** the setting is in the Link addon's saved
   table; the companion already reads the save file when a session begins
   (`session_began` in heartbeat.rs) and takes the settings from it then. This
   catches anything a missed strip lost.
3. **Game closed:** the companion uses its own copy (settings.toml as today), so
   the talk button works before WoW starts.

The game is the truth, settings.toml becomes the companion's cache of it.

## Cost, honestly

- Lua: rows on the settings page (the page and row kinds exist), a strip on
  change, `SetBinding`/`SaveBindings` for the game-fired keys. Small.
- Rust: a `set` verb on the command strip, reading the settings from the save
  at session start, writing settings.toml from them. The mic list needs a
  message to the game listing devices. Moderate: the strip and save readers
  exist; this adds fields to them.
- Setup window: its rows for these settings become read-only ("set in game"),
  or go.
- Upkeep: one more thing the strip carries. The settings themselves get
  simpler (one home each) than today's two.

## Open questions

- A talk-button change has to reach the pad reader live: the voice loop reads
  `ask` at start. It would need to take a new button without a restart.
- First run before the game has ever loaded: the setup window's defaults stand
  until the first save.

## Review (2026-11-12, the Rust side)

I agree with the rule, and the Rust side is small with the changes below. One
question the proposal leaves out decides the talk button.

**The decision for the player: how a WoW button name maps to a pad bit.** The
game knows the talk button as a WoW name (`PADSOCIAL`); the companion reads an
HID byte and mask (`9:0x10`, crates/pad). Mirroring `set talk PADSOCIAL` needs a
map from one to the other. The two vocabularies are what let the two homes
disagree.

Proposed way, not yet chosen by the player. The player asked for a robust version
of naming by WoW's names and Main proposed this (2026-11-12):
the companion keeps reading raw HID and names buttons the way WoW does, from
data instead of hand tables. WoW's raw order in `WTF/GamePadConfig_Default.json`
is SDL's (raw 4 Back = `PADSOCIAL`, 5 Guide = `PADSYSTEM`, 15 misc = `PAD5`,
16-19 the paddles), and SDL names buttons from `gamecontrollerdb.txt`.

1. **Buttons from the pad's HID report descriptor**: the Button page's usages
   in order are SDL's `b0..bN` on Windows. This is also the pad-learn fix (no
   baseline diff, so byte 31's counter is never taken for a button).
2. **Names from SDL's `gamecontrollerdb.txt`, shipped as a file** (2,295 lines,
   community kept), looked up by vid:pid: `back:b8` is `PADSOCIAL`,
   `guide:b12` `PADSYSTEM`. No SDL at runtime, so nothing else opens the pad
   while WoW has it.
3. **Checked against the measured bits:** the database has both the DualSense
   (054c:0ce6) and the Edge (054c:0df2), and its `b0..b14` are the bits crates/pad
   measured, in order: Square..Triangle byte 8 0x10..0x80 (`b0..b3`), L1..R3
   byte 9 0x01..0x80 (`b4..b11`, Create `b8`, Options `b9`), PS, touchpad and mute
   byte 10 0x01..0x04 (`b12..b14`). So the player's pad needs no hand table.

What stays hand-made, each fixed by its maker: XInput (Microsoft's 16-bit button
word, already in `xinput::NAMES`), the Edge's extras (the database lists no
paddles; WoW's `PADPADDLE1-4` come from SDL's own DualSense driver; Fn and the
back buttons are in byte 10 above 0x04, only `Edge_R_Fn` 0x20 measured), and the
triggers (the database maps them as axes `a3`/`a4`, while the companion reads
the descriptor's digital buttons `b6`/`b7`). A pad that is in neither the
database nor these tables is named by an exact pairing: the row says "hold the
button", the game draws `WCCMD n learn talk PADxxx` while it is held, and the
companion takes the one button held when it reads the strip.

On the game side, the binding itself is the truth: the row reads
`GetBindingKey("WOWCOMPANION_WINDOW")` and writes it with `SetBinding`, with no
copy in `WowCompanionLinkDB` to drift from the Keybindings screen. (On
2026-11-11 the binding was simply empty after 5834a61, and minus did nothing.)
The row is one `WC.SettingsPage.Add` call (addon/WowCompanion/SettingsPage.lua).

**A change applies by restart, not live.** `talk`, `feedback`, `speech` and `mic`
are all read once at the top of `voice::listen()`. Applying one = write
settings.toml (`Settings::set` + `save`) + the existing handover (restart.rs):
the new copy opens the mic and loads the engine while the old one serves, so the
headset link never drops and no press is handled twice. One path for all four
and no change to the voice loop; an engine or mic switch needs a reload or a
reopen anyway. This closes the open question. Costs: a few seconds of model load,
a wait for `lifecycle::idle()` (a long request delays it), and it moves onto
whatever `SOURCE_EXE` is (the same build for players, target/debug for us).

**One path, not three.** Path 2 (the save read at session start) goes; the loop
closes instead. The companion's `status` message (heartbeat.rs, sent on a change
and after a reload) carries the settings it runs with; the page shows those and
redraws `WCCMD n set <key> <value>` while the game's value differs. That covers a
missed strip, a companion that was off, and the first start after a change, and
shows the player when a change has taken. `set` carries a value, never a toggle;
the nonce gets it past strip.rs's same-payload dedupe.

**The mic list on demand.** Opening the mic row draws `WCCMD n mics`; the
companion answers with one message from `voice::microphones()`. No polling, and no
list sent at a reload that a headset connecting later would make stale. `status`
also says which engines are installed (streaming only with `stream_model`
downloaded).

**The setup window loses the moved rows** rather than showing them read-only: a
second writer of these keys is what clobbered settings.toml on 2026-11-11 at
20:39 (95bafad). First run uses defaults (`default_talk`, the default input,
rumble, the engine that is downloaded). It keeps the AddOns path, the pad, the
models and its mic test.

So the Rust work is a `set` verb in `requests.rs` `watch_commands` (check the
value, write the file, request a restart), `status` carrying the applied values,
and a `mics` verb: tens of lines each, on existing machinery. Since this changes
how the game reaches the PC, check before moving the rows that a `set` drawn
while a Stop or cancel strip is pending queues behind it rather than replacing
it (the strip shows one payload at a time).
