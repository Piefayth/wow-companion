# WoW Companion

Voice and agent control for World of Warcraft: Forever, played on a controller.
Hold a button, speak, and the PC side turns it into something done in game: chat
in the box, macros, bars, wheels, addon code, addons installed.

This file is what is true now, kept short because the in-game agent reads it on
every request. **How each thing was learned is in `docs/history.md`**; when a rule
here looks odd, its story is there. **Get information from the API first** (the player's standing rule, 2026-11-10):
Lua in a `lua` step, and the export after a reload. **Screenshots are allowed to
read what our own code or an addon puts on screen**, to skip a reload: draw the
data in a frame of ours, take the shot (`tools/shot.ps1`), `Read` it. Reading the
player's screen for anything else needs their explicit ask. Looking never becomes
acting for them.

**What we do next is `docs/PLAN.md`**, with the
player's standing terms. Read it before starting anything sizeable.

## The player

**`player/profile.md` is this player's terms, preferences and setup**, sent with
every agent request. This file and the agent's rules are the same for every
player: a new preference goes in the profile, never here. Product rules that hold
for everyone: never play for them (casting, targeting, moving, and the step that
spends or sends are their press); addons are vetted and installed only after a
yes; don't reinvent what Claude Code has.

## Shape

- `crates/pad`: the controller over raw HID (DualSense and other HID pads;
  rumble is DualSense output report 0x02). Which pad this player has is in their
  profile. Buttons are named by byte and mask (`home` byte 10/0x01, `minus` 9/0x10
  on a DualSense), or learned in the setup window. **Xbox pads go through XInput**
  (`pad=xinput`, `crates/pad/src/xinput.rs`): their state becomes a 4-byte report
  so learning and names work the same; Guide (the default talk button there) via
  `XInputGetStateEx`; rumble works. Button names follow the pad (`press_for`).
- `crates/voice`: mic (`cpal`) and Whisper (the model and GPU backend the setup window chose), its own crate
  so the CUDA build is not invalidated by edits elsewhere.
  Files: `lib.rs` (the push-to-talk loop), `mic.rs`, `transcribe.rs`, `cue.rs`,
  `bluetooth.rs` (the hands-free reconnect).
- `src/`: the helper, one job per file: `main.rs` (command dispatch, `run`'s
  wiring of the voice loop), `channel.rs` (slots, the cursor, sending, bells),
  `requests.rs` (asking the agent, progress, auto-continue, re-sync, `tell`),
  `context.rs` (the export, profile and integrations the agent gets), `chat.rs`
  (spoken chat lines), `restart.rs`, `install.rs`, `agent.rs` (the agent and its
  rules), `bells.rs`, `heartbeat.rs`, `doctor.rs`, `modules.rs`.
- `addon/WowCompanion/`: the in-game half, one job per file, in .toc order
  (split 2026-11-10 so conversations stop editing the same file; a change goes in
  the file that owns it):
  - `Engine.lua` `WC`, the module engine. `Style.lua` Blizzard look, glyphs,
    destroy dialog.
  - `Companion.lua` the core: the channel (slots, bells, polling, `receive`), the
    message handlers' dispatch, conversations and the waiting line, the offered
    button, `/wc`, events. It publishes what the others need as `WC.Core.<name>`
    (at the end of the file); the others hand back functions as `WC.<File>.<name>`,
    with one-line wrappers left in Companion.lua.
  - `Sandbox.lua` agent code (`lua`, `module` steps, the sandbox, taint measuring).
    `Tests.lua` taint and PlaceAction tests. `Window.lua` the Companion window and
    its tabs. `Transcript.lua` its text and the queued mark. `Board.lua` the toast
    and agents' board. `Chat.lua` whisper lookup, send preview, item viewer.
    `Chords.lua` name lookups, the pad, chord learning. `Probes.lua` probes and API
    dumps. `Export.lua` the context export. `Pins.lua`, `Strip.lua`, `Bags.lua`,
    `Status.lua` (minimap button), `Modules.lua` (generated).
  - Files share nothing local. `tools/split_addon.py` moves a block out of
    Companion.lua as a pure move (anchored by text, refuses if the file changes
    under it). `addon/WowCompanion_Wheel/`: the wheels.
- `modules/`: the agent's modules, one `<Name>.lua` each, in git. A `module` step
  writes the file (`src/modules.rs`), which regenerates the addon's `Modules.lua`
  (gitignored, reread at every /reload) and also runs it at once. The save file's
  copy is only a fallback; the file wins.

Build with `CUDAARCHS` set to the GPU's generation (the profile says which; one
generation skips most of ggml's CUDA build);
libclang is in `C:\Program Files\LLVM`. No Lua here: check addon files with
`python -I tools/luacheck.py <file>`. Tests: `cargo test --workspace`.

## Running it

- `wow-companion run` (options from `settings.toml`, written by the setup window;
  `run <AddOns> <model> ask=minus mic=<name>` overrides them)
  (one talk button: a line opening with a channel word goes to chat, the rest to
  the agent; `chat=on:home` brings back a separate dictation button)
  **Conversation slots**: a trigger (L1, L2, R1, R2) held with minus sends the
  request to that slot's own conversation (`thread-l2.txt`…), shown as "[L2] …";
  slots run side by side. **L2+R2 together is Quick** (`agent::QUICK_SLOT`): Sonnet at low effort (Haiku was too weak, the player, 2026-11-10), 12 turns, a trimmed export, for chat, links and buttons. Saying "start over" alone in a conversation begins it
  fresh. Home is free. Only the main conversation can `look`.
  starts the companion. It runs from a copy in `%LOCALAPPDATA%\wow-companion\bin`,
  so `cargo build` works while it runs.
- **Never kill it.** `wow-companion restart` asks it to move onto the newest build:
  it waits for no request in flight and no button held, starts the new copy, which
  opens its mic and loads, and only then closes its own mic and exits. Killing it
  loses the reply in flight and has wedged a Bluetooth headset's voice link.
- `wow-companion doctor <AddOns>` checks the whole chain in seconds: game,
  companion, restart, agent, slots, bells, heartbeat, mic. Run it first when
  something seems broken.
- Also: `install <AddOns>`, `send <AddOns> …`, `think <AddOns> <text>` (the agent's
  answer, sent nowhere), `context <AddOns>` (what the agent and Whisper are given),
  `miccheck <mic>`, `reconnect`, `buzz`.
- The conversation survives restarts (`%LOCALAPPDATA%\wow-companion\thread.txt`;
  delete it to start fresh). The agent's rules are sent on every request
  (`--system-prompt-snapshot off`), so an update applies at once.

## The channel

There is no way for the game to send the PC anything while it runs; the PC
reaches the game with two tricks, and the game reaches the PC only at a reload.

- **Slots**: 512 load-on-demand addons, `WowCompanion_S001…`. The helper writes Lua
  into a slot's `Inbox.lua` and the addon loads it. Each loads once per UI session;
  a `/reload` refills them all. New slot folders need a full game restart, so the
  helper sends only as far as the addon says it can see (`slotCount`, recorded at
  every reload). About 4 slots per request; at 16 left the Reload button is
  offered once, and with none left the pad buzzes three times.
- **Bells** say "a new message is waiting": the addon plays a bell and asks
  `C_Sound.IsPlaying` 0.15 s later. **All bell files go through `src/bells.rs`,
  which holds the rules the game forced on us**: a bell is half a second (the game
  holds a playing sound open, a long one for its whole length), over 174,762
  bytes (smaller sounds are cached and held), silenced by deleting it (an empty
  polled file gets cached and locked for good), and every write and delete is
  retried and reported. Never write a sound file the game reads any other way.
- **The addon also checks the next slot's bell**, so a missed ring delays one
  message instead of losing every one after it. Polling runs from `OnUpdate`
  under `pcall`, never a ticker, and errors show once in the window.
- **Game to PC** is SavedVariables, written at `/reload` and logout only (measured:
  nothing else reaches disk while playing). The export carries character, bars,
  chords, macros, spellbook, reach, code runs, Lua errors from non-Blizzard addons,
  and the channel's counts. The agent's `look` offers a Reload and resumes after
  it. Data our code draws on screen may be read by screenshot to skip a reload (the player's rule, 2026-11-10). **The data strip** does it for kilobytes: `WowCompanion_Strip.Send(text)` draws colour cells in the bottom-right corner, `tools/strip.py --watch <s> <file>` decodes them (DPI-aware). Measured 7.8 KB in one shot.
- **The heartbeat**: while the voice loop can hear, one of two `pulse` bells exists
  and swaps every 4 s; `Status.lua` shows the minimap button in colour on a swap
  seen recently, grey with a red edge otherwise.

## Changing the channel

**Never change how messages reach the game in the live game.** On 2026-11-10 five
changes in one night (shorter bells, deleting, quiet bells, polling more bells)
each broke delivery in a new way, the player went most of the night without
replies, and three sets of bell files had to be abandoned under new names
because the game held them open. The message channel is the 2026-11-09 protocol
(`bells::message_bell`, one bell polled at a time, emptied to silence, files
`m1`..`m8`) until a replacement is proven. A replacement runs **beside** it, on
its own files, and switches over only after the addon's channel counts show it
delivering for a whole session. The **catch-up bells** (`c1`..`c8`, `ring_catch_up`
in main.rs) are such a replacement, beside it since 2026-11-10: the newest slot's
rings until the next send, so a missed message bell is taken late instead of
stalling the rest; their count is `channel.caughtUp`. Renaming files to escape a wedged one is a sign
the change should not have shipped, not a fix.

## The agent

`claude -p`, Claude Code at full strength (`--dangerously-skip-permissions`, every
tool, repo root as working directory), **Opus**, by the player's choice. The prompt
goes on stdin (the export overflows a Windows command line). Its answer is `say`
plus `steps`, the shapes the addon dispatches (chat, macro, press, reload, bar,
lua, module, show…), sent as one batch; at most one button per answer. Output is
streamed and shown as a progress line, at most two per request. Requests run off
the voice loop; one made while another runs shows as waiting. **The voice loop
must never wait on anything a request can hold** (a session's lock, a send): it is
what reads the pad, so a wait there is a dead controller and no rumble for as long
as the request runs. Locks, sends and lookups go on the request's own thread. The agent must never
wait for the player inside a turn (its answer is invisible until done): waiting
goes to a detached process.

## Rules for game code

- **Never set a property of Blizzard's frames, open their windows from code, or
  replace their globals.** That taints them, and the gamepad UI's
  `SetPreferredGamepadInteractTarget` then fails: the A and B buttons stop
  working. Chat text goes only into a box the player opened. Our frames are fine.
- **Protected things are a button the player presses**: a `SecureActionButtonTemplate`
  with `macrotext`, registered for `"AnyDown"` (other edges misfire). `ReloadUI()`
  is protected.
- **A window of ours the controller can focus**: `SmartNavigation_MarkFrameFocusable`,
  an entry in `UIPanelWindows`, shown with `ShowUIPanel`, and `OnHide` calling
  `GamepadMode.FrameControlsManager:FrameHidden(self)`, or the bars stay dead after
  it closes. **Never fire the panel manager's events or call its `FrameShown` /
  `Focus*` yourself** (`EventRegistry:TriggerEvent("UIParentPanelManager...")`): its
  focus code then runs tainted and `SetPreferredGamepadInteractTarget` is blocked
  (the bag window, 2026-11-10). `ShowUIPanel` called from a secure snippet's
  `CallMethod` tainted it too (the same night): for a window opened by a secure
  button, take the pad with our own bindings, as ImprovedForever does.
  **Never set `useCustomNavigation` or define `FocusGamepad`/`UnfocusGamepad` on
  our frames**: the manager reads them while switching focus, so the switch runs
  tainted. And a window the controller manages must live in the addon's own files,
  never in a module (modules run ForceTaint_Strong). Both measured on the bag
  window, 2026-11-10; it now cycles focus cleanly.
  **Standing in for a Blizzard window works** (the bag window, 2026-11-10, the
  player: "works exceptionally"): never close or set anything of theirs. React with
  `EventRegistry:RegisterCallback` (dispatched through secureexecuterange) and
  `hooksecurefunc` post-hooks (the caller stays secure); hide theirs with an alpha
  animation of ours aimed at their frame (`anim:SetTarget`, `SetToFinalAlpha`);
  drop it from the focus cycle with `GamepadMode.FrameControlsManager:FrameHidden`,
  the one manager call Blizzard wraps for insecure callers. Calling their
  `CloseAllBags` from our code, by contrast, tainted the next focus switch.
- **A window usable in combat** (the bags, 2026-11-10; verified by the player).
  A frame holding a secure button is protected, and a protected frame cannot
  Show/Hide in a fight. So keep the window itself **unprotected** and put
  bindings on a separate invisible `SecureHandlerShowHideTemplate` (`WCBagsPad`):
  its `_onshow` binds the pad with `SetBindingClick` by button name, `_onhide`
  clears, and `CallMethod` shows or hides the window. The opener is a
  `SecureHandlerClickTemplate` that shows the handler in combat. Item slots are
  Blizzard's `ContainerFrameItemButtonTemplate` (bag from the parent's `GetID`,
  slot from the button's), the Bagnon way. Never write Lua fields on those
  buttons; keep our data in a side table. Attributes are written only out of
  combat (owe the layout until the fight ends).
  **SmartNavigation's `SecureHelper` wraps `FrameHidden` and `MarkFrame*`**: an
  addon calling one in a fight gets "Interface action failed" with no
  `ADDON_ACTION_BLOCKED`. Use `WC.FrameHidden(frame)`, which waits for the fight's
  end, and mark frames out of combat. `WowCompanionDB.blockedNotices` records
  every such notice with our calling line.
- **Look before calling.** `docs/api-surface.md` and `.tsv` give every one of the
  10,957 names a tier and its terms (protected, press only, out of combat, secret
  results in combat, read, change, dormant, Blizzard's own Lua). `docs/wow-ui-source`
  is Blizzard's UI for this exact build (gitignored; `git clone --depth 1 -b forever
  https://github.com/Gethe/wow-ui-source docs/wow-ui-source`): read how Blizzard
  calls a thing. Never call the API blind or in bulk: one blind read crashed the
  client in C, which `pcall` cannot catch.
- The API is **retail 11.x behind a 1.60.1 version string**, with 12.0's secret
  values: `C_Spell`, `C_SpellBook`, `C_ClassTalents`; no `GetSpellInfo`. Forever's
  game type in Blizzard's manifests is `camelot`.
- New addon *folders* need a full game restart, not a reload. A new file added to
  an existing addon's .toc was picked up by a plain /reload (`Modules.lua`, measured
  2026-11-10: the game had run since 01:20, the file was added at 03:10).
- Agent Lua runs out of combat in a sandbox that refuses a short list by name
  (deleting items, sending chat, trading, gold, leaving groups) and is followed by
  an `issecurevariable` taint diff. `PlaceAction` was measured clean.

## Facts about the game and this kind of setup

- **Gamepad bars are slots 181–272**: top 181–184 (d-pad alone), left 185–192 (L2),
  right 193–200 (R2), bottom 201–208 (L2+R2), the in-form page 265–272 on R2
  (`GamepadStanceBarOverride` = 3), extra action 397. On every bar, buttons 1–4 are
  d-pad left/up/right/down and 5–8 the face buttons (square/triangle/circle/cross;
  X/Y/B/A on an Xbox pad).
- **The headset is in the profile.** A Bluetooth headset's hands-free link can be
  8 kHz and hiss whenever audio plays; push-to-talk feedback is rumble (one firm
  pulse on press, one soft on release), with beeps off (`cue=hands-free`), and the
  mic stays open since switching to hands-free outlasts a press. A mic that delivers nothing for 1.5 s is reconnected in place
  (`KSPROPERTY_ONESHOT_RECONNECT`, as Sound settings' Connect does) and the window
  says so.
- **Every dropped clip says why in the window**: too little audio, nothing heard,
  only Whisper echoing its prompt (cut off when it prefixes real speech).
- **Names are first and last** ("First Last"; `UnitName` gives only "First"). The
  addon resolves a spoken name for whispers.
- **Other addons are integrations, optional**: `integrations/<AddOn folder>.md`
  holds what we know of each (API, terms); the agent is given only those whose
  folder is installed (`integrations` in main.rs). Our code guards every call
  (`if Polestar then`, pcall) and works without them. Another player has others.
- One client per install: two running at once both consume slots and bells.
