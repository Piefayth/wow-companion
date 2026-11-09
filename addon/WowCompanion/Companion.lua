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
local pendingTicker
local actionButton
-- which pad key the offer button binds to; set with /wc key <PADNAME>
local offerKey

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
	-- the game's own dialog art, so it sits in the UI rather than on top of it.
	-- CreateFrame throws on a template this build lacks, and an ugly window beats
	-- an addon that fails to load.
	local made, frame = pcall(CreateFrame, "Frame", "WowCompanionLog", UIParent, "BackdropTemplate")
	if not made or not frame then
		frame = CreateFrame("Frame", "WowCompanionLog", UIParent)
	end
	frame:SetSize(560, 340)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)
	frame:Hide()
	if frame.SetBackdrop then
		frame:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			edgeSize = 32,
			insets = { left = 11, right = 12, top = 12, bottom = 11 },
		})
	end

	-- the header strip is the drag handle, so a drag inside the transcript is free
	-- to select text instead of hauling the window around
	local header = CreateFrame("Frame", nil, frame)
	header:SetPoint("TOPLEFT", 12, -12)
	header:SetPoint("TOPRIGHT", -12, -12)
	header:SetHeight(26)
	header:EnableMouse(true)
	header:RegisterForDrag("LeftButton")
	frame:SetMovable(true)
	header:SetScript("OnDragStart", function() frame:StartMoving() end)
	header:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)

	local crest = header:CreateTexture(nil, "ARTWORK")
	crest:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
	crest:SetPoint("TOP", frame, "TOP", 0, 12)
	crest:SetSize(230, 64)
	local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOP", crest, "TOP", 0, -14)
	title:SetText("Companion")

	local closed, close = pcall(CreateFrame, "Button", nil, frame, "UIPanelCloseButton")
	if closed and close then
		close:SetPoint("TOPRIGHT", -6, -6)
		close:SetScript("OnClick", function() frame:Hide() end)
	end

	-- the waiting line: the agent takes seconds, and silence reads as broken
	local pending = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	pending:SetPoint("BOTTOMLEFT", 18, 16)
	pending:Hide()
	frame.pending = pending

	local messages = CreateFrame("ScrollingMessageFrame", nil, frame)
	messages:SetPoint("TOPLEFT", 18, -40)
	messages:SetPoint("BOTTOMRIGHT", -20, 34)
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

	-- 1.60.1 added a SmartNavigation API for exactly this: an addon can mark its own
	-- frames focusable by the gamepad cursor, so the window is reachable on a
	-- controller instead of needing a mouse.
	if SmartNavigation_MarkFrameFocusable then
		pcall(SmartNavigation_MarkFrameFocusable, frame)
	end
	-- Marking may not be enough: "focus interface" cycles registered UI panels, and
	-- a frame the addon merely shows is not one. Registering here is cheap to undo
	-- if it turns out to be the wrong lever.
	if UIPanelWindows then
		UIPanelWindows["WowCompanionLog"] = {
			area = "center",
			pushable = 0,
			whileDead = 1,
			allowOtherPanels = 1,
		}
	end

	frame:SetResizable(true)
	if frame.SetResizeBounds then
		frame:SetResizeBounds(320, 180)
	end
	local grip = CreateFrame("Button", nil, frame)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -8, 8)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
	grip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing() end)

	return frame
end

local function logFrame()
	logWindow = logWindow or buildLog()
	return logWindow
end

-- Shown through the panel system when it is available, so the frame is a UI panel
-- the gamepad's focus cycle can find, rather than just a frame we made visible.
local function reveal(frame)
	if ShowUIPanel and UIPanelWindows and UIPanelWindows["WowCompanionLog"] then
		local shown = pcall(ShowUIPanel, frame)
		if shown and frame:IsShown() then
			return
		end
	end
	frame:Show()
end

local function colouredFor(who)
	if who == "you" then
		return "|cff9ad5ff"
	elseif who == "error" then
		return "|cffff7777"
	end
	return "|cffffe08a"
end

-- Only the first line of a reply is labelled; the rest line up underneath, or a
-- nine-line answer says "claude" nine times and reads as nine separate replies.
local function showLine(who, text, continued, at)
	local messages = logFrame().messages
	if continued then
		messages:AddMessage("              " .. text)
	else
		messages:AddMessage(("|cff4a5260%s|r %s%-6s|r %s"):format(
			date("%H:%M", at or time()), colouredFor(who), who, text))
	end
end

-- Spinning while the agent thinks. Several seconds of silence after you speak is
-- indistinguishable from a broken channel, which is the whole reason this exists.
local function setPending(text)
	local frame = logFrame()
	if pendingTicker then
		pendingTicker:Cancel()
		pendingTicker = nil
	end
	if not text then
		frame.pending:Hide()
		return
	end
	local turn = 0
	local function spin()
		turn = turn + 1
		frame.pending:SetText(("%s%s"):format(text, ("."):rep(turn % 4)))
	end
	spin()
	frame.pending:Show()
	if not frame:IsShown() and not InCombatLockdown() then
		reveal(frame)
	end
	pendingTicker = C_Timer.NewTicker(0.4, spin)
end

