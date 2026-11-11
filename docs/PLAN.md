# The plan

The shared to-do for everyone working on the companion: the player, the in-game
agent, and any other session. Whoever finishes an item moves it to Done with one
line on how it went; whoever learns something that changes the order says so here.
CLAUDE.md is the truth about how things work; this file is what we do next.

## The player's standing terms

They outrank any item below, and live in `player/profile.md` (sent with every
agent request). One more, for whoever works on the companion itself:

- **Don't reinvent what Claude Code already has.** The agent is Claude Code; give it
  tools and instructions. Write code only for the channel, the pad, the voice, and
  fences that must hold whatever the model decides.

## Who does what

The in-game agent owns day-to-day work, features and code alike. A second session
(in a terminal) works on the companion itself when asked, and before touching
anything checks that no request is in flight (a `claude.exe` with `--json-schema`
on its command line means one is). Two writers on one file is how replies got lost.

## Next, in order

### 1. Promises already made (checked against the code, 2026-11-11)

1. **Speech: both engines stay** (the player, 2026-11-11: Whisper is "much higher
   quality", streaming's speed "way too good to give up"; on streaming for now).
   Nothing is deleted; the setup window's Engine choice is the switch.
4. **The addon split's PC side, the rest** (docs/proposals/addon-split.md, items
   5-6): install and uninstall per addon (`install <AddOns> [names]`), the setup
   window offering each extra and showing its options only when installed, and the
   agent's rules for an addon only when `WowCompanionDB.addons` lists it (Core
   writes it; nothing on the PC reads it yet). Done of it: Signals, saved files,
   Modules.lua, stale files removed by install, agents Off.
5. **The mailbox's absence said in game** (docs/proposals/ledger.md, failure
   table: "not built yet"): Link.lua takes `WowCompanion_Mail` if it is a table
   and says nothing when it is missing.
6. **CI on every push** (docs/proposals/rule-compliance.md, 4): `luacheck`,
   `luaglobals`, `luarules`, `tools/test_jobs.py` and `cargo test`. Only the
   release workflow exists.
7. **The first tech debt review** (docs/review.md): recurring, by an agent that did
   not write the code; `docs/reviews/` is still empty.
8. **Dated history in comments**: 48 comments in `addon/`, `src/`, `crates/` still
   say "the player, 2026-11-1x"; move them to docs/history.md, one file at a time
   (rule-compliance 3). Also stale: the bridge probe in the comments of
   `src/context.rs` and `src/savedvars.rs`, and streaming-speech.md's "0.5 s poll"
   and "1.4 s to the first bell" (the slot bells changed both).
9. **Measured by use**: each agent Lua run records the API names it called and
   whether it errored, and `tools/api_surface.py` promotes those to measured. Today
   it reads only `docs/api-useful.md`.
10. **Friend release, untested parts** (memory note, 2026-11-10): the CUDA release
   job and the setup window's uninstall button by hand. The Xbox mapping is done
   (XInput).

### 2. Voice bindings in Core (the player, 2026-11-11; designed, not built)

docs/proposals/addon-split.md, addendum: exact phrases the player sets, each
readying an action the player's press carries out, no agent. Measure first
whether a `/cast` line our code puts in a chat box the player opened runs on
their send in combat; if not, in a fight the same bindings live on a wheel. With
streaming speech, a phrase can be recognised before the button is let go.

### 3. Bags (the player: "item stuff has been my biggest problem")

Built: the window in and out of combat, verdicts, Sections by default, Sell all at
a vendor, bag swap, make room, sort from the triangle menu, contents in the
export. Open, as docs/proposals/bags.md:
- Colours for the verdicts, and which views besides sections and storage order.
- Filters and finding by voice ("show what I can sell", a name moves focus there).
- Item level and quality on icons; upgrade arrows from GearQuest.
- Bag swap on a real swap (`WCSwapBag` is untested).
- Later: bank in the window, alts' bags offline, quick mail and auction posting.

### 4. Controller features

In the player's order (2026-11-09). From `docs/api-surface.md`, all live in Forever:

- **Self-filling wheels**: `items` and `quest` rules exist (Wheel.lua). Left:
  mounts, toys, travel, party, and the **magic slot** ("I need my hearthstone"
  puts it there).
- **Quest helper**: next objective, waypoint, its items on a wheel, track and
  abandon without the quest log. The live route (guide capability), nav, pins and
  errands exist; for quests Polestar has no guide for, a generated guide
  registered as data (`Polestar.Import`, `ns.RegisterPack`).
