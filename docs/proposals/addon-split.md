# Splitting the addon (proposal, 2026-11-11; nothing built until the player agrees)

The player's decisions: **Core** is a complete product with the PC's agents off;
an **Agent** addon carries everything the LLM needs; **extras** are standalone
addons that work without Core or the PC wherever they can, and use Core or a
capability only optionally. One collapsible entry in the AddOns list.

## The addons

| Addon (folder) | What it is | Needs |
|---|---|---|
| `WowCompanion` (Core) | the message channel (slots, bells, polling, dispatch), the data strip, the board/toast, dictation into Blizzard's chat box (chat line, whisper lookup, ChatWheel), the item viewer, the minimap button | the PC (it is the PC's half); WCLib |
| `WowCompanion_Agent` | the Companion window, conversations, jobs, transcript, export, agent code (sandbox, modules), probes, tests, chord learning, focus log | Core |
| `WowCompanion_Bags` | the bag window, verdicts, sections, sell all, bag swap, make room | WCLib; prices optional |
| `WowCompanion_Interact` | combat loot/interact key | WCLib |
| `WowCompanion_Fonts` | live interface fonts and text size | nothing |
| `WowCompanion_Wheel` | radial wheels (already standalone) | nothing |
| `WowCompanion_Errands` | the to-do tracker | WCLib; nav, pins optional |
| `WowCompanion_Pins` | minimap and world map pins | WCLib |
| `WowCompanion_Buffs` | watched buffs (per character) and the button glow | WCLib |
| `WowCompanion_S001..512` | slots | Core (load on demand) |

Every addon gets `## Group: WowCompanion`, so the AddOns list folds them under
Core. Read from `Blizzard_AddOnList/AddonList.lua` (~453-520): `Group` must
equal the parent's folder name; a child whose parent is missing falls back to a
top-level entry, so an extra installed alone still shows normally. (The slots
already carry the group.) `## Category` is only a heading above groups; not
needed.

## Shared code: one library, embedded the LibStub way

What standalone addons share: the module engine (`WC.Module`, `Event`, `On`,
`Send`, `Settings`), `WC.AfterCombat`, the focus helpers (`MarkFocusable`,
`MarkIgnored`, `FrameHidden`, `ShowPanel`), the Blizzard look and glyphs
(`Style.lua`), and the capability registry (`Provide`, `Use`, `Has`) with its
providers (price, nav, gear, itemSource, guide, pins).

**Recommended: `WCLib`, one source file set in the repo (`lib/`), embedded into
each addon's folder by `install` and the packager, registered with LibStub
(public domain) so the newest loaded copy wins and every addon shares one
instance.** Why:
- each extra stays one folder that works alone, publishable as an ordinary addon;
- one runtime instance, so the capability registry and the message bus are
  shared across addons (a provider registered by Core is seen by Bags);
- one source in git, never hand-copied: the copies are build output.

The alternative, a separate `WowCompanion_Lib` addon every addon depends on,
is one more folder the player must have, and an extra published alone would
fail without it.

## Each addon owns its saved table

| Addon | Saved table | Moves out of `WowCompanionDB` |
|---|---|---|
| Core | `WowCompanionDB` | keeps: channel counts, `board`, `chatChannel`, `talkKey`, `minimapAngle`, `links`, `tradeLinks`, `loads`, `leftAt` |
| Agent | `WowCompanionAgentDB` | `log`, `unread`, `jobs`, `jobModel`, `window*`, `runs`, `modules`, `mods`, `probe`, `placeTests`, `pathTaint`, `taint`, `errors`, `blocked*`, `focusLog`, `chords*`, `spellForms`, `audit` |
| Bags | `WCBagsDB` | `mods.Bags`, `standInBags` |
| Interact | `WCInteractDB` | `interact` |
| Fonts | `WCFontsDB` | `font`, `fontScale`, `fontError` |
| Errands | `WCErrandsDB` | `errands` |
| Pins | `WCPinsDB` | `pins` |
| Buffs | `WCBuffsDB` (per character) | `WowCompanionCharDB.buffWatch` |
| Wheel | `WowCompanionWheelDB` | already its own |

## Every current file

- **WCLib**: `Engine.lua` (minus its helper aliases, below), `Style.lua` (minus
  the talk key), `Providers/*.lua`.
- **Core**: `Companion.lua` (the channel and dispatch only), `Board.lua`,
  `Chat.lua`, `ChatWheel.lua`, `Strip.lua`, `Status.lua`, the pad and name
  lookups of `Chords.lua`, `modules/LinkCatcher.lua` (becomes a Core file:
  links caught for the item viewer and profession links).
