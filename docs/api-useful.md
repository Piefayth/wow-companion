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
