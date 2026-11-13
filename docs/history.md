# How we got here

The working notes of 2026-11-08 to 2026-11-10, moved here verbatim from CLAUDE.md
when it outgrew being read on every request. CLAUDE.md now says what is true; this
says how each thing was learned, measured, and in places got wrong first. When a
rule in CLAUDE.md looks odd, its story is here.

---

# WoW Companion

Voice and agent control for World of Warcraft: Forever, played on a controller.
Hold a controller chord, speak, and the PC side turns that into something done in
game: text in the chat box, macros written, action bars rearranged.

**Notes from the terminal session to the in-game agent** (2026-11-09, read, then
delete once acted on):
- The "companion up?" indicator is a minimap button plus an addon-drawer entry
  (`addon/WowCompanion/Status.lua`, the toc's `AddonCompartmentFunc` lines), fed by
  `src/heartbeat.rs`. Three wiring lines sit in files you were editing: `mod
  heartbeat;` and `heartbeat::start(...)` in `src/main.rs`, and `READY` in the
  voice crate. Keep them when you commit.
- Other addons are yours to use. Their code is in the AddOns folder and their
  globals are live in game: `GearQuest` (`_G.GearQuest`, GearQuest Forever, with
  `GQ.Compare:RankEntries`, `ScoreEntry` and the rest) and Polestar. For "what
  does GearQuest think my next upgrades are", read its source, then call it in a
  `lua` step and print the answer.

**What we do next is `docs/PLAN.md`**: the shared to-do, the player's standing terms, and
who does what. Read it before starting anything sizeable, and update it when you finish.

## Shape

A cargo workspace, three crates, split along their build costs:

- **`crates/pad`**: the controller, over raw HID (`hidapi`). Not `gilrs` and not
  Windows.Gaming.Input: the pad here is a Switch controller through a switch2connect
  adapter in **DS5 mode**, which WGI does not enumerate at all, so neither does
  anything built on it. Raw HID sees it fine, needs no focused window, and reads
  buttons the game has no binding for. Measured on `054c:0ce6`: `home → byte 10 bit
  0x01`, `capture → 10/0x02`, `l1 → 9/0x01`, `r1 → 9/0x02`, `minus → 9/0x10`,
  `plus → 9/0x20`. DS5 mode stays — every other game works with it.
- **`crates/voice`**: mic capture (`cpal`) and local transcription (`whisper-rs`,
  large-v3-turbo on the 4090). Its own crate purely so the CUDA build cannot be
  invalidated by edits elsewhere; see "Building".
- **Helper (`src/`)**: the orchestration — chord to clip to agent to slot write to
  bell — plus every subcommand.
- **Addon (Lua, `addon/WowCompanion/`)**: the in-game half. Applies what the helper
  sends.

There is no Lua on this machine, so `python -I tools/luacheck.py addon/WowCompanion/Companion.lua`
stands in: it catches an unterminated string and an unbalanced block, which are both
mistakes we have actually shipped into the game and paid a reload to discover.

## The channel (PC → game)

Addons can't use the network or read files, so we use the tricks measured by
[t3code-wow](https://github.com/ryanrhughes/t3code-wow/blob/main/docs/ARCHITECTURE.md).
All of it now confirmed on Windows against a live client (see "Where we are"):

- **Slots**: `WowCompanion_S001…` are load-on-demand addons. `LoadAddOn` reads a slot's
  `Inbox.lua` from disk when it loads, so the helper writes Lua there first. Each slot
  loads once per UI session (`/reload` resets). The client only knows files that
  existed at launch, so `install` creates every slot up front and new folders need a
  full game restart.
  Spending all 64 is the real constraint: a reused slot loads from cache and hands back
  nothing, so the helper must track its cursor and know when the game reset it. It can,
  without a game → PC channel: the game rewrites SavedVariables on `/reload` and logout,
  which is exactly when the cursor resets, so that file's mtime *is* the reset signal.
- **Bells**: the "new data" signal. Sound files over 174,762 bytes are reread from
  disk on every play. The helper writes a 10 s silent WAV to ring a bell and empties
  it to silence it; the addon plays the next bell every 0.5 s and checks
  `C_Sound.IsPlaying` 0.15 s later (`PlaySoundFile`'s return value lies). Needs game
  sound on.

## Decisions

- **Don't reinvent what Claude Code already has.** A standing rule from the
  player. The agent *is* Claude Code, so searching, fetching pages, reading and
  judging are its own tools (`WebSearch`, `WebFetch`, `Read`, `Grep`); give it the
  tool and the instructions rather than writing our own version. Write code only
  for what Claude Code cannot do: the channel into the game, the controller, the
  voice, and fences that must hold whatever the model decides (the install-time
  file checks, the Lua sandbox). The first addon manager broke this with a Rust
  GitHub search that returned Flutter widgets; the agent's own search found the
  right addon on the first try.
- **Voice is the last resort, not the interface.** The player would rather have a
  controller path that works in every situation, and reach for speech only where
  the game has none. So a chat draft is cleared by the chat setting that clears it,
  not by saying "scratch that" (which exists, but is the fallback).
- **The agent is Claude Code at full strength.** Every tool, no permission
  prompts (`--dangerously-skip-permissions`), working from the repository root, at
  the player's explicit request. The first design walled it off (read-only tools
  over `docs/`, `--restricted`, a domain allow-list) and the result was the
  opposite of the rule above: code of ours to install addons and restart the game,
  doing badly what Claude Code already does. Steps remain, because they are the
  only way *into the game*; everything on the PC the agent does with its own
  tools. The trade is stated plainly: what it reads from the web or chat can steer
  it, and the player accepted that. The prompt goes on stdin, since the character
  export pushes a command line past Windows' 32,767-character limit. Requests run
  off the voice loop, so the pad stays live during a minutes-long job.
- **Addons are installed on the player's terms, as instructions.** GitHub first
  (CurseForge and Wago are fine), the maintainer checked (account age, other
  repositories, stars, fork, commits, tags, the `.toc` listing interface 16001, the
  CurseForge or Wago page linking back where reachable), the files looked at in a
  staging folder before placing (Lua, XML, `.toc` and media only; an executable or
  PC script means stop), the good and the concerning told, and nothing installed
  before the player says yes. Then the agent installs it the way a release would
  (`.pkgmeta` ignores and dotfiles left out), backs up what it replaces, and records
  it in `%LOCALAPPDATA%\wow-companionddons.json`. Not foolproof against a
  determined attacker; it catches the low-grade kind. A restart is the agent's too:
  it offers `/quit` as a button (quitting from addon code is protected, killing the
  process skips the save), waits for the exit, and relaunches (flavour `wowf`).

- **No game → PC channel.** t3code-wow reads an on-screen pixel strip; we skip it.
  It's the complex part and the ToS-grayest part. Context the agent needs (current
  bars, macros) comes from SavedVariables, which the game writes on `/reload` or logout.
- **Never act for the player.** Configuration only, out of combat only. Chat text is
  placed in the box; the player presses send. No automation of play.
- **Reload after touching the bars.** Placing actions from insecure code taints the UI,
  which later surfaces as "Interface action failed because of an AddOn" on an unrelated
  keypress. A reload clears the taint, flushes SavedVariables and resets the slot
  cursor in one move — but the addon cannot ask for one: `ReloadUI()` is **protected**,
  and calling it comes back as `ADDON_ACTION_BLOCKED: WowCompanion called Reload()`.
  (This file claimed the opposite for a while; it was never tested.) So a reload is
  offered as a secure button, like everything else protected. Chat
  insertion taints too, and not harmlessly: opening the edit box from insecure code
  leaves the gamepad focus restore blocked, and **the A and B buttons stop working**
  until the taint clears. It announces itself as one mild "interface action failed"
  notice, which is why it read as cosmetic at first. It is not.
  The blocked call is `SetPreferredGamepadInteractTarget`, the gamepad UI's interact
  targeting — so it lands squarely on the controller player we are building for, and
  it fires whenever that targeting next runs rather than when we taint it, which is
  why it looks intermittent. Corroborated outside this project: Horizon-Suite #489
  reports the same function blocking on the same client, and identifies the cause as
  addon code reparenting, showing or hiding a *Blizzard* frame. That is exactly what
  opening the chat box was, and it is why the player opens it instead of us.
  The continuous bell poll is **not** a taint source: `/wc quiet` stops it, and a fresh
  session with it running interacts cleanly. Worth stating because it was the obvious
  suspect, being the only thing the addon does nonstop, and it was wrong twice over.
  So chat delivery no longer opens anything: it writes only into a box **the player
  opened**, and refuses with a hint when none is open. A box opened by real input
  keeps the secure focus path intact; we only set its text.
  Dictation appends, and the controller's cancel unfocuses the box without
  emptying it, so a discarded line used to come back glued to the next. Saying
  "scratch that" (or clear, cancel, never mind) empties it, focused or not, by
  `SetText("")` alone. A clip that opens with a channel ("party, ...", "to guild
  ...", "slash g ...") is sent as that slash command, since neither Whisper nor a
  controller can produce "/p". Whispering a player by name is not mapped: names
  are first and last here, and where a spoken name ends is a guess.
- **The agent writes Lua; the client is the fence.** This replaced "the model never
  writes Lua". Insecure code cannot cast, target or move — that is what protection
  means — so agent code can do no more for the player than any installed addon.
  `lua` runs a chunk once; `module` also stores it in SavedVariables and reruns it at
  every login, the nearest thing to the agent writing its own addon (new addon
  folders need a game restart). Each runs out of combat in its own environment:
  `print` goes to the window, new globals are allowed, replacing a Blizzard global is
  refused (taint), and a short list of things that are not ours — deleting items,
  sending chat, trading, spending gold, leaving groups, `loadstring`/`getfenv` — is
  refused by name. That list guards against mistakes, not an adversary. Every
  non-login run is followed by the `issecurevariable` diff, so code that taints says
  so. Results, stored modules and taint land in the context export, so the agent sees
  what its code did after the next reload. `cargo run -- think <AddOns> <text>`
  shows its answer without sending anything into the game (it can still act on
  the PC, now that it has every tool).
- **Register a secure button for `"AnyDown"`.** Measured one variable at a time:
  `"AnyUp"` alone runs the wrapper — `PreClick` and `PostClick` both fire — while the
  macro does not, which reads exactly like a permissions refusal and is not one. Both
  edges fire it twice, once per edge. `"AnyDown"` alone fires once. The earlier claim
  here that ordering was the cause was wrong: two things were changed at once and the
  fix was credited to the wrong one.
- **For anything protected, offer a button.** Insecure code cannot call protected
  functions — `ReloadUI()` is one, and asking comes back as "WowCompanion called
  Reload()". A hardware button press is trusted, so build a
  `SecureActionButtonTemplate` button, set `macrotext` on it out of combat, and let
  the player press it. Macro text is the ceiling, which is also the ceiling of what
  the player could type, so it grants nothing new — and `PlaceAction` is *not*
  expressible, so bar rearranging stays outside this door.
- **Addon frames can be gamepad-focusable; it takes three things.**
  `SmartNavigation_MarkFrameFocusable(frame)` (the `SmartNavigation_*` globals
  arrived in 1.60.1, this client's exact patch), registration in `UIPanelWindows`,
  and showing via `ShowUIPanel` — marking alone is not enough, because the focus
  cycle walks registered panels, not frames an addon merely showed. Hide with a plain
  `frame:Hide()`: a programmatic `HideUIPanel` from a click handler is a known taint
  path on this client. Measured working, after three wrong guesses that could have
  been one search.
  A plain Hide leaves the frame in `FrameControlsManager.shownFrames`, so its
  fallthrough catcher keeps the d-pad and face buttons off the bars **after the
  window is closed**. So `OnHide` calls `GamepadMode.FrameControlsManager:FrameHidden(self)`,
  as Blizzard's ColorPickerFrame does (it is SecureHelper-wrapped for such callers).
- **Never leave a bell ringing.** `/reload` puts the addon's cursor back at slot 1, so
  a bell still ringing from the last send is heard again and the command runs a second
  time. That is how the chat taint above turned into A and B staying broken across
  reloads: reloading re-triggered it. Ring a bell only until it is heard, then silence
  it, and clear stale bells before sending.
- Voice: push-to-talk, whole clip transcribed after release (more accurate than
  streaming dictation). Pass a vocabulary prompt (spell names etc.).
- **Not Windows voice typing (Win+H).** It needs "online speech recognition" on, which
  sends mic audio to Microsoft system-wide. Local Whisper keeps a push-to-talk mic —
  which catches whatever was in the room — on the machine, and beats a network round
  trip besides. Note the agent step still sends the transcript off the box: local
  transcription protects the microphone, not the instruction.

## Where we are

The channel works on Windows, end to end, against
`S:\World of Warcraft\_forever_` (client 1.60.1.70862, toc 16001 — the toc is just the
version encoded, so 1.60.1 → 16001). Measured 2026-11-09:

- **10 of 10 messages delivered**, about 1 s from write to arrival. That 1 s is the
  floor of the measurement, not the latency: both sides stamp with second-resolution
  clocks, and the real figure is bounded by the 0.5 s poll plus the 0.15 s
  `IsPlaying` check. Sub-second timestamps on both ends if the number ever matters.
- **Bells behave, and the file lock is bounded.** `always.wav` plays, `never.wav`
  doesn't. The probe runs saw no lock at all; live sending does hit one, and the retry
  loop in `write_reporting` clears it in 100–205 ms over 3–5 tries. So the open Windows
  question — can the helper overwrite a sound the game has open — is answered yes, with
  a retry, and the loop's 2 s ceiling has never been approached.
- **Chat and macros work.** `CreateMacro` and `EditMacro` succeed out of combat, and
  `SetText` on a player-opened chat box works. `ChatFrame_OpenChat` also works, but it
  is the call that broke A and B (see Decisions), so nothing uses it now.
- `FrameXML.log` logs every slot load, including empty ones — a free, precise trace of
  the channel that costs nothing to read.

Three things the real client taught us that a Mac couldn't:

- **Opening chat from a slash command defeats itself.** The Enter that submits the
  command tears the edit box down after the handler returns, so the open has to be
  deferred a tick. Bell-triggered delivery isn't affected, but any slash-command path is.
- **Action slots are not 1–120 here.** They are addressed by number, and the classic
  bars use the low ones, but the **gamepad UI draws 181–272**: top bar 181–184, left
  185–192, right 193–200, bottom 201–208, stance 265–272, with the extra action
  button at 397. The classic bars (1–72) and the multi-bars up to 180 all exist and
  are all hidden. Anything that loops `1, 120` is looking at the wrong bars. Measured
  by walking every frame (`EnumerateFrames`) for an `action` field or attribute; the
  export now labels each filled slot with the bar that draws it.
- **Chords are not bindings.** `GetBindingKey` on a gamepad button's
  `bindingAction` (`ACTIONBUTTON189`) returns nothing, and no frame field names the
  trigger that brings a bar up. Each button's `SlotArt` atlas does name its base
  input, identically on every bar: 1–4 d-pad left/up/right/down, 5–8 square,
  triangle, circle, cross (PS icons, because the pad is in DS5 mode). The modifier
  is learned: a watcher reads `C_GamePad.GetDeviceMappedState` and, when a bar
  button enters its `PUSHED` state, credits that bar with the modifiers held. Keyed
  by bar, since forms page the slots under the same buttons. `state.buttons` counts
  from 1 and `ButtonIndexToBinding` from 0, so it is `index - 1`; the first version
  missed that and learned L2 as "R2" and R2 as "PADLSTICKUP". Measured on this pad:
  top bar no modifier, left L2, right R2, bottom L2+R2. The "StanceBar" frames
  learned R2 as well, and the player explained why: they are not a bar but the
  in-form page of the bar `GamepadStanceBarOverride` names, set here to the R2 bar.
  Switching forms is the L1+L2 wheel. The export prints the form and that setting,
  and the agent says which page it picked and why. The export's
  "controller" section shows what is learned and how many presses lit a button,
  and the agent is told never to guess a `?`.
- **Names are first and last.** The character is "Pietra Fayth", and
  `UnitName("player")` returns only "Pietra": a whisper addressed by it came back
  "No player named Pietra is currently playing". The API knows surnames
  (`C_PlayerInfo.ShouldDisplaySurname`, `C_NameUtil.ReplaceSurnameSeparatorWithLinkSeparator`,
  so the full name carries its own separator). Which form a whisper accepts is not
  yet measured; until it is, nothing addresses a player by name.
- **One client per install.** Two running at once both load slots, both consume bells,
  and both write the same SavedVariables file, so the last to reload wins and the
  measurements quietly lie. Diagnosed the hard way.

**What this client's API actually is.** It is a **retail-11.x-era API behind a 1.60.1
version string**, which is the single most useful thing in this file: `C_ClassTalents`
has hero talents, the spellbook is `C_SpellBook`, names come from
`C_Spell.GetSpellInfo` — and `GetSpellInfo`, `GetSpecialization`, `GetNumSpellTabs` and
`GetSpellBookItemInfo` do not exist here at all. So reach for the *retail* reference,
never a Classic one, and expect anything removed in 11.0 to be gone.

Two local files say it exactly, both regenerated from the live client:

- `api-1.60.1.txt` — **10,957 names**, every global function plus every member of the
  271 `C_*` namespaces. `/wc dump`, then `cargo run -- api <AddOns> <out>`. This is the
  complete truth about what exists; the agent's failure mode is not forgetting what a
  function does, it is confidently calling one that exists in retail and not here.
- `api-1.60.1-signatures.txt` — **8,437 signatures**: 6,621 functions with argument and return
  types, 1,816 events with payloads, plus the structures and enumerations those point
  at (so `SpellBookItemInfo`'s fields and `Enum.SpellBookSpellBank`'s values are stated
  rather than guessed). `/wc docs`, then `cargo run -- apidocs <AddOns> <out>`.

The probe reported "no API documentation tables" and that was a misreading:
`APIDocumentation` is nil *at startup* but `APIDocumentation_LoadUI()` loads it, which
is what `/wc docs` does. The coverage is partial and the gap has a shape — 5,038 of the
names carry a signature, 5,919 do not, and the undocumented half is the old
FrameXML-era C globals, which is to say precisely the ones we depend on: `PlaceAction`,
`HasAction`, `GetActionInfo`, `CreateMacro`, `GetBinding`, `ReloadUI`,
`EnumerateFrames`. For those, the name index proves existence and the retail wiki
supplies the signature.

The docs also carry flags, which `/wc docs` now keeps: `SecretArguments` on most,
`HasRestrictions` on 281, `IsProtectedFunction` on 74 — but only frame methods such as
`Show` and `SetPoint`. Since the globals we lean on are undocumented, the docs cannot
say whether *they* are protected; only calling them can. And existing is not working:
`/wc alive` calls every documented read that needs no arguments and sorts each by
what came back (value / zero / empty / nil / nothing / error / absent), and
`cargo run -- alive <AddOns> <out>` pulls the list.

Dead ends, so nobody re-walks them: `ADDON_ACTION_BLOCKED` never fires for the gamepad
taint (it does fire for a direct protected call such as `ReloadUI()`), and `General.log`
carries nothing. `Logs	aint.log` is **not** a dead end, contrary to what this said:
it appears once something is actually blocked, with full stacks naming our file and
line. Check it whenever "Interface action failed" shows.

**The whole API surface, with the terms of each part:** `docs/api-surface.md`
(summary) and `docs/api-surface.tsv` (all 10,957 names, one row each: tier,
conditions, secret-argument policy, how often Blizzard's UI calls it, our own
measurement, signature). Generated by `tools/api_surface.py` from the client's
docs flags, the wiki's protected/nocombat/hwevent tags (cached in
`docs/api-wiki-tags.tsv`), Blizzard's source and `api-useful.md`; rerun it after a
patch. Look a function up there before using it: its tier says whether addon code
may call it at all, only out of combat, only inside a press, or may get secret
values back. This client runs retail 12.0's **secret values** system: in combat
and other restricted contexts many results (`UnitHealth`, auras, cooldowns) come
back opaque to addon code.

**Read Blizzard's code before calling anything.** `docs/wow-ui-source` is a
shallow clone of [Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source),
branch `forever`, which is this exact build (1.60.1.70862): 2,877 Lua files of the
interface Blizzard ships. How Blizzard calls a function (its arguments, its guards)
is evidence that costs no call and cannot crash the game, which is why it replaced
widening the blind survey: with thousands of functions, surveying by calling means
crashing over and over to learn little. Not committed (gitignored); reclone with
`git clone --depth 1 -b forever` after a patch. `docs/third-party/` holds another
gamepad addon's notes (Improved Forever, MIT), which reached our own taint
conclusions independently.

**Never call the API blind.** The first `/wc alive` called every documented
no-argument read in the client and **crashed it**: an ACCESS_VIOLATION reading
address 0 inside `Wow.exe`. `pcall` catches Lua errors, not a C null dereference.
Seven more calls were refused (`ADDON_ACTION_FORBIDDEN … called UNKNOWN()`). The
survey now covers only the namespaces this project would use and skips anything
flagged `HasRestrictions`. It keeps the running function's name in a plain local,
because a crash report prints the executing Lua frame's locals — which is all that
named "call 58" last time. The A/B breakage is intermittent: it took three identical attempts to see it
once.

What did work is `issecurevariable`. `/wc place <variant>` asks it about all ~265,000
globals and global-table fields, before and after the action, and diffs. The
known-bad control lights up: opening the chat box from addon code newly taints 8
variables, among them `LAST_ACTIVE_CHAT_EDIT_BOX` and `ChatFrame1EditBox.text`. The
gamepad UI reading that state is how A and B break. So attribution *is* reachable
from Lua after all, a variable at a time; it was only the logs that were dead.

Measured: `pickup`; `PlaceAction` into an undrawn slot (4); `PlaceAction` into a
slot the gamepad UI draws (189, left bar 5); `C_ActionBar.PutActionInSlot` into
another (202, bottom bar 2); and a move (`PickupAction` 181, place in 13, and back):
each taints **nothing** and raises no blocked-action notice. So the old claim that placing actions taints the UI was wrong, and bar
placement is now an agent command (`bar`: slot, spell/macro/item/empty, name). Taint lives until `/reload`, so the harness allows one variant per
session; the first run did several in one, and every hand check after `chatopen`
was judging `chatopen`'s taint. `DisplayInterfaceActionBlockedMessage` is hooked
(`hooksecurefunc`), so each "Interface action failed" is now timestamped and pinned
to the test in flight.

## Building

`whisper-rs`'s `cuda` feature compiles ggml's CUDA backend from source: hundreds of
`.cu` files, each built for every architecture ggml supports. Set `CUDAARCHS=89` (cmake
3.20+ reads it; 8.9 is the 4090's) to build for this GPU alone and skip most of that.
`whisper-rs-sys` has no passthrough for it, which is why it goes in the environment and
not in `Cargo.toml`. Needs libclang for bindgen — `C:\Program Files\LLVM` here.

## The agent

`claude -p` headless, not the API: no key to manage, it draws on the signed-in
subscription, and `--json-schema` constrains it to `say` plus a list of `steps`,
each one of the shapes the addon's dispatch table accepts. Several steps travel as
one `batch` message (one bell), run in order, and each step's result shows in the
window; at most one `press`/`reload`, since only one button can be offered. The
first version allowed one command per answer and told the player to "ask again for
each one", which nobody wants. The model is **Opus** (`run ... agent=sonnet` to
trade back): Sonnet got chords and multi-step requests wrong often enough that
the player noticed. A four-change request takes about 9.5 s on Opus. `session_id` from the
first reply plus `--resume` keeps one thread, which is what makes "put it on the other
bar instead" mean anything. Startup is seconds per utterance — a deliberate trade, and
the reason the agent is spawned *before* the in-game "thinking" announcement, so the
bell wait overlaps the call.

## Next

The pipeline runs end to end: chord → mic → whisper → agent → slot write + bell, with
replies and the offered button arriving in one message. `probe` refuses to run unless
`Wow.exe` is up, which is worth keeping for anything that writes into a live client.

Open:

- **The agent has the context.** The addon exports character, filled action slots,
  empty on-screen slots, every action-bound frame, bound keys, macro bodies and the
  spellbook on every `/reload` and logout (`PLAYER_LOGOUT` fires just before
  SavedVariables is written, the only moment that reaches disk). The helper sends the
  agent the five sections it reasons with (~2.5 KB), once per change, and Whisper's
  prompt is the spellbook and macro names, rebuilt per clip. `cargo run -- context
  <AddOns>` prints exactly what both receive.
- **`PlaceAction` is isolated, and clean.** Every `/wc place` variant except the
  `chatopen` control tainted nothing (see "Where we are"), so bar rearranging is an
  agent command. What the scan cannot see is a hand check under real play: no
  `/wc verdict` has been recorded yet, so the first "Interface action failed" after
  a `bar` command is worth a look at `taint.log`.
- **Never kill the companion; restart it.** `wow-companion restart` closes the mic
  properly and hands over. On 2026-11-09 a night of `taskkill /F` and exits that
  skipped cleanup, each abandoning a live hands-free stream, left the AirPods' voice
  link wedged: Windows listed every device as OK and the mic delivered zero buffers
  (`miccheck` measures it). Now the stream is closed before handover, and a mic that
  delivers nothing for 1.5 s is healed in place: KSPROPERTY_ONESHOT_RECONNECT
  (KSPROPSETID_BtAudio) sent to `IKsControl` on each endpoint's connected filter
  device (not its topology part, which refuses the interface), the same call as
  Sound settings' "Connect", no admin needed, then the mic reopened and the player
  told. Measured accepted by the three AirPods endpoints. `wow-companion reconnect`
  sends it by hand. Push-to-talk feedback is rumble (DualSense report 0x02): beeps
  played over the 8 kHz hands-free link hiss, and opening the mic per press is too
  slow (no audio during a whole press).
- **Devices come and go.** A pad that sleeps or a headset that drops hands-free used
  to end `run`. Now a failed HID read, or a mic stream error other than an underrun
  (`DeviceNotAvailable` is what WASAPI reports), is waited out and reopened every 2 s;
  a clip in progress when the pad vanishes is discarded. Neither has to be present
  at startup either; a missing mic prints the inputs it can see, so a mistyped
  `mic=` is visible as a name absent from that list. Whisper's silence phantoms
  ("Thank you.") are dropped when the clip's RMS is under 0.01, and every clip prints
  its level so that floor can be tuned from real numbers.
- **No file is written live; reloads are the return path.** Measured: `LoggingChat`
  creates `Logs\WoWChatLog.txt` on demand and then writes nothing, not even across
  two reloads. An addon-registered CVar set to a marker, and our own macro edited
  to carry one, changed **zero** files under the client in 25 s: settings and
  macros reach disk at reload or logout, like SavedVariables. (`Screenshot()` does
  write at once, but reading data out of it is the pixel strip by another name,
  the ToS-gray thing this project declined; that is the player's call.) So the
  agent's answer carries `look`: it gets a Reload button offered, and when the save
  lands the helper calls it again with the refreshed context, so one press is the
  whole cost of the agent seeing what its code did.
- **The chat draft survives cancel, by Blizzard's design.** The box closes on
  losing focus only when empty (`ShouldDeactivateChatOnEditFocusLost` is
  `GetText() == ""`), in every chat style; Escape clears it (`ClearChat`), but the
  controller's cancel takes focus instead. Offering `chatStyle classic` was a wrong
  guess made before the source was here to read. The fix: on `EventRegistry`
  "ChatFrame.OnEditBoxFocusLost", which fires before that check, empty the box,
  and Blizzard's own code closes it (`keepChatDraft` turns it off). Dictated
  "/g hi" also runs the box's `ParseText(0)`, which is what typing the space does,
  so the header shows Guild before send. Both new paths get the taint diff the
  first time they run each session (`WowCompanionDB.pathTaint`). Sending from Git
  Bash rewrites a leading `/console` into a Windows path; use `MSYS_NO_PATHCONV=1`.
- **The agent never waits on the player inside a turn.** Its answer is invisible
  until finished, so its first restart sat ten minutes waiting for a Quit press and
  looked hung. Waiting goes to a detached process; the turn ends at once.

---

## From the code's comments (moved 2026-11-11)

History that sat in the addon's comments; the comments now say only what is true.

### Errands.lua
- The raw map API ignores a place's frame `f`, so the first live arrow pointed wrong; positions now come from the nav capability (Polestar's frames). A later "wrong arrow" was a test errand pinned at a different spot than Polestar's target: measure before swapping art.
- Arrow art tried: supertrack chevron (too wide), the tracker's waypoint arrow (curved), NPE_ArrowUp (disliked); the minimap player arrow stayed.
- One grey detail line was unreadable on bright ground: each fact got its colour, the tracker a dark backing. The layout follows Blizzard's objective tracker metrics, set by a design pass from its source.

### Window.lua
- Blizzard's DropdownButton (and a cover over it) stayed out of the controller's focus cycle; the dropdown is plain Buttons.
- A plain Hide left the window on FrameControlsManager's list and the bars dead; OnHide calls FrameHidden.
- L1/R1 once paged the tabs; they became talk-button slots, so the window binds nothing.

### Board.lua
- Anchoring to the 10x10 GamepadPersistentInputLegend put the board on top of the legend; it anchors to the widest visible child background.
- A non-wrapping font string anchored only left and right drew just its first line.
- Hiding the board mid-fight read as a lost panel; it shows in combat (the old hold-until-the-fight-ends path was removed).

### ChatWheel.lua
- The player gave up on a slow line and spoke another, so a "transcribing" tag shows; a 30 s wait looked stuck, so it times out at 6 s.

### Chat.lua
- A Battle.net whisper cannot go out from a macro: the line whispers the friend's character instead.

### Style.lua
- labelStyle reads "Shapes" on this client, not "Shp" (measured); unmatched, the player saw numbered glyphs instead of Sony shapes.

### Bags.lua, BagsStandIn.lua
- BattlepayItemTexture (the store highlight) showed on every slot by default.
- The controller cursor and our own highlight both landed on a slot (two markers, two tooltips).
- The secure child of ContainerFrameCombinedBags replaced the first stand-in (their frame at alpha 0 under ours, mirror mode, cursor anchors).

### Interact.lua
- Earlier combat-interact designs saved `mode`, `takeKey`, `holdTested`, `tapMoved`; `db()` clears them.

### Fonts.lua
- An odd entry in `GetFonts()` raised a Lua error on a font switch; each object is read under pcall.

### Engine.lua
- SecureHelper calls made in a fight showed "Interface action failed" 40 times in one night: the deferred focus helpers.

### Tests.lua
- The first PlaceAction run was spoiled by chatopen's taint living on: one test per UI session.

### Export.lua
- Advice the export now prevents: an off-hand beside a two-hander, a pouch already worn, Skinning called missing.
- StanceBar frames are the in-form page of the bar `GamepadStanceBarOverride` names, not a bar of their own (the player's correction).

### Status.lua
- The first heartbeat used 10 s bells the game held open for good; it moved to `pulse-a.wav` / `pulse-b.wav`.

### Probes.lua
- The first probe called every read-shaped API; one crashed the client in C, seven were ADDON_ACTION_FORBIDDEN, and the crash named only "call 58 of a batch": the name is now held in a local while it runs.

### JobsModel.lua
- The game's and the PC's clocks were measured 2.3 s apart (2026-11-10).

### The Companion window and its messages (the player, 2026-11-10/11)
- Each message got its own controls ("give the individual messages their own panel ... once a message doesn't have anything you can do to it anymore, the majigger goes away"), as small icons on the lines already there; the glowing loot X beside a plain arrow did not match, so both are one flat family.
- A cancel is an intent until the job ends ("I'd like to truly know that it actually got cancelled"); an X on a message already sent read as cancelling the message, so the running job's X sits on the work line.
- Hiding the button under the cursor left the cursor aiming at nothing; Xs scrolled out of view were still reached below the window; the scroll frame did not redraw until the cursor moved; up from the scroll arrow did not reach Cancel (the jump chain).
- A line placed among ones already read made the conversation jump, and a queued line covered the working line: lines only append, the work entry changes in place.
- Two shortcuts' legend lagged the tab; on Errands "square to cancel, cancel what?": they live on the Chat tab only. L3 presses the offered button.
- A Reload from one agent replaced the Quit another had offered: one offer per conversation.
- The window "randomly disappearing and sometimes showing up in combat": secure buttons are stowed for a fight (Stow.lua).
- Replies waited unseen unless checked: the minimap button shows unread news.
- The slate: the two darkest of three tried; Blizzard's tiles first (marble too busy and near black, rock flat grey, the neutral tile wooden planks); brown beside grey read as muddy. The warm off-white for replies was an experiment against halation on a TV.
- Top tabs, not side tabs (tabs on tabs beside the list); the well's shadow; "one panel that you filled with stuff" (ButtonFrameTemplate); the window scale for a TV.

### Other addon comments (2026-11-11)
- Export: a quit released the character mid-export and wrote four "-- nil" lines; the export now says the character was released.
- Fonts: SetFont's false on a first load was measured to mean "loading", not "refused".
- Link: bells asked every frame made the game hold its sound files; at 0.1 s it never did, and 0.5 s was the earlier rate.
- Offer: the click edge was measured one variable at a time: "AnyUp" ran PreClick and PostClick but not the macro, which read like a permissions refusal.

### The companion's comments (src/, crates/, 2026-11-10/11)
- Bells: a small bell polled constantly was locked for good (the window bell); a bell deleted while polled and made again was never heard (223 polls, 0 heard, 2026-11-10); the quiet bell, 10 ms of sound padded to size, could not be emptied once polled; a retry that gave up quietly made a stuck bell look like nothing.
- Slots: a session spent all 64 (progress lines nearly half) and every later reply was lost; there are 512. After a relaunch, messages were counted against the old session and the fresh addon waited on a slot that had already rung (2026-11-10): the cursor's stamp holds the game's start. A ring that reached an idle set across a reload was taken before its slot was written, the old inbox read and the real one never (2026-11-11).
- Twice a retired handler still live in the game kept opening the chat box: a stuck chat box and a half-dead controller. Hence `addon_is_stale`, which held everything but lines, progress and reloads while the addon on disk was newer than the UI session. It went on 2026-11-11: an evening of agents installing addon files dropped the player's dictation ("You are welcome", "Hello") and `heard`, and what it guarded against, our code opening Blizzard's frames, `tools/luarules.py` refuses at the source since 2026-11-10.
- Install emptied every inbox and bell and wiped messages the addon had not read ("Inbox.lua is empty", "slot 4 failed: nil", 2026-11-10). A `"$Exe:"` stopped the release script parsing, unseen until a release (2026-11-11); a test parses it now.
- Messages were Lua text built by `format!`, edited with `replacen` and told apart by their prefix; a field added in front broke a reader elsewhere and lost every reply made while the game was closed (2026-11-11).
- Jobs: while every clip let go during another's hearing joined it, an 11 s transcription swallowed the two messages after it (2026-11-10). A cancel hit the message after the one meant, and a cancelled message the agent had seen was answered as if said (2026-11-10).
- Requests: L1's addon split ran out of steps and stopped dead until someone said "continue" (2026-11-10). An L1 request ended when its announcement failed (the game had closed) while its agent worked on, and the reply was lost (2026-11-11). A background command finishing after a turn woke it again, and its "No change from my last message..." replaced the real answer twice (2026-11-10).
- The voice loop: sending from it froze the buttons and the cues whenever an agent was talking (measured with a request made while another ran). Making a slot's conversation locked the main one, held for a whole request: the voice loop waited minutes, the pad and the rumble dead (2026-11-10).
- Restart: closing the mic before the next copy opened its own let Windows drop the hands-free link, and the first press after every restart recorded silence (seen twice). Both copies read the pad and answered one clip twice (2026-11-10). A game still saving after its window closed counted as a second client beside the new one (2026-11-11).
- Mic: a floor on level dropped a real, quiet sentence (0.0024, the first press after a restart) without a word to the player. The resampler before the sinc doubled each sample of an 8 kHz mic, mirroring the voice into 4-8 kHz, and let half of what a 48 kHz mic heard above 8 kHz fold back into the voice.
- Strip: three `strip --send` reads in a row each returned the one before (2026-11-11); each read names a fresh id.
- Saves: an edit of ours put a raw newline inside a string and broke a save file for minutes (2026-11-11). We no longer edit saves, and every save the game writes is copied.

## The frame bell trial (2026-11-11)

The player asked for the game to check for messages every frame instead of every
half second ("if it's cheap i'd do it every frame"). Measured first, in game at
120 fps: a check of a missing file cost about a microsecond and moved no frame
time, and the half-second pulse bell played 2 ms after it started. The trial
(PC 850e3ca, game 3a25fb2) rang eight frame bells `f1`..`f8` beside the message
bells, with the message bell's ten-second file, emptied 2 s after each ring.

It broke delivery for the evening. The ten-second bell is streamed and was not
playing a frame after it started, so the game restarted it every frame and never
heard it; a file being played is held, so the PC could not empty it. Left
ringing, `f3` rang again for slot 11, 19...: the game took those slots (an
earlier session's message, skipped), and ran ahead of the PC to slot 26 while the
PC wrote slot 9, so everything after went into slots the game had passed. The
constant restarting also held the heartbeat's pulse bells (the minimap button
went grey). "Beside" was not isolation: the trial shared the game's sound system
and, by taking slots, the message channel's cursor. `/wc frames off` and a
reload restored it. The one real message the frame bell caught arrived in 8 ms.
What came of it: docs/proposals/slot-bells.md (a bell per slot, a set per
session, watched before it takes anything).

## The companion's settings move into the game (2026-11-12)

The talk button lived in two places that could disagree: `ask=` in
settings.toml (the bit the companion reads over HID) and WoW's binding of
`WOWCOMPANION_WINDOW` (the tap that opens the window). On 2026-11-11 the WoW half
was simply empty after 5834a61 and minus did nothing in game. Rejected on the way
(docs/proposals/settings-in-game.md): the game as the truth, which needs either
a name-to-bit database for every pad (SDL's `gamecontrollerdb.txt` has the
DualSense and the Edge with the measured bits, but its lookup and WoW's own
remapping make it a second implementation agreeing by hope) or a screen read per
request (and no talking on loading screens). Chosen: the companion holds every
setting; a button is set by pressing it on our page, so one press gives WoW's
name and the bit, stored together; WoW's binding is a copy the addon writes from
`status`. The setup window's button learning went with it: it guessed buttons by
which bytes stayed still (a counter byte fooled it); buttons now come from the
pad's report descriptor, Sony's layout or the XInput word. Built the same day:
the Lua half 3e9b04f (Main), the Rust half after it. The fallback tag is
`settings-in-game-before`.

## The strip's reads cost frames; a window of ours keeps the game composited (2026-11-12)

With the command-strip watcher on, WoW ran at 116 fps instead of 120, and the
player felt it as stutter (with vsync, a frame shown twice about four times a
second). Lowering every graphics setting to the minimum still gave 116, so it was
not GPU headroom. Turning the watcher off gave 120. The cause: a game in
independent flip hands its frames straight to the display, and every Desktop
Duplication capture made Windows switch it onto the compositor and back, losing
frames at each switch. A 2x2, alpha-2, click-through, never-activated topmost
window over the screen's corner keeps WoW composited all the time, so a capture
switches nothing: 120 fps with the watcher looking twice a second, and 116 again
the moment the window closed. The window now lives with the capture session
(`src/composited.rs`). The cost is a frame reaching the screen up to one refresh
later. With looks cheap, the watcher went to ten looks a second (a press waits
about 50 ms instead of 250), still 120 fps. Considered and left for later: hearing the game through its file opens
(ETW, docs/proposals/etw-signals.md), which needs no capture at all.

## A request outlives the companion copy that started it (2026-11-12)

A restart waited for every request in flight, because an agent's answer came
back on a pipe the starting copy owned: an R2 request held a restart for ten
minutes, settings changes queued behind agents (before they became hot), and a
crash lost the reply in flight. Now an agent starts detached, its prompt a file
for stdin and its stream and complaints files in `runs\<job>\`, with `run.json`
naming its conversation, round and process (id and start time, so a later
process given the same id is not taken for it). Any copy follows the stream to
its answer. At a hand-over or exit the old copy's followers let go of their
runs, any reply already on its way out finishes, and the channel closes; the new
copy takes over (ledger, runs, the game's commands) only once the old one has
exited (the companion lock), so two copies never write the ledger or the slots.
A job running at a start with its run on disk is followed again instead of
ended. The look waiting for a reload moved to a file for the same reason. The
progress courier no longer holds a finished request: it slept 15 s after a
progress line before looking again, so a reply could wait on it (rarely: 1 of
36 replies that followed a progress line went out right after one).

## A session's messages waited on a slot that never rang (2026-11-12)

At 21:11 the player reloaded twice in 23 s, and for the whole session that
followed the game took no message (`channel.taken = 0` in 5,064 plays): Main's
replies, the agents' reads, everything. The cursor took the session from Core's
save time, the bell set from Link's load count. A send landed while the game
was writing its save: Core's file was new and Link's not yet, so the cursor
started over at slot 1 in the old set. At the next send Link's count was new,
the set moved on, and the cursor went on at 2. The game waited on its set's
slot 1. The two readings had been compared on every send since 2026-11-11
(`session.rs`, on trial), 162 agreements and this one pair of disagreements,
which the trial's audit lines showed. Session took over the channel: the cursor,
the set and the slot count come from one reading of Link's save, so they cannot
come apart, and a save that does not parse yet is read again.

## The conversations filled with old copies of the character (2026-11-12)

The player noticed the agents getting worse. Measured from their transcripts:
L1 at 940k tokens of a 1M window, R2 545k, R1 495k, Main 490k, L2 360k. Each
request after a reload carried the whole export, profile and integrations
(28k characters): the companion skipped it only when unchanged, and a reload
always changes it (its time, the press counters and log), and the agents ask for
reloads all the time. L1 had been sent 235 copies. Claude Code compacted only
near the 1M window. The character became a file the agent reads (the message
says it changed and where each section is), the profile moved into the appended
system prompt, and `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=20` makes a conversation
compact at about 200k: measured honoured by `--print` on a resumed session (2%
compacted 27.8k to 5.8k in 12 s), while `CLAUDE_CODE_AUTO_COMPACT_WINDOW` alone
was not. A fresh agent reading the file answered from it at 57k tokens.

## A message stayed "running" above newer ones (2026-11-13)

The player saw Main's work line, its seconds counting, sitting above messages
sent and answered after it. Two messages had been said while Main was busy, and
one run took both. The companion restarted onto a new build during that run. The
run's members were a field of the jobs table, held in memory only; the ledger
keeps each job's id, conversation and state. The copy that took over followed the
run by the job that led it, and its answer ended only that job. The other job
stayed running for good, and the game draws one work line over a conversation's
running jobs, from the oldest. The field is gone: a conversation runs one agent
at a time, so its running jobs are that run's, which the states alone say, and
the game already read them that way.
