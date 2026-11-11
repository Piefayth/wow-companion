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

## Phases

1. Audit trail (done 2026-11-10): `src/audit.rs`, the game's
   `WowCompanionDB.audit`, `tools/audit.py` merging both.
2. PC: per-conversation entry list and versioned snapshots; tests that replay
   the hard races (cancel while heard, cancel as the reply lands, speak again
   at once, slow Whisper, missed message).
3. Game: a renderer that draws the snapshot plus overlays by the three rules,
   replacing Jobs.lua's matching and Transcript's key ordering.
