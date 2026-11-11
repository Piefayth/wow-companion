# One saved ledger: every conversation line reaches the game, provably (2026-11-11)

The player: "i don't want any notion of a fallback 'ohh if my logic fucked up we
try again' - robust guarantees with error reporting". Design only; nothing is
built until the player says yes.

## What is wrong today

"What has the game not got?" is answered by four separate guesses:

- `requests.rs` `resync`: its own `REPLIES` list, an 8 s sleep, a 10-minute
  window, and a check whether a reply's first 60 characters appear in the save
  file's text.
- `src/undelivered.rs`: lines that failed to send, in `undelivered.txt`,
  re-sent once a session "held steady" for 10 s.
- `src/crash.rs`: jobs running at a crash, in `inflight.txt`.
- `src/offline.rs`: lines made while the game is closed are written into the
  player's save file, a Lua file the game runs at login. On 2026-11-11 this
  broke the save's Lua; a check caught it before the game read it.

The structure that permits this (rule 7): nothing on either side names a line,
so the PC can only guess from timing and text whether the game has one. The
job states do not settle it either: the board's state list can mark a job
answered in the game without its reply text ever arriving.

## The design

1. **Every conversation line has a number.** Each conversation (main, l1, l2,
   r1, r2, quick) numbers its lines 1, 2, 3... with no gaps: "you" lines,
   replies, failures, notices, everything the window shows. Status messages
   (progress, board, show) are not lines; they only ever describe now.
2. **The PC keeps every line until the game has saved it.** The ledger (the
   jobs of `src/jobs.rs` and their lines) is written to
   `%LOCALAPPDATA%\wow-companion\ledger.json` on every change (whole file,
   temporary then rename, so it is never half written).
3. **The game records what it has.** Per conversation, the highest number it
   holds with none missing below it (`WowCompanionDB.lines[conversation]`).
   A line it already holds is ignored, so a line may arrive twice and still
   shows once.
4. **The game says when it is listening.** When the addon has loaded, it draws
   a one-off `WCCMD ready <loads>` on the data strip (the corner the companion
   already watches for Stop and cancel). Until then, nothing is sent; after it,
   the PC sends **one bundle**: every line the game might not have (all lines
   not yet confirmed), oldest first, in one message, then one board.
5. **A save confirms.** When the game writes its save (a reload, a logout), the
   PC reads each conversation's number and drops the lines at or below it from
   the ledger. Jobs whose end the save records are dropped the same way. No
   time windows decide what is kept.

Lines made while the game is closed simply wait in the ledger, and arrive in
the bundle seconds after the next login. The save file is never edited by us.

## Guarantees

- **Every line reaches the window exactly once, in order**: by the next
  `ready` after it was made at the latest, live within a session through the
  bells as now. Why: a line leaves the ledger only once a save shows the game
  holds it, every `ready` sends all unconfirmed lines, and the game ignores
  numbers it holds.
- **A crash loses nothing.** The ledger is on disk before a line is sent. A
  job still running at a crash is ended at the next start with a line saying
  so (the time, and `crash.log`). The game's own crash loses its unsaved lines,
  and its save then shows a lower number, so they are sent again. That is not a
  retry: it is what the save says the game lacks.
- **No message is ever partially applied.** The bundle is one slot, read whole
  by the addon, so the catch-up bells' gap at 8 behind cannot matter for it.

## Failures, each reported, none retried in the dark

| Failure | Report |
|---|---|
| The ledger cannot be written (disk full, permissions) | in the window and `doctor`: lines are not safe while the game is closed |
| The save cannot be read at a confirmation | `doctor`; nothing is dropped, so the next `ready` sends those lines again and the game ignores what it holds |
| The game is running but never draws `ready` (the addon broken or not loaded) | the tray and `doctor`: "the game has not said it is listening"; lines wait in the ledger |
| Slots spent before the session ends | the pad buzz (as now); the lines wait for the next `ready` |

## What it deletes

`REPLIES` and everything `resync` does except the one board after `ready` (the
8 s sleep, the 10-minute window, the text match); `src/undelivered.rs` and
`undelivered.txt`; `inflight.txt` and `crash.rs`'s handling of it (the ledger
is the record); `src/offline.rs` and every edit of the player's save file;
`jobs.rs`'s 30-minute `KEEP` (a save confirms instead); the `req` field.

## With plan item 1.1 (one typed message)

Same change, because the ledger stores lines as values: one `Message` type in
Rust (a line, with its conversation, number, job and state; or a status
message), written as Lua in one place. The channel tells a line from a status
message by its type, not by the text's prefix; every `replacen` and
`starts_with("{ kind = ...")` goes.

## The game's part (Main builds it once approved)

Draw `ready` at load; hold `WowCompanionDB.lines`; apply each line by its
number and ignore one already held; take a bundle (a list of lines) as if each
had arrived alone. Its state handling (forward-only per job) is unchanged.

## For the player to decide

1. **The save is never edited by us**: lines made while the game is closed
   appear seconds after login, through the bundle, instead of already being in
   the window when it opens. Yes?
2. **A reply's changes (macros, bars, Lua) that arrive in a later session**:
   today they are not run, and the line says so. Keep that, or run them?
3. **The `ready` strip**: a corner flash of about two seconds at every login and
   reload, as the Stop button's already is. Acceptable?