- **Vendor**: Sell all is built; repair in the same press is not (agent Lua
  refuses `RepairAllItems`; it needs the player's press).
- **Crafting queue**: "make ten of these and whatever levels me", one press per craft.
- **Mail**: collect all; send materials to an alt.
- **Roles**: talents, equipment sets and bars per role, swapped with one press.
- **Auction house**: search, price and prepare; the player presses post or buy.
- **Home as a wheel button** (an idea, still liked, not designed): Home is free;
  opening a wheel needs a press the game can see, so a game-side binding, measured
  first and agreed before building (profile: no new bindings unasked).

### Later: a custom look (the player, 2026-11-09)

A separate addon (`WowCompanion_Look`), independent of the AI pipeline: one theme
file, one file per UI part, Blizzard-style art. The ambitious part is a fork of
Blizzard's controller action bars (source in `docs/wow-ui-source/Interface/AddOns/
Blizzard_GamepadActionBars`), rebuilt on secure templates and state drivers so
paging and modifiers still work in combat, then styled our own way. Also: the
experience bar, which floats at the bottom out of keeping with everything else.
Start from the three things on screen that bother the player most.


## Decided

- **The data strip is the live game-to-PC path** (the player, 2026-11-10;
  replaces "no live pixel channel" of 2026-11-09): colour cells our code draws,
  read by the companion. Reloads stay the path for the full export.
- **Opus for every conversation; Quick (L2+R2) is Sonnet at low effort** (the
  player, 2026-11-10: Haiku was too weak).
- **Conversation slots stay general** (the player, 2026-11-10): never pre-assigned
  a job ("L2 is gear").
- **No relaunching the game from the PC** (2026-11-10). Measured in Battle.net's log:

  | Route | Result |
  |---|---|
  | `Battle.net.exe --exec="launch wowf"`, `launch_uid wowf`, `--uri="battlenet://wowf"` | selects Forever, never presses Play |
  | `Wow.exe` directly | asks to log in |
  | `Wow.exe -launcherlogin -uid wowf` | "unable to reconnect": the login token comes only from Battle.net's launch |
  | the Agent's local API, 127.0.0.1:1120 | 401 on every path, locked to Battle.net |
  | Battle.net's accessibility tree | not exposed (CEF), no Play button to invoke |
  | click Play | launched |

  The one working route is clicking Play, which is computer use on the player's
  screen: dropped. A detached relaunch script also died with the agent's turn;
  anything that waits for the player belongs in the companion.
- **Not wanted**: trimming the addon's memory.
- **A chat line goes only into Blizzard's chat box the player opened** (the
  player, 2026-11-11): the send preview and dictation into other text boxes
  (2026-11-09) are gone; a line waits for the next box they open.
- **Closed until seen again**: the invisible-focus bug (once, 2026-11-10).

## Done

- 2026-11-09: controller chords learned from play; multi-step answers on Opus; full
  Claude Code; progress, a seconds count, and replies that always arrive; chat
  channels by voice, drafts cleared on cancel; addon vetting; Blizzard's UI source
  for this build; the API surface and its terms; Lua errors exported; conversations
  that survive restarts; wheels; minimap pins from coordinates (`WCPins`); safe
  self-restart (`wow-companion restart`); a visible queue; the slot budget.
- 2026-11-10, the loop: CLAUDE.md split into what is true and docs/history.md;
  conversation slots on the triggers and Quick; one talk button (channel words go
  to chat); typed requests (`tell`); auto-continue at the step limit; the jobs
  ledger (`src/jobs.rs`, one forward-only state per request); cancel and Send now
  from the window, carried to the PC by the strip; the window's state in a pure,
  property-tested model (JobsModel.lua); an audit trail (`tools/audit.py`).
- 2026-11-10, the window and look: tabs, a conversation picker, Blizzard's scroll
  bar, glyphs that follow the pad, the toast board per conversation, the minimap
  status button with unread dot, live interface fonts, opens and closes in combat.
- 2026-11-10, game features: the bag window (combat-usable, verdicts, sections,
  Sell all, bag swap, make room); combat interact; capabilities and providers
  (price, nav, gear, itemSource, guide, pins; Polestar, Auctionator, GearQuest);
  errands with tracker, tab and live arrow; watched buffs per character and their
  glow (BuffWatch, BuffGlow); the `send` step; class-neutral (nothing druid ships).
- 2026-11-10, structure: the engine `WC` (modules, bus, settings, AfterCombat, focus
  helpers safe in a fight); `WC.Core` reach-ins gone; split main.rs, the voice crate
  and the big Lua files; `tools/luarules.py`, `tools/luaglobals.py`; save files
  backed up and resets told by the load count.
- 2026-11-10, for other players: the setup window, settings.toml, XInput pads with
  Guide as talk button, optional integrations, the profile split, the release
  workflow (Vulkan, CPU, optional CUDA), an uninstall ledger, the watcher and tray
  (`start`), crash.log, one companion at a time.
- 2026-11-10, the data strip: game to PC by colour cells, decoded by the companion
  (`src/strip.rs`); agents read chat with `strip --chat` when they need it.
- 2026-11-11, the channel: the ledger and mailbox (lines numbered, every line
  until the game saved it; offline, undelivered and resync code removed); one typed
  message (`src/message.rs`) and batching; the clip's exact identity (`heard`);
  the slot bells became the channel after a clean trial (the message, catch-up and
  frame bells, the 2 s wait and `BELL_LINGER` removed); no process launches on the
  send path.
- 2026-11-11, the addon split: Core, Link, Agent and the extras, each with its own
  saved table, and the PC side (Signals, saved files, Modules.lua, install).
- 2026-11-11, speech: streaming Nemotron on trial beside Whisper, chosen in the
  setup window; the player's first verdict for streaming. Whisper's audio
  resampled through a windowed-sinc low-pass.
- 2026-11-11, the rest: dictation only (the agents Off); the bridge probe run and
  removed (C_Log too slow, late fonts never load, strip capture moved to DXGI
  Desktop Duplication); taint scans spread over frames; the spellbook export fixed;
  the version in the setup window and doctor; the window scale slider.
