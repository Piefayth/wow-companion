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

### 1. (Dropped) a bell name per session

Proposed, then dropped the same day: it rested on an inferred cause (the game
replaying a played name), and a probe showed a sound file created after the
game launched does not play at all (`willPlay` nil for a full bell copied in at
16:53), so names made ahead of a session would likely never ring. The design no
longer depends on why early takes happen.

### 1. A stale slot is refused

Every slot carries its session's number (274ee58). A slot whose number is not
this session's is an early take: the game applies nothing from it and counts it.
Its real content is lost from that slot, and layer 2 delivers it.

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

Each step removes what it replaces in the same change.

## Review (the PC-side session, 2026-11-13, against 235af88)

Measured from the take audit in Link's save (15:06-16:52) and the PC's
audit.log and timing.log. Wow.exe started 14:26:37.

**1. "Every false take was a name already played in this game run" is wrong.**
Dropping per-session names was right; the claim should go from "What failed"
too, so the history doesn't keep it.
- Session from 16:40 (set 2): before it, this run had rung set 2 only up to slot
  26. The game falsely took 27-31 (16:42:25-40) and 54-59 (16:45:37-16:47:46).
  The PC's audit, which goes back to 2026-11-10, has 54-59 never rung at all.
- This morning: Wow.exe started 10:36:04, and the first session (10:44:06) took
  slots 2 and 3 in its first second. Their bells were empty, and the game had not
  played them in that run. This predates the take audit, so there is no
  `willPlay` for it.
- Session from 16:25: the PC wrote nothing (the save was unreadable). The game
  still took slots 1-23 one at a time over 7 minutes, and slot 1 only after 108 s,
  roughly 1,000 asks that correctly said "not playing".
- The pattern is moments, not names. Takes come in runs of 3-4 consecutive slots
  inside one second, because the drain asks the next slot at once after a take.
  They come at random times, with no PC file activity within ±4 s. Roughly 12
  such moments in the ~4,600 asks of the 16:25 session (0.3% of asks).
- Ten never-played bells probed once each cannot show immunity at that rate:
  ten asks see nothing 97% of the time.

**2. Suggest: stop the drain on a stale take.** The drain exists to empty a
backlog of written slots. A stale take proves there is no backlog, so asking the
next slot "at once" only spends more slots inside the same bad moment. If the
next ask waits the normal 0.1 s, the measured runs of 3-4 should shrink toward
one. This matters for layer 2's tail:
- An early take moves the game's cursor *ahead* of the PC.
- The PC's next writes land in slots the game has passed, until the PC's cursor
  catches up.
- One echo 2 s later lands in the next burned slot whenever the run was longer
  than one. Today's runs of 3-4 would defeat it.
- Either shorten the runs as above, or say plainly that the tail waits for the
  next send or reload.

**3. Dedup by `n`, and `andThen`** (asked):
- **Re-applying a held line is safe.** Agent.lua `handlers.log` returns `HELD`
  for a held `n`, and Link.lua `dispatch` returns before `JOB_MESSAGE` and before
  `andThen`. Out-of-order arrival is handled by `Hold`'s `above`.
- **Carried copies have no steps.** `Book::number` keeps `kept.steps = None`, and
  `Line::msg(false)` leaves `andThen` out (the test at message.rs:247). So if the
  slot carrying a line's live copy is lost, the text is repaired but its button,
  macro or Lua runs zero times. "Never twice" holds; "never lost" doesn't, for
  steps.
- **To repair steps too:** the ledger keeps them for the session they were sent
  in, stamped with it, and the game runs a carried `andThen` only when the stamp
  is this session's. Without that stamp, a game crash before a save rolls the
  game's held numbers back while the ledger still holds the line, and the step
  would rerun after the relaunch. The mailbox avoids this today by never carrying
  steps.
- `WC.Jobs.Hold` returns true (apply) when the jobs model isn't built yet, and
  for a message with no `n`. Every carried line must have `n`, and the model must
  exist before Link's first take at load. Worth checking the load order.

**4. What isn't a line stays lossy.** Mostly harmless; `status` is the
exception:
- `heard`: the clip's waiting line shows late.
- `progress`, `context`: stale for a moment.
- `read`: the WCCMD command gives way after `COMMAND_SECONDS`, no stall.
- An agent's strip `lua`: its read times out.
- `stopped`: the cancel retries.
- `status`: the mic warning and settings stay wrong until the next change. It is
  a "now" value, so carrying the latest copy in every slot is cheap and
  idempotent.

**5. Dictation as a ledger entry needs more than the ledger.**
- Chat.lua has no dedup: `chat`, `send` and `wheel` carry no number.
- `Hold` lives in the Agent addon.
- With the agents off (the dictation product), there is no Agent addon, and
  `ledger::open` returns at once when `!agents`.
- So dictation needs a ledger in that product too, its own number, and dedup in
  Link, recorded when applied even while the line waits for a chat box.

**6. Slot size, measured:**
- The 52 sessions in today's companion.log carried at most 14 lines (10.4 KB) of
  `log` messages each; the median is 2.1 KB.
- The player reloads every few minutes and each save confirms the ledger, so
  50-150 KB is a session hours long with no reload.
- Add the `LoadAddOn` time (`debugprofilestop`) and the inbox's bytes to the take
  audit, and the cap question gets answered from data.
- The PC already writes the same lines to the mailbox at every change, so its
  side costs nothing new.

**7. Layer 3 and the outage case:**
- The player's rule is "dont do this sort of 'negative confirmation' stuff".
  Keep the window message to a gap still open after the repair, and count the
  rest silently, as the doc already says.
- For the PC-side outage, 156779d removed the buzz that fired on an unreadable
  save: it was the false "all slots spent" alarm, and the player asked what the
  unexplained buzzing was. A buzz for "cannot send" would be a new signal and
  needs the player's yes. The first slot that works could carry "the companion
  could not send from hh:mm to hh:mm: <why>" instead.

## Finding the bug first (the player, 2026-11-13)

The player asked whether all this patches around a bug nobody has found. It
does: the design makes a wrong bell reading survivable without knowing why the
game gives one. So the build waits, and the bug is looked for first.

What is known: the game plays an empty slot bell, and about 0.3% of the time
`PlaySoundFile` says it will play and `C_Sound.IsPlaying` says it is playing 20
ms later. That comes at random moments, in runs of 3-4 consecutive asks within
a second, whatever the name's history. The leading guess, untested: the game
opens a sound file in the background, and at a busy moment the 20 ms ask comes
before an empty file's open has failed, so a sound about to fail counts as
playing. If so, the fix is in how a ring is confirmed (a real bell is half a
second of sound, so it still plays long after a failed open has given up), and
the layers above are not needed.

The probe (`WowCompanion_Link/BellProbe.lua`, beside the channel, never takes
a slot):
- It asks empty bells no session reaches (slots 509-512 of each set, and
  never.wav) every 0.1 s, the channel's way.
- On an anomaly it asks again at 0.02, 0.1, 0.3, 0.6 and 1 s, and asks the next
  control at once, as the drain does.
- Every 5 s it asks always.wav (ten silent seconds) the same way, for what a
  real sound answers.
- Counts, anomalies with frame times, combat and the time since the last
  loading screen go to `WowCompanionLinkDB.bellProbe`, read live by strip.
- One play session, then this section gets the result.
