# Settings in game: the companion holds them, our page edits them

Status: agreed with the player (2026-11-12), not built.

## Why

The player lives in WoW. The companion (the Rust app) is set up once and then
never looked at. Today the talk button is set in two places that can disagree:
the setup window (`ask=` in settings.toml, read from the pad over HID) and WoW's
Keybindings (`WOWCOMPANION_WINDOW` on the same button, for the tap that opens
the window). On 2026-11-11 the WoW half was simply empty after 5834a61 and minus
did nothing in game. The conversation chords live only in the companion's code.

## The rule

**The companion is the one truth for its settings; our settings page in WoW is
where the player sees and changes them; WoW's own binding is a copy we write.**
The game keeps no copy of its own, so nothing is reconciled.

Why the companion and not the game: the companion must react to the talk button
at once and anywhere (loading screens, character select, alt-tabbed), so it
needs the button's bit over HID. The game can reach the PC only by a screen read
(the strip) or a reload. Truth in the game would mean a screen read per request
or a name-to-bit database; truth in the companion needs neither.

## Buttons: set by pressing, stored as both names

A button is set in its row on our page by pressing it, as in any game's key
settings. One press gives both halves: the game sees WoW's name (`PADSOCIAL`),
the companion sees the bit. The companion stores them together:
`talk = 9:0x10 PADSOCIAL`. No side ever works out one from the other.

1. Confirming the row draws `WCCMD <nonce> bind <key> start`; the companion
   reads it and collects the buttons that go down from then on.
2. The press makes the game draw `WCCMD <nonce> bind <key> PADxxx`; the
   companion takes the one button that went down between the two strips.
   Exactly one: stored. None or several: `status` says so and the row asks again.
3. Refused in the row: buttons the game hard-wires (`PADBACK` Focus UI,
   `PADFORWARD` the game menu) and a button another companion key already has.
   The talk button's press always reaches the game too (we cannot swallow it).

This needs the pad layer to know which bits are buttons: the pad's HID report
descriptor where it describes the report, and the two fixed layouts we read
anyway (the DualSense, whose Bluetooth report 0x31 is undescribed, and XInput).
That is also the pad-learn fix (no baseline diff, so byte 31's counter is never
taken for a button). No database of names anywhere.

Keys: `talk`, and the conversation chords `l1`, `l2`, `r1`, `r2` (Quick is L2+R2,
dictation L1+R1, from the same keys). Defaults come from the two layouts we
know: minus (Guide on XInput) and the shoulders and triggers, each with its WoW
name. Another pad starts with them unset: Main works by our page and the
minimap mark until talk is pressed in its row.

## WoW's binding is a copy

Our addon writes WoW's binding for the tap from the companion's `talk` at every
login and after a change (out of combat; `WC.AfterCombat` otherwise). It is not
declared in a Bindings.xml, so it is not in WoW's Keybindings screen: a change
made there would come with no press for the companion to see. If WoW loses it,
the next login puts it back. This changes the rule "our keys are addon
keybindings in WoW's Keybindings screen" for the companion's keys; CLAUDE.md
says so when this is built. The window's other keys and the combat loot key stay
addon keybindings.

## Other settings

Feedback (rumble/beep), the speech engine and the mic work the same way: the
companion holds them in settings.toml, the page shows the values `status`
reports and edits them with `WCCMD <nonce> set <key> <value>`. The row shows
"applying" until a `status` carries the new value. `set` carries a value, never
a toggle.

- **Applying is a restart.** `voice::listen()` reads all of these once at its
  start. A change writes settings.toml (`Settings::set`, `save`) and asks for the
  existing handover (restart.rs): the new copy opens the mic and loads the engine
  while the old one serves, so the headset link never drops and no press is
  handled twice. Costs: a few seconds of model load, a wait for
  `lifecycle::idle()`, and it moves onto whatever `SOURCE_EXE` is now (the same
  build for players, target/debug for us).
- **The mic list on demand:** opening the mic row draws `WCCMD <nonce> mics`;
  the companion answers with one message from `voice::microphones()`. `status`
  says which engines are installed (streaming only with `stream_model`).
- **The setup window loses these rows** (and its button learning): a second
  writer of these keys is what clobbered settings.toml on 2026-11-11 at 20:39
  (95bafad). It keeps the AddOns path, the pad, the models and its mic test.
  First run uses the defaults above, the default input, rumble and the engine
  that is downloaded.

## The talking indicator

The game draws its own preview of the conversation while the talk button is
held, by the same rule as the companion (last trigger pulled; L2+R2 Quick; L1+R1
dictation) on the chord keys' WoW names from `status`. Two readers of one pad
can differ only when triggers change within a frame of each other; the clip's
`heard` names the conversation it went to when it is let go. The rule is written
once in Lua: today it is in Agent.lua (last pulled) and again in Pad.lua's
`WowCompanion_PadSlot` (a fixed order, used by Offer.lua and ChatWheel.lua),
which can disagree with each other and with the companion.

## Work

- Rust: the `bind` and `set` verbs in `requests.rs` `watch_commands`, the button
  bits from the descriptor and the two layouts (crates/pad), `talk`/chord keys
  stored as bit plus name, `status` carrying the applied settings, the `mics`
  verb, the setup window's rows removed.
- Lua: the rows (`WC.SettingsPage.Add`), the bind and set strips, writing WoW's
  binding from `status`, the Bindings.xml entry removed, one slot rule.
- Before moving the rows: check that a `set` or `bind` strip drawn while a Stop
  or cancel strip is pending queues behind it (the strip shows one payload at a
  time).
