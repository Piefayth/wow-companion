# The API this project uses

Out of 10,957 names in `api-1.60.1.txt`, these are the ones that serve what the
companion does: configuration, out of combat, never play. Each has a status, and
the status is the point: **measured** means called on this client (1.60.1.70862)
and seen to work; **listed** means it exists and is documented, but we have not
called it, so treat it as a claim.

How the statuses were earned:

- `/wc alive` called every no-argument read in the namespaces below: 129 calls, no
  crash, none refused, none erroring. 64 returned values, 46 an honest
  false/zero, and the rest empty or nil for reasons that fit a level 21 druid (no
  equipment sets, no pet, no hero talents). `docs/` does not keep that raw list;
  rerun it if you need it.
- `/wc place` measured `PlaceAction` with an `issecurevariable` diff over ~265,000
  variables (see CLAUDE.md).
- Everything else came out of the earlier probes.

Never call outside this list blind. The first survey called every read in the
client, and one of them crashed `Wow.exe` (a null read in C, which `pcall` does not
catch).

## Action bars

The gamepad bars are slots **181–272**, not 1–120 (CLAUDE.md, "Where we are").

| Function | Status |
|---|---|
| `HasAction(slot)`, `GetActionInfo(slot)` | measured: the context export reads every slot. Undocumented legacy globals. |
| `PickupAction(slot)`, `PickupMacro(index)`, `ClearCursor()` | measured: no taint |
| `PlaceAction(slot)` | measured: taints nothing, into an undrawn slot (4), a drawn one (189), and as a move (181 → 13 and back, `PickupAction` then `PlaceAction`) |
| `C_ActionBar.PutActionInSlot(slot)` | measured: the documented twin of `PlaceAction`; taints nothing into a drawn slot (202) |
| `C_ActionBar.GetActionBarPage`, `GetBonusBarOffset`, `HasBonusActionBar` | measured: which page is live, e.g. after a shapeshift. Druid forms swap the bar. |
| `C_ActionBar.FindSpellActionButtons(spellID)` | listed: "where is Moonfire on my bars" without walking every slot |
| `C_Spell.PickupSpell(spell)`, `C_SpellBook.PickupSpellBookItem(i, bank)` | listed: how a spell gets onto the cursor for placing |

## Macros

| Function | Status |
|---|---|
| `CreateMacro`, `EditMacro`, `DeleteMacro`, `GetMacroInfo`, `GetMacroIndexByName`, `GetNumMacros` | measured: undocumented globals; the `macro` handler uses them |
| `C_Macro.GetMacroName`, `GetSelectedMacroIcon` | listed |
| `C_Macro.RunMacroText` | **do not use**: `HasRestrictions`, and running a macro for the player is acting for them |

## Spells, spec, talents

The modern API, not Classic: `GetSpellInfo`, `GetSpecialization`, `GetNumSpellTabs` and
`GetSpellBookItemInfo` do not exist here.

| Function | Status |
|---|---|
| `C_Spell.GetSpellInfo(id)` | measured: the export's name lookups |
| `C_SpellBook.GetNumSpellBookSkillLines`, `GetSpellBookSkillLineInfo`, `GetSpellBookItemInfo` | measured: the export's spellbook walk |
| `C_SpecializationInfo.GetSpecialization`, `GetActiveSpecGroup`, `CanPlayerUseTalentUI` | measured |
| `C_ClassTalents.GetActiveConfigID`, `CanEditTalents`, `CanChangeTalents` | measured: talents are the modern loadout system here |
| `C_Traits.*` (config/node reads) | listed: reading the talent tree needs the config ID above; untested |

## Bindings

| Function | Status |
|---|---|
| `GetNumBindings`, `GetBinding(i)` | measured: the export's bindings section |
| `SetOverrideBindingClick`, `ClearOverrideBindings` | measured: the offer button's temporary binding |
| `SetBinding`, `SaveBindings` | listed: permanent rebinding. Not yet tried; expect the same taint questions as `PlaceAction`. |
| `C_KeyBindings.GetTurnStrafeStyle` | measured |

## Settings

