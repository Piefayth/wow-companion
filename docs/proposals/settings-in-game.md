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
