# Splitting the addon (the player's final shape, 2026-11-11; built the same day)

No embedding: Core is the shared code, and every other addon depends on it.
Mixed versions cannot arise (one copy of each); no compatibility promises before
a 1.0 the player blesses.

## The addons (as built)

| Folder | What | `## Dependencies` | Saved |
|---|---|---|---|
| `WowCompanion` (Core) | `Engine.lua` (modules, bus, settings, `WC.AfterCombat`, focus helpers, capabilities, `WC.Saved`/`WC.MoveSaved`, the load list), `Style.lua`, `Board.lua` (toast, board, `WC.Board.Post`), `Providers/` (price, nav positions, gear, itemSource, guide, Polestar's pins). Nothing of the PC. | none | `WowCompanionDB` (module settings, `addons`), `WowCompanionCharDB` (only until the buffs move is done) |
| `WowCompanion_Link` | the PC bridge: `Link.lua` (slots, bells, polling, the mailbox, dispatch, the talk button, `/wc`), `Pad.lua`, `Chat.lua` (chat line, whisper lookup, `chat`/`send`), `ChatWheel.lua`, `Strip.lua`, `BridgeProbe.lua`, `Status.lua`, `Signals/` | WowCompanion | `WowCompanionLinkDB` |
| `WowCompanion_Agent` | `Agent.lua` (conversations, board rows, offered button, the agents' kinds, `/wc` agent commands), `Sandbox`, `Tests`, `Window`, `Transcript`, `JobsModel`, `Jobs`, `Chords`, `Probes`, `Export`, `FocusLog`, `ItemView`, `LinkCatcher`, `Modules.lua` | WowCompanion_Link | `WowCompanionAgentDB` |
| `WowCompanion_Bags` | the bag window, verdicts, `BagSwap.lua`, `MakeRoom.lua` | WowCompanion | `WowCompanionBagsDB` |
| `WowCompanion_Interact` | combat loot/interact | WowCompanion | `WowCompanionInteractDB` |
| `WowCompanion_Fonts` | fonts, `Fonts/` | WowCompanion | `WowCompanionFontsDB` |
| `WowCompanion_Wheel` | wheels | WowCompanion | `WowCompanionWheelDB` (per character) |
| `WowCompanion_Pins` | pins; the builtin `pins` and `nav` (aim, clear) | WowCompanion | `WowCompanionPinsDB` |
| `WowCompanion_Buffs` | `BuffWatch.lua`, `BuffGlow.lua` | WowCompanion | `WowCompanionBuffsDB` (per character) |
| `WowCompanion_Errands` | the to-do list | WowCompanion_Agent | `WowCompanionErrandsDB` |
| `WowCompanion_Mailbox` | the ledger's mail (the PC writes it) | WowCompanion_Link | none |

**AddOns list**: every one carries `## Group: WowCompanion`. Blizzard's list
(`AddonList.lua` ~453-520) has one level: a group node exists only for an addon
whose name equals the group, so slots grouped under `WowCompanion_Link` would
fall to the top level (Link is itself a child of WowCompanion). The slots stay
`## Group: WowCompanion` (src/channel.rs `SLOT_TOC`, unchanged).

**How they talk**: upward only through the bus (`WC.Send` / `M:On`) or a guarded
global. Link sends `TALK_TAP`, `TALK_HELD(slot)`, `LINK_STEP(step, ok, outcome)`,
`LINK_FAILED(text)`, `MAILBOX_JOBS(jobs)`; Link's Status sends `TOGGLE_WINDOW`;
Fonts sends `FONT_CHANGED`. Handlers register with `WC.Link.Handle(kind, fn)`;
`/wc` words with `WC.Link.Slash(word, fn)`; the Agent sets `WC.Board.poster`.
The mailbox is applied at Link's `PLAYER_ENTERING_WORLD`, after the Agent's
window is built and refilled at `PLAYER_LOGIN`.

**Removed with it**: Engine's aliases reaching up (`WC.Board`/`WC.Chat`/`WC.Items`
and the metatable for Pins/Strip/Style/Wheel; each addon now sets its own), the
bags' `standInBags` switch, `/wc key` (unused), `tools/split_addon.py` and
`tools/addon_locals.py` (Companion.lua is gone), modules BagSwap, MakeRoom,
BuffGlow, LinkCatcher (now addon files).

**Settings move once**: `WC.Saved(addon, table, move)` makes each table at that
addon's load and runs `move`, which takes its keys out of `WowCompanionDB` (or
`WowCompanionCharDB.buffWatch`, `WowCompanionDB.mods.Bags`). Remove the moves,
`WC.MoveSaved` and `WowCompanionCharDB` once the player has logged in on every
character.

**What is running**: Core writes `WowCompanionDB.addons` (the WowCompanion*
addons that loaded, slots left out) at every save. The PC reads it; live through
C_Log later, if the bridge probe proves it.

