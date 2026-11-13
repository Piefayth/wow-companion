# Settings in game: the companion holds them, our page edits them

Status: agreed with the player and built (2026-11-12): the Lua half 3e9b04f,
the Rust half 5c5e40c. Not yet tried in game.

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

- **Applying is in place, never a restart** (the player, 2026-11-12). A change
  writes settings.toml (`Settings::set`, `save`) and goes to the voice loop
  (`voice::change`), which takes it between presses: the buttons and feedback at
  once, the mic closed properly and the new one opened (as when a mic comes
  back), a speech engine loaded beside the one in use and swapped in when it is
  ready, never mid-hold. `status` follows within a quarter second of the loop
  taking it (heartbeat.rs). The first build applied by restart, which waits for
  no request in flight: with an agent busy, the player's mic changes sat on
  "applying" for minutes.
- **The mic list rides in `status`** (2026-11-12, replacing the `mics` command
  and message): `settings.mics` is the inputs Windows lists now, re-sent when
  the list changes, so a headset connected mid-session appears without a
  reload. `status` also says which engines are installed (streaming only with
  `stream_model`).
- **The setup window keeps its mic and engine rows and loses its button
  learning.** It is one more editor of the same file, not a second truth: since
  95bafad it writes only the fields it changed and follows the file when
  something else writes it (the stale snapshot that clobbered settings.toml on
  2026-11-11 at 20:39 cannot recur). A first run needs them before the game has
  ever loaded. Its talk-button row goes: the button is set on our page.

## The talking indicator

The game draws its own preview of the conversation while the talk button is
held, by the same rule as the companion (last trigger pulled; L2+R2 Quick; L1+R1
dictation) on the chord keys' WoW names from `status`. Two readers of one pad
can differ only when triggers change within a frame of each other; the clip's
`heard` names the conversation it went to when it is let go. The rule is written
once in Lua: today it is in Agent.lua (last pulled) and again in Pad.lua's
`WowCompanion_PadSlot` (a fixed order, used by Offer.lua and ChatWheel.lua),
which can disagree with each other and with the companion.

## Protocol

The game to the companion: command strips (`WCCMD <nonce> ...`, as Stop and
cancel are drawn; a new nonce for every draw).

| strip | meaning | the companion answers |
|---|---|---|
| `bind <key> start` | the row is waiting for a press; `key` is `talk`, `l1`, `l2`, `r1`, `r2`, `quick` or `say` (dictation) | collects every button that goes down from now, ignores the talk button meanwhile, and sends `status` with `binding = "<key>"`; only then does the row say "press a button". Ends by itself after 30 s. |
| `bind <key> <NAMES>` | the press the row caught, by WoW's names joined with `+`: for `talk` the first button pressed; for a conversation every button that went down from the first press until all were let go (a chord) | exactly one button went down since `start`: writes `<key> = "<byte>:<mask> <PADNAME>"` and the voice loop takes it; `status` carries it. Otherwise `status` with `bind = { key = "<key>", error = "<why>" }`. |
| `bind <key> cancel` | the row left without a press | stops collecting |
| `set <key> <value>` | `feedback` (`rumble`, `beep`, `both`), `speech` (`whisper`, `streaming`), `mic` (a device name, the rest of the line) | writes it if it differs and the voice loop takes it; a value it refuses gets `status` with `set = { key = "<key>", error = "<why>" }` |

The companion to the game: `status`, sent when the companion starts, at every
new session (a reload), when the mic comes or goes, and with the answers above:

```lua
{ kind = "status", mic = true,
  settings = { talk = "PADSOCIAL", l1 = "PADLSHOULDER", l2 = "PADLTRIGGER",
               r1 = "PADRSHOULDER", r2 = "PADRTRIGGER",
               quick = "PADLTRIGGER+PADRTRIGGER", say = "PADLSHOULDER+PADRSHOULDER",
               feedback = "rumble", speech = "streaming",
               mic = "Headset (AirPods Max Hands-Free AG Audio)",
               mics = { "Headset (AirPods Max Hands-Free AG Audio)", ... },
               engines = { "whisper", "streaming" } },
  binding = "talk",                          -- only while collecting
  bind = { key = "talk", error = "..." },    -- only after a failed bind
  set = { key = "mic", error = "..." } }     -- only after a refused set
```

Each conversation key is a chord: its buttons' WoW names joined with `+`
(`talk` is always one). The game picks a conversation from them by one rule
(addon/WowCompanion_Link/Pad.lua, the companion's own): at the talk press the
fully held chord with the most buttons wins, ties in the order l1, l2, r1, r2,
quick, say, none held is Main; during the hold each newly pressed button picks
the fully held chord with the most buttons among those containing it, and
letting go keeps the pick.

A button key the companion has no button for is absent from `settings`
(another pad before it is pressed). `engines` lists what is installed: the
Whisper model file, the streaming model's folder. The row shows "applying"
until `settings` carries the value: a moment, or the seconds a speech engine
takes to load.

## Work

- Rust: the `bind`, `set` and `mics` verbs in `requests.rs` `watch_commands`;
  crates/pad gives the bits that are buttons (the descriptor; the DualSense's
  report 0x31 turned into its 0x01 layout; the Edge's Fn and back buttons; the
  XInput word) and the defaults for the two layouts; `talk` and the chord keys
  stored as bit plus name; `status` carrying the settings; the setup window's
  button learning and talk row removed, and `learn` with them.
- Lua: the rows (`WC.SettingsPage.Add`), the bind and set strips, writing WoW's
  tap binding from `status` (a `SetBindingClick` on a button of ours, both edges,
  out of combat, clearing the old key only when it still holds ours), the
  `WOWCOMPANION_WINDOW` Bindings.xml entry removed, one slot rule.
- Before moving the rows: check that a `set` or `bind` strip drawn while a Stop
  or cancel strip is pending queues behind it (the strip shows one payload at a
  time).