-- Kept in SavedVariables, so it is written on /reload or logout like everything else.
local function remember(who, text, continued)
	WowCompanionDB.log = WowCompanionDB.log or {}
	local entries = WowCompanionDB.log
	entries[#entries + 1] = { at = time(), who = who, text = text, continued = continued or nil }
	while #entries > LOG_KEEP do
		table.remove(entries, 1)
	end
	showLine(who, text, continued, entries[#entries].at)
end

local function replayLog()
	for _, entry in ipairs(WowCompanionDB.log or {}) do
		showLine(entry.who or "claude", entry.text or "", entry.continued, entry.at)
	end
end

-- A button in the Companion window, retargeted on demand.
--
-- Protected calls are refused from insecure code, but a hardware button press is
-- trusted -- so for anything we cannot do ourselves, we put a button in front of the
-- player and they press it. It lives inside the window rather than on an action bar
-- so the gamepad cursor has a normal piece of UI to land on, and because it costs no
-- binding and no bar slot.
--
-- SecureActionButtonTemplate for the secure path, UIPanelButtonTemplate so it looks
-- like the game's own. Macro text is the limit of what it can do, which is also the
-- limit of what the player could type -- it grants no power they lacked.
local function offer(label, macro)
	-- attributes on a secure frame cannot be set in combat, and this is
	-- configuration anyway
	if InCombatLockdown() then
		return "refused: in combat"
	end
	local frame = logFrame()
	if not actionButton then
		local made, button = pcall(CreateFrame, "Button", "WowCompanionDo", frame,
			"SecureActionButtonTemplate, UIPanelButtonTemplate")
		if not made or not button then
			return "could not build the button: " .. tostring(button)
		end
		actionButton = button
		actionButton:SetSize(150, 24)
		actionButton:SetPoint("BOTTOMRIGHT", -32, 12)
		-- Measured, one variable at a time. "AnyUp": the wrapper runs -- PreClick and
		-- PostClick both fire -- and the macro does not, which reads exactly like a
		-- permissions refusal and is not one. Both edges: runs, but twice, once down
		-- and once up. "AnyDown" alone: runs once. That is the answer.
		--
		-- Attributes are still set first, which is cheap and conventional, but the
		-- edge is what decides whether the macro fires at all.
		actionButton:SetAttribute("type", "macro")
		actionButton:RegisterForClicks("AnyDown")

		-- kept while this is still being pinned down: without it a failure is
		-- indistinguishable from the click never arriving
		actionButton:SetScript("PreClick", function(_, button)
			say(("clicked %s, about to run %q"):format(
				tostring(button), tostring(actionButton:GetAttribute("macrotext"))))
		end)
		-- make the cursor able to land on it, and tell SmartNavigation this frame is
		-- where the window's focusable button lives
		if SmartNavigation_MarkFrameFocusable then
			pcall(SmartNavigation_MarkFrameFocusable, actionButton)
		end
		if SmartNavigation_SetButtonFrame then
			pcall(SmartNavigation_SetButtonFrame, actionButton)
		end
		if SmartNavigation_SetReturnFrameFocusButton then
			pcall(SmartNavigation_SetReturnFrameFocusButton, frame, actionButton)
		end
		actionButton:SetScript("PostClick", function(self)
			if ClearOverrideBindings then
				ClearOverrideBindings(self)
			end
			self:Hide()
		end)
	end
	actionButton:SetAttribute("macrotext", macro)
	actionButton:SetText(label)
	actionButton:Show()
	if not frame:IsShown() then
		reveal(frame)
	end

	-- The window is not a frame the gamepad cursor will focus, so instead of making
	-- it focusable we bind a pad button straight to clicking this one. The binding
	-- exists only while a button is pending and is cleared the moment it is pressed,
	-- so it costs nothing the rest of the time.
	local bound = "nothing"
	if SetOverrideBindingClick then
		ClearOverrideBindings(actionButton)
		-- built without holes: ipairs stops at the first nil, so a nil offerKey at the
		-- front meant this loop never ran once and every key looked unbindable
		local candidates = {}
		if offerKey then
			candidates[#candidates + 1] = offerKey
		end
		-- names taken from the client's own config, not guessed
		for _, fallback in ipairs({ "PADDRIGHT", "PADDUP", "PADRSHOULDER" }) do
			candidates[#candidates + 1] = fallback
		end
		for _, key in ipairs(candidates) do
			if key and SetOverrideBindingClick(actionButton, true, key, "WowCompanionDo") ~= false then
				bound = key
				break
			end
		end
	end
	-- show the macro, not just the label: the player is the one authorising this, and
	-- "Do it" tells them nothing about what they would be running
	remember("claude", ("button |cffffffff%s|r runs |cff9ad5ff%s|r — %s or click it")
		:format(label, macro, bound ~= "nothing" and ("press " .. bound) or "mouse"))
	return ("offering %q which runs %q, bound to %s"):format(label, macro, bound)
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
	-- `pending` starts the waiting line; any message without it clears it, so the
	-- reply arriving is what stops the spinner
	setPending(inbox.pending)
	-- a reply arrives as one message but reads as many lines, and AddMessage takes
	-- one line at a time; blank lines are kept because they carry the paragraphs
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		remember(who, line, lines > 0)
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

-- Probing for a game -> PC channel that is not the pixel strip we ruled out.
--
-- `LoggingChat(true)` makes the client write chat to Logs\WoWChatLog.txt, a plain
-- text file the helper can tail. The open question is what counts as chat: the log
-- may capture only server CHAT_MSG_* events, in which case an addon's own print
-- never appears and this whole idea is dead. So emit the marker three ways and let
-- the helper report which, if any, reached disk.
function handlers.bridge(inbox)
	local running, failed = pcall(LoggingChat, true)
	if not running then
		return "LoggingChat failed: " .. tostring(failed)
	end
	local nonce = tostring(inbox.nonce or "?")
	print(("WCBRIDGE-print %s"):format(nonce))
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage(("WCBRIDGE-frame %s"):format(nonce))
	end
	-- a real chat event, addressed to nobody: the only kind the log certainly keeps.
	-- Echoed back to us alone, so it is not a message sent on the player's behalf.
	if C_ChatInfo and C_ChatInfo.SendAddonMessage then
		C_ChatInfo.SendAddonMessage("WowCompanion", nonce, "WHISPER", UnitName("player"))
	end
	return ("logging on: %s, marked %s"):format(tostring(LoggingChat()), nonce)
end

-- A reload clears taint, flushes SavedVariables and resets the slot cursor. We
-- cannot do it ourselves: ReloadUI wraps a protected call, and asking from insecure
-- code comes back as "WowCompanion called Reload()".
--
-- A real button press is a hardware event, and that is the one path the client
-- trusts. So build a secure button on the fly, point it at a macro, and let the
-- player press it: the click runs through the secure path, taints nothing, and is
-- never blocked. Anything expressible as a macro can go through here.
function handlers.reload()
	return offer("Reload UI", "/reload")
end

-- Whatever the helper asks for, as a button the player presses. The macro text is
-- the limit of what this can do, which is also the limit of what the player could
-- type themselves -- so it grants no power they did not already have.
function handlers.press(inbox)
	return offer(inbox.label or "Do it", inbox.macro or "")
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
	-- only probe traffic is worth narrating in chat; the window is where the rest goes
	if inbox.kind == "probe" or not ok then
		record("slot " .. slot, ok and tostring(result) or ("error: " .. tostring(result)))
	end
	-- A reply and the action it describes are one thought, so they ride in one
	-- message: two sends would mean two bells and two seconds of waiting between
	-- reading the answer and being offered the button.
	local following = inbox.andThen
	if following and handlers[following.kind or ""] then
		local done, outcome = pcall(handlers[following.kind], following)
		if not done then
			record("slot " .. slot .. " follow-up", "error: " .. tostring(outcome))
		end
	end
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

-- What the gamepad UI gives us to work with. Controller focus matters well beyond
-- one button, and the client's own Lua is not on disk to read, so ask the client.
local function probeGamepad()
	for _, name in ipairs({
		"C_GamePad",
		"SmartNavigation",
		"GamePadSmartNavigation",
		"UIPanelWindows",
		"SetOverrideBinding",
		"GetBindingKey",
		"C_GamePad.GetActiveDeviceID",
		"C_GamePad.GetDeviceMappedState",
		"C_GamePad.SetVibration",
		"SmartNavigationFrameMixin",
		"GamePadCursorMixin",
	}) do
		local holder, member = name:match("^(%w+)%.(%w+)$")
		local found
		if holder then
			local parent = _G[holder]
			found = type(parent) == "table" and parent[member] ~= nil
		else
			found = _G[name] ~= nil
		end
		record("has " .. name, found and "yes" or "no")
	end
	record("interface style", cvar("InputDeviceInterfaceStyle"))

	-- SmartNavigation exists; find out whether it will let us register a frame
	if type(SmartNavigation) == "table" then
		local members = {}
		for key, value in pairs(SmartNavigation) do
			members[#members + 1] = ("%s(%s)"):format(tostring(key), type(value))
		end
		table.sort(members)
		record("SmartNavigation members", table.concat(members, " "))
	end

	-- which pad key names this build will actually accept for an override binding
	local usable = {}
	if SetOverrideBindingClick and actionButton then
		for _, key in ipairs({
			"PAD1", "PAD2", "PAD3", "PAD4",
			"PADDUP", "PADDDOWN", "PADDLEFT", "PADDRIGHT",
			"PADLSHOULDER", "PADRSHOULDER", "PADLSTICK", "PADRSTICK",
			"PADFORWARD", "PADBACK", "PADSYSTEM", "PADSOCIAL",
		}) do
			local ok = pcall(SetOverrideBindingClick, actionButton, true, key, "WowCompanionDo")
			if ok and GetBindingByKey and GetBindingByKey(key) then
				usable[#usable + 1] = key
			elseif ok then
				usable[#usable + 1] = key .. "?"
			end
		end
		ClearOverrideBindings(actionButton)
	end
	record("pad keys accepted", #usable > 0 and table.concat(usable, " ") or "none")

	-- 1.60.1's SmartNavigation_* globals are the documented way in. Mark the window,
	-- then ask whether it took: the API can answer for itself, so there is no need
	-- to infer it from whether the cursor happens to land.
	local frame = logFrame()
	if SmartNavigation_MarkFrameFocusable then
		pcall(SmartNavigation_MarkFrameFocusable, frame)
	end
	for _, check in ipairs({ "SmartNavigation_IsFrameFocusable", "SmartNavigation_CanFocusFrame" }) do
		local probe = _G[check]
		if probe then
			local ok, answer = pcall(probe, frame)
			record(check, ok and tostring(answer) or "errored")
		else
			record(check, "missing")
		end
	end
	if actionButton and SmartNavigation_IsFrameFocusable then
		local ok, answer = pcall(SmartNavigation_IsFrameFocusable, actionButton)
		record("button focusable", ok and tostring(answer) or "errored")
	end
end

-- Can the client tell us its own API? That would beat any external reference, which
-- is written about WoW in general while this is one specific build -- and version
-- drift is exactly what has caught us out repeatedly.
local function probeApi()
	for _, name in ipairs({
		"APIDocumentation",
		"C_ApiDocumentation",
		"GetAPIDocumentation",
		"APIDocumentationMixin",
		"ApiDocumentation",
	}) do
		record("has " .. name, _G[name] ~= nil and type(_G[name]) or "no")
	end

	-- failing that, the globals themselves are a complete list of what exists
	local functions, namespaces, members = 0, 0, 0
	local biggest, biggestCount = "none", 0
	for key, value in pairs(_G) do
		if type(value) == "function" then
			functions = functions + 1
		elseif type(value) == "table" and type(key) == "string" and key:match("^C_%w+$") then
			namespaces = namespaces + 1
			local count = 0
			for _, member in pairs(value) do
				if type(member) == "function" then
					count = count + 1
				end
			end
			members = members + count
			if count > biggestCount then
				biggest, biggestCount = key, count
			end
		end
	end
	record("global functions", functions)
	record("C_ namespaces", namespaces)
	record("C_ functions", members)
	record("largest namespace", ("%s (%d)"):format(biggest, biggestCount))
end

-- Everything this build can call, as one string.
--
-- The client ships no API documentation tables, so signatures are not available
-- locally -- but the *names* are, exhaustively and exactly for this build. That is
-- the half that matters: the agent's failure mode is not forgetting what a function
-- does, it is confidently calling something that exists in retail and not here.
--
-- One string rather than a nested table because the helper has to parse this back
-- out of SavedVariables without a Lua parser.
local function dumpApi()
	local lines, namespaces = {}, 0
	for key, value in pairs(_G) do
		if type(key) == "string" then
			if type(value) == "function" then
				lines[#lines + 1] = key
			elseif type(value) == "table" and key:match("^C_%w+$") then
				namespaces = namespaces + 1
				for name, member in pairs(value) do
					if type(member) == "function" and type(name) == "string" then
						lines[#lines + 1] = key .. "." .. name
					end
				end
			end
		end
	end
	table.sort(lines)
	local version, build = GetBuildInfo()
	-- built with an explicit newline rather than an escape: the escapes in this file
	-- have been through a shell and a script, and one of them arrived as a literal
	-- line break inside a string literal
	local newline = string.char(10)
	WowCompanionDB.api = ("-- World of Warcraft %s build %s%s%s%s"):format(
		tostring(version), tostring(build), newline, table.concat(lines, newline), newline)
	say(("dumped %d names across %d namespaces; /reload to write it to disk")
		:format(#lines, namespaces))
end

-- Signatures, if the client will give them up. The name index came from _G, but
-- retail keeps documentation in a load-on-demand Blizzard addon, and this build has
-- APIDocumentation_LoadUI -- so the table may only be absent because nothing has
-- loaded it yet. Kept separate from dumpApi so a failure here costs nothing.
-- the fields every function entry has; anything else is a flag worth keeping, and
-- the flags are where the documentation says what is restricted
local SHAPE = { Name = true, Type = true, Arguments = true, Returns = true,
	Documentation = true, System = true }

local function describe(fields)
	local parts = {}
	for _, field in ipairs(fields or {}) do
		parts[#parts + 1] = ("%s: %s%s"):format(
			tostring(field.Name), tostring(field.Type), field.Nilable and "?" or "")
	end
	return table.concat(parts, ", ")
end

local function dumpDocs()
	if not APIDocumentation then
		for _, loader in ipairs({
			function() APIDocumentation_LoadUI() end,
			function() C_AddOns.LoadAddOn("Blizzard_APIDocumentationGenerated") end,
			function() C_AddOns.LoadAddOn("Blizzard_APIDocumentation") end,
		}) do
			pcall(loader)
			if APIDocumentation then
				break
			end
		end
	end
	if type(APIDocumentation) ~= "table" or type(APIDocumentation.systems) ~= "table" then
		record("api docs", "unavailable: APIDocumentation " .. type(APIDocumentation))
		return
	end

	local newline = string.char(10)
	local lines, systems = {}, 0
	for _, system in ipairs(APIDocumentation.systems) do
		systems = systems + 1
		local prefix = system.Namespace and (system.Namespace .. ".") or ""
		for _, fn in ipairs(system.Functions or {}) do
			local returns = describe(fn.Returns)
			local flags = {}
			for key, value in pairs(fn) do
				if not SHAPE[key] and type(value) ~= "table" and type(value) ~= "function" then
					flags[#flags + 1] = ("%s=%s"):format(tostring(key), tostring(value))
				end
			end
			table.sort(flags)
			lines[#lines + 1] = ("%s%s(%s)%s%s"):format(prefix, tostring(fn.Name),
				describe(fn.Arguments), returns ~= "" and (" -> " .. returns) or "",
				#flags > 0 and (" [" .. table.concat(flags, " ") .. "]") or "")
		end
		for _, event in ipairs(system.Events or {}) do
			lines[#lines + 1] = ("event %s(%s)"):format(
				tostring(event.LiteralName or event.Name), describe(event.Payload))
		end
		-- the signatures are only half an answer without these: a function that
		-- returns SpellBookItemInfo tells you nothing about what to read off it,
		-- and an argument typed SpellBookSpellBank tells you nothing about what to
		-- pass. Enumerations carry their values, so this is also where the magic
		-- numbers stop being magic.
		for _, entry in ipairs(system.Tables or {}) do
			local kind = tostring(entry.Type)
			if kind == "Enumeration" or kind == "Constants" then
				local values = {}
				for _, value in ipairs(entry.Values or entry.Fields or {}) do
					values[#values + 1] = ("%s = %s"):format(
						tostring(value.Name),
						tostring(value.EnumValue ~= nil and value.EnumValue or value.Value))
				end
				lines[#lines + 1] = ("%s %s { %s }"):format(
					kind == "Enumeration" and "enum" or "constants",
					tostring(entry.Name), table.concat(values, ", "))
			else
				lines[#lines + 1] = ("struct %s { %s }"):format(
					tostring(entry.Name), describe(entry.Fields))
			end
		end
	end
	table.sort(lines)
	WowCompanionDB.apidocs = table.concat(lines, newline) .. newline
	record("api docs", ("%d entries from %d systems; /reload to write"):format(#lines, systems))
end

-- Name lookups, asked rather than assumed.
--
-- This client is 1.60.1: not retail, and not any Classic we have a reference for.
-- GetSpellInfo has been removed, restored and reshaped across builds, so which of
-- these exists -- and whether it returns a string or a table -- is a runtime
-- question. Each is tried in turn and the first that answers wins.
local function spellName(id)
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, id)
		if ok and type(info) == "table" and info.name then
			return info.name
		end
	end
	if GetSpellInfo then
		local ok, name = pcall(GetSpellInfo, id)
		if ok then
			if type(name) == "table" then
				return name.name
			elseif type(name) == "string" then
				return name
			end
		end
	end
	return nil
end

-- Written as two ifs rather than a loop over { C_Item and ..., GetItemInfo }:
-- ipairs stops at the first nil, so if the namespaced form were missing the loop
-- would never reach the global one. That exact hole cost us an afternoon already.
local function itemName(id)
	if C_Item and C_Item.GetItemInfo then
		local ok, name = pcall(C_Item.GetItemInfo, id)
		if ok and type(name) == "string" then
			return name
		end
	end
	if GetItemInfo then
		local ok, name = pcall(GetItemInfo, id)
		if ok and type(name) == "string" then
			return name
		end
	end
	return nil
end

-- What the agent needs to know about this character, as one string.
--
-- The same shape as dumpApi and for the same reason: the helper has no Lua parser,
-- so one string it can slice out of SavedVariables beats a nested table. Sections
-- are marked "== name ==" so either side can take just the part it needs -- the
-- whole thing is too big for every prompt, but "macros" or "action slots" is not.
--
-- Two sections answer open questions rather than feed the agent. "action buttons on
-- screen" walks every frame in the UI looking for one bound to an action slot,
-- which is how we learn which of the flat 1..120 space the gamepad UI actually
-- draws -- measured from the live UI instead of guessed from the classic bar
-- layout. "bindings" is the other half: what the controller can already press, and
-- therefore what is left for us.
local function exportContext()
	local newline = string.char(10)
	local out = {}
	local function line(text)
		out[#out + 1] = text
	end
	local function section(name)
		line("")
		line("== " .. name .. " ==")
	end

	local version, build = GetBuildInfo()
	line(("-- WowCompanion context, %s, client %s build %s")
		:format(date("%Y-%m-%d %H:%M:%S"), tostring(version), tostring(build)))

	section("character")
	line(("name: %s"):format(tostring(UnitName("player"))))
	line(("level: %s"):format(tostring(UnitLevel("player"))))
	line(("class: %s"):format(tostring(UnitClass("player"))))
	line(("race: %s"):format(tostring(UnitRace("player"))))
	line(("faction: %s"):format(tostring(UnitFactionGroup("player"))))
	if GetSpecialization and GetSpecializationInfo then
		local index = GetSpecialization()
		if index then
			local _, specName = GetSpecializationInfo(index)
			line(("spec: %s"):format(tostring(specName)))
		end
	end
	if GetMoney then
		line(("copper: %s"):format(tostring(GetMoney())))
	end

	section("action slots")
	line("-- the flat 1..120 space, addressed by number; empty slots omitted")
	if HasAction and GetActionInfo then
		local filled = 0
		for slot = 1, 120 do
			if HasAction(slot) then
				filled = filled + 1
				local kind, id, subType = GetActionInfo(slot)
				local what
				if kind == "spell" then
					what = ("spell %s (%s)"):format(tostring(id), tostring(spellName(id) or "?"))
				elseif kind == "macro" then
					local name = GetMacroInfo and GetMacroInfo(id)
					if not name and GetActionText then
						name = GetActionText(slot)
					end
					what = ("macro %s (%s)"):format(tostring(id), tostring(name or "?"))
				elseif kind == "item" then
					what = ("item %s (%s)"):format(tostring(id), tostring(itemName(id) or "?"))
				else
					what = ("%s %s"):format(tostring(kind), tostring(id))
				end
				if subType and subType ~= "" then
					what = what .. " [" .. tostring(subType) .. "]"
				end
				line(("%3d: %s"):format(slot, what))
			end
		end
		line(("-- %d of 120 filled"):format(filled))
	else
		line("-- HasAction/GetActionInfo unavailable")
	end

	section("action buttons on screen")
	line("-- every frame bound to an action slot: which of the 120 the UI draws, and where")
	if EnumerateFrames then
		local seen, walked = {}, 0
		local frame = EnumerateFrames()
		while frame and walked < 50000 do
			walked = walked + 1
			local slot
			if type(frame.action) == "number" then
				slot = frame.action
			elseif frame.GetAttribute then
				local ok, value = pcall(frame.GetAttribute, frame, "action")
				if ok and type(value) == "number" then
					slot = value
				end
			end
			if slot then
				local name = frame.GetName and frame:GetName() or nil
				local shown = frame.IsVisible and frame:IsVisible()
				seen[#seen + 1] = ("%3d: %s%s"):format(slot,
					tostring(name or "(anonymous)"), shown and "" or " (hidden)")
			end
			frame = EnumerateFrames(frame)
		end
		table.sort(seen)
		for _, entry in ipairs(seen) do
			line(entry)
		end
		line(("-- %d action-bound frames out of %d walked"):format(#seen, walked))
	else
		line("-- EnumerateFrames unavailable")
	end

	section("bindings")
	line("-- what is already taken. PAD* are the controller's; those are the scarce ones")
	if GetNumBindings and GetBinding then
		local total = GetNumBindings()
		local bound = 0
		for index = 1, total do
			-- GetBinding's return shape differs between builds (some insert a
			-- category before the keys), so take everything after the command and
			-- report it rather than indexing positions we have not verified
			local bits = { GetBinding(index) }
			if index == 1 then
				line(("-- GetBinding returns %d values per binding"):format(#bits))
			end
			local keys = {}
			for at = 2, #bits do
				if type(bits[at]) == "string" and bits[at] ~= "" then
					keys[#keys + 1] = bits[at]
				end
			end
			if #keys > 0 then
				bound = bound + 1
				line(("%s = %s"):format(tostring(bits[1]), table.concat(keys, ", ")))
			end
		end
		line(("-- %d bound of %d bindings"):format(bound, total))
	else
		line("-- GetNumBindings/GetBinding unavailable")
	end

	section("macros")
	if GetNumMacros and GetMacroInfo then
		local global, perChar = GetNumMacros()
		line(("-- %s global, %s character"):format(tostring(global), tostring(perChar)))
		for index = 1, 200 do
			local name, _, body = GetMacroInfo(index)
			if name then
				line(("%d: %s"):format(index, name))
				local shown = (tostring(body or "")):gsub(newline, newline .. "    ")
				line("    " .. shown)
			end
		end
	else
		line("-- GetNumMacros/GetMacroInfo unavailable")
	end

	section("spellbook")
	line("-- also the vocabulary the transcriber needs: these are the words you will say")
	-- the name index says this build has no GetNumSpellTabs, GetSpellBookItemInfo or
	-- GetSpellInfo at all: it is a retail-11.x-era API behind a 1.60.1 version
	-- string. The classic branch stays only so a differently-built client says so
	-- out loud instead of exporting an empty spellbook.
	local walked = pcall(function()
		if GetNumSpellTabs and GetSpellTabInfo and GetSpellBookItemInfo then
			for tab = 1, GetNumSpellTabs() do
				local tabName, _, offset, numSpells = GetSpellTabInfo(tab)
				line(("-- %s"):format(tostring(tabName)))
				for at = (offset or 0) + 1, (offset or 0) + (numSpells or 0) do
					local kind, id = GetSpellBookItemInfo(at, "spell")
					local name = GetSpellBookItemName and GetSpellBookItemName(at, "spell")
					if not name and id then
						name = spellName(id)
					end
					if name then
						line(("%s %s (%s)"):format(tostring(kind), tostring(name), tostring(id)))
					end
				end
			end
		elseif C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
			for tab = 1, C_SpellBook.GetNumSpellBookSkillLines() do
				local info = C_SpellBook.GetSpellBookSkillLineInfo(tab)
				local offset = info and info.itemIndexOffset or 0
				line(("-- %s"):format(tostring(info and info.name)))
				-- GetSpellBookItemInfo's second argument is typed SpellBookSpellBank,
				-- so name it rather than passing the 0 I would otherwise have assumed
				local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
				for at = offset + 1, offset + (info and info.numSpellBookItems or 0) do
					local item = C_SpellBook.GetSpellBookItemInfo(at, bank)
					if item and item.name then
						line(("%s %s (%s)"):format(
							tostring(item.itemType), item.name, tostring(item.spellID)))
					end
				end
			end
		else
			line("-- no spellbook API found under either name")
		end
	end)
	if not walked then
		line("-- the spellbook walk failed partway; the lines above are what it reached")
	end

	WowCompanionDB.context = table.concat(out, newline) .. newline
	return #out
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

-- PlaceAction, tested one variable at a time.
--
-- The chat taint taught us that "it seemed fine" means nothing: the damage lands
-- later, on an unrelated keypress, and only sometimes. So the A/B check by hand is
-- kept, but it is not the instrument. The instrument is issecurevariable: every
-- global, and every string-keyed field of every global table, is asked who last
-- wrote it, before and after the action. Anything that turns insecure in between,
-- and is not one of our own names, is taint we caused, named by variable.
--
-- That is a claim about the scanner, so it gets a positive control: `chatopen`
-- does the one thing we know broke A and B. If the scan cannot see that, a clean
-- scan for PlaceAction proves nothing.

local function ours(name)
	name = tostring(name)
	return name:find("WowCompanion", 1, true) or name:find("WOWCOMPANION", 1, true)
end

local function taintScan()
	local tainted, checked = {}, 0
	local function check(label, tbl, key)
		checked = checked + 1
		local ok, secure, by
		if tbl then
			ok, secure, by = pcall(issecurevariable, tbl, key)
		else
			ok, secure, by = pcall(issecurevariable, key)
		end
		if ok and not secure then
			tainted[label] = tostring(by)
		end
	end
	for name, value in pairs(_G) do
		if type(name) == "string" and not ours(name) then
			check(name, nil, name)
			-- forbidden frames refuse to be walked; pcall keeps one from ending the scan
			if type(value) == "table" then
				pcall(function()
					for field in pairs(value) do
						if type(field) == "string" and not ours(field) then
							check(name .. "." .. field, value, field)
						end
					end
				end)
			end
		end
	end
	return tainted, checked
end

-- slot -> { visible = bool } for every action slot some frame is drawn for
local function actionFrames()
	local slots = {}
	if not EnumerateFrames then
		return slots
	end
	local frame, walked = EnumerateFrames(), 0
	while frame and walked < 50000 do
		walked = walked + 1
		local slot = type(frame.action) == "number" and frame.action or nil
		if not slot and frame.GetAttribute then
			local ok, value = pcall(frame.GetAttribute, frame, "action")
			if ok and type(value) == "number" then
				slot = value
			end
		end
		if slot then
			local entry = slots[slot] or { visible = false }
			entry.visible = entry.visible or (frame.IsVisible and frame:IsVisible()) or false
			slots[slot] = entry
		end
		frame = EnumerateFrames(frame)
	end
	return slots
end

local PLACE_MACRO = "WCPLACE"

local function placeMacro()
	local index = GetMacroIndexByName(PLACE_MACRO)
	if index and index > 0 then
		return index
	end
	return CreateMacro(PLACE_MACRO, "INV_MISC_QUESTIONMARK", "/wc ping", false)
end

-- chosen fresh each run, so each variant reports exactly where it acted
local function pickSlots()
	local frames = actionFrames()
	local picked = {}
	for slot = 1, 120 do
		local drawn = frames[slot] and frames[slot].visible
		if not HasAction(slot) then
			if drawn and not picked.emptyVisible then
				picked.emptyVisible = slot
			elseif not frames[slot] and not picked.emptyHidden then
				picked.emptyHidden = slot
			end
		elseif drawn and not picked.filledVisible then
			picked.filledVisible = slot
		end
	end
	return picked
end

local placeVariants = {}

placeVariants.none = function()
	return "did nothing: the scan's own noise floor"
end

placeVariants.chatopen = function()
	local open = ChatFrame_OpenChat or (ChatFrameUtil and ChatFrameUtil.OpenChat)
	if not open then
		return "no chat opener on this client"
	end
	-- deferred a tick, as the slash-command path requires, then closed again so the
	-- only thing measured is having opened it
	C_Timer.After(0.1, function()
		open("")
		C_Timer.After(0.1, function()
			local box = activeEditBox()
			if box and ChatEdit_DeactivateChat then
				pcall(ChatEdit_DeactivateChat, box)
			end
		end)
	end)
	return "opened and closed the chat box from addon code (the known-bad control)"
end

placeVariants.pickup = function()
	PickupMacro(placeMacro())
	ClearCursor()
	return "picked up the test macro and cleared the cursor, placing nothing"
end

local function placeInto(slot, how)
	PickupMacro(placeMacro())
	if how == "put" then
		C_ActionBar.PutActionInSlot(slot)
	else
		PlaceAction(slot)
	end
	ClearCursor()
	local kind, id = GetActionInfo(slot)
	return ("slot %d now holds %s %s"):format(slot, tostring(kind), tostring(id))
end

placeVariants.hidden = function(slots)
	if not slots.emptyHidden then
		return "no empty undrawn slot"
	end
	return "PlaceAction into an undrawn slot: " .. placeInto(slots.emptyHidden, "place")
end

placeVariants.visible = function(slots)
	if not slots.emptyVisible then
		return "no empty drawn slot"
	end
	return "PlaceAction into a drawn slot: " .. placeInto(slots.emptyVisible, "place")
end

placeVariants.put = function(slots)
	if not (C_ActionBar and C_ActionBar.PutActionInSlot) then
		return "no C_ActionBar.PutActionInSlot"
	end
	if not slots.emptyVisible then
		return "no empty drawn slot"
	end
	return "PutActionInSlot into a drawn slot: " .. placeInto(slots.emptyVisible, "put")
end

-- A real rearrangement that undoes itself: a filled, drawn slot moves to an empty
-- undrawn one and back. The bars end where they started, but every call a
-- rearrangement needs has run, including holding a live action on the cursor.
placeVariants.move = function(slots)
	local from, to = slots.filledVisible, slots.emptyHidden
	if not (from and to) then
		return "need a filled drawn slot and an empty undrawn one"
	end
	local was, wasId = GetActionInfo(from)
	PickupAction(from)
	PlaceAction(to)
	PickupAction(to)
	PlaceAction(from)
	ClearCursor()
	local now, nowId = GetActionInfo(from)
	return ("moved slot %d to %d and back: holds %s %s, held %s %s"):format(from, to,
		tostring(now), tostring(nowId), tostring(was), tostring(wasId))
end

placeVariants.clean = function()
	local removed = 0
	local index = GetMacroIndexByName(PLACE_MACRO)
	if index and index > 0 then
		for slot = 1, 120 do
			local kind, id = GetActionInfo(slot)
			if kind == "macro" and id == index then
				PickupAction(slot)
				ClearCursor()
				removed = removed + 1
			end
		end
		DeleteMacro(index)
	end
	return ("removed the test macro from %d slot(s) and deleted it"):format(removed)
end

local PLACE_ORDER = { "none", "chatopen", "pickup", "hidden", "visible", "put", "move", "clean" }

local function placeTest(variant)
	local act = placeVariants[variant]
	if not act then
		return "variants: " .. table.concat(PLACE_ORDER, ", ")
	end
	if InCombatLockdown() then
		return "refused: in combat"
	end
	WowCompanionDB.placeTests = WowCompanionDB.placeTests or {}
	local before, checked = taintScan()
	local ok, result = pcall(act, pickSlots())
	if not ok then
		result = "error: " .. tostring(result)
	end
	local entry = { at = time(), variant = variant, result = result, checked = checked }
	table.insert(WowCompanionDB.placeTests, entry)
	remember("probe", ("place %s: %s"):format(variant, tostring(result)))
	-- long enough for whatever the action set off to have run: events, OnUpdate,
	-- the deferred chat open
	C_Timer.After(1.5, function()
		local after = taintScan()
		local fresh = {}
		for label, by in pairs(after) do
			if before[label] == nil then
				fresh[#fresh + 1] = ("%s (by %s)"):format(label, by)
			end
		end
		table.sort(fresh)
		entry.tainted = #fresh
		entry.taint = #fresh == 0 and "none" or table.concat(fresh, "; ")
		remember("probe", ("place %s: %d newly tainted of %d checked%s"):format(variant, #fresh,
			checked, #fresh > 0 and (": " .. table.concat(fresh, "; ", 1, math.min(#fresh, 6))) or ""))
		remember("probe", "now A on an NPC, B out of a menu; then /wc verdict ok or /wc verdict broken")
	end)
	return result
end

local function placeVerdict(word)
	local tests = WowCompanionDB.placeTests
	local last = tests and tests[#tests]
	if not last then
		return "no place test to judge"
	end
	last.verdict = word
	remember("probe", ("place %s judged %s"):format(last.variant, word))
	return word
end

-- from the helper too, so the bell path is measured and not just the slash command
function handlers.place(inbox)
	return placeTest(inbox.variant or "")
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
-- fires on /reload as well as logout, just before SavedVariables is written: the
-- one moment worth exporting at, since nothing reaches disk any other time
frame:RegisterEvent("PLAYER_LOGOUT")
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
	elseif event == "PLAYER_LOGOUT" then
		-- a failed export must not cost the rest of the save
		pcall(exportContext)
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
	elseif command == "gamepad" then
		probeGamepad()
	elseif command == "api" then
		probeApi()
	elseif command == "dump" then
		dumpApi()
	elseif command == "docs" then
		dumpDocs()
	elseif command == "context" then
		say(("context: %d lines; /reload to write it to disk"):format(exportContext()))
	elseif command:match("^place") then
		local variant = command:match("^place%s+(%S+)") or ""
		-- deferred a tick, like chat: the Enter that submitted this is still unwinding
		C_Timer.After(0.1, function()
			say(placeTest(variant))
		end)
	elseif command:match("^verdict ") then
		say(placeVerdict(command:match("^verdict (%S+)")))
	elseif command == "taint" then
		local tainted, checked = taintScan()
		local names = {}
		for label, by in pairs(tainted) do
			names[#names + 1] = ("%s (by %s)"):format(label, by)
		end
		table.sort(names)
		WowCompanionDB.taint = table.concat(names, "\n")
		say(("%d tainted of %d checked; /reload to write the list"):format(#names, checked))
	elseif command == "ping" then
		-- the macro test target: no side effects, and unmistakable when it fires.
		-- remember() rather than say(), so the answer survives to SavedVariables --
		-- a probe whose result only reaches the chat frame cannot be read back.
		remember("probe", "pong at " .. date("%H:%M:%S") .. " -- the macro ran")
		record("macrotext runs", "yes, at " .. date("%H:%M:%S"))
	elseif command == "test" then
		-- point the button at our own slash command. If pong appears, macrotext works
		-- and /reload is being refused specifically; if not, macrotext never runs.
		say(offer("Run /wc ping", "/wc ping"))
	elseif command:match("^key ") then
		offerKey = command:match("^key (%S+)")
		say(("offer button will try %s first"):format(tostring(offerKey)))
	elseif command == "button" then
		say(offer("Reload UI", "/reload"))
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
			-- plain Hide, not HideUIPanel: a programmatic HideUIPanel from a click
			-- handler is the exact path that taints gamepad navigation on this client
			frame:Hide()
		else
			reveal(frame)
		end
	elseif command == "clear" then
		WowCompanionDB.log = {}
		logFrame().messages:Clear()
		say("conversation cleared")
	else
		say("/wc log, /wc clear, /wc button, /wc gamepad, /wc api, /wc dump, /wc test, /wc chat, /wc macro, /wc sound, /wc quiet, /wc listen")
	end
end
