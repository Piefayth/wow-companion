-- The gear capability (see Engine.lua, Capabilities): upgrade picks for this
-- character, ranked by a gear addon.
--   slots() -> { slotName, ... }   the slots it has picks for, for this class
--   upgrades(slotName, n) -> { { itemID, source, zone, npc, quest }, ... } | nil
--       source: "quest_reward" | "vendor" | "boss_drop" | "world_drop" | "profession"
-- A pick is item data alone: check it against what is equipped (a two-hand
-- weapon leaves no off hand) before advising.

-- GearQuest Forever (GearQuestForever/Data.lua). Counts only while it is loaded.
local function data()
	local GQ = GearQuest
	local D = type(GQ) == "table" and GQ.Data
	return type(D) == "table" and D or nil
end
WC.Provide("gear", "GearQuestForever", {
	slots = function()
		local D = data()
		if not (D and D.GetSlotsForClass) then return nil end
		local _, classFile = UnitClass("player")
		local ok, slots = pcall(D.GetSlotsForClass, D, classFile)
		if ok and type(slots) == "table" then return slots end
	end,
	upgrades = function(slotName, n)
		local D = data()
		if not (D and D.GetTopUpgradesForSlot) then return nil end
		local ok, list = pcall(D.GetTopUpgradesForSlot, D, slotName, n or 3)
		if not (ok and type(list) == "table") then return nil end
		local out = {}
		for _, e in ipairs(list) do
			if type(e) == "table" and e.itemId then
				out[#out + 1] = { itemID = e.itemId, source = e.sourceType, zone = e.zone,
					npc = e.npc, quest = e.questName }
			end
		end
		return out
	end,
}, { addon = "GearQuestForever", rank = 10 })
