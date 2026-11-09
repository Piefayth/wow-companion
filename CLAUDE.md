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
- **Action slots are a flat 1–120 space**, addressed by number regardless of what's
  drawn. The gamepad UI surfaces a different subset than the classic bars, so
  "rearrange my bars" has to target the slots the controller UI actually shows. Rather
  than guess the classic bar offsets, `/wc context` walks every frame in the UI
  (`EnumerateFrames`) and reports the ones bound to an action slot, which is the live
  UI's own answer.
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
- `apidocs-1.60.1.txt` — **8,437 signatures**: 6,621 functions with argument and return
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

Dead ends, so nobody re-walks them: `ADDON_ACTION_BLOCKED` never fires for the gamepad
taint (it does fire for a direct protected call such as `ReloadUI()`), `/console
taintLog 1` writes no `taint.log` in this build, and `General.log` carries nothing
either. The A/B breakage is intermittent: it took three identical attempts to see it
once.

What is left is `issecurevariable`. `/wc place <variant>` asks it about every global
and every field of every global table, before and after the action, and reports what
turned insecure. Whether that can see the gamepad taint at all is settled by the
`chatopen` variant, the known-bad control: if it shows nothing, a clean scan
elsewhere proves nothing.

## Building

`whisper-rs`'s `cuda` feature compiles ggml's CUDA backend from source: hundreds of
`.cu` files, each built for every architecture ggml supports. Set `CUDAARCHS=89` (cmake
3.20+ reads it; 8.9 is the 4090's) to build for this GPU alone and skip most of that.
`whisper-rs-sys` has no passthrough for it, which is why it goes in the environment and
not in `Cargo.toml`. Needs libclang for bindgen — `C:\Program Files\LLVM` here.

## The agent

`claude -p` headless, not the API: no key to manage, it draws on the signed-in
subscription, and `--json-schema` constrains it to one of the shapes the addon's
dispatch table already accepts, so the model never writes Lua. `session_id` from the
first reply plus `--resume` keeps one thread, which is what makes "put it on the other
bar instead" mean anything. Startup is seconds per utterance — a deliberate trade, and
the reason the agent is spawned *before* the in-game "thinking" announcement, so the
bell wait overlaps the call.

## Next

The pipeline runs end to end: chord → mic → whisper → agent → slot write + bell, with
replies and the offered button arriving in one message. `probe` refuses to run unless
`Wow.exe` is up, which is worth keeping for anything that writes into a live client.

Open:

- **Give the agent the context.** The addon exports character, filled action slots,
  every action-bound frame, bound keys, macro bodies and the spellbook as one
  sectioned string on every `/reload` and logout (`PLAYER_LOGOUT` fires just before
  SavedVariables is written, the only moment that reaches disk). `cargo run --
  context <AddOns> <out>` pulls it. The spellbook half is also Whisper's vocabulary.
- **Isolate `PlaceAction`.** Our one test *succeeded* (`action 4 now holds macro`), and
  the claim that it taints gamepad targeting was a guess, never isolated. `/wc place`
  runs the variants one per fresh session: `none`, `chatopen` (control), `pickup`,
  `hidden`, `visible`, `put` (`C_ActionBar.PutActionInSlot`), `move`, then `clean`.
  `/wc verdict ok|broken` records the hand check; results live in
  `WowCompanionDB.placeTests`. If it is clean, bar rearranging is back on the table.
- **A game → PC channel, maybe.** The `bridge` command probes `LoggingChat`: the game
  writes chat to a log file we can read, which would be a real return path without
  reading pixels. Built, never run.
