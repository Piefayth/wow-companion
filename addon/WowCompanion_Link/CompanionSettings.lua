-- WowCompanion_Link: the companion's settings on our settings page. The
-- companion is their one truth (docs/proposals/settings-in-game.md): the rows
-- show what its last `status` says it runs with (WC.Link.Settings()) and change
-- them with commands on the strip (WowCompanion_Strip.Command, the Protocol
-- there). Nothing is kept here: a row shows "applying" until a status carries
-- the value it asked for, and the companion's answer (an error) in its note.
--
-- Buttons are set by pressing, as in any game's key settings: confirming a row
-- draws `bind <key> start`; once the companion's status says it is collecting
-- (`binding`), the row says so and takes the press. The talk button is one
-- button; a conversation's is a chord, every button that goes down from the first
-- press until all are let go. The row draws `bind <key> <NAMES>` (WoW names
-- joined with +); the companion takes the buttons that went down between the
-- two, so both sides learn it from the same press, and refuses a chord another
-- key has or one holding the talk button.

local SECTION = "Companion"
local BIND_SECONDS = 30
-- the game keeps these to itself: Focus UI and the game menu
local REFUSED = { PADBACK = true, PADFORWARD = true }

local function command(words)
	if WowCompanion_Strip and WowCompanion_Strip.Command then WowCompanion_Strip.Command(words) end
end
local function settings() return WC.Link.Settings() end
local function refresh() if WC.SettingsPage.Refresh then WC.SettingsPage.Refresh() end end

-- what each row asked for and has not seen yet, and the companion's last word
local pending, errors = {}, {}

-- ── buttons ────────────────────────────────────────────────────────────────
local bindKey, waiting -- the row binding now; true once the companion collects
-- the chord being pressed: every button down since the first, in order, and how
-- many are still held
local pressed, holding = {}, 0
local capture = _G["WCBindCapture"] or CreateFrame("Frame", "WCBindCapture", UIParent)
capture:Hide()
local function stopCapture()
	capture:Hide()
	capture:EnableGamePadButton(false)
	capture:SetScript("OnUpdate", nil)
	pressed, holding = {}, 0
end
local function cancelBind()
	if not bindKey then return end
	command(("bind %s cancel"):format(bindKey))
	bindKey, waiting = nil, nil
	stopCapture()
	refresh()
end
local function finish()
	local key, names = bindKey, table.concat(pressed, "+")
	command(("bind %s %s"):format(key, names))
	pending[key], errors[key] = names, nil
	bindKey, waiting = nil, nil
	stopCapture()
	refresh()
