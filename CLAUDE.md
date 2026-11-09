# WoW Companion

Voice and agent control for World of Warcraft: Forever, played on a controller.
Hold a controller chord, speak, and the PC side turns that into something done in
game: text in the chat box, macros written, action bars rearranged.

## Shape

- **Helper (Rust, `src/`)**: runs on the PC. Will read the controller directly
  (`gilrs`), record the mic (`cpal`), transcribe locally (`whisper-rs`, large-v3-turbo
  on the 4090), hand commands to an agent, and deliver results to the game.
- **Addon (Lua, `addon/WowCompanion/`)**: the in-game half. Applies what the helper
  sends.

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
  keypress. `ReloadUI()` is unprotected, so the addon can call it itself, and it clears
  the taint, flushes SavedVariables and resets the slot cursor in one move. Chat
  insertion taints too, and not harmlessly: opening the edit box from insecure code
  leaves the gamepad focus restore blocked, and **the A and B buttons stop working**
  until the taint clears. It announces itself as one mild "interface action failed"
  notice, which is why it read as cosmetic at first. It is not.
  The blocked call for bar placement is `SetPreferredGamepadInteractTarget`, the
  gamepad UI's interact targeting — so it lands squarely on the controller player we
  are building for, and it fires whenever that targeting next runs rather than when we
  taint it, which is why it looks intermittent.
  The continuous bell poll is **not** a taint source: `/wc quiet` stops it, and a fresh
  session with it running interacts cleanly. Worth stating because it was the obvious
  suspect, being the only thing the addon does nonstop, and it was wrong twice over.
  So chat delivery needs to stop touching the edit box. Write the line into a **macro
  body** instead and let the player press it: macro writing is the one path that has
  never tainted anything, it needs no new binding if a macro slot is kept for it, and
  it is "configuration only, never act for the player" taken literally — we write, the
  player executes. A `SecureActionButtonTemplate` with `macrotext` is the other
  taint-free option, but it costs a gamepad binding, and those are scarce.
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
- **Bells behave.** `always.wav` plays, `never.wav` doesn't, and Windows never once
  refused to overwrite a bell the game had open — zero lock retries across two runs.
  That was the open Windows question and it's answered.
- **Chat and macros work.** `ChatFrame_OpenChat` puts text in the box; `CreateMacro`,
  `EditMacro` and `PlaceAction` all succeed out of combat.
- `FrameXML.log` logs every slot load, including empty ones — a free, precise trace of
  the channel that costs nothing to read.

Three things the real client taught us that a Mac couldn't:

- **Opening chat from a slash command defeats itself.** The Enter that submits the
  command tears the edit box down after the handler returns, so the open has to be
  deferred a tick. Bell-triggered delivery isn't affected, but any slash-command path is.
- **Action slots are a flat 1–120 space**, addressed by number regardless of what's
  drawn. The gamepad UI surfaces a different subset than the classic bars, so
  "rearrange my bars" has to target the slots the controller UI actually shows. Unmapped.
- **One client per install.** Two running at once both load slots, both consume bells,
  and both write the same SavedVariables file, so the last to reload wins and the
  measurements quietly lie. Diagnosed the hard way.

Dead ends, so nobody re-walks them: `ADDON_ACTION_BLOCKED` never fires for the taint
error, `/console taintLog 1` writes no `taint.log` in this build, and `General.log`
carries nothing either. The taint is also intermittent — three identical repro attempts
to get one. Attribution isn't reachable from Lua here, and the `ReloadUI()` mitigation
doesn't need it.

## Building

`whisper-rs`'s `cuda` feature compiles ggml's CUDA backend from source: hundreds of
`.cu` files, each built for every architecture ggml supports. Set `CUDAARCHS=89` (cmake
3.20+ reads it; 8.9 is the 4090's) to build for this GPU alone and skip most of that.
`whisper-rs-sys` has no passthrough for it, which is why it goes in the environment and
not in `Cargo.toml`. Needs libclang for bindgen — `C:\Program Files\LLVM` here.

## Next

The channel is proven, so the remaining work is the helper's real pipeline: controller
chord (`gilrs`) → mic (`cpal`) → `whisper-rs` → agent → slot write + bell. `probe`
refuses to run unless `Wow.exe` is up, which is worth keeping for anything that writes
into a live client.

Still unmapped: which action slots the controller UI exposes, and what the agent needs
out of SavedVariables to reason about current bars and macros.
