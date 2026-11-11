# The plan

The shared to-do for everyone working on the companion: the player, the in-game
agent, and any other session. Whoever finishes an item removes it (its commit says
how it went); whoever learns something that changes the order says so here.
CLAUDE.md is the truth about how things work; this file is what we do next.
Started over on 2026-11-11 (the player: "clean slate the plan").

## The player's standing terms

They outrank any item below, and live in `player/profile.md` (sent with every
agent request). One more, for whoever works on the companion itself:

- **Don't reinvent what Claude Code already has.** The agent is Claude Code; give it
  tools and instructions. Write code only for the channel, the pad, the voice, and
  fences that must hold whatever the model decides.

## Who does what

The in-game agent owns day-to-day work, features and code alike. A second session
(in a terminal) works on the companion itself when asked, and before touching
anything checks that no request is in flight (`doctor`'s agent line). Two writers
on one file is how replies got lost.

## Next, in order

1. **Settings screens, no slash commands, no tutorials** (the player,
   2026-11-11: "there should just be a settings screen"; "fine for now, can
   always evolve"). Built (PC c8dad13, game 5834a61); not yet tried in game.
   - Game: one settings page owned by Core (works without the Agent), in
     Blizzard's look and the row rule (CLAUDE.md); the Companion window's tab
     shows it, the minimap mark opens it, and Blizzard's AddOns panel has one row
     that opens it. The Tools tab's settings move there; the wheel editor and the
     buff picker live there later.
   - Game bindings are addon keybindings in WoW's Keybindings screen (bound with
     the pad): toggling the Companion window (a tap, told from a hold on
     release) and combat loot. `/wc talkkey` and `/wci bind` go.
   - PC: the setup window is the companion's settings window: titled so, no
     "Next:" guidance.
   - Open: whether WoW sees an Xbox pad's Xbox button; if not, an Xbox player
     binds the window to another button.
2. **rc2 for the friend** after an evening of play on 2026-11-11's changes.

## Later

- **Paged wheels** (the player, 2026-11-11, designed, not built): 8 slots a page,
  any number of pages; L1/R1 flip while the wheel is open and wrap around; page
  dots and a page name; it reopens on the last page used; positions never move
  (muscle memory). Combat-safe: every page's secure buttons are made ahead and
  flipping shows another set. Wheels stay the player's own: none ships.
- **The agent's permission level optional, and its permission requests shown
  to the player** (the player, 2026-11-11: long term, not now).
- Reviews recur (docs/review.md); the first one's fixes are all in
  (`docs/reviews/2026-11-11.md`).

## Decided

- **The data strip is the live game-to-PC path** (the player, 2026-11-10;
  replaces "no live pixel channel" of 2026-11-09): colour cells our code draws,
  read by the companion. Reloads stay the path for the full export.
- **Opus for every conversation; Quick (L2+R2) is Sonnet at low effort** (the
  player, 2026-11-10: Haiku was too weak).
- **Conversation slots stay general** (the player, 2026-11-10): never pre-assigned
  a job ("L2 is gear").
- **No relaunching the game from the PC** (2026-11-10). Measured in Battle.net's log:

  | Route | Result |
  |---|---|
  | `Battle.net.exe --exec="launch wowf"`, `launch_uid wowf`, `--uri="battlenet://wowf"` | selects Forever, never presses Play |
  | `Wow.exe` directly | asks to log in |
  | `Wow.exe -launcherlogin -uid wowf` | "unable to reconnect": the login token comes only from Battle.net's launch |
  | the Agent's local API, 127.0.0.1:1120 | 401 on every path, locked to Battle.net |
  | Battle.net's accessibility tree | not exposed (CEF), no Play button to invoke |
  | click Play | launched |

  The one working route is clicking Play, which is computer use on the player's
  screen: dropped. A detached relaunch script also died with the agent's turn;
  anything that waits for the player belongs in the companion.
- **Not wanted**: trimming the addon's memory.
- **Dictation goes where the cursor is** (the player, 2026-11-11): a text box
  other than chat with the keyboard focus (the auction house search, a mail
  recipient) gets the words as said; otherwise the chat box on the wheel's
  channel. A chat line (dictation's, or an agent's chat step, which is chat
  only) goes into Blizzard's chat box the player opened, or waits for the next
  one they open; the send preview is gone.
- **Both speech engines stay** (the player, 2026-11-11): Whisper for quality,
  streaming for speed; the setup window's Engine choice is the switch.
- **Closed until seen again**: the invisible-focus bug (once, 2026-11-10).
