-- The in-game half. The helper writes Lua into load-on-demand slot addons and
-- "rings" a bell sound file; we hear the bell and load the next slot.
-- Right now it only probes whether that channel, and the APIs we need, work.
-- Probe results land in WowCompanionDB.probe once you /reload.

local ADDON = "WowCompanion"
local BELLS = 8
local SIGNALS = "Interface\\AddOns\\WowCompanion\\Signals\\"

-- how much conversation to keep; it rides in SavedVariables, so not unbounded
local LOG_KEEP = 300

local nextSlot = 1
local blocked = 0
local ticker
local logWindow

local function say(message)
	print("|cff66ccffCompanion|r " .. message)
end

local function record(key, value)
	-- storing nil would delete the key rather than save it, quietly losing the
	-- result instead of reporting that we got nothing
	WowCompanionDB.probe[key] = value == nil and "nil" or value
	say(key .. ": " .. tostring(value))
end

local function slotName(n)
	return ("%s_S%03d"):format(ADDON, n)
end

local function bellPath(n)
	return SIGNALS .. ((n - 1) % BELLS + 1) .. ".wav"
end

-- PlaySoundFile claims every file will play, even empty ones, so only IsPlaying counts
local function listen(path, heard)
	local _, handle = PlaySoundFile(path, "Master")
	C_Timer.After(0.15, function()
		local playing = handle ~= nil and C_Sound.IsPlaying(handle)
		if handle then
			StopSound(handle)
		end
		heard(playing)
	end)
end

local function activeEditBox()
	local get = ChatEdit_GetActiveWindow or (ChatFrameUtil and ChatFrameUtil.GetActiveWindow)
	return get and get()
end

-- The conversation window. Chat lines scroll away and cannot be scrolled back
-- through, so replies live in their own frame and in SavedVariables, which is what
-- makes history survive a /reload.
--
-- Deliberately not registered in UISpecialFrames: Escape handling is where the
-- gamepad taint lives, and this frame has a close button instead.
local function buildLog()
	-- CreateFrame throws on a template this build does not have, and an unreadable
	-- window is better than an addon that fails to load
	local made, frame = pcall(CreateFrame, "Frame", "WowCompanionLog", UIParent, "BackdropTemplate")
	if not made or not frame then
		frame = CreateFrame("Frame", "WowCompanionLog", UIParent)
	end
	frame:SetSize(560, 340)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:Hide()
	if frame.SetBackdrop then
		frame:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			edgeSize = 24,
			insets = { left = 6, right = 6, top = 6, bottom = 6 },
		})
	end
	frame:SetMovable(true)
	frame:SetResizable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 16, -14)
	title:SetText("Companion")

	local closed, close = pcall(CreateFrame, "Button", nil, frame, "UIPanelCloseButton")
	if closed and close then
		close:SetPoint("TOPRIGHT", -6, -6)
		close:SetScript("OnClick", function()
			frame:Hide()
		end)
	end

	local messages = CreateFrame("ScrollingMessageFrame", nil, frame)
	messages:SetPoint("TOPLEFT", 18, -40)
	messages:SetPoint("BOTTOMRIGHT", -18, 16)
	messages:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
	messages:SetJustifyH("LEFT")
	messages:SetFading(false)
	messages:SetMaxLines(LOG_KEEP)
	messages:SetHyperlinksEnabled(true)
	messages:EnableMouseWheel(true)
	messages:SetScript("OnMouseWheel", function(self, delta)
		if IsShiftKeyDown() then
			if delta > 0 then self:ScrollToTop() else self:ScrollToBottom() end
		elseif delta > 0 then
			self:ScrollUp()
		else
			self:ScrollDown()
		end
	end)
	frame.messages = messages
	return frame
end

local function logFrame()
	logWindow = logWindow or buildLog()
	return logWindow
end

local function colouredFor(who)
	if who == "you" then
		return "|cff9ad5ff"
	elseif who == "error" then
		return "|cffff7777"
	end
	return "|cffffe08a"
end

local function showLine(who, text)
	logFrame().messages:AddMessage(("%s%s|r  %s"):format(colouredFor(who), who, text))
end

