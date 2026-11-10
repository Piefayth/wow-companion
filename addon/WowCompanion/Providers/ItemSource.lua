-- The itemSource capability (see Engine.lua, Capabilities): where an item comes
-- from.
--   sources(itemID) -> { { type, ... }, ... } | nil
--       type "vendor" (npc, cost, limited), "drop" (npc, chance, instance),
--       "object" (object, chance), "quest" (quest, choice), "gift" (npc, spell),
--       "craft" (spell, skillLine, skill), "rep" (faction, standing, npc),
--       "pvp" (rank, npc), "container" (item, chance), "world" (minLevel, maxLevel);
--       chance in percent; npc, object and quest are IDs
--   npcName(npcID) -> name | nil ; questName(questID) -> title | nil

-- Polestar's Codex (Polestar/Lookup/Codex.lua; GPL: called, never copied). Its
-- data is a load-on-demand addon that Polestar never loads in combat, so an
-- unloaded Codex answers nothing in a fight.
local function codex()
	local C = Polestar and Polestar.Codex
	if type(C) ~= "table" then return nil end
	if C.IsLoaded and not C.IsLoaded() then
		if InCombatLockdown() or not C.Load then return nil end
		local ok, loaded = pcall(C.Load)
		if not (ok and loaded) then return nil end
	end
	return C
end
WC.Provide("itemSource", "Polestar", {
	sources = function(id)
		local C = codex()
		if not (C and C.Item) then return nil end
		local ok, rec = pcall(C.Item, id)
		if ok and type(rec) == "table" and type(rec.sources) == "table" then return rec.sources end
	end,
	npcName = function(id)
		local C = codex()
		if not (C and C.Name) then return nil end
		local ok, name = pcall(C.Name, "npc", id)
		if ok then return name end
	end,
	questName = function(id)
		local C = codex()
		if not (C and C.Name) then return nil end
		local ok, name = pcall(C.Name, "quest", id)
		if ok then return name end
	end,
}, { addon = "Polestar", rank = 10 })
