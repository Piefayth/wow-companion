# Slots the game took before the PC wrote them (2026-11-13)

The player: "we keep coming back to this as a problem... resiliency solutions
to these kinds of problems exist, please design something better". A design
was drawn that would carry every unconfirmed line in every slot (235af88,
reviewed in cbe7fc7). The player asked whether that patched around a bug nobody
had found. It did, so the bug was looked for first. It was found, and the
carrying design is not needed.

## What failed

The take audit (Link.lua `receive`: every slot taken, with whether its inbox was
stamped for this session) showed the game taking slots before the PC wrote them.
There were about 150 in one afternoon and evening, in runs of 2-3 within a
second, at random moments: every couple of minutes while playing, once in two idle hours. Each
one read an earlier session's inbox and moved the cursor past the slot, so the
message the PC wrote there later was never read. The old inbox was handled
again: old `lua` reran, and old progress lines showed.

It was not about names. Bells never rung since 2026-11-10 were taken, and so
were bells in a session where the PC wrote nothing. `PlaySoundFile` says it will
play an empty bell every time, so only `C_Sound.IsPlaying` tells a ring.

## The cause, measured

A probe beside the channel (BellProbe.lua, 2026-11-13, removed) ran the
channel's own procedure on empty bells that nothing writes. It played each one
every 0.1 s, asked it 20 ms later, and asked the next one at once after a ring.

- 18:02-18:13, two sessions, 5,717 asks: no ring. The channel also took nothing
  falsely in those minutes.
- 18:13-22:05, one session, 138,562 asks: 29 false rings, in runs of 1-3.
- From 18:15 on, the probe's play landed in the same frame as the channel's
  (adjacent sound handles). In that stretch **every channel false take had a
  probe ring in the same frame, and every probe ring had a channel twin: 26 of
  26**, run for run. Before the two were aligned, the probe had a run of 3 at
  18:14:47 that the channel, playing in other frames, did not have.
- A false ring is short, and counted in frames, not time. 17 of the 29 still
  read playing one frame after the ask, and none did at the ask after that
  (0.1 s after the play, or a frame later after a long frame). One asked after
  a 0.147 s frame still read playing at the next frame, and was gone at the one
  after.
- A real sound (always.wav, asked the same way) read playing at once and all
  through its first second: 40 of 40.

So the game opens a sound file in the background, and an empty file reads as
playing until that open has failed. Usually that is within a frame. At a busy
moment it takes several frames, and every empty file opened in that frame
reads as playing. The PC, the bells' names and their history play no part.
`bells.rs` said an empty file "fails to play at once"; that is what let one
early answer count as a ring.

## What does not fix it

- **Asking again later** (a real bell is half a second of sound): a delay on
  every message and a guessed threshold. The player turned it down.
- **A control bell** (`never.wav`, empty, played in the same frame): on the next
  five false takes (2026-11-13, 22:28-22:31) it read playing on four and quiet
  on one, slot 5, whose bell had been empty since 18:13. It was removed.
- The game tells a sound only by `C_Sound.IsPlaying`, so nothing else read from
  a bell can tell a false ring from a true one.

So a false ring has to cost nothing.

## Why a false ring costs a message now

A slot is one message: the PC writes message k into slot k, and the game takes
slot k when bell k rings. Both sides count slots. A false take moves the game's
count ahead, and the PC cannot learn it. Every message the PC writes after that
lands in a slot the game has passed, until a reload. That is what the player saw
at 22:30: an L1 question and its start went to slots 5 and 6, which the game had
passed, and showed only after the reload.

## The design: one inbox that every slot reads

Built 2026-11-14 (`src/inbox.rs`, Link.lua `receive`), after the trial below.

- **One file, read by every slot.** Every slot's `Slot.xml` names the inbox
  outside its folder (`..\WowCompanion_Mailbox\Mail.lua`). Whichever slot the
  game loads, it reads what the PC wrote last. A slot is one chance to read the
  inbox, and any ring spends one. The slots' own `Inbox.lua` files are gone.
- **The inbox carries everything the game may not have applied**: every batch
  sent this session as write n, steps included (a progress line only until a
  newer one for its request; a write left with nothing still says its number),
  and the ledger's unsaved lines and every job's state, which the game takes at
  every load. The game keeps the last write it applied and applies only newer
  ones, each once, however often it reads them. Writes of an earlier session are
  never applied.
- **Bells count writes, not slots.** The PC replaces the inbox, then rings bell
  n of the session's set (and any bell below it that could not be rung at its
  own send). The game asks the bell after the last write it applied, and a ring
  loads its next slot.
- **A false ring** loads a slot, finds nothing newer, and stops: one slot spent,
  nothing lost, nothing late. The game asks the same bell again.
- **The inbox is never half written or empty.** The game reports an empty or
  unparsable Lua file as a Lua error and opens its error window, which takes the
  controller's focus (measured 2026-11-14: an empty `Inbox.lua` loaded gave
  "File ... Inbox.lua is empty."). The PC writes a new file beside it and renames
  it over the inbox, so the game opens the old file or the new one; a rename the
  game's read is in the way of is retried, as bells are. A write that could not
  replace the inbox is taken back out of `inbox.json`, so its number is never
  rung for a write the game cannot read.
- **The game counts its own slots**, true takes and false, and offers the Reload
  once at 16 left, of slots or bells. The PC's slot cursor, its stamp and its
  "slots spent" reckoning are gone; it stops progress lines 14 bells before the
  last, and with all 512 rung it buzzes the pad.

Costs:
- Every take parses the whole inbox: the lines since the last save (at most
  10.4 KB in a session, measured) and the session's writes. A `LoadAddOn` of a
  slot took 2.6-6.5 ms with an inbox of 0, 1, 10 or 50 KB (2026-11-14): the load
  itself costs that, and the size did not show.
- False takes spend slots, about 80 an hour at the worst seen (16:27-18:00) and
  five in one second at a busy moment (2026-11-14). A session has 512.

Tested 2026-11-14, on slots no session reaches (500-512), with the game running:
1. **A slot reads a file outside its folder**: `Slot.xml` naming
   `..\WowCompanion_S504\Inbox.lua` (or `../`) loaded that file. A path from the
   game's root (`Interface\AddOns\...`) is taken inside the slot's folder, fails
   ("Error loading" in `Logs\FrameXML.log`), and the load still says done. The
   file has to exist when the game starts: the client only knows those.
2. **Each load reads the file as it is then**, after it was replaced by a
   rename (a new file under the old name) three times, through any slot,
   whatever its size. `...` in the file is the loading slot's addon name.
3. Hard links, tried first, also read fresh through every name, and
   `fs::write` kept them; the rename needs none, and so no NTFS.

## The trial (2026-11-14)

Beside the channel, on 256 slots and bells of its own: every batch the channel
sent also went, after the channel's bell, as write n into a trial inbox, and
`Trial.lua` in game asked its bells as the channel asks its own, counted what it
read and applied nothing. In its first session (326):

- 4 s after entering the world, the channel took slot 2 before the PC wrote
  it; the trial's false ring in the same frame found nothing newer. The PC's
  next message, written into slot 2, was lost; the trial read it.
- At 12:42:44 the channel had five false takes in one second (slots 4-8). The
  player's next request went into those slots: its `heard`, the player's line,
  two progress lines and a read were all lost, until the PC's count passed the
  game's. The trial's three false rings there cost nothing, and it read all five
  writes, each within a second of the PC writing it.

The trial's slots, bells, inbox and tool went at the switch.