| Function | Status |
|---|---|
| `C_CVar.GetCVar`, `C_CVar.AreCVarsLoaded` | measured |
| `C_CVar.SetCVar` | listed: `RequiresNonSecureCVar`, `RequiresValidAndPublicCVar`. A `/console` line on an offered button is the safe route. |

## Equipment

| Function | Status |
|---|---|
| `C_EquipmentSet.CanUseEquipmentSets`, `GetNumEquipmentSets`, `GetEquipmentSetIDs` | measured (none saved yet) |
| `C_EquipmentSet.UseEquipmentSet` | listed. Prefer `/equipset Name` on an offered button: that is the player pressing it. |

## Chat

| Function | Status |
|---|---|
| `C_ChatInfo.GetNumActiveChannels`, `GetGeneralChannelID` | measured |
| `ChatFrame_OpenChat` | **do not use**: measured to taint 8 chat variables and break A/B |
| active edit box `:SetText` | measured: only on a box the player opened |

## Protected: offer a button instead

| Function | Status |
|---|---|
| `ReloadUI` | measured protected (`ADDON_ACTION_BLOCKED … Reload()`); `/reload` on a secure button works |
| `C_Macro.RunMacroText`, anything that casts, targets or moves | not ours to call, by rule |

## Minimap pins (measured working, 2026-11-09)

The agent can mark places on the minimap: a dot plus a shaded area, at map
coordinates from the conversation ("kill Outrunners at 72.5, 69.5"). Built into
`Companion.lua` (`WCPins`), kept in `WowCompanionDB.pins`, so pins survive reloads.

From a `lua` step:

```lua
WCPins.Set({ { map = 1440, x = 72.5, y = 69.5, r = 60, color = {1, 0.3, 0.2} } })
WCPins.Add({ map = 1440, x = 75.6, y = 70.3, r = 45 })   -- append one
WCPins.Clear()                                           -- remove all
```

`map` is a uiMapID (`C_Map.GetBestMapForUnit("player")` for the current zone),
`x`/`y` the 0-100 coordinates players quote, `r` the area radius in yards (0 for a
dot only), `color` optional (default gold).

How it draws (every 0.05 s, one frame child of `Minimap` at its level + 5):

- **World yards, not map positions.** `C_Map.GetPlayerMapPosition` errors on this
  client. `UnitPosition("player")` and `C_Map.GetWorldPosFromMapPos(map, vec)` both
  give (north, west); the difference times `Minimap:GetWidth()/2 /
  C_Minimap.GetViewRadius()` is the pixel offset (east = -(west difference)).
  Rotate by `GetPlayerFacing()` when the `rotateMinimap` CVar is 1.
- **Vector APIs need the mixins in the sandbox.** C functions that take or return a
  vector look up `Vector2DMixin` raw in the caller's environment; the sandbox
  rawsets the common mixins in (the error was "unable to find mixin or metatable").
- **Circles are `SetColorTexture` plus a `CircleMask` atlas mask.** Texture files
  (`TempPortraitAlphaMask`) drew nothing on the minimap.
- **A texture honours one mask here**, so the minimap's round edge never clipped
  the area: its radius is capped at `half - 2 - distance` instead. Off the map there
  is no area, only the dot clamped to the rim, pointing the way.

Not done yet: world map pins, labels, clearing a pin automatically on arrival.

## Looting in combat on the gamepad (measured 2026-11-10, Interact.lua)

- Blizzard sets the secure CVar `SoftTargetInteract` to 0 while in combat with an
  attackable target (TargetLogic.lua). Addon code cannot change it in combat, and
  `/console` cannot either, because it calls `forceinsecure()`.
- Targeting yourself (`/target player`) makes Blizzard turn it back on. The corpse
  became the soft interact target 0.1 s later.
- The gamepad's auto-retarget puts the enemy back about 1 s later, so the loot has
  to happen within one press.
- Blizzard's gamepad interact button (`GamepadMainActionBarFrame`, top bar
  `Right.ActionButton1`) can be pressed from a macro with `/click <name> LeftButton
  true|false`. It decides on release, or at 0.5 s held, and takes a lootable soft
  interact target first.
- So Home is one secure button. A wrap script picks the down or up macro.
  - Down: focus the enemy, target yourself, press Blizzard's button down.
  - Up: release it, then target the focus again.
  - The player measured it working.
