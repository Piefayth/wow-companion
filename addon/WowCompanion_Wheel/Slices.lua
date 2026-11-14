-- The wheel's slices, a settings row. The right stick reaches a wheel as four
-- direction keys (Wheel.lua), and the game turns a key on at about 0.5 along
-- its axis: a cardinal then gets 60 degrees and a diagonal 30, while the ring
-- draws eight 45-degree slices. "Equal" sets the keys' threshold on both
-- right-stick axes to sin 22.5 degrees (0.38), where four keys split the circle
-- into eight equal slices (on trial with the player, 2026-11-14).
--
-- The thresholds go in the game's own pad profile for each pad the game reads
-- (C_GamePad.SetConfig, keyed by the pad's vendor and product id as the game
-- sees them, not Windows). The game did not keep it over a /reload (the
-- player, 2026-11-14), so the choice is ours, saved account-wide, and put back
-- at login and when a pad connects. Only the two thresholds are ours; a profile
-- the player had is kept, and "Game default" takes out only what we put in.
-- Out of combat (the call is restricted). The stick keys exist only while a
-- wheel is open, so nothing else in the game feels it.

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

local function saved() return WC.Settings("WheelSlices", { equal = false }) end

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

local function applyAll(equal)
	for _, id in ipairs(pads()) do
		local ok, err = pcall(apply, id, equal)
		if not ok then return WC.Say("Wheel slices: the game refused (" .. tostring(err) .. ")") end
	end
	C_GamePad.ApplyConfigs()
end

local function set(name)
	if InCombatLockdown() then return WC.Say("Wheel slices: not in combat") end
	saved().equal = name == "Equal"
	applyAll(saved().equal)
end

local function restore()
	if saved().equal then WC.AfterCombat(function() applyAll(true) end) end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("GAME_PAD_CONNECTED")
events:SetScript("OnEvent", restore)

WC.SettingsPage.Add({ kind = "dropdown", section = "Wheels", order = 40, label = "Wheel slices",
	text = "Equal: the right stick picks eight equal slices, as the wheel is drawn. "
		.. "Game default: straight directions take wider slices than diagonals. "
		.. "Kept in the game's profile for your controller; changes out of combat.",
	options = function() return { "Equal", "Game default" } end,
	get = function() return saved().equal and "Equal" or "Game default" end,
	set = set })
