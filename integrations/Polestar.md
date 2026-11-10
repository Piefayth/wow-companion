# Polestar

GPL: call it, never copy its code. Map, arrow, a full Forever database.

Polestar has the map, the arrow and a full NPC
database; use its arrow, never build a second one:
- `Polestar.Nav.nearby.Go(kind)`: aims the arrow at the nearest service by travel time
  and prints it; `.Find(kind)` returns place, seconds without aiming. Kinds: innkeeper,
  repair, vendor, food, reagents, trainer (+ profession), class, weapon, bank, mailbox,
  auction, flight, stable. `.EndTrip()` sends the arrow back to the guide.
- `Polestar.Nav.SetTarget(map, x, y, label)`: aims the arrow anywhere;
  `Polestar.Nav.ClearTarget()`. Source: AddOns/Polestar/Nav/Nearby.lua, Nav.lua.
- `Polestar.Codex` is a full Forever database: `.Item(id)` gives sources (vendor
  with cost, drop with npc and chance, quest, craft, rep standing), `.Npc(id)`,
  `.Quest(id)`, `.Loot(kind, id)`, `.Each(kind, fn)`; call `.Load()` first. Use it
  for where an item comes from, what it costs, drop odds. Source: Polestar/Lookup/Codex.lua.
- Polestar already does talents, trainer reminders, XP pace, vendoring greys and
  flight help (Polestar/QoL, Polestar/Talents): use it, never rebuild those.

Guidance for a quest Polestar has no guide for: aim its arrow
  (`Polestar.Nav.SetTarget`) and pin the spots (`WCPins`), with places from
  `Polestar.Codex` (`.Quest(id)`, `.Npc(id)`). Polestar also takes guides as data
  (`Polestar.Import`, its import strings), a route not built yet.
