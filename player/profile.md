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
- **Never change how the game behaves without their explicit yes** (2026-11-13):
  settings, CVars, modules that alter play. Explain the option and wait for a
  yes before any step that changes it. (A combat camera module went in unasked.)
- **Addon sources:** strong preference for the addon's own GitHub repository with
  maintainer checks; CurseForge and Wago are fine. Install only after a yes.
- **All UI we build looks like Blizzard's** (2026-11-09): the game's own borders,
  backings, fonts and atlases, never flat colour boxes.
- **The look: "a luxury World of Warcraft addon"** (2026-11-12). The reference is
  the chat well: marbled navy slate turns, washed-out bronze (not Blizzard's
  saturated gold), the medium vine dividers, the fleur-and-heartwood scroll bar.
  A little more elevated than Blizzard's own, at the game's saturation and
  contrast; everything else (the frame, other windows) is brought into that
  palette. Painted detail at a scale that reads at TV distance: no fine grooves
  or noise, no over-smoothing, no belts or accents across the middle of a piece.
  Ornament is wire scrollwork in the vine's bark, never a ball or boss; its
  wire has weight and never tapers to a hairline (thin ends read as fading
  into the dark), and errs bigger rather than smaller (2026-11-12).
  **No heart motifs**, ever: not the ornament asked for (2026-11-12).
  Nothing floats: every element sits in structure (a rule it grows from,
  a cell it fills, a border it closes); a mark or crest placed alone in
  empty stone reads as unfinished. A selection must be the same structure
  as its unselected neighbours, only lit (2026-11-12).
  Every vine joint comes in two variants, ornamental and plain; plain where
  space is tight, like the Status rows (2026-11-12).
  Settings controls (2026-11-12, Trials round 3): sunk wells made the
  buttons look off; a dropdown with no box (bare arrows round the word)
  rejected; the lit well and a small lit socket for a button glyph are
  tolerable. The slate is reused too much and getting old: new pieces want
  a fresh material, not more slate.
  **Existing parts first** (2026-11-12): build new pieces from the window's
  own parts (vines, wire scrollwork, the two stones, bronze, the crests)
  until an insufficiency is identified; a "fresh material" never means a
  new world. Six looks in wood, leather, brass, enamel, iron and lacquer
  were rejected as foreign to the window. Rows in a list are compact, not
  full-height cells sharing the well.
  Raised wells rejected after four rounds (2026-11-12): bevels, slopes and
  shadows laid over a well read as "2001 amateur web designer" overlapping
  rectangles. Depth must be designed with the page's structure (the dividers,
  the joints, the border), never added to a panel on its own.
  Tabs never open into the chat (2026-11-12): its stone is shaded to sit back
  and scrolls, so no tab can join it; tabs stand apart, on its border.
- **Options, built and side by side** (2026-11-12): they hand us the legwork
  for speed, not judgement. Never ask them to think a design up; draw many
  real options at once (six or more, at true size, in game) and let them pick.
  Ask only what only they can answer (taste, a yes to install or restart).
- **No way to reload but our button** (2026-11-12): until they pick their own
  reload key, every answer whose change needs a /reload ends with a `reload`
  step (the Reload button), in every conversation. `look` alone is not enough:
  only Main's look offers a button.
- **Nothing of ours opens itself** (2026-11-10). The Companion window opens only
  when they ask (minus tap, `/wc log`); news goes to the board/toast. No data cards
  left on screen: the data strip shows only for the moment of the shot.
- **API first; screenshots only to read our own displays** (2026-11-10): reading
  anything else on their screen needs their explicit ask; never input to the game
  window.
- **Clean up freely** (2026-11-11: "I love cleaning up"): remove what is dead,
  done or replaced without asking first.
- **Combat bars are for combat** (2026-11-10): no agent puts a non-combat entry
  (a chat, menu or utility macro, a wheel opener) on the action bars without
  their explicit permission, at minimum anything on the first page (the gamepad
  bars, slots 181-272). Offer another way (a chord, a wheel, a press) instead.
  They may extend this to other pages later.
- **No new keybindings without agreeing first** (2026-11-10): agree on how a
  feature should feel before building it, and never add pad bindings (d-pad,
  face buttons) to a window or feature unasked. Chat mode lasts one minus hold,
  never longer.
- **No paging through lists** (2026-11-11): never propose a design where a key
  steps through items one by one (cycling offers, conversations). Pick things
  directly, e.g. by the conversation's own trigger chord.
- **One focus, always** (2026-11-10): a window of ours is focused the same way as
  the game's own windows (the controller's native focus cycle), in combat too.
  Never a second "focus this window" press or mode beside it; not acceptable,
  ever. When the game seems to forbid it, research harder before calling
  anything impossible.

## The player

- Character: Pietra Fayth, a druid (names in Forever are first and last). Forms
  change on the L1+L2 wheel.
- Bar layouts: read `player/layout-rules.md` before proposing or
  changing any layout. It holds their rules and the layouts already rejected.

## Their setup

- Controller: a Switch pad through a switch2connect adapter in DS5 mode
  (`054c:0ce6`); DS5 mode stays ("ds5 ride or die"). Talk button: minus.
- Headset: AirPods Max (8 kHz hands-free link, hisses when audio plays), so
  push-to-talk feedback is rumble and beeps are off.
- GPU: RTX 4090, Whisper large-v3-turbo on CUDA (`CUDAARCHS=89`).
- Speech (2026-11-11): keeps both engines. Whisper is "much higher quality",
  streaming's speed "way too good to give up"; on streaming for now.
- Installed addons the agent may use: see the request's `== integrations ==`.
