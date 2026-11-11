# Errands (proposal, second draft, 2026-11-10)

**Built 2026-11-10** (untested in game): Errands.lua, Providers/Pins.lua, provider
self-checks in Engine.lua, the Errands tab, Nav via Polestar's Nav.API.

Nothing here is built. The rushed first attempt (`Providers/Errands.lua`,
`Todo.lua`) is on disk, out of the .toc; parts of `Todo.lua` (the store, the
item/quest ticks) carry over, the Polestar guide provider is discarded.

## The player's answers (2026-11-10)
1. Like the quest log: a short always-visible tracker, plus a log with details.
2. They don't use Polestar's UI: no Polestar route tab.
3. Agents add (and remove) errands only when asked, by voice.
4. Never depend on another author adding an API ("you can only trust your fists").
Ny's To-Do List has an API but is left out by the player's choice. No addon offers a
quest-log-like list that takes custom entries; Blizzard's tracker cannot take ours
without taint.

## Shape
Errands are **our feature** (like the bag window), not a capability. Around it,
it **uses** capabilities, each optional:

| Used for | Capability | Providers (only addons the player runs) |
|---|---|---|
| where it is, on the map | `pins` (new: set(layer, points), clear(layer)) | builtin Pins.lua (minimap); Polestar Pins.SetLayer (internal, no public API) |
| take me there | `nav` (exists) | Polestar **Nav.API.Navigate** (documented; replaces our SetTarget call); builtin pin |
| where to get the item | `itemSource` (exists) | Polestar Codex |
| what it costs / is worth | `price` (exists) | Auctionator, builtin |
| near your next quest step | `guide` (exists) | Polestar (read only) |

Without Polestar it still works: our minimap pins, no drop sources.

## Every errand completes itself (enforced in code)
The player's call (addendum): the errand API itself refuses an errand without a
`done` condition from a fixed set of kinds, each kind validated (ids exist, numbers
in range), not left to the agent's judgement. The agent says why when it is
refused. Kinds (one or more, all must hold; the set grows as needed):
- `have = { item, count }`: bag count (BAG_UPDATE_DELAYED)
- `visit = { npc, kind }`: merchant / trainer / gossip / bank opened with that NPC
  (MERCHANT_SHOW etc., NPC id from `UnitGUID("npc")`)
- `reach = { map, x, y, r }` or `{ zone }`: position or zone (Pins.lua's world-yard
  maths; ZONE_CHANGED_NEW_AREA)
- `quest = { id, state = "accepted" | "complete" | "turnedin" }`
- `skill = { name, rank }`, `level = n`
Refused at creation if already true (it would vanish at once). Done errands leave
the tracker with a toast, and stay in the log's history for a while.

Adding is the one common action; removing and editing are rare and start as agent
calls (a `lua` step on the errand API), by voice, only when asked.

## Display: no new bindings, nothing pressed
How Blizzard does it in this build (verified in docs/wow-ui-source): the quest
tracker is reached from the shortcuts bar (HUD modifier + d-pad up,
Blizzard_GamepadActionBars/TargetActionBars/ShortcutsActionBar.lua:66, which calls
`FrameControlsManager:FrameShown(ObjectiveTrackerFrame)`); inside it, A on a section
header clicks its minimize button (`ObjectiveTrackerFrameMixin:MinimizeTrackerModule`,
Blizzard_ObjectiveTracker.lua:267). The whole tracker collapses through
`ObjectiveTrackerContainerMixin:SetCollapsed` (Blizzard_ObjectiveTrackerContainer.lua:195).
`GamepadHudMode` exists, but nothing in this build calls `RegisterForHudMode`.

- **Tracker**: our own frame, **not** docked to `ObjectiveTrackerFrame` (the player,
  2026-11-10, from a screenshot: their tracker fills the whole right column, from the
  minimap to the bottom). A fixed place (never moves, not anchored to anything that
  moves): top left, directly under where the board/toast appears, below the board's
  tallest size (all six conversations at work: 2*10 pad + 20 header + 6 rows * 16 =
  136 units, Board.lua), so they never collide. In the tracker's fonts and header style: errand text and place or count ("Lockbox,
  Silverpine 30, 29"; "Wrathtail Head 3/20"), this zone's first. Not focusable, no
  buttons; nothing of Blizzard's touched or hooked. 
- **Log**: an **Errands tab in the Companion window** (minus tap opens the window, as
  now), display only: each errand newest first with its note, where (itemSource),
  value (price), when added, and what will complete it; done ones below for a while.
- Both display only: no buttons, nothing secure, so both work in combat. No new
  bindings.
- **No ageing**: errands never fade or expire on their own (the player, 2026-11-10);
  one leaves when it completes or when the player has it deleted.

## Guardrails for providers
- Documented public APIs first (Polestar Nav.API, TomTom); internals only where an
  addon has none, and said so in its provider file.
- Each provider lists the functions it relies on; at login the engine checks they
  exist. A missing one disables that provider, shows in the Status tab and goes into
  the export, so an agent repairs it instead of the feature degrading silently.
- Providers only for addons the player runs; small capabilities, a method added only
  when a feature needs it.

## Pins: a capability (the player, 2026-11-10)
`pins`: `set(layer, points)`, `clear(layer)`; a point is { map, x, y, label }.
Providers, best first: Polestar (its pin layer, world map and minimap; internal,
no public API, so its provider self-checks at login and steps aside when the
functions are gone), then **builtin** (our Pins.lua, minimap only, moved behind the
capability). Another addon (HandyNotes, TomTom) is one more provider later.
Errands only ever call `WC.Use("pins")`.
