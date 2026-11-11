# Tech debt and abstraction review (recurring)

The player, 2026-11-11: a recurring task, "tech debt review and abstraction
leakage". Five or six agents commit here every day, each fixing what is in front
of it; this is the pass that looks at the whole. It is done by an agent that did
not write the code under review, reads before it judges, and **changes nothing**:
it writes `docs/reviews/<date>.md`, and fixes happen only after the player picks
them.

## What to look for

1. **Abstraction leakage**
   - Files reaching into each other's internals: `WC.Core.<name>` uses per file
     (74 reach-ins on 2026-11-10), globals read across files, one feature's
     state written by another.
   - Blizzard API or frames touched outside the file that owns that job (the
     chat box outside Chat.lua, focus calls outside the window files).
   - Other addons called directly instead of through `WC.Use(capability)`.
   - The PC side: modules reaching into each other's statics; `main.rs` doing
     another file's job (CLAUDE.md, "Shape": one job per file).
2. **One truth per thing**: the same state kept in two places (the old
   request-status statics were ten of these; Jobs.lua and Transcript.lua had
   their own copies). Name each pair and which should go.
3. **Old paths beside new ones** (CLAUDE.md: a replacement removes what it
   replaces): modes, settings, fallbacks, traces and rules for designs that were
   replaced.
4. **Rules versus code**: a CLAUDE.md or `src/agent.rs` rule the code breaks, a
   rule describing code that no longer exists, and a rule worth a check in
   `tools/luarules.py`.
5. **Size and shape**: files that grew past one job, functions too long to hold
   in your head, copy-pasted helpers (name lookups, Lua quoting, frame styling).
6. **Untested state**: logic of ours that has needed a second fix and has no
   pure model or test (`JobsModel.lua` and `tools/test_jobs.py` show how).
7. **Product versus player**: anything shipped that is this player's (their
   class, wheels, bars, paths) and belongs in their profile or saved data.
8. **Heuristics**: thresholds, time windows, "close enough" matching, guessing
   from text shape (the player's standing rule: a heuristic needs their
   explicit permission). Name each and the exact signal that would replace it.
9. **Bug classes**: for the fixes since the last review, what in the structure
   permitted each bug, and whether that structure is still producing them
   (strings built by surgery and parsed by prefix, state kept twice, rules only
   a reader can enforce). Prefer the fix that removes the structure.

## Numbers to record each time (so the trend shows)

- `python -I tools/luarules.py`: errors and warnings.
- `python -I tools/luaglobals.py --notes`: count.
- `WC.Core.` uses per addon file; lines per file (addon and `src/`), largest
  five each.
- `cargo build` warnings for the workspace.

## The report

`docs/reviews/<date>.md`: the numbers (with the last review's beside them),
then findings ranked by what they cost the player (bugs they cause or invite
first, tidiness last), each with the file and lines, why it matters, and the
smallest fix. Ten findings that matter beat forty that don't. End with the
three you would do first.
