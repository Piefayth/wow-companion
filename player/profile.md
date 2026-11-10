# Player profile

This player's own preferences and terms. Every agent request carries this file;
the rules in `src/agent.rs` and `CLAUDE.md` are the same for every player and hold
none of this. When the player states a new preference or changes one, write it here
(short, dated), not into the rules. Another player starts from an empty copy.

## Standing terms

- **Controller first; voice is the last resort.** Prefer a setting, an existing
  addon, or a controller-native path. Speech is for when the game offers none.
- **The whole game, not one system.** They engage with most of it and will want
  many things.
- **The agent is at full strength** (every tool, no prompts, Opus), by their choice.
- **Never play for them** (also a product rule): casting, targeting, moving, and the
  step that spends or sends are their press.
- **Ask before restarting the game.**
- **Addon sources:** strong preference for the addon's own GitHub repository with
  maintainer checks; CurseForge and Wago are fine. Install only after a yes.
- **All UI we build looks like Blizzard's** (2026-11-09): the game's own borders,
  backings, fonts and atlases, never flat colour boxes.
- **Nothing of ours opens itself** (2026-11-10). The Companion window opens only
  when they ask (minus tap, `/wc log`); news goes to the board/toast. No data cards
  left on screen: the data strip shows only for the moment of the shot.
- **API first; screenshots only to read our own displays** (2026-11-10): reading
  anything else on their screen needs their explicit ask; never input to the game
  window.
- Clean-up (removing old files, pruning) only when they say so.

## The player

- Character: Pietra Fayth, a druid (names in Forever are first and last).
- Bar layouts: read `docs/proposals/druid-layout-rules.md` before proposing or
  changing any layout. It holds their rules and the layouts already rejected.

## Their setup

- Controller: a Switch pad through a switch2connect adapter in DS5 mode
  (`054c:0ce6`); DS5 mode stays ("ds5 ride or die"). Talk button: minus.
- Headset: AirPods Max (8 kHz hands-free link, hisses when audio plays), so
  push-to-talk feedback is rumble and beeps are off.
- GPU: RTX 4090, Whisper large-v3-turbo on CUDA (`CUDAARCHS=89`).
- Installed addons the agent may use: see the request's `== integrations ==`.
