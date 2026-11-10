# The plan

The shared to-do for everyone working on the companion: the player, the in-game
agent, and any other session. Whoever finishes an item moves it to Done with one
line on how it went; whoever learns something that changes the order says so here.
CLAUDE.md is the truth about how things work; this file is what we do next.

## The player's standing terms

These outrank any item below.

- **Controller first; voice is the last resort.** Prefer a setting, an existing
  addon, or a controller-native path. Speech is for when the game offers none.
- **Don't reinvent what Claude Code already has.** The agent is Claude Code; give it
  tools and instructions. Write code only for the channel, the pad, the voice, and
  fences that must hold whatever the model decides.
- **The agent is at full strength** (every tool, no prompts), by the player's choice.
- **The whole game, not one system.** The player engages with most of it and will
  want many things.
- **Never play for them.** Casting, targeting, moving and the final step that spends
  or sends (buy, post, mail gold, send chat) are the player's press.
- **Addons are vetted before install** (maintainer, files, the `.toc`), and installed
  only after a yes.
- **Ask before restarting the game; restart the companion only between requests.**
- **All UI we build looks like Blizzard's** (the player, 2026-11-09): the game's own
  borders, backings, fonts and atlases (tooltip border, dialog background, the
  gamepad art), never flat colour boxes. Read how Blizzard builds the nearest
  equivalent in `docs/wow-ui-source` and copy it.