-- Kept in SavedVariables, so it is written on /reload or logout like everything else.
local function remember(who, text)
	WowCompanionDB.log = WowCompanionDB.log or {}
	local entries = WowCompanionDB.log
	entries[#entries + 1] = { at = time(), who = who, text = text }
	while #entries > LOG_KEEP do
		table.remove(entries, 1)
	end
	showLine(who, text)
end

local function replayLog()
	for _, entry in ipairs(WowCompanionDB.log or {}) do
		showLine(entry.who or "claude", entry.text or "")
	end
end

-- What the helper is allowed to ask for. A dispatch table rather than loadstring on
-- whatever arrives: the rule is configuration only, and this is where that rule lives.
local handlers = {}

-- Writes into a chat box the player already opened, and never opens one itself.
-- That distinction is the whole point: when we called ChatFrame_OpenChat, the
-- gamepad focus restore on close came back blocked and the A and B buttons died.
-- A box the player opened was activated by real hardware input, so the secure path
-- stays intact and we only set text on it. Refuses rather than opening one, because
-- opening one is the thing that broke the controller.
function handlers.chat(inbox)
	local box = activeEditBox()
	if not box or not box:IsVisible() then
		say("no chat box open, so nothing was written -- open chat first, then speak")
		return "refused: no chat box open"
	end
	-- append, so speaking twice builds a line instead of replacing it
	box:SetText((box:GetText() or "") .. (inbox.text or ""))
	remember("you", inbox.text or "")
	return ("chat box holds %q"):format(box:GetText())
end

-- A line for the conversation window. Opens it out of combat so a reply is not
-- missed, but never steals the screen mid-fight.
function handlers.log(inbox)
	local text = inbox.text or ""
	local who = inbox.who or "claude"
	local lines = 0
	-- a reply arrives as one message but reads as many lines, and AddMessage takes
	-- one line at a time; blank lines are kept because they carry the paragraphs
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		remember(who, line)
		lines = lines + 1
	end
	if lines == 0 then
		remember(who, text)
	end
	if not InCombatLockdown() and not logWindow:IsShown() then
		logWindow:Show()
	end
	return ("logged %d line(s)"):format(lines)
end

function handlers.macro(inbox)
	if InCombatLockdown() then
		return "refused: in combat"
	end
	if not inbox.name then
		return "refused: no macro name"
	end
	local index = GetMacroIndexByName(inbox.name)
	if index and index > 0 then
		EditMacro(index, inbox.name, inbox.icon, inbox.body)
		return ("edited macro %s at %d"):format(inbox.name, index)
	end
	index = CreateMacro(inbox.name, inbox.icon or "INV_MISC_QUESTIONMARK", inbox.body, false)
	-- deliberately not placed on a bar: PlaceAction taints the UI, so bar edits are
	-- their own operation followed by a reload
	return index and ("created macro %s at %d"):format(inbox.name, index) or "CreateMacro failed"
end

-- clears taint, flushes SavedVariables and resets the slot cursor, all at once
function handlers.reload()
	C_Timer.After(0.1, ReloadUI)
	return "reloading"
end

function handlers.probe(inbox)
	WowCompanionDB.probe.received = (WowCompanionDB.probe.received or 0) + 1
	return ("message %d, %ds after the helper wrote it"):format(inbox.n, time() - inbox.sent)
end

local function receive()
	local slot = nextSlot
	nextSlot = nextSlot + 1
	local loaded, reason = C_AddOns.LoadAddOn(slotName(slot))
	local inbox = WowCompanion_Inbox
	WowCompanion_Inbox = nil
	if not loaded or not inbox then
		record("slot " .. slot, "failed: " .. tostring(reason))
		return
	end
	local handler = handlers[inbox.kind or ""]
	if not handler then
		record("slot " .. slot, "unknown kind: " .. tostring(inbox.kind))
		return
	end
	local ok, result = pcall(handler, inbox)
	record("slot " .. slot, ok and tostring(result) or ("error: " .. tostring(result)))
end

local function poll()
	listen(bellPath(nextSlot), function(rang)
		if rang then
			receive()
		end
	end)
end

local function cvar(name)
	local get = C_CVar and C_CVar.GetCVar or GetCVar
	return get and get(name) or "?"
end

-- controls: a long silent file should play, an empty one shouldn't.
-- an unfocused game mutes everything, so both come back false if you alt-tabbed away;
-- the cvars tell that case apart from a bell that genuinely didn't play
local function probeSound()
	record("sound enabled", cvar("Sound_EnableAllSound"))
	record("background sound", cvar("Sound_EnableSoundWhenGameIsInBG"))
	record("master volume", cvar("Sound_MasterVolume"))
	listen(SIGNALS .. "always.wav", function(playing)
		record("always.wav plays (want true)", playing)
	end)
	listen(SIGNALS .. "never.wav", function(playing)
		record("never.wav plays (want false)", playing)
	end)
end

local function probeChat()
	local open = ChatFrame_OpenChat or (ChatFrameUtil and ChatFrameUtil.OpenChat)
	record("chat opener", ChatFrame_OpenChat and "ChatFrame_OpenChat" or open and "ChatFrameUtil.OpenChat" or "none")
	if not open then
		return
	end
	-- the Enter that submits /wc chat closes the edit box once the command returns,
	-- so opening it from here only sticks if we let that finish first
	C_Timer.After(0.1, function()
		open("hello from the companion")
		C_Timer.After(0.1, function()
			local box = activeEditBox()
			record("chat box", box and box:IsVisible() and ("open, holds %q"):format(box:GetText()) or "not open")
		end)
	end)
end

local function probeMacro()
	if InCombatLockdown() then
		say("leave combat first")
		return
	end
	local created, index = pcall(CreateMacro, "WCPROBE", "INV_MISC_QUESTIONMARK", "/say created", false)
	record("CreateMacro", index)
	if not created or not index then
		return
	end
	local edited, err = pcall(EditMacro, index, nil, nil, "/say edited")
	record("EditMacro", edited and GetMacroBody(index) or err)
	local empty
	for action = 1, 120 do
		if not HasAction(action) then
			empty = action
			break
		end
	end
	if empty then
		PickupMacro(index)
		local placed, placeErr = pcall(PlaceAction, empty)
		ClearCursor()
		local kind = GetActionInfo(empty)
		record("PlaceAction", placed and ("action %d now holds %s"):format(empty, tostring(kind)) or placeErr)
		if kind == "macro" then
			PickupAction(empty)
			ClearCursor()
		end
	else
		record("PlaceAction", "no empty action slot to test with")
	end
	DeleteMacro(index)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("ADDON_ACTION_BLOCKED")
frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
frame:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" and ... == ADDON then
		WowCompanionDB = WowCompanionDB or {}
		-- the game saves before it reloads, so hold on to the session we just read
		-- from disk or a second /reload discards the run we were trying to measure
		WowCompanionDB.previous = WowCompanionDB.probe
		WowCompanionDB.probe = {}
	elseif event == "PLAYER_LOGIN" then
		local version, build, _, toc = GetBuildInfo()
		record("client", ("%s.%s, toc %d"):format(version, build, toc))
		-- build the window and refill it before anything can write to it
		logFrame()
		replayLog()
		probeSound()
		ticker = C_Timer.NewTicker(0.5, poll)
	elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
		-- taint cascades, and the first block names the real culprit, so number them
		-- rather than letting each one overwrite the last
		local addon, func = ...
		blocked = blocked + 1
		record(("%s %d"):format(event, blocked), ("%s called %s"):format(tostring(addon), tostring(func)))
	end
end)

SLASH_WOWCOMPANION1 = "/wc"
SlashCmdList.WOWCOMPANION = function(command)
	if command == "chat" then
		probeChat()
	elseif command == "macro" then
		probeMacro()
	elseif command == "sound" then
		probeSound()
	-- the bell poll is the only thing this addon does continuously, so silencing it
	-- is how we find out whether it is what taints the gamepad interact target
	elseif command == "quiet" then
		if ticker then
			ticker:Cancel()
			ticker = nil
		end
		say("bell poll stopped; nothing from the helper will arrive until /wc listen")
	elseif command == "listen" then
		if not ticker then
			ticker = C_Timer.NewTicker(0.5, poll)
		end
		say("bell poll running")
	elseif command == "log" then
		local frame = logFrame()
		if frame:IsShown() then
			frame:Hide()
		else
			frame:Show()
		end
	else
		say("/wc log, /wc chat, /wc macro, /wc sound, /wc quiet, /wc listen")
	end
end
