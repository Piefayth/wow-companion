# Conversation sync: the PC decides, the window predicts within rules

2026-11-10. The player: "PC is the source of truth. But we need to display a
consistent view of the state of the world that is predictable and
non-disruptive to the user at all times in the add-on." The channel to the
game takes 1-3 s per message and the game's commands back take ~1 s, so the
window must hide that latency without ever inventing or reordering anything.

## Why the last version failed

The window kept a second state machine: it matched clips to jobs by time
windows, placed lines by its own rules, and resolved cancels on its own. Late,
missed or reordered messages made those guesses disagree with the PC, and each
fix added another guess.

## The model

1. **The PC owns the conversation.** Per conversation, an ordered list of
   entries (your message, a reply, a note), each with a stable id, an order
   number and a state. It is the only thing that orders or decides anything.
2. **Snapshots, not deltas.** Every change sends the conversation's tail
   (the last N entries: id, order, who, state; text only for entries the game
   has not seen) with a version number. The window takes a snapshot only if
   its version is newer than the one it holds. A missed, repeated or reordered
   message can then never corrupt the view: the next snapshot repairs it.
3. **Predictions are overlays with three rules.** The window may show what it
   expects before the PC confirms (latency hiding), but only as an overlay:
   - *anchored*: drawn at the end, or on an entry the PC already confirmed;
     never between confirmed entries, never moving one;
   - *matched by identity*: each overlay names exactly what confirms it (the
     clip's release, the entry id it acts on), and the PC echoes that name;
   - *bounded*: if no confirmation comes within a fixed time, the overlay
     settles to a visible, honest state ("not confirmed"), never silently.
   When the confirmation arrives, the overlay is replaced **in place** by the
   confirmed entry, so the user never sees a jump.
4. **One identity for a clip, on both sides.** The PC reads the pad itself, so
   it sees every release at the same instant the game does. A clip is named by
   (conversation, release time); the PC echoes it on the job's first message.
5. **Buttons are requests.** X and Send now draw a command and show a pending
   mark on their entry; the snapshot that follows decides. Repeats are
   harmless (the PC takes them as one).

## What the research says, and where we stand (later the same evening)

This is two solved problems put together:

- **Replicated state over an unreliable, reordering channel**: a state-based
  CRDT (Shapiro et al., "Conflict-free Replicated Data Types", 2011). Each
  job's state is a join-semilattice (hearing < queued < running < one end;
  the first end wins) and merging is "take the higher". The PC's ledger
  (src/jobs.rs) already is exactly this, and every message carries the job's
  state, so any order of delivery converges. Snapshots were not needed.
- **Hiding latency**: client-side prediction with server reconciliation
  (Gambetta, "Fast-Paced Multiplayer"; Valve's networking model). The client
  shows its own inputs at once and drops each one when the authoritative
  state acknowledges *that input by its identity*.

The bugs were all in identity and placement, not in the ledger:

1. A hearing cancel was named by a press time to the second, and the PC took
   the newest clip let go before it: with two clips in flight it cancelled the
   wrong one. Now the clip is named by its release (both sides see it, to the
   ms), matched nearest within 1.2 s (`jobs::heard_at`, tested).
2. Clips joined any clip still being transcribed, so a slow Whisper merged
   separate messages. Now only a clip let go within 1.5 s joins (tested).
3. The window inserted replies above lines already read. Confirmed lines now
   only append; whatever is still to come waits at the end.

## Phases

1. Audit trail (done 2026-11-10): `src/audit.rs`, the game's
   `WowCompanionDB.audit`, `tools/audit.py` merging both.
2. PC: per-conversation entry list and versioned snapshots; tests that replay
   the hard races (cancel while heard, cancel as the reply lands, speak again
   at once, slow Whisper, missed message).
3. Game: a renderer that draws the snapshot plus overlays by the three rules,
   replacing Jobs.lua's matching and Transcript's key ordering.

## Proposal (for the player's yes): an exact identity for a clip

Today a cancel pressed on a "hearing you" line names the clip by when it was
let go, and the PC takes the job let go nearest that time, within 1.2 s,
across two clocks the game has to line up by learning their 2.3 s gap
(`jobs::heard_at`, `RELEASE_MATCH`; the model's `offset`, `takeClip`). That is
a heuristic: two clips close together, or a clock drift, can name the wrong
one.

**Why the architecture permits it:** the game invents a clip's identity on
its own (its clock at release), when the only identity both sides share is
one the PC makes: the job id, made the instant the PC sees the release.

**The exact design:** the PC tells the game the job id when a clip is let go,
in a `{ kind = "heard", job = <id>, slot = ... }` message (the job's state is
`hearing`, so it is just the ledger's first message about that job). The
game's hearing line is drawn from that message, so its X carries the job id
and a cancel says `cancel <id>`, as every other cancel already does. Nothing
is matched, no clock is lined up, no hearing cancel command exists.

**What it removes:** `heard_at`, `RELEASE_MATCH`, `cancel_clip` and the
`hear` command on the PC; on the game the clip placeholders, `Released`,
`DropHearing`, `CancelClip`, `takeClip`, the learned clock offset, `nowMs`'s
wall-clock catch, and the `Claim` hidden/dup rules (a cancelled hearing job's
words are dropped on the PC, which already never sends them).

**What it costs:** the hearing line appears when the message lands, about a
second after you let go, not the instant you do, and the X with it. And every
clip costs one more send, which holds the channel for a bell (the 2 s that
once delayed a short request's own line). Whisper usually takes ~1.4 s, so
the line may often arrive with, or after, the words: then it shows only the
words. If the instant feedback matters, the pad's rumble on release is the
instant cue, and the hearing line stays exact.

**Not proposed:** keeping an instant local line beside the exact one. It
needs matching the local line to the PC's message, which is the same
heuristic again.