- **API first; screenshots to read our own displays** (the player, 2026-11-10):
  information comes from the API; when it is only on screen (our frame, an addon's)
  and a reload is the alternative, draw it and read it by screenshot. Anything
  else on the player's screen only when they ask.
- **Nothing of ours opens itself.** The Companion window opens only when the player
  asks (minus tap, `/wc log`); news goes to the bottom-left toast.

## Who does what

The in-game agent owns day-to-day work, features and code alike. A second session
(in a terminal) works on the companion itself when asked, and before touching
anything checks that no request is in flight (a `claude.exe` with `--json-schema`
on its command line means one is). Two writers on one file is how replies got lost.

## Next, in order

### 1. Make the loop tight

Being built by the terminal session (the player's call, 2026-11-09). The foundation: everything after this is cheaper once requests are never lost,
never invisible and never slow for no reason.

1. **Safe self-restart.** (Done, 2026-11-09: `wow-companion restart`.) `run` checks for a restart request (a file), finishes the
   request in flight, and exits; a small loop relaunches the new build. Then the
   agent can rebuild and restart the companion without ever losing a reply, and
   nobody has to kill anything.
2. **A visible queue.** (Done.) A request made while another runs shows at once in the
   window as "waiting", not only when it starts.
3. **The slot budget.** (Done: progress stops at 50, replies warn from 56.) 64 messages per UI session, and progress lines spend them.
   Warn in the window at about 50, offer Reload at the limit, and stop progress
   lines before replies run out. Today running out fails silently.
4. **A lighter CLAUDE.md.** It is ~28 KB, read on every request, and partly history
   ("we skip a game-to-PC channel", superseded designs). Split it into a short file
   of what is true now and `docs/history.md` for how we got here. Every request
   gets faster and stops reading claims that are no longer true.
5. **Dictation into any focused text box** (done), not only chat: the auction house
   search, a mail recipient, any search field. The player focused it, so setting
   its text is the same as chat. It turns voice into typing everywhere.
7. **Cancel a misspoken request** (the player, 2026-11-09, after several garbled
   clips went through). Controller first: (a) while the talk button is held, a
   second button (circle, or capture) throws the clip away before it is
   transcribed; (b) while the agent is thinking, a Cancel button in the Companion
   window stops the request in flight (kill that `claude` child, drop its reply,
   keep the thread). "Never mind" by voice stays as the fallback. Show the
   transcript first in the window, so a misheard line is visible before it acts.
6. **Measured by use.** Each agent Lua run records which API names it called and
   whether it errored; `tools/api_surface.py` promotes those from inferred to
   measured. The map gets truer as the agent works, at no extra cost.

### 2. Controller features

In the player's order (2026-11-09). From `docs/api-surface.md`, all live in Forever:

- **Self-filling wheels** (first): food and drink, quest items, mounts, toys, travel,
  party. Plus a **magic slot**: one slot on a wheel that becomes "the thing you just
  asked for" ("I need my hearthstone" puts it there).
- **Find things in my bags, fast**: say or pick it, and it is found, shown, usable.
- **Quest helper**: next objective on screen, a waypoint to it, its items on a wheel,
  track and abandon without the quest log.
- **Vendor button**: sell greys and repair in one press at a merchant.
- **Crafting queue**: "make ten of these and whatever levels me", one press per craft.
- **Mail**: collect all; send materials to an alt.
- **Bags**: sort, summarise what is new or sellable, use from a wheel.
- **Roles**: talents, equipment sets and bars per role, swapped with one press.
- **Auction house**: search, price and prepare; the player presses post or buy.

### Later: the Companion window's controls (the player, 2026-11-09)

Not the main initiative now. A full button row was too many for the main screen;
much of what the player wants is contextual, so think **tabs** (e.g. transcript,
actions, settings) with at most a few buttons on the main view. Constraints already
known: a window button cannot reach the PC (no game-to-PC channel), so app actions
(cancel, retry, new conversation) are minus chords the helper reads off the pad;
the offered button must never take focus while the window is hidden (that broke
the bars once, cause not yet reproduced).

- **Several conversations** (the player, 2026-11-10, an idea): separate threads,
  each its own agent session, picked from a side list in the window.

- **Home as a wheel button** (the player, 2026-11-10, an idea): Home tap, or Home
  with a modifier, opens a wheel. Home + trigger and Home held already start a
  conversation over, so a tap and the remaining chords are what is free. The PC
  reads Home, so opening a wheel needs a press the game can see: likely a binding
  on the game side, measured first.

### Next up: a game-to-PC data strip (the player, 2026-11-10)

Data the PC needs without a reload, read by screenshot (the player allowed it).
Not text: a tight strip of solid colour cells in the **very bottom-right corner**,
shown only for the moment of the shot and gone right after (no lingering cards:
the player's rule). Bytes in RGB per cell, corner markers and a header with
length and checksum, compressed payloads paged across shots; decoded by code on
the PC at full resolution. Built beside the PC-to-game channel, never touching it.

### Later: a custom look (the player, 2026-11-09)

A separate addon (`WowCompanion_Look`), independent of the AI pipeline: one theme
file, one file per UI part, Blizzard-style art. The ambitious part is a fork of
Blizzard's controller action bars (source in `docs/wow-ui-source/Interface/AddOns/
Blizzard_GamepadActionBars`), rebuilt on secure templates and state drivers so
paging and modifiers still work in combat, then styled our own way. Also: the
experience bar, which floats at the bottom out of keeping with everything else.
Start from the three things on screen that bother the player most.

### 3. Decided

- **No live pixel channel** (2026-11-09): reloads stay the return path. Screenshots
  could carry data live, but that is the ToS-grey pixel strip; the player said no.
- **Opus for everything** (2026-11-09): smarts over speed, even for quick requests.

### Addon installs waiting for one restart (the player, 2026-11-09)

Install all together, one game restart, once the player's research list is done.
- **Polestar 0.3.5**: vetted and approved. GitHub fitzforge/polestar, release zip
  `Polestar-0.3.5.zip` (SHA256 ef9184e6...16d36c), staged at `target/vet/`.
  Addon only, not the desktop client. Turn party-chat progress off after install.
- **Undying 0.28.3**: vetted (closed source, no "next upgrade" finder yet); the
  player has not decided.
- **UpQuest Forever**: rejected for now (51-60 paywalled, closed, 187 downloads).
- Downloaded and file-checked in `target/vet/` (Lua, XML, toc, media only, no
  escaping paths): BuddiesQuestForever 1.0.32 (`bqf.zip`), GearQuest Forever
  1.1.2 (`gq.zip`, core + one module per class: enable only DRUID), GearedForever
  1.0.1 (`gf.zip`). Awaiting the player's picks.

### Restarting the game (investigated 2026-11-10)

Every attempt so far failed, and now we know why. Measured, in Battle.net's own log:

| Route | Result |
|---|---|
| `Battle.net.exe --exec="launch wowf"` | selects Forever ("Selecting game family by id: wowf"), never presses Play |
| `--exec="launch_uid wowf"` | selects it ("Selecting game by uid"), never presses Play |
| `--uri="battlenet://wowf"` | selects it, never presses Play |
| `Wow.exe` directly | asks to log in |
| `Wow.exe -launcherlogin -uid wowf` (Battle.net's own arguments) | "unable to reconnect, please log in": the login token comes only from Battle.net's launch |
| the Agent's local API, 127.0.0.1:1120 | 401 on every path: locked to Battle.net, and not ours to work around |
| Battle.net's accessibility tree | not exposed (CEF renders without one), so no Play button to invoke |
| **click Play** (Battle.net to the front, click the Forever card's Play) | **launched**, with Battle.net's `-launcherlogin -uid wowf` and the login handed over |

Also: the agent's detached relaunch script died mid-wait (its log stops), most likely
ended with the agent's turn. Anything that waits for the player belongs in the
companion, the long-running process.

The one route that works is a synthetic click, so it is a last resort with rules:
the companion owns it (a relaunch request beside `restart.request`; the agent offers
`/quit`), it selects Forever with `--uri="battlenet://wowf"`, finds the Play button by
looking at the window rather than a fixed position (the first time: half-scale
window offset 776,276, full 1552,552, new layout, Forever the first card), clicks,
and then **must verify**: `Wow.exe` with `-launcherlogin` within 30 s, or say so in
the window. It can break when Blizzard changes the launcher; it must never fail
quietly. Not built yet: the player's call.

### 4. Small and open

- Restarting the game: the last attempt failed; worth a look when it matters.
- The offered button's controller shortcut (PADDRIGHT): confirm it fires.
- Which form of a two-part name a whisper accepts.
- Read the taint verdicts for the chat paths (`pathTaint` in the export).

## Done

- 2026-11-09: controller chords learned from play; multi-step answers on Opus; full
  Claude Code; progress, a seconds count, and replies that always arrive; chat
  channels by voice, drafts cleared on cancel; addon vetting; Blizzard's UI source
  for this build; the API surface and its terms; Lua errors exported; conversations
  that survive restarts; wheels (the agent's, and the player's favourite).
- 2026-11-09: minimap pins the agent draws from coordinates in conversation
  (`WCPins`; how and why in `docs/api-useful.md`, "Minimap pins"). The player:
  "we're really going to want that feature in the future." Next: world map pins.
