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
[t3code-wow](https://github.com/ryanrhughes/t3code-wow/blob/main/docs/ARCHITECTURE.md):

- **Slots**: `WowCompanion_S001…` are load-on-demand addons. `LoadAddOn` reads a slot's
  `Inbox.lua` from disk when it loads, so the helper writes Lua there first. Each slot
  loads once per UI session (`/reload` resets). The client only knows files that
  existed at launch, so `install` creates every slot up front and new folders need a
  full game restart.
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
- Voice: push-to-talk, whole clip transcribed after release (more accurate than
  streaming dictation). Pass a vocabulary prompt (spell names etc.).

## Where we are

Built on a Mac without WoW: `install`, `probe`, and an addon that runs the probe. Nothing
has touched a real client yet. All the measurements above come from t3code-wow on
Linux/macOS, never Windows.

## Next: run the probe on Windows

1. Find the Forever client's `Interface\AddOns` folder (under `World of Warcraft\`).
2. `cargo run -- install "<AddOns path>"`, then **fully restart** WoW.
3. Log in with game sound on. Expect chat lines for `client` (note the toc: if it isn't
   16001, update both TOC strings), `always.wav plays (want true)`, and
   `never.wav plays (want false)`.
4. `cargo run -- probe "<AddOns path>"`, press Enter once in game. The game should print
   messages 1 to 10, each a few seconds after it was sent. Watch the helper for
   "locked" lines: Windows may refuse to overwrite a bell while the game has it open.
5. In game, out of combat: `/wc chat` (chat box should open with text) and `/wc macro`
   (creates, edits, places and deletes a test macro).
6. Also try Windows voice typing (Win+H) in the chat box. If it types, voice to chat
   may need no code at all.
7. `/reload`, then read the results from
   `WTF\Account\<account>\SavedVariables\WowCompanion.lua` (`WowCompanionDB.probe`).

If the bells fail on Windows, the whole delivery design changes; stop and rethink
before building anything on top.
