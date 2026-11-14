-- The wheel's slices, a settings row. The right stick reaches a wheel as four
-- direction keys (Wheel.lua), and the game turns a key on at about 0.5 along
-- its axis: a cardinal then gets 60 degrees and a diagonal 30, while the ring
-- draws eight 45-degree slices. "Equal" sets the keys' threshold on both
-- right-stick axes to sin 22.5 degrees (0.38), where four keys split the circle
-- into eight equal slices (on trial with the player, 2026-11-14).
--
-- The setting lives in the game's own pad profile for each pad the game reads
-- (C_GamePad.SetConfig, keyed by the pad's vendor and product id as the game
-- sees them, not Windows), so nothing of ours is saved: the row reads the
-- profile. Only the two thresholds are ours; a profile the player had is kept,
-- and "Game default" takes out only what we put in. Out of combat (the call
-- is restricted). The stick keys exist only while a wheel is open, so nothing
-- else in the game feels it.

local EQUAL = 0.38
local NAME = "WoW Companion wheel"
local AXES = {
	RStickX = { pos = "PADRSTICKRIGHT", neg = "PADRSTICKLEFT" },
	RStickY = { pos = "PADRSTICKUP", neg = "PADRSTICKDOWN" },
}

-- every pad the game reads (the combined device has no raw state), as config ids
local function pads()
	local ids = {}
	for _, device in ipairs(C_GamePad.GetAllDeviceIDs() or {}) do
		local raw = C_GamePad.GetDeviceRawState(device)
		if raw then ids[#ids + 1] = { vendorID = raw.vendorID, productID = raw.productID } end
	end
	return ids
end

local function equalOn(config)
	for _, axis in ipairs(config and config.axisConfigs or {}) do
		if AXES[axis.axis] and axis.buttonThreshold and math.abs(axis.buttonThreshold - EQUAL) < 0.005 then
			return true
		end
	end
	return false
end

local function current()
	for _, id in ipairs(pads()) do
		if equalOn(C_GamePad.GetConfig(id)) then return "Equal" end
	end
	return "Game default"
end

-- One pad's profile with our thresholds put in (equal) or taken out. An axis
-- entry we made carries only the threshold and its keys, and goes with it.
local function apply(id, equal)
	local config = C_GamePad.GetConfig(id) or { configID = id, name = NAME, rawButtonMappings = {},
		rawAxisMappings = {}, axisConfigs = {}, stickConfigs = {} }
	local seen, kept = {}, {}
	for _, axis in ipairs(config.axisConfigs) do
		local keys = AXES[axis.axis]
		if keys then
			seen[axis.axis] = true
			axis.buttonThreshold = equal and EQUAL or nil
			local ours = axis.buttonPos == keys.pos and axis.buttonNeg == keys.neg and not axis.shift
				and not axis.scale and not axis.deadzone
			if equal or not ours then kept[#kept + 1] = axis end
		else
			kept[#kept + 1] = axis
		end
	end
	if equal then
		for name, keys in pairs(AXES) do
			if not seen[name] then
				kept[#kept + 1] = { axis = name, buttonThreshold = EQUAL, buttonPos = keys.pos, buttonNeg = keys.neg }
			end
		end
	end
	config.axisConfigs = kept
	if not equal and config.name == NAME and #kept == 0 and #config.rawButtonMappings == 0
		and #config.rawAxisMappings == 0 and #config.stickConfigs == 0 then
		C_GamePad.DeleteConfig(id)
	else
		C_GamePad.SetConfig(config)
	end
end

local function set(name)
	if InCombatLockdown() then return WC.Say("Wheel slices: not in combat") end
	local ids = pads()
	if #ids == 0 then return WC.Say("Wheel slices: no controller found") end
	for _, id in ipairs(ids) do
		local ok, err = pcall(apply, id, name == "Equal")
		if not ok then return WC.Say("Wheel slices: the game refused (" .. tostring(err) .. ")") end
	end
	C_GamePad.ApplyConfigs()
end

WC.SettingsPage.Add({ kind = "dropdown", section = "Wheels", order = 40, label = "Wheel slices",
	text = "Equal: the right stick picks eight equal slices, as the wheel is drawn. "
		.. "Game default: straight directions take wider slices than diagonals. "
		.. "Kept in the game's profile for your controller; changes out of combat.",
	options = function() return { "Equal", "Game default" } end,
	get = current,
	set = set })
