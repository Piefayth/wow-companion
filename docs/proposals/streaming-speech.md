# Streaming speech: is it fast, and is it accurate enough? (2026-11-11)

The player: "if we can get streaming to work at even close to the current accuracy
it'd be huge"; "current speed already very limiting". Measured on this PC
(i9-12900KF, RTX 4090), game closed, on synthetic clips. **Synthetic speech flatters
every engine; the player's own voice, in game, must confirm before anything ships.**

## The answer so far

1. **The slowness is not Whisper's own speed.** On an idle GPU, Whisper as configured
   decodes a short command in ~120 ms and 10-20 s of dictation in ~155 ms. Live, over
   384 clips in `timing.log`, the same takes **637 ms (short) and 1,160 ms (long)**:
   WoW shares the GPU and Whisper runs 5-7x slower while the game renders. Then
   **1,377 ms** more from transcript to the first bell (the 0.5 s gather window and the
   channel), then up to 0.5 s for the addon's poll.
2. **A streaming engine on the CPU keeps pace with speech and never touches the
   game's GPU.** NVIDIA's Nemotron streaming 0.6B (160 ms chunks, int8, sherpa-onnx)
   computes at 0.25-0.4x real time on 4 CPU threads, so its text trails the voice by
   about one chunk plus compute (~0.2-0.3 s, estimated from that rate; the real-time
   test did not run), and the final text is ready about when the button is let go.
3. **Accuracy is close on dictation, not yet on short WoW commands:**

| Engine | Long dictation WER (clean / noisy) | Short commands WER (clean / noisy) | Exact short commands (clean) |
|---|---|---|---|
| Whisper large-v3-turbo, live settings (prompt with spell names) | 1.9% / 3.1% | **3.0% / 6.0%** | 91% |
| Whisper, no prompt | 2.2% / 3.1% | 6.7% / 10.0% | 76% |
| **Nemotron streaming 0.6B, 160 ms** (no vocabulary given) | **3.2% / 5.4%** | 8.0% / 12.7% | 74% |
| Parakeet unified 0.6B, streaming 240 ms | 2.9% / 7.1% | 16.0% / 19.7% | 59% |
| Zipformer streaming (2023) | 11.4% / 14.8% | 25.7% / 33.7% | 35% |

   96 clips (24 lines x 2 voices x 2 rates), each also with hiss mixed in; "short" is
   up to 8 words. Nemotron's misses are the game's words: "Orihime" -> "or him",
   "Faerie Fire" -> "ferry fire", "party" -> "Hardy", "R2" -> "our two". Without its
   spell-name prompt Whisper drops from 3.0% to 6.7% on the same commands, so
   Nemotron unbiased (8.0%) is near Whisper unbiased: **vocabulary biasing is the gap**,
   and sherpa-onnx has it (hotwords, below), untested.

## What did not run, and what comes next

Claude Code stopped the benchmark when the PC ran critically low on memory (other
programs and five agent sessions were running); not restarted. Not measured yet:
hotwords on Nemotron (the decisive test: the spell and player names as biased
words), Parakeet offline and Moonshine on all clips (one clip each: Parakeet 124 ms,
Moonshine 55 ms on CPU, both missed "Orihime"), true real-time lag over the
websocket client (script ready), and each engine's RAM. Next, with memory to spare:
those, then the player's own voice in game. Measure RAM per engine before choosing.

## Shape if it holds

- **Engine:** sherpa-onnx (Apache-2.0) with Nemotron streaming (NVIDIA Open Model
  License: check its terms before shipping it to other players), on the CPU through
  ONNX Runtime. The official `sherpa-onnx` crate (2.0.1, k2-fsa) downloads prebuilt
  static libraries at build time (or `SHERPA_ONNX_LIB_DIR`): no C++ or CUDA build,
  one exe, macOS libraries exist. Its CUDA build needs cuDNN 9 (not on this PC); the
  CPU is the point anyway, since it keeps the GPU for the game.
- **Whisper:** kept only if the player's voice shows Nemotron with hotwords still
  falls short on commands; otherwise it goes (one engine).
- **The game side:** each message is one of 512 slots per session, picked up on a 0.5 s
  poll, so partial words cannot be sent as they come (two a second would spend the
  session in about four minutes). Worth sending: the finished line at release (one
  slot, now about 1 s sooner), and a recognised voice command the moment its words
  are heard, before release. Live captions in game need a different channel design.
- **Separately, and bigger than Whisper:** the 1.4 s from transcript to the first bell
  (gather window plus the channel holding each send for its bell). That is the
  message channel (CLAUDE.md, "Changing the channel"): measured and changed beside
  the current one, never live.