end
capture:SetScript("OnGamePadButtonDown", function(_, name)
	if not (bindKey and waiting) then return end
	if REFUSED[name] then
		errors[bindKey] = ("%s is the game's own; press another."):format(name)
		pressed, holding = {}, 0
		refresh()
		return
	end
	pressed[#pressed + 1] = name
	holding = holding + 1
	-- the talk button is one button: the first press is it
	if bindKey == "talk" then finish() end
end)
capture:SetScript("OnGamePadButtonUp", function()
	if not (bindKey and waiting) or holding == 0 then return end
	holding = holding - 1
	if holding == 0 then finish() end
end)

local function startBind(key)
	if InCombatLockdown() then
		errors[key] = "Set buttons out of combat."
		refresh()
		return
	end
	if bindKey then cancelBind() end
	bindKey, waiting, errors[key] = key, nil, nil
	command(("bind %s start"):format(key))
	-- the companion collects for 30 s; the row gives up with it
	local started = GetTime()
	capture:SetScript("OnUpdate", function()
		if GetTime() - started > BIND_SECONDS then cancelBind() end
	end)
	capture:Show()
	refresh()
end

local function buttonText(key)
	return function()
		if bindKey == key then
			if not waiting then return "Waiting..." end
			return key == "talk" and "Press a button" or "Hold the buttons, then let go"
		end
		local now = settings()
		if not now then return "Not reported" end
		if pending[key] and now[key] ~= pending[key] then return "Applying..." end
		if not now[key] then return "Not set" end
		-- a chord: each button's glyph, joined
		local glyphs = {}
		for name in now[key]:gmatch("[^+]+") do glyphs[#glyphs + 1] = WowCompanion_Glyph(name) end
		return table.concat(glyphs, " + ")
	end
end
local function note(key, what)
	return function()
		local now = settings()
		if errors[key] then return errors[key] end
		if not now then return what .. " The companion has not reported its settings yet." end
		return what
	end
end

local BUTTON_ROWS = {
	{ "talk", "Talk button", "Hold to talk to the conversation the buttons held pick; tap to open the Companion window. Press the row, then the button." },
	{ "l1", "L1 conversation", "Held with the talk button, talks to L1. Press the row, then hold the buttons and let go." },
	{ "l2", "L2 conversation", "Held with the talk button, talks to L2." },
	{ "r1", "R1 conversation", "Held with the talk button, talks to R1." },
	{ "r2", "R2 conversation", "Held with the talk button, talks to R2." },
	{ "quick", "Quick conversation", "Held with the talk button, asks Quick: fast, for chat, links and buttons." },
	{ "say", "Dictation", "Held with the talk button, what you say goes into chat as you said it." },
}
for i, def in ipairs(BUTTON_ROWS) do
	local key, label, what = def[1], def[2], def[3]
	WC.SettingsPage.Add({
		kind = "key", section = SECTION, order = 100 + i, label = label,
		text = note(key, what),
		button = buttonText(key),
		onClick = function() if bindKey == key then cancelBind() else startBind(key) end end,
	})
end

-- ── values ─────────────────────────────────────────────────────────────────
local function current(key)
	local now = settings()
	if not now then return nil end
	if pending[key] and now[key] ~= pending[key] then return pending[key] end
	return now[key]
end
local function valueRow(key, order, label, what, options)
	WC.SettingsPage.Add({
		kind = "dropdown", section = SECTION, order = order, label = label,
		text = function()
			local now = settings()
			if errors[key] then return errors[key] end
			if not now then return what .. " The companion has not reported its settings yet." end
			if pending[key] and now[key] ~= pending[key] then return what .. " Applying: the companion restarts with it." end
			return what
		end,
		options = options,
		get = function() return current(key) end,
		set = function(value)
			-- against what was last asked for, not what runs: the companion may not
			-- have restarted onto the last choice yet, and going back must still ask
			if not settings() or value == current(key) then return end
			pending[key], errors[key] = value, nil
			command(("set %s %s"):format(key, value))
			refresh()
		end,
	})
end
valueRow("feedback", 110, "Talk feedback", "What you feel or hear when the companion starts and stops listening.",
	function() return { "rumble", "beep", "both" } end)
valueRow("speech", 111, "Speech engine", "Whisper is more accurate; streaming is much faster.",
	function()
		local now = settings()
		return now and type(now.engines) == "table" and now.engines or {}
	end)
-- the inputs Windows lists now, which every status carries (re-sent when they change)
valueRow("mic", 112, "Microphone", "The input the companion listens on.",
	function()
		local list = {}
		local now = settings()
		for _, name in ipairs(now and type(now.mics) == "table" and now.mics or {}) do list[#list + 1] = name end
		local chosen = current("mic")
		if #list == 0 and chosen then list[1] = chosen end
		return list
	end)

-- ── the companion's answers ────────────────────────────────────────────────
local bus = WC.Module("CompanionSettings")
bus:On("COMPANION_STATUS", function(inbox)
	local now = type(inbox.settings) == "table" and inbox.settings or {}
	for key, value in pairs(pending) do
		if now[key] == value then pending[key] = nil end
	end
	-- collecting: the press can be taken now
	if bindKey and inbox.binding == bindKey then
		waiting = true
		capture:EnableGamePadButton(true)
	end
	for _, field in ipairs({ "bind", "set" }) do
		local answer = inbox[field]
		if type(answer) == "table" and answer.key then
			errors[answer.key] = tostring(answer.error or "The companion refused it.")
			pending[answer.key] = nil
		end
	end
	refresh()
end)

