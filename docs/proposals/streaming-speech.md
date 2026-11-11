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

## The deciding test: vocabulary biasing (2026-11-11)

**Verdict: with the same vocabulary as Whisper, streaming Nemotron is within reach:
better on noisy commands and clean dictation, behind on clean commands and noisy
dictation, level overall.** Same 96 clips, one engine at a time, both engines given
exactly the same words: Whisper as its prompt (the companion's own format,
`transcribe::prompt`), Nemotron as hotwords (sherpa-onnx contextual biasing,
modified beam search, score 3.0).

The vocabulary: the character's 32 castable spells from the export's `reach`
section, the 6 macros, and Whisper's command words (the export's spellbook
section is empty, a bug for the in-game side; its `reach` section lists the same
spells). "+ names" adds what the game knows and the companion should pass to
either engine: friends and guild (Orihime, Cecil Sorrowheart), zones (Astranaar,
Darnassus, Barrens), items (Wool Cloth, Deviate Hides), a profession (Skinning).
The earlier run's hotword list had held those words too, which flattered
streaming; here both engines get them or neither does.

| Engine (same words) | Commands clean | Commands noisy | Dictation clean | Dictation noisy |
|---|---|---|---|---|
| Whisper, spells + macros | 3.0% | 5.7% | 2.0% | 3.1% |
| Nemotron, spells + macros, hotwords 3.0 | 6.3% | 6.7% | 2.2% | 5.1% |
| **Whisper, + names** | **3.0%** | 6.3% | 1.9% | **3.2%** |
| **Nemotron, + names, hotwords 3.0** | 4.3% | **4.7%** | **1.4%** | 4.1% |
| Nemotron, + names, no hotwords (beam search) | 7.3% | 11.3% | 3.1% | 4.9% |
| Nemotron, spells + macros, hotwords 1.5 (default) | 8.7% | 10.0% | 2.2% | 4.4% |
| Nemotron, spells + macros, hotwords 4.5 | 7.0% | 19.0% | 3.9% | 4.9% |

- **The score matters and was chosen on these clips** (1.5 too weak: "ferry fire"
  survives; 4.5 too strong: spells appear that were not said, "Swap" becomes
  "Swipe"). 3.0 is the setting; the player's voice confirms it or moves it.
- **Nemotron's remaining misses:** "R2" heard as "our two" a few times, "Moonglade"
  as two words, and one "Bear Form" heard as "Therefore". Whisper's: "Orihime" and
  "Moonglade" too.
- **Parakeet streaming cannot be biased** in sherpa-onnx 2.0.1 (its streaming model
  supports greedy decoding only: "Unsupported decoding method:
  modified_beam_search"), and unbiased it was far behind (16% on commands). Out.
- **Memory:** Nemotron with hotwords peaks at 748 MB of RAM on the longest clip
  (14 s), on the CPU, against Whisper's ~1.6 GB of video memory beside the game.
- **The lag of partial words** could not be read from the websocket client (it
  prints its results only at the end); it was measured inside the companion
  instead (below).

## The trial in the companion (stage 2, 2026-11-11)

**Built, beside Whisper, for the player to compare in play.** Both engines are in
every build; the setup window's Speech card picks one (Engine: Whisper or
Streaming), or `settings.toml` says `speech = "streaming"` and `stream_model =
"<folder>"`. The window downloads the model from k2-fsa's release (checked by
SHA-256, unpacked, the archive deleted) after showing NVIDIA's licence. After the
player's verdict the losing engine is deleted, code and setting both.

- **How it runs:** the voice loop feeds the mic's audio to the engine's thread
  while the button is held (`crates/voice/src/stream.rs`); partial words go to the
  log only; at release the final text goes the way Whisper's does (same checks,
  same routing). Each utterance gets the same words Whisper's prompt carries
  (`context::vocabulary`: spell and macro names, the command words) as hotwords,
  score 3.0.
- **Measured inside the companion** (debug build, the bench's clips fed at the
  pace of speech, `wow-companion transcribe-stream`): **final text 178 ms after the
  audio ends** (median, max 251 ms, 24 clips), against Whisper's 637 / 1,160 ms
  live. Partial words trail the voice by about 60 ms of compute per 100 ms piece.
- **Linking:** sherpa-onnx's static libraries are built with the static C runtime
  and whisper-rs with the dynamic one, which MSVC refuses to link together
  (LNK2038), so the crate's `shared` feature is used: four DLLs (ONNX Runtime and
  sherpa-onnx's) beside every exe. The companion's bin copy and the release zip
  carry them.
- **Not yet known:** the player's own voice, in game, with the game on the CPU
  too. The live vocabulary also lacks spells until the export's spellbook section
  is fixed (it is empty; Whisper is short of them the same way).

## Licences

- **Nemotron streaming 0.6B and this Parakeet export: NVIDIA Open Model License.**
  Free to use and redistribute, commercially too, provided a Notice file reads
  "Licensed by NVIDIA Corporation under the NVIDIA Open Model License", a copy of
  the agreement goes with it, use stays consistent with NVIDIA's Trustworthy AI
  terms, its guardrails are not defeated, and NVIDIA is indemnified. When the
  setup window downloads the model from its public source, as it does Whisper's,
  we do not redistribute it; the window shows the licence before downloading.
- sherpa-onnx: Apache-2.0. Zipformer: Apache-2.0. Moonshine: MIT. Whisper: MIT.

## Shape if it holds

- **Engine:** sherpa-onnx (Apache-2.0) with Nemotron streaming (NVIDIA Open Model
  License: check its terms before shipping it to other players), on the CPU through
  ONNX Runtime. The official `sherpa-onnx` crate (2.0.1, k2-fsa) downloads prebuilt
  libraries at build time (or `SHERPA_ONNX_LIB_DIR`): no C++ or CUDA build, macOS
  libraries exist. Beside Whisper it links as DLLs (above); with Whisper gone its
  static build would make one exe again. Its CUDA build needs cuDNN 9 (not on this
  PC); the CPU is the point anyway, since it keeps the GPU for the game.
- **Whisper:** kept only if the player's voice shows Nemotron with hotwords still
  falls short on commands; otherwise it goes (one engine), and the setup window's
  Engine choice with it.
- **The game side:** each message is one of 512 slots per session, picked up on a 0.5 s
  poll, so partial words cannot be sent as they come (two a second would spend the
  session in about four minutes). Worth sending: the finished line at release (one
  slot, now about 1 s sooner), and a recognised voice command the moment its words
  are heard, before release. Live captions in game need a different channel design.
- **Separately, and bigger than Whisper:** the 1.4 s from transcript to the first bell
  (gather window plus the channel holding each send for its bell). That is the
  message channel (CLAUDE.md, "Changing the channel"): measured and changed beside
  the current one, never live.