## The PC side (Rust; for the PC-side Claude)

Must land before the next login, or the channel is dead:
1. **Signals moved** to `WowCompanion_Link\Signals`: `channel.rs` (2 places),
   `doctor.rs`, `heartbeat.rs` (2), `install.rs` (2), which use
   `addons.join(ADDON).join("Signals")`.
2. **Saved files per addon**: `context` (the export), `lines`, `jobModel` are in
   `WowCompanion_Agent.lua` as `WowCompanionAgentDB` (context.rs `saved_string`,
   ledger.rs `held_in`). `slotCount`, `channel`, `loads`, `leftAt`, `bridgeProbe`
   are in `WowCompanion_Link.lua` as `WowCompanionLinkDB` (channel.rs, backups.rs
   `reset_suspected`/`loads`, bridge_probe.rs, the stamp in channel.rs/requests.rs).
   `addons` is in `WowCompanion.lua` (`WowCompanionDB`). Tests that write
   `WowCompanionDB = {...}` follow.
3. **Modules.lua** goes to `addon/WowCompanion_Agent/Modules.lua` (modules.rs,
   both the repo and the installed copy).
4. **bridge_probe.rs** font source: `addon/WowCompanion_Fonts/Fonts/`.
5. **agent.rs RULES**: `WowCompanionDB.links`/`.tradeLinks` are
   `WowCompanionAgentDB.*`; LinkCatcher, BagSwap (`addon/WowCompanion_Bags/BagSwap.lua`),
   BuffGlow are addon files, not modules; `Bags*.lua` is in `addon/WowCompanion_Bags/`;
   the pins live in `WowCompanionPinsDB`; give each addon's rules only when it is
   in `WowCompanionDB.addons`.
6. **Install / uninstall per addon** (`install <AddOns> [names]`, `uninstall`),
   `addons.json` recording each; the setup window shows an addon's options only
   when installed; **agents off** in `settings.toml` (dictation only, no `claude`).
7. `install` copies every `addon/` folder already; stale files left in the old
   installed `WowCompanion` folder (Companion.lua and the rest) are not in its
   .toc and do nothing, but install should remove them.

## Addendum: voice bindings in Core (the player, 2026-11-11)

An exact phrase list the player sets ("Hearthstone", "Mount up", "Rez"), each
mapped to an action (a spell, an item, a macro, or macro text). Saying a phrase
readies it; **the player's press carries it out**, never ours. No agent.

**Where it lives**: `VoiceBindings.lua` in Core. The list is per character
(spells differ), in Core's per-character table. A new channel message kind,
`voice` (the phrase), handled by Core, so it works with agents off.

**The press**: Core already has one secure button the player presses for an
offered action: the offered button (the `press` step, today in the
conversation half of `Companion.lua`). It moves into Core, and a voice binding
is a press offered without an agent. No new button, no new binding.

**Out of combat**: Core points the offered button at the phrase's action
(`macrotext`), shows it on the board ("Hearthstone: press ..."), the player
presses it. This is today's `press` path, proven.

**In combat**: a protected button cannot be re-pointed by our code. Two
candidates, both to be measured before either ships:
1. **The chat-box flow**: Core puts `/cast X` into the chat box the player
   opened (the same rule as chat lines: nothing opens it), and the player's send
   runs it. Untested: whether a slash line our code typed runs as a secure cast
   on the player's Enter, or is blocked as tainted. If it runs, this is the one
   combat path and it needs nothing else.
2. **If it does not**: no voice path exists in combat. The honest fallback is
   what the game allows: the same bindings on a wheel (secure, works in combat,
   picked by stick, not voice), and the board says "in a fight: use the wheel".
   No re-pointing tricks.

**What the PC needs**
- **Routing without an agent**: the voice loop already sends a line that opens
  with a channel word to chat (`src/chat.rs`). A line that **equals** a phrase
  (lower-cased, punctuation stripped; exact, no fuzzy matching) goes to Core as
  a `voice` message instead. Checked before the agent, so it works with agents
  off and costs no tokens.
- **Whisper's prompt**: the phrases go first in the prompt
  (`crates/voice/src/transcribe.rs`, `prompt()`), ahead of spell names, inside
  the 224-token budget, so the exact words are what Whisper hears.
- **The list reaches the PC** like everything game-side: in the export at a
  reload (Core's own short section), read by the voice loop at start and after
  each reload.
- **Setting the list without an agent**: a Core slash (`/wc voice add <phrase> =
  <action>`, `/wc voice remove <phrase>`, `/wc voice`) and, with agents on, the
  agent may set it by request. A controller-friendly editor is later.

**Found while looking**: `transcribe.rs`'s `FALLBACK_SPELLS` (used before a
spellbook is exported) names druid spells (Rejuvenation, Moonfire, Bear Form):
class-specific, to remove under the class-neutral rule.
