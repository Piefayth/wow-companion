# WoW Companion

Voice and agent control for World of Warcraft: Forever, played on a controller.
Hold a controller chord, speak, and the PC side turns that into something done in
game: text in the chat box, macros written, action bars rearranged.

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
- **The agent installs addons, on the player's terms.** GitHub first, with the
  maintainer checked (account age, other repositories, stars, fork, commits, tags,
  the `.toc` listing interface 16001, and the CurseForge or Wago page linking back
  where reachable); CurseForge and Wago are fine as sources. It reports the good
  and the concerning and installs only after the player says yes. The research is
  the agent's (`WebFetch` pre-approved for github.com, api.github.com,
  raw.githubusercontent.com, curseforge and wago, nowhere else). `src/addons.rs` is
  only the disk: download with curl, unpack with Windows' tar into a staging
  folder, drop what the addon's `.pkgmeta` ignores plus dotfiles (a source install
  should match the release), refuse any file type an addon has no reason to ship,
  back up what it replaces, and record it in `%LOCALAPPDATA%\wow-companion`.
  It removes only what it installed. New folders need a full game restart.

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
  what its code did after the next reload. The agent gets `Read`/`Grep`/`Glob` over
  `docs/` only (`--restricted`, cwd `docs/`) and 8 turns, to look functions up
  before calling them. `cargo run -- think <AddOns> <text>` shows its answer without
  sending anything.
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
- **The chat draft survives cancel** because `chatStyle` defaults to "im". The fix
  is the setting, offered as a button (`/console chatStyle classic`), not code.
  Sending from Git Bash rewrites a leading `/console` into a Windows path; use
  `MSYS_NO_PATHCONV=1`, since a macro line without its slash may be sent as chat.
