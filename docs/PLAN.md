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

## Who does what

The in-game agent owns day-to-day work, features and code alike. A second session
(in a terminal) works on the companion itself when asked, and before touching
anything checks that no request is in flight (a `claude.exe` with `--json-schema`
on its command line means one is). Two writers on one file is how replies got lost.

## Next, in order

### 1. Make the loop tight

The foundation: everything after this is cheaper once requests are never lost,
never invisible and never slow for no reason.

1. **Safe self-restart.** `run` checks for a restart request (a file), finishes the
   request in flight, and exits; a small loop relaunches the new build. Then the
   agent can rebuild and restart the companion without ever losing a reply, and
   nobody has to kill anything.
2. **A visible queue.** A request made while another runs shows at once in the
   window as "waiting", not only when it starts.
3. **The slot budget.** 64 messages per UI session, and progress lines spend them.
   Warn in the window at about 50, offer Reload at the limit, and stop progress
   lines before replies run out. Today running out fails silently.
4. **A lighter CLAUDE.md.** It is ~28 KB, read on every request, and partly history
   ("we skip a game-to-PC channel", superseded designs). Split it into a short file
   of what is true now and `docs/history.md` for how we got here. Every request
   gets faster and stops reading claims that are no longer true.
5. **Measured by use.** Each agent Lua run records which API names it called and
   whether it errored; `tools/api_surface.py` promotes those from inferred to
   measured. The map gets truer as the agent works, at no extra cost.

### 2. Controller features

Order is the player's call. From `docs/api-surface.md`, all live in Forever:

- **Self-filling wheels**: food and drink, quest items, mounts, toys, travel, party.
- **Quest helper**: next objective on screen, a waypoint to it, its items on a wheel,
  track and abandon without the quest log.
- **Vendor button**: sell greys and repair in one press at a merchant.
- **Crafting queue**: "make ten of these and whatever levels me", one press per craft.
- **Mail**: collect all; send materials to an alt.
- **Bags**: sort, summarise what is new or sellable, use from a wheel.
- **Roles**: talents, equipment sets and bars per role, swapped with one press.
- **Auction house**: search, price and prepare; the player presses post or buy.

### 3. Decisions for the player

- **A live return channel.** Reloads are the only way results reach the agent.
  `Screenshot()` writes a file at once, so the addon could draw data on screen for a
  frame and the companion read it: live results, no reload. It is the pixel-strip
  idea this project declined as the ToS-grey part, so it is the player's call.
- **Speed versus smarts.** Opus everywhere (now), or Sonnet for quick requests
  (chat, a single bar change) and Opus for the rest.

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
