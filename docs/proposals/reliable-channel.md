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

## Proposed: one inbox that every slot reads

- **One file, 512 names.** Every slot's `Inbox.lua` is a hard link to one file,
  the inbox. Whichever slot the game loads, it reads what the PC wrote last. A
  slot is then one chance to read the inbox, and any ring spends one.
- **The inbox carries everything the game may not have applied.** Each message
  is numbered in its session (`seq`):
  - lines, until a save confirms them (what the mailbox holds now);
  - the latest of each "now" message (progress per job, context per
    conversation, status);
  - the session's one-off messages (`lua`, `read`, `chat`, `stopped`).

  The game keeps the highest number it has applied and applies only what is
  newer. A message applies once, steps included, however often it is read.
- **Bells count messages, not slots.** The PC writes the inbox, then rings bell
  `seq`. The game asks the bell after the last message it applied, and a ring
  loads the next unused slot.
- **A false ring** loads a slot, finds nothing newer, and stops: one slot spent,
  nothing lost, nothing late. The game asks the same bell again.
- **A read during a write must never happen.** The game reports an empty or
  unparsable Lua file as a Lua error and opens its error window, which takes
  the controller's focus (measured 2026-11-14: an empty `Inbox.lua` loaded gave
  "File ... Inbox.lua is empty."). So the inbox is never empty, and the PC's
  write is atomic to the game: see "Still to test".
- **The mailbox becomes this file.** The game reads it at load as now, and
  every slot reads it during the session. One file holds everything the game
  has not applied, before a reload and after.
- **The game counts its own slots**, true takes and false, so it offers the
  Reload at 16 left from the real count. The PC stops keeping a slot cursor in
  step with the game: the cursor, its stamp and the PC's "slots spent" reckoning
  go.

Costs:
- Every take parses the whole inbox: the lines since the last save (at most
  10.4 KB in a session, measured) and the session's one-off messages. A
  `LoadAddOn` of a slot took 2.6-6.5 ms with an inbox of 0, 1, 10 or 50 KB
  (2026-11-14): the load itself costs that, and the size did not show.
- False takes still spend slots, about 80 an hour at the worst seen
  (16:27-18:00). A session has 512, and the Reload offer comes at 16 left.
- It needs hard links, which NTFS has. Windows game drives are NTFS (this one
  is); install refuses any other file system and says why.

Tested 2026-11-14, on slots 509-512 (no session reaches them):
1. **The game reads a hard-linked `Inbox.lua` fresh at each load.** With S510-S512's
   inboxes linked to S509's, each load read what the file held at that moment:
   A at S510; B, the same size, written through S512's name, at S511; a longer C
   at S512 and S509. `...` in an inbox is its slot's addon name.
2. **Writing in place keeps every link**: Python's and Rust's `fs::write`
   (truncate in place) both did. A rename would cut the links.

Still to test: a write the game never sees half done. Either
- `Slot.xml` naming one file outside the slot's folder
  (`..\WowCompanion_Link\Inbox.lua`), which the PC replaces whole by a rename:
  no hard links, no NTFS; whether the game follows a `..` path is unknown (no
  addon here or in Blizzard's source uses one); or
- the hard links, with the PC holding the file shut to readers while it writes:
  the game's open then fails, and whether it reports that as a Lua error is
  unknown.

Then a trial beside the channel, on slots and bells it never reaches, and the
switch after a whole session of counts (CLAUDE.md, "Changing the channel").
