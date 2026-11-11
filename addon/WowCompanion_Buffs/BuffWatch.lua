-- Buffs to watch for (class-neutral): a per-character list, empty
-- until the player asks ("remind me when X is missing"). Read by the export
-- ("buffs missing at export") and by the BuffGlow module. Kept in
-- WowCompanionBuffsDB (per character), so another character, class or player
-- starts with none.
--   WowCompanion_WatchBuffs({ "Spell", ... })   set the list ({} clears it)
--   WC.BuffWatch.List()      the names
--   WC.BuffWatch.Missing()   those the character knows and is not wearing
--   WC.BuffWatch.Button()    an on-screen gamepad bar button that casts one, or
--                            opens a wheel (WCWheel) holding one; nil if none

WC.BuffWatch = WC.BuffWatch or {}
WC.Saved("WowCompanion_Buffs", "WowCompanionBuffsDB")
local B = WC.BuffWatch

local function db()
	WowCompanionBuffsDB = WowCompanionBuffsDB or {}
	WowCompanionBuffsDB.spells = WowCompanionBuffsDB.spells or {}
	return WowCompanionBuffsDB
end

function B.List() return db().spells end

function B.Missing()
	local out = {}
	for _, name in ipairs(B.List()) do
		local info = C_Spell.GetSpellInfo(name)
		local known = info and info.spellID and IsPlayerSpell(info.spellID)
		if known and not C_UnitAuras.GetAuraDataBySpellName("player", name, "HELPFUL") then
			out[#out + 1] = name
		end
	end
	return out
end

-- a slot that casts a watched spell, or a macro opening a wheel that holds one
local function slotFor(watched)
	local wheels = WowCompanionWheelDB and WowCompanionWheelDB.wheels or {}
	for slot = 181, 272 do
		local kind, id = GetActionInfo(slot)
		if kind == "spell" and id then
			local info = C_Spell.GetSpellInfo(id)
			if info and watched[info.name] then return slot end
		elseif kind == "macro" and id then
			local body = select(3, GetMacroInfo(id)) or ""
			local key = body:match("/click%s+WCWheel_([%w_]+)")
			for _, s in ipairs(key and wheels[key] and wheels[key].slots or {}) do
				if s.spell and watched[s.spell] then return slot end
			end
		end
	end
end

local BARS = { "Bottom", "Left", "Right", "Top" }
function B.Button()
	local watched = {}
	for _, name in ipairs(B.List()) do watched[name] = true end
	if not next(watched) then return end
	local slot = slotFor(watched)
	if not slot then return end
	for _, bar in ipairs(BARS) do
		local base = "GamepadMainActionBarFramePageUnitBottomCenteredAnchor" .. bar .. "BarActionButton"
		for i = 1, 8 do
			local b = _G[base .. i]
			if b and b:IsVisible() and (b.action == slot or (b.GetAttribute and tonumber(b:GetAttribute("action")) == slot)) then
				return b
			end
		end
	end
end

function WowCompanion_WatchBuffs(list)
	local spells = {}
	for _, name in ipairs(type(list) == "table" and list or {}) do
		if type(name) == "string" and name ~= "" then spells[#spells + 1] = name end
	end
	db().spells = spells
	if WC.Send then WC.Send("BUFF_WATCH_CHANGED") end
	print(#spells > 0 and ("watching for: " .. table.concat(spells, ", ")) or "watching for no buffs")
end
