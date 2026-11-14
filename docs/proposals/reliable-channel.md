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

A later ask would not fix it. The false ring lasts frames, and a frame can be
longer than any fixed wait. A control can fix it.

## The fix

1. **A control** (Link.lua `check`): each slot bell is played with `never.wav`,
   which is empty and written by nothing, in the same frame and after the bell.
   Both are asked at the same moment. If the control still reads as playing,
   the game has not decided yet, and the slot bell's answer says nothing.
   - The measurement: 26 of 26 same-frame pairs agreed.
   - The order: the control is opened after the bell. If the control's open
     has failed, the bell's open, queued first, has been decided too.
   - It costs one more empty play every 0.1 s. The probe did the same for four
     hours. The heartbeat went stale twice in that session (`channel.slowed`),
     which is what held files look like; the count step shows whether that
     comes from the extra play.
2. **A stale slot is dropped** (Link.lua `receive`): a slot stamped for an
   earlier session is counted and not handled. The PC takes the stamp and the
   bell set from one number (session.rs), so a message written for this
   session always carries this session's stamp.

## Rollout (CLAUDE.md, "Changing the channel")

1. **Count** (2026-11-13): every take's audit line says `control=playing` or
   `control=quiet`, and `channel.undecided` counts the asks made while the
   control played. Nothing is obeyed yet. After one played session, every fresh
   take should read quiet and every stale take playing. A fresh take that reads
   playing would mean a real open delays the control's open, and the next step
   would then hold real messages.
2. **Obey**: while the control plays, the slot is asked again at the next tick
   instead of being taken. The heartbeat (Status.lua) asks its pulse bells the
   same way at 0.15 s, so it can misread a quiet bell in the same race. It gets
   the control in this step too.
