# Slot bells: a bell per slot, a set per session

The player, 2026-11-11: "let's get that robust design going", after the frame
bell trial broke delivery for an evening (docs/history.md, 2026-11-11).

## What the game allows (src/bells.rs, and measured)

- The game can only tell the PC's files apart by playing a sound and asking
  `C_Sound.IsPlaying`.
- A half-second bell (`bells::bell`, 192,044 bytes, 96 kHz stereo) plays 2 ms
  after `PlaySoundFile`: the next frame. A ten-second one (the message bell) is
  streamed and is not playing a frame later.
- An empty file fails at once and holds nothing; a check of one costs about a
  microsecond, and one every frame left frame times unchanged at 120 fps.
- A file the game is playing is held: the PC can neither change nor empty it.
- A missing file the game has asked for is remembered missing: one created later
  is never heard.
- A slot loads once per UI session; a `/reload` makes all of them loadable again.

## What broke

The frame bells were eight files shared by 512 slots, emptied 2 s after each
ring. Played every frame, a rung ten-second bell was never heard and so always
held, so it could not be emptied; still ringing, it rang again for the slot
eight on, which the game took (an earlier session's message, skipped) and so ran
ahead of the PC: waiting on slot 26 while the PC wrote 9, every message after
that went into slots the game had passed. The message bells share both flaws in
milder form, which is why they need the catch-up bells and a 2 s wait per send.

## The design

- **A bell per slot**: `Signals\g<set>-<slot>.wav`, slot 001 to 512. The PC
  writes the slot's inbox, then rings its bell (`bells::bell`), and never empties
  it during the session: a slot is used once per session, so its ring can only
  ever mean that slot, and nothing has to be changed while the game holds it.
- **A set per session, three sets**: the set is `loads % 3`, where `loads` is the
  Link addon's own count of its loads (`WowCompanionLinkDB.loads`, one more at
  every load). The game knows it at load; the PC reads the save, where it is the
  last session's, and adds one (`backups::loads`). Both read the same save, so they
  agree with no message between them, a crash included (no save written: both
  count the same session again).
- **Emptied while idle**: during a session the PC empties every rung bell of the
  two other sets, which nothing polls. A set is used again two sessions after it
  was last used, so it is emptied in time unless two reloads both finish before
  the PC sees either (it watches the save's time 4 times a second; a reload takes
  seconds). When the game exits, all three sets are emptied; and a crashed
  session's set, used again by the next one, is emptied then too.
- **The game**: every frame, the next slot's bell of this session's set, asked
  the next frame. A ring takes the slot. Nothing else: no session check, no
  catch-up, no half-second poll.
- **Every file exists before the game can ask for it**: `install` makes all
  1,536, empty.

## How it is proven (CLAUDE.md, "Changing the channel")

Beside the message bells, **watching only**: the game asks the slot bells every
frame and records when it heard each slot's ring against when the message path
took that slot, but never takes a slot itself, so the cursor stays the message
path's. Counts readable without a reload (`/wc slotbells`): rings heard, how much
earlier than the message path, slots the message path took that never rang,
and frame times. The PC logs any bell it could not write.

After a session of clean counts and the player's yes, the slot bells take the
slots, and the replacement removes what it replaces: the message bells, the
catch-up bells, the half-second poll, the session check on taking, the PC's
2 s wait per send and `BELL_LINGER`.

## Cost

1,536 files in Signals, empty when idle; a rung bell is 192 KB until its set is
emptied (a busy session of 100 messages leaves about 19 MB, gone two sessions
later).
