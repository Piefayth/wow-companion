-- The focus log (the player's go, 2026-11-11): every step of the controller's
-- window focus, recorded the moment it happens, so a focus bug (the invisible
-- focus, bars left blocked, a window that cannot be reached) is in the export
-- instead of described afterwards.
--
-- Driven by events only (the player: "as long as your validation is not running
-- every single frame"): post-hooks on GamepadMode.FrameControlsManager's public
-- methods (hooksecurefunc keeps Blizzard's caller secure) and the fight's start
-- and end. Nothing of the manager's is set or called; its fields are only read.
-- Nothing is recorded while the gamepad UI is off.
--
-- WowCompanionDB.focusLog: the last 60 lines, oldest first. A line marked "!!"
-- caught an impossible state; WC.FocusLog.Problems() counts them this session.
-- Shown as one Status tab line and the export's "focus log" section, nowhere else.

local RING = 60
local problems, lastProblem = 0, nil
local wasFocused -- isUIFocused as the previous line saw it

local function nameOf(f)
	if not f then return "-" end
	local ok, n = pcall(f.GetName, f)
	if ok and n then return n end
	ok, n = pcall(f.GetDebugName, f)
	return ok and n or "?"
end
local function shown(f)
	if not f then return false end
	local ok, s = pcall(f.IsShown, f)
	return ok and s
end
local function ours(f)
	local n = nameOf(f)
	return n:find("^WowCompanion") or n:find("^WC")
end

local function record(method, frame, flag)
	if not (InputUtil and InputUtil.IsGamepadUIEnabled and InputUtil.IsGamepadUIEnabled()) then return end
	local m = GamepadMode and GamepadMode.FrameControlsManager
	if not m or not WowCompanionDB then return end
	local combat = InCombatLockdown()
	local focused, uiFocused = m.focusedFrame, m.isUIFocused
	local list, focusedShownOnList = {}, false
	for i, f in ipairs(m.shownFrames or {}) do
		list[i] = nameOf(f) .. (shown(f) and "" or "(hidden)")
		if f == focused and shown(f) then focusedShownOnList = true end
	end

	-- the impossible states
	local why
	if uiFocused and not shown(focused) then
		why = "UI focused on a hidden or no frame"
	elseif m.fallThroughCatcherActive and not focusedShownOnList and not (GamepadMode.PopupHandler
		and GamepadMode.PopupHandler.visiblePopups and #GamepadMode.PopupHandler.visiblePopups > 0) then
		why = "bars blocked with no shown frame focused"
	elseif combat and focused and ours(focused) and not shown(focused) then
		why = "in combat, a hidden window of ours holds focus"
	elseif method == "FrameShown" and flag == false and uiFocused and not wasFocused then
		why = "a FrameShown that asked not to focus focused the UI"
	end
	wasFocused = uiFocused

	local log = WowCompanionDB.focusLog or {}
	WowCompanionDB.focusLog = log
	log[#log + 1] = ("%s%s %s %s %s | focus %s%s ui=%s catcher=%s | %s"):format(
		why and "!! " or "", date("%H:%M:%S"), combat and "C" or "-", method, nameOf(frame),
		nameOf(focused), shown(focused) and "" or "(hidden)", tostring(uiFocused and true or false),
		m.fallThroughCatcherActive and "on" or "off", table.concat(list, ","))
	if why then
		log[#log] = log[#log] .. " | " .. why
		problems = problems + 1
		lastProblem = date("%H:%M") .. " " .. why
	end
	while #log > RING do table.remove(log, 1) end
end

-- FrameShown(frame, isPopup, shouldFocusFrame); FrameHidden(frame); the rest
-- take a frame or nothing (Blizzard_GamepadSharedUtility/FrameControlsManager.lua)
local HOOKS = { "FrameShown", "FrameHidden", "SetUIFocusState", "FocusNextFrame",
	"FocusPreviousFrame", "FocusFrame", "HandlePopupShown", "HandlePopupHide" }

local hooked = false
local function hookAll()
	if hooked then return end
	local m = GamepadMode and GamepadMode.FrameControlsManager
	if not m then return end
	hooked = true
	for _, method in ipairs(HOOKS) do
		if type(m[method]) == "function" then
			hooksecurefunc(m, method, function(_, a, b, c)
				local frame, flag = a, nil
				if method == "FrameShown" then flag = c end
				if method == "SetUIFocusState" then frame, flag = nil, a end
				pcall(record, method, frame, flag)
			end)
		end
	end
end

local events = CreateFrame("Frame")
pcall(hookAll) -- the manager is Blizzard's and loads before us; login retries if not
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" then
		pcall(hookAll)
		return
	end
	pcall(record, event == "PLAYER_REGEN_DISABLED" and "fight starts" or "fight ends")
end)

WC.FocusLog = {
	-- this session's "!!" count, and the last one ("21:14 why")
	Problems = function() return problems, lastProblem end,
}
