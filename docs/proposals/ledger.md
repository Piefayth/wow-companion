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
4. **A mailbox the game reads at every load.** `WowCompanion_Mailbox`, a small
   addon of ours that the game loads with Core at every login and reload (not
   load-on-demand); its `Mail.lua` holds every line not yet confirmed and each
   job's state, oldest first. The PC rewrites it whole (temporary then rename,
   so the game reads the old file or the new, never half of one) whenever the
   ledger changes, the game closed or running. At load the addon takes the
   mailbox before the window draws, so lines made while the game was closed are
   already there when it opens: no wait for a signal, no bundle sent later, no
   bell. Within a session, lines go live through the bells as now; the mailbox
   only matters at the next load.
5. **A save confirms.** When the game writes its save (a reload, a logout), the
   PC reads each conversation's number and drops the lines at or below it from
   the ledger. Jobs whose end the save records are dropped the same way. No
   time windows decide what is kept.

Lines made while the game is closed wait in the ledger and the mailbox, and are
in the window when it opens at the next login. The save file is never edited by
us. (The player, 2026-11-11, asked why lines should arrive late at all; an
earlier version of this design sent them after a "ready" signal, seconds after
login. The mailbox removes the wait and the signal.)

## Guarantees

- **Every line reaches the window exactly once, in order**: live within a
  session through the bells as now, and at the latest at the next load, from
  the mailbox. Why: a line leaves the ledger only once a save shows the game
  holds it, the mailbox always holds every unconfirmed line, the game reads it
  at every load, and it ignores numbers it holds.
- **A crash loses nothing.** The ledger is on disk before a line is sent. A
  job still running at a crash is ended at the next start with a line saying
  so (the time, and `crash.log`). The game's own crash loses its unsaved lines,
  and its save then shows a lower number, so they are sent again. That is not a
  retry: it is what the save says the game lacks.
- **No message is ever partially applied.** The mailbox is replaced whole, so
  the game reads all of it or the previous whole one, and it uses no slot, so
  neither the slot limit nor the catch-up bells' gap at 8 behind can matter for it.

## Failures, each reported, none retried in the dark

| Failure | Report |
|---|---|
| The ledger cannot be written (disk full, permissions) | in the window and `doctor`: lines are not safe while the game is closed |
| The mailbox cannot be written | in the window and `doctor`: the lines it should hold are named |
| The save cannot be read at a confirmation | `doctor`; nothing is dropped, so the mailbox keeps those lines and the game ignores what it holds |
| A save after a load still lacks lines the mailbox held (the mailbox addon disabled or broken) | the tray and `doctor`: "the game did not take its mailbox", with which lines |
| Slots spent before the session ends | the pad buzz (as now); the lines are in the mailbox for the next load |

## What it deletes

`REPLIES` and everything `resync` does (the 8 s sleep, the 10-minute window,
the text match, and its board: the mailbox carries the job states); `src/undelivered.rs` and
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

Hold `WowCompanionDB.lines`; at load, take the mailbox before the window draws;
apply each line by its number and ignore one already held, whether it came
from the mailbox or a slot. Its state handling (forward-only per job) is
unchanged. The mailbox is a new addon folder: one game restart, which lands
with the addon split's.

## Decided by the player (2026-11-11)

1. Lines made while the game is closed are in the window when it opens (the
   mailbox), never late, and the save file is never edited by us.
2. A reply whose changes (macros, bars, Lua) could not run because the game was
   closed: the changes do not run, and the line shows an error saying so.
3. The data strip's corner flash is acceptable (this design no longer needs a
   `ready` signal).
