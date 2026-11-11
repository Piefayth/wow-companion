# Bringing the code into line with the standing rules (2026-11-11)

The player's standing rules (their global CLAUDE.md) were missing from this PC
until 2026-11-11, so two days of work were written without them. This is the
plan to bring the code into line, ordered by what pays off first: the structures
that keep producing bugs (rule 7), then the guesses (rule 8), then old versions
and stale comments (rules 1-3). Each item names its owner; work goes around
what agents are editing now. Counts are from 2026-11-11.

## 1. Structures that produce whole classes of bugs (rule 7)

1. **Messages to the game are strings cut and parsed by shape.** `src/` builds
   Lua messages with `format!` in 7 files, edits them with `replacen` (14
   places) and recognises them by prefix (`starts_with("{ kind = ...")`). The
   closed-game loss of 2026-11-11 was one instance: a field added in front broke
   a reader elsewhere. Fix: one message type in Rust (kind, fields, the job's
   state as a typed value), written out as Lua in one place; senders build it,
   the channel, the closed-game keeper, the undelivered file and the crash path
   take it as a value. Every `replacen` and prefix test goes. Owner: PC-side
   Claude, after Main's sync work in requests.rs/jobs.rs lands.
2. **Blizzard's combat-locked calls made anywhere.** Each call site had to
   remember a guard; the window forgot and raised "Interface action failed" all
   day. Fix (in progress, L2): every such call goes through Engine helpers that
   wait for the fight's end; then `tools/luarules.py` checks exactly that nothing
   else calls them, and its guessing rule is deleted.
3. **The window's message state kept twice** (Jobs.lua matching, Transcript.lua
   ordering, against the PC's ledger). Fix (in progress, Main): the window draws
   from `JobsModel.lua`, property-tested; the old matching is deleted.
4. **Files reaching into each other** (`WC.Core`: 44 uses, Companion.lua 29,
   Chords.lua 13, Errands.lua 2). Fix: each file owns its state and offers named
   functions (`WC.<File>.<verb>`); `WC.Core` shrinks to nothing. Owner: an
   in-game agent, one file per change, after the chat-box and sync work.

## 2. Guesses (rule 8: none without the player's permission)

| Guess | Where | Exact signal | Status |
|---|---|---|---|
| Save reset by line counts | src/backups.rs | the addon's own load counter | R1 adds the counter, then the guess is deleted |
| Combat guard "somewhere before" a call; function ends by indentation | tools/luarules.py | 1.2 above makes the rule exact | after L2 |
| Cancel matched to the nearest clip within 1.2 s, across two clocks | src/jobs.rs (heard_at) | an identity both sides know | Main to propose |
| "Is this request about chat?" by keywords | src/context.rs wants_chat | the agent asks for live chat when it wants it (a step), instead of the PC guessing from words | PC-side Claude |
| Whisper's prompt echo stripped by text; quiet clips by a level threshold | crates/voice/src/lib.rs, mic.rs | (speech is approximate) | permitted by the player, 2026-11-11 |
| Spoken names matched to the closest player name | Lua name lookup | (speech is approximate) | permitted by the player, 2026-11-11 |

Not guesses: the 1.5 s clip join (the player's own spec), bell length and slot
counts (measured), the strip's cell size (a format).

## 3. Old versions and stale comments (rules 1-3)

- `req` sent beside `job` in every job message (requests.rs, offline.rs): kept
  "while it costs nothing"; rule 2 says delete it, with the addon's reading of it.
  Owner: whoever does 1.1 (it is the same code).
- `tools/strip.py` beside `src/strip.rs`: move its one dev-only feature
  (`--send`) into `wow-companion strip`, then delete it.
- 176 lines of code comments carry dated history ("the player, 2026-11-10: ...").
  History belongs in `docs/history.md`; a comment says what is true now. Every
  change prunes the comments near what it touched (rule 3); a one-time pass per
  file moves the rest.
- Old bell files from abandoned names in Signals/: cleanup waits for the
  player's word.
- Main's sweep (9d9eb98) removed what the ledger replaced; the review checks
  nothing else of the old request path is left.

## 4. Keeping it that way

- The recurring review (`docs/review.md`) carries the rules as lenses:
  heuristics and bug classes are items 8 and 9.
- `tools/luarules.py` grows a rule each time a class is closed, so it cannot
  come back unnoticed.
- CI on every push: `luacheck`, `luaglobals`, `luarules` (seconds) and
  `cargo test` (minutes), so a broken rule fails before it reaches the game.
