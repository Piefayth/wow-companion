# A channel that cannot silently lose a message (2026-11-13)

The player: "we keep coming back to this as a problem... resiliency solutions
to these kinds of problems exist, please design something better", and "be
explicit about the trade-offs". No ping back to the PC over the data strip
(the player, 2026-11-13). Design only; nothing is built until the player says yes.

## What failed, measured

The take audit (Link.lua `receive`, commit 274ee58) caught it on 2026-11-13:

- The game took slots **before the PC wrote them**, in bursts: 8 in a row in
  one session, 23 in another. Each read an earlier session's inbox, moved past
  the slot, and the PC's real message, written seconds later, was never read.
- Every false take had `willPlay=true` and a live handle on a bell file that
  was **empty on disk**, and every one was a bell name already played earlier
  in the same game run (names repeat every third reload). Ten never-played
  empty bells, probed live, all reported nothing.
- Separately, 16:25-16:38: an unreadable save stopped every send for a session
  (fixed in 156779d); those lines waited for the next reload.

What permitted it (rule 7): **a slot is spent by one bell reading, the game
cannot read a slot twice, and the PC never learns which slots were read.** A
wrong reading is unrecoverable and silent. Every earlier fix made the bell more
trustworthy; none made a wrong bell survivable.

## The design

### 1. A bell name is used in one session only

Bells are named for the session (`g<loads>-<slot>.wav`), not one of three sets.
The PC keeps the next two sessions' bells created (empty) ahead of time, and
deletes a session's bells once the game has left it for good (at Wow.exe exit).

- Gain: removes the measured cause, if the cause is the replay of a played name.
- Cost: **the cause is inferred, not proven.** The evidence is strong (every
  false take, no clean one) but it is correlation; layer 2 is what makes the
  design hold if this inference is wrong.
- Cost: **the PC must stay two reloads ahead.** If the companion is not
  running across two or more reloads, the game asks for names that do not exist,
  remembers them as missing (rule 3), and that session hears nothing until the
  next reload. Today's three fixed sets cannot fail this way. Mitigation: the
  companion makes them at start, and the addon's install makes the first ten
  sessions' worth; `doctor` checks it. This is a new failure mode traded for
  removing the current one.
- Cost: the same file count as today (about 1,536), with deletes added; the
  deletes happen only with the game closed, so rule 3 is never in play.

### 2. Every slot carries everything not yet confirmed

There is no way back to the PC, so the PC can never know a slot was lost. So it
does not try: **each slot carries every conversation line the ledger still
holds** (all lines since the last save, the same set the mailbox holds), plus
its new status messages. The game already ignores a line it holds (by its
number), so a line arrives once however many slots carry it.

- Gain: any lost slot, or any burst of lost slots of any length, is repaired by
  the next slot that reaches the game. No window size to choose. No new
  numbering: it reuses the ledger and the line numbers that already exist.
- Gain: steps ride on their line (`andThen`), so a button or code step can never
  run twice.
- Cost: **slots grow over a session.** A slot holds every reply since the last
  reload: about 1-3 KB per line, so a 50-line session ends with 50-150 KB slots,
  each loaded as Lua. Not yet measured in game; if loading 150 KB hitches a
  frame in a fight, the remedy is a measured cap on what rides along, which would
  bring back a small chance of loss, and I would bring that choice to you.
- Cost: **status messages are not repeated** (progress, the running line,
  context size): each describes now, the next replaces it, so a lost one is a
  stale progress line for a moment, not a lost message.
- **Dictation** becomes a ledger entry like a line (today it is fire-and-forget,
  which is how "Thank you both for the help" vanished). Once it is past its
  session, it is never typed into chat late (a reload later it would be out of
  place): it shows in the window as "not sent: <text>" so you can say it again.
- **The last slot of a burst has no next slot to repair it.** So 2 s after the
  last send, the PC sends one more slot carrying the same lines (only if nothing
  was sent meanwhile). Cost: about one extra slot per exchange. A session uses
  about 50 of its 512 today, so perhaps 80; the reload offer at 16 left is
  unchanged.

### 3. A loss the game can see is told at once

The game knows a slot was taken early (its stamp is not this session's) and
knows a conversation's line numbers have a gap. A gap still open after the
next slot shows in the window: "a message from the companion is missing; it
arrives with the next one or at your next reload".

- Gain: nothing is silent again, on the game's side.
- Limit: **a loss the PC suffers before writing anything** (it cannot read the
  save, like 16:25) cannot reach the game at all. There the PC buzzes the pad,
  as it does for "all slots spent", and with layer 2 everything waiting goes
  with the first slot that works, not at the next reload.

## What this does not do, and why

- **No acknowledgement from the game.** The only way back while playing is the
  data strip, which is not to be used for that. Without it, "delivered" is
  proven only at the next save, as today; layers 2 and 3 make that enough.
- **No faster bell.** Polling stays at 0.1 s (rule 6: faster makes the game hold
  its files).

## Rollout (CLAUDE.md, "Changing the channel")

1. **Layer 3 alone**: the game tells; delivery unchanged. One session.
2. **Layer 2**: the PC adds the carried lines; the game counts what they
   repaired before relying on them. It changes what is in a slot, not how a slot
   is found, so it is the safest change and fixes losses whatever their cause.
3. **Layer 1 beside the channel**: the PC also writes per-session names; a
   watcher in the game asks the new name of the slot after the one the real poll
   takes, never takes a slot, and counts false rings. One whole session at zero,
   then the poll switches and the three sets are removed.

Each step removes what it replaces in the same change.