- **Agent**: the conversation half of `Companion.lua` (conversations, the waiting
  line, the offered button, `/wc`), `Window.lua` (its conversation tabs),
  `Transcript.lua`, `JobsModel.lua`, `Jobs.lua`, `Export.lua`, `Sandbox.lua`,
  `Tests.lua`, `Probes.lua`, `FocusLog.lua`, chord learning from `Chords.lua`,
  `Modules.lua` and `modules/` (the agent's own modules).
- **Bags**: `Bags.lua`, `BagsEvaluate.lua`, `BagsInput.lua`, `BagsMenu.lua`,
  `BagsStandIn.lua`, and `modules/BagSwap.lua`, `modules/MakeRoom.lua` become
  its files.
- **Interact**: `Interact.lua`. **Fonts**: `Fonts.lua`, `Fonts/`. **Pins**:
  `Pins.lua`. **Errands**: `Errands.lua` and the Errands page now in
  `Window.lua`. **Buffs**: `BuffWatch.lua`, `modules/BuffGlow.lua`.
- `modules/ExtraButtons.lua` is this player's own (PAD5 autorun): it stays an
  agent module, not shipped.

## Dependencies to cut first

Found by a scan of who calls whom (globals defined in one file, used in
another). Each must point downward (extra → WCLib, Agent → Core → WCLib) or
become optional (`if X then`, a capability, or a `WC.Send` message).

1. **Engine.lua's helper aliases** (`WC.Board`, `WC.Chat`, `WC.Pins`,
   `WC.Strip`, `WC.Style`, `WCBags`, `WowCompanion_Recent`): the library
   reaching up into Core and the extras. Remove; each addon publishes its own.
2. **Style.lua → Core**: `WowCompanion_Glyph`, `WowCompanion_TalkKey`,
   `WC.Toast`, `WCBags`, `WCPins`. Glyphs belong in Style; the talk key and
   toast are Core's and leave Style.
3. **Companion.lua → everything** (Board, Chat, ChatWheel, Chords, Export,
   Jobs, Probes, Sandbox, Strip, Tests, Transcript, Window): the dispatch calls
   each feature by name. It becomes a handler registry: Core handles `chat`,
   `send`, `press`, `reload`; Agent registers `lua`, `module`, `bar`, `macro`,
   `look` and the rest. **L2 is removing the `WC.Core` reach-ins this round:
   this waits on that; I do not touch `Companion.lua` or `Chords.lua`.**
4. **Chat.lua → Agent**: `WC.Sandbox.measureOnce` (taint measuring of the chat
   path) moves to Agent, hooked from there; `WC.Chords.spoken` moves with the
   name lookups into Core.
5. **Board.lua → Companion.lua**: glyph and talk key (see 2).
6. **Export.lua → Errands, BuffWatch, Probes, FocusLog, Chords**: Export goes to
   Agent and reads each extra only if loaded (a capability per extra, e.g.
   `WC.Use("errands")`), never by global.
7. **Window.lua → Errands, Fonts, Pins, Status, FocusLog**: the Tools and
   Errands tabs leave the window; each extra draws its own UI (Fonts: a Settings
   panel or slash; Errands: its tracker; Pins: clear on its own slash).
8. **Errands.lua → `WC.ErrandsPage` in Window, `WC.Board.toast`**: its page
   moves into Errands; the toast becomes optional (Core's board if present,
   else the chat frame line).
9. **Fonts.lua → `WC.Transcript.SetScale`**: becomes `WC.Send("FONT_CHANGED")`;
   the transcript listens.
10. **Status.lua → `SlashCmdList.WOWCOMPANION`, `WowCompanion_Unread`**: the
    unread dot is Agent's; the minimap button asks Agent through a message.
11. **Jobs.lua ⇄ Transcript.lua**: a cycle inside Agent; fine inside one addon.
12. **modules → features**: `BuffGlow` → `BuffWatch`, `MakeRoom`/`BagSwap` →
    `WC.Board`: once they are files of Bags and Buffs, the board is optional.
13. **Strip.lua, Pins.lua** headers name `WCBags` and an old .toc order: stale
    comments, rewritten when the files move.

## The PC side

- **Agents off** (`agents = off` in `settings.toml`, a switch in the setup
  window): the talk button only dictates into the chat box (the chat path that
  exists now), no `claude` is started, no export is read, the trigger slots are
  inert. Core alone then is the whole product.
- **Install and uninstall per addon**: `install <AddOns> [Core,Agent,Bags,...]`
  (default: all), `uninstall <AddOns> <name>`; WCLib is embedded into each one
  installed; `addons.json` records ours, as for third-party addons. The setup
  window gets a checklist.
- `context.rs` sends the agent only the sections of addons installed, as it does
  for integrations; the agent rules name each extra's API only when present.
- The packager stages each addon folder, with WCLib embedded.

## Cost

**One full game restart**: new addon folders are seen only at a restart, not a
reload. Everything lands in one change, so it is one restart, not one per
addon.

## Open questions for the player

1. **Saved settings**: under rule 2 the split is a fresh start (each addon's new
   table starts empty: fonts back to Default, the bag view to sections, pins and
   errands gone, the Companion window's log and size reset). Moving them over is
   a one-time copy at first login, only if you ask. Wheels and watched buffs
   (already per character) are unaffected... except Buffs, whose table moves:
   say if that one should be copied.
2. **Names**: `WowCompanion_Bags` and so on, or shorter folder names for
   publishing (e.g. `PadBags`)? The Group line needs only the Core folder name.
3. **LinkCatcher**: Core (I propose: the item viewer and profession links work
   without agents) or its own extra?
4. **Pins**: its own extra (proposed), or part of Errands?
5. **Publishing**: do you want the extras on CurseForge/Wago later? It only
   changes licensing notes (the Wheel carries Improved Forever's MIT licence).

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
