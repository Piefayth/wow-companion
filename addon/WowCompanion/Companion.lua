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
	-- A fixed box, text pinned left and never wrapping: with one anchor the region
	-- resized to its text on every tick, so the dots coming and going made the
	-- line jump. Now only the dots move.
	pending:SetPoint("BOTTOMLEFT", 18, 16)
	pending:SetPoint("BOTTOMRIGHT", -180, 16)
	pending:SetJustifyH("LEFT")
	pending:SetWordWrap(false)
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
	-- Not registered in UIPanelWindows, and not shown with ShowUIPanel: a UI panel
	-- puts the gamepad UI into panel mode (FrameControlsManager's fallthrough
	-- catcher), which takes the d-pad, face buttons and triggers away from the bars
	-- for as long as it is open, and a plain Hide never tells it the panel closed.
	-- Measured: with the window up, PAD1-4 and the d-pad were bound to a blank
	-- click and the form wheel would not open.

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

-- A plain Show, never ShowUIPanel: see buildLog for why the panel system is out.
local function reveal(frame)
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
-- set further down, once taintScan exists: what follows a dictated line
local onDictated

-- Writes into a chat box the player already opened, and never opens one itself.
-- That distinction is the whole point: when we called ChatFrame_OpenChat, the
-- gamepad focus restore on close came back blocked and the A and B buttons died.
-- A box the player opened was activated by real hardware input, so the secure path
-- stays intact and we only set text on it. Refuses rather than opening one, because
-- opening one is the thing that broke the controller.
function handlers.chat(inbox)
	-- The controller's cancel unfocuses the box but keeps its text, and dictation
	-- appends, so a discarded line would come back glued to the next one. Clearing
	-- reaches the box whether or not it still has focus, and only sets its text:
	-- showing or hiding Blizzard's frame is what broke A and B.
	if inbox.clear then
		local box = activeEditBox() or LAST_ACTIVE_CHAT_EDIT_BOX or ChatFrame1EditBox
		if box and box.SetText then
			box:SetText("")
			return "chat box cleared"
		end
		return "refused: no chat box to clear"
	end
	local box = activeEditBox()
	if not box or not box:IsVisible() then
		-- in the window, where it is seen: opening the box ourselves is what broke
		-- A and B, so the player opens it and speaks again
		remember("error", "No chat box open, so nothing was written. Open chat, then speak.")
		return "refused: no chat box open"
	end
	-- append, so speaking twice builds a line instead of replacing it. Not echoed
	-- into the window: that is the conversation with the agent, and dictation is
	-- the player talking to other players
	box:SetText((box:GetText() or "") .. (inbox.text or ""))
	if onDictated then
		onDictated(box)
	end
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

-- What the agent is doing right now, on the waiting line: "reading StanceBar.lua".
-- Not logged; the reply is what stays.
function handlers.progress(inbox)
	setPending(inbox.text or "thinking")
	return "progress"
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
	-- There was a self-whisper here, addressed by UnitName("player"). Names on this
	-- client are first and last ("Pietra Fayth"); UnitName gives only the first,
	-- and the server answered "No player named Pietra is currently playing".
	-- Addressing a player needs the full name in a form not yet measured
	-- (C_NameUtil mentions a surname separator), so the whisper is gone.
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

-- What a step did, in the window, so a refusal ("in combat", "no macro named")
-- is seen rather than silently dropped. Only kinds whose result is news: chat,
-- lua and press already show themselves.
local REPORTED = { bar = true, macro = true, module = true }
local function report(step, ok, outcome)
	if not ok then
		remember("error", ("%s failed: %s"):format(tostring(step.kind), tostring(outcome)))
	elseif REPORTED[step.kind] and type(outcome) == "string" then
		remember(outcome:find("^refused") and "error" or "game", outcome)
	end
end

-- Several steps from one answer, in order, each reported. One failing does not
-- stop the rest: they were asked for together, but each stands on its own, and
-- the report says which landed.
function handlers.batch(inbox)
	for _, step in ipairs(inbox.steps or {}) do
		local handler = handlers[step.kind or ""]
		if not handler or step.kind == "batch" then
			report(step, false, "unknown kind")
		else
			report(step, pcall(handler, step))
		end
	end
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
		report(following, done, outcome)
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

local function loadDocs()
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
		return false
	end
	return true
end

local function dumpDocs()
	if not loadDocs() then
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

-- Which documented functions actually answer on this client.
--
-- Documented is not working: Forever carries retail's namespaces, and a function can
-- exist, be documented, and return nothing. Calling it is the only test, and calling
-- blind is only safe for one kind -- a read that needs no arguments. So: every
-- documented function whose name starts Get/Is/Has/Can/Should/Are/Does and whose
-- arguments are all optional is called once, under pcall, and sorted by what came
-- back. Anything that changes state is left alone; those need a test of their own.
--
-- Batched across frames so a few thousand calls do not hitch the game.
--
-- The first version called every such read in the client, and one of them crashed
-- it outright: ACCESS_VIOLATION reading address 0 inside Wow.exe, from a plain pcall
-- -- pcall catches Lua errors, not a C null dereference. Seven others were refused
-- as ADDON_ACTION_FORBIDDEN. The crash report named only "call 58 of a batch". So:
-- only the namespaces this project would use, nothing the docs flag as restricted,
-- and the name of each function in a plain local while it runs, because the crash
-- report prints the locals of the Lua frame that was executing.
-- "%u" after the verb: "^Can" alone matched CancelEmote, which is not a read
local READS = { "^Get%u", "^Is%u", "^Has%u", "^Can%u", "^Should%u", "^Are%u", "^Does%u" }
local SURVEYED = {
	C_ActionBar = true, C_Macro = true, C_Spell = true, C_SpellBook = true,
	C_ClassTalents = true, C_Traits = true, C_SpecializationInfo = true,
	C_EquipmentSet = true, C_CVar = true, C_KeyBindings = true, C_ChatInfo = true,
	C_GamePad = true, C_Container = true, C_Item = true, C_PlayerInfo = true,
	C_UnitAuras = true, C_PetInfo = true, C_MountJournal = true, C_ToyBox = true,
}

local function verdict(ok, ...)
	if not ok then
		return "error"
	end
	local count = select("#", ...)
	if count == 0 then
		return "nothing"
	end
	local first = ...
	if first == nil then
		return "nil"
	elseif type(first) == "table" then
		return next(first) == nil and "empty" or "value"
	elseif first == 0 or first == false or first == "" then
		return "zero"
	end
	return "value"
end

local function surveyApi()
	if InCombatLockdown() then
		say("leave combat first")
		return
	end
	if not loadDocs() then
		return
	end
	local queue = {}
	for _, system in ipairs(APIDocumentation.systems) do
		-- widget methods (frame:Show and friends) need an object; only namespaces
		-- and plain globals can be called bare
		local owner = system.Namespace and SURVEYED[system.Namespace] and _G[system.Namespace] or nil
		for _, fn in ipairs(system.Functions or {}) do
			local name = tostring(fn.Name)
			local read = false
			for _, pattern in ipairs(READS) do
				read = read or name:find(pattern) ~= nil
			end
			local optional = true
			for _, arg in ipairs(fn.Arguments or {}) do
				optional = optional and (arg.Nilable or arg.Default ~= nil)
			end
			if read and optional and owner and not fn.HasRestrictions then
				queue[#queue + 1] = {
					label = (system.Namespace and (system.Namespace .. ".") or "") .. name,
					owner = owner,
					name = name,
				}
			end
		end
	end
	local results, tally, at = {}, {}, 0
	local function batch()
		for _ = 1, 150 do
			at = at + 1
			local job = queue[at]
			if not job then
				table.sort(results)
				local summary = {}
				for kind, count in pairs(tally) do
					summary[#summary + 1] = ("%s %d"):format(kind, count)
				end
				table.sort(summary)
				local newline = string.char(10)
				WowCompanionDB.alive = ("-- %d no-argument reads called: %s"):format(#queue,
					table.concat(summary, ", ")) .. newline .. table.concat(results, newline) .. newline
				record("api survey", table.concat(summary, ", ") .. "; /reload to write")
				return
			end
			local kind
			local fn = type(job.owner) == "table" and rawget(job.owner, job.name)
			-- read by the crash reporter, not by us: see the note above
			local survey_calling = job.label
			if type(fn) ~= "function" then
				kind = "absent"
			else
				local refusedBefore = blocked
				kind = verdict(pcall(fn))
				if blocked ~= refusedBefore then
					kind = "forbidden"
				end
			end
			survey_calling = nil
			tally[kind] = (tally[kind] or 0) + 1
			results[#results + 1] = ("%s %s"):format(kind, job.label)
		end
		C_Timer.After(0, batch)
	end
	say(("calling %d documented no-argument reads..."):format(#queue))
	batch()
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

-- The action slot space is not 1..120 on this client. The classic bars use the
-- low numbers, but the gamepad UI draws 181..272 (top 181-184, left 185-192, right
-- 193-200, bottom 201-208, stance 265-272) and the extra action button sits at 397.
-- Measured from the live UI. Scan well past that; an invalid slot just errors.
local LAST_ACTION_SLOT = 1024

local function slotHas(slot)
	local ok, has = pcall(HasAction, slot)
	return ok and has
end

-- "GamepadMainActionBarFramePageUnitLeftCenteredAnchorLeftBarActionButton3" -> "LeftBar 3"
local function barLabel(name)
	return (tostring(name):gsub("^GamepadMainActionBarFramePageUnit", "")
		:gsub("^%a-CenteredAnchor", ""):gsub("ActionButton(%d+)$", " %1"))
end

-- Which chord fires which button.
--
-- Not in the bindings: GetBindingKey("ACTIONBUTTON189") is empty for every gamepad
-- button, and no frame field names the trigger. What is measurable is each button's
-- icon -- its SlotArt atlas names the base input, the same eight on every bar
-- (1-4 the d-pad left, up, right, down; 5-8 the face buttons) -- and, by watching,
-- which modifiers are held when a button goes into its pushed state. So the base
-- comes from the art and the modifier is learned from play, keyed by bar position
-- rather than slot, because druid forms page the slots under the same buttons.
local GAMEPAD_BARS = {
	{ "TopCenteredAnchorTopBar", 4 },
	{ "LeftCenteredAnchorLeftBar", 8 },
	{ "RightCenteredAnchorRightBar", 8 },
	{ "BottomCenteredAnchorBottomBar", 8 },
	{ "TopCenteredAnchorStanceBar", 8 },
}
local ART_INPUT = {
	dpadleft = "left", dpadup = "up", dpadright = "right", dpaddown = "down",
	["ps%-square"] = "square", ["ps%-triangle"] = "triangle",
	["ps%-circle"] = "circle", ["ps%-cross"] = "cross",
}

-- { frame, label = "LeftBar 3", bar = "LeftBar", base = "right" } for each button
local padButtons
local function gamepadButtons()
	if padButtons then
		return padButtons
	end
	padButtons = {}
	for _, bar in ipairs(GAMEPAD_BARS) do
		for i = 1, bar[2] do
			local name = "GamepadMainActionBarFramePageUnit" .. bar[1] .. "ActionButton" .. i
			local button = _G[name]
			if button then
				local art = button.SlotArt and button.SlotArt.GetAtlas and button.SlotArt:GetAtlas() or ""
				local base
				for pattern, input in pairs(ART_INPUT) do
					if art:find(pattern) then
						base = input
					end
				end
				local label = barLabel(name)
				padButtons[#padButtons + 1] = {
					frame = button, label = label, bar = label:gsub(" %d+$", ""), base = base,
				}
			end
		end
	end
	return padButtons
end

-- The pad as the client maps it: modifiers held (triggers, shoulders, sticks,
-- sorted) and the d-pad and face buttons held. nil when there is no pad to read.
local function padState()
	if not (C_GamePad and C_GamePad.GetDeviceMappedState and C_GamePad.ButtonIndexToBinding) then
		return nil
	end
	local ok, state = pcall(C_GamePad.GetDeviceMappedState)
	if not ok or type(state) ~= "table" or type(state.buttons) ~= "table" then
		return nil
	end
	local modifiers, bases = {}, {}
	for index, down in pairs(state.buttons) do
		if down then
			-- state.buttons is a Lua array, from 1; ButtonIndexToBinding counts from 0.
			-- Measured: without the -1, L2 read as R2 and R2 as PADLSTICKUP.
			local name = C_GamePad.ButtonIndexToBinding(index - 1)
			if name then
				if name:find("^PADD") or name:find("^PAD%d") then
					bases[name] = true
				else
					modifiers[#modifiers + 1] = name
				end
			end
		end
	end
	table.sort(modifiers)
	return modifiers, bases
end

-- WowCompanionDB.chords[bar] = { [modifier] = presses }. chordStats counts every
-- d-pad or face press and how many lit an action button within a few frames: if
-- "lit" stays at zero, the pushed state is the wrong signal, and the export says so
-- instead of quietly learning nothing.
local CHORD_WINDOW = 0.25

-- The first learner read every button one place off (see padState). Its record is
-- still good once renamed: what it called R2 was L2, and PADLSTICKUP was R2.
local function fixFirstChords()
	if not WowCompanionDB.chords or WowCompanionDB.chordsFixed then
		WowCompanionDB.chordsFixed = true
		return
	end
	local renamed = { PADRTRIGGER = "PADLTRIGGER", PADLSTICKUP = "PADRTRIGGER" }
	for bar, seen in pairs(WowCompanionDB.chords) do
		local fixed = {}
		for chord, count in pairs(seen) do
			local parts = {}
			for part in chord:gmatch("[^+]+") do
				parts[#parts + 1] = renamed[part] or part
			end
			table.sort(parts)
			local key = table.concat(parts, "+")
			fixed[key] = (fixed[key] or 0) + count
		end
		WowCompanionDB.chords[bar] = fixed
	end
	WowCompanionDB.chordsFixed = true
end

-- every pushed button the UI has, by name: what lit when none of ours did
local function pushedElsewhere()
	local found = {}
	local frame, walked = EnumerateFrames(), 0
	while frame and walked < 50000 and #found < 4 do
		walked = walked + 1
		if frame.GetButtonState then
			local ok, state = pcall(frame.GetButtonState, frame)
			if ok and state == "PUSHED" then
				local named = frame.GetName and frame:GetName()
				found[#found + 1] = ("%s (action %s)"):format(tostring(named or frame:GetDebugName()), tostring(frame.action))
			end
		end
		frame = EnumerateFrames(frame)
	end
	return #found > 0 and table.concat(found, ", ") or "nothing pushed"
end

-- the presses that taught nothing, newest last, so the next reload shows why
local function missedChord(press)
	-- a face button alone is jump or interact, never a bar; twenty jumps would
	-- push out the one miss worth reading
	if press.chord == "none" and tostring(press.base):find("^PAD%d") then
		return
	end
	WowCompanionDB.chordMisses = WowCompanionDB.chordMisses or {}
	local misses = WowCompanionDB.chordMisses
	local form = GetShapeshiftForm and GetShapeshiftForm() or "?"
	misses[#misses + 1] = ("%s + %s, form %s, page %s: %s"):format(press.chord, press.base,
		tostring(form), tostring(C_ActionBar and C_ActionBar.GetActionBarPage and C_ActionBar.GetActionBarPage()),
		press.scanned or "not scanned")
	while #misses > 20 do
		table.remove(misses, 1)
	end
end

local function learnChords()
	fixFirstChords()
	local watcher = CreateFrame("Frame")
	local was, wasBase = {}, {}
	local pending -- the modifiers of the last base press, until a button lights or it expires
	watcher:SetScript("OnUpdate", function()
		local modifiers, bases = padState()
		if not modifiers then
			return
		end
		WowCompanionDB.chordStats = WowCompanionDB.chordStats or { presses = 0, lit = 0 }
		local stats = WowCompanionDB.chordStats
		for name in pairs(bases) do
			if not wasBase[name] then
				stats.presses = stats.presses + 1
				pending = {
					chord = #modifiers > 0 and table.concat(modifiers, "+") or "none",
					base = name, at = GetTime(), frames = 0,
				}
			end
		end
		wasBase = bases
		if pending then
			pending.frames = pending.frames + 1
			-- two frames and none of our buttons lit: look at everything once, while
			-- whatever did light is still held down
			-- (13,000 frames is a visible hitch; never in combat, and a jump is a miss too)
			if pending.frames == 3 and not pending.scanned and not InCombatLockdown() then
				pending.scanned = pushedElsewhere()
			end
			if GetTime() - pending.at > CHORD_WINDOW then
				missedChord(pending)
				pending = nil
			end
		end
		for _, entry in ipairs(gamepadButtons()) do
			local ok, state = pcall(entry.frame.GetButtonState, entry.frame)
			local pushed = ok and state == "PUSHED"
			if pushed and not was[entry.label] and pending then
				stats.lit = stats.lit + 1
				WowCompanionDB.chords = WowCompanionDB.chords or {}
				local bar = WowCompanionDB.chords[entry.bar] or {}
				bar[pending.chord] = (bar[pending.chord] or 0) + 1
				WowCompanionDB.chords[entry.bar] = bar
				pending = nil
			end
			was[entry.label] = pushed
		end
	end)
end

-- "L2+R2" from "PADLTRIGGER+PADRTRIGGER": the words the player says
local PAD_WORDS = {
	PADLTRIGGER = "L2", PADRTRIGGER = "R2", PADLSHOULDER = "L1", PADRSHOULDER = "R1",
	PADLSTICK = "L3", PADRSTICK = "R3",
}
local function spoken(chord)
	if chord == "none" then
		return "no modifier"
	end
	return (chord:gsub("PAD%u+", function(name) return PAD_WORDS[name] or name end))
end

-- bar -> modifier words, from the most-seen chord, or nil while none is learned
local function barModifier(bar)
	local seen = WowCompanionDB.chords and WowCompanionDB.chords[bar]
	if not seen then
		return nil
	end
	local best, most = nil, 0
	for chord, count in pairs(seen) do
		if count > most then
			best, most = chord, count
		end
	end
	return best and spoken(best), most
end

-- "L2+R2 + right", or "? + right" while the bar's modifier is unlearned
local function chordFor(label)
	for _, entry in ipairs(gamepadButtons()) do
		if entry.label == label then
			local modifier = barModifier(entry.bar)
			if modifier == "no modifier" then
				return entry.base or "?"
			end
			return ("%s + %s"):format(modifier or "?", entry.base or "?")
		end
	end
	return nil
end

-- slot -> { visible = bool, label = "LeftBar 3" } for every slot some frame draws.
-- The label is the first visible frame's, since several frames (edit mode, the
-- hidden classic bars) can point at the same slot.
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
		if slot and slot > 0 then
			local entry = slots[slot] or { visible = false }
			local shown = frame.IsVisible and frame:IsVisible() or false
			if shown and not entry.visible then
				entry.label = barLabel(frame.GetName and frame:GetName())
			end
			entry.visible = entry.visible or shown
			slots[slot] = entry
		end
		frame = EnumerateFrames(frame)
	end
	return slots
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
	line("-- addressed by number; empty slots omitted. 'on screen' names the bar that")
	line("-- draws it now; anything without it is stored but not shown")
	if HasAction and GetActionInfo then
		local frames = actionFrames()
		local filled = 0
		for slot = 1, LAST_ACTION_SLOT do
			if slotHas(slot) then
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
				local drawn = frames[slot]
				if drawn and drawn.visible then
					what = what .. " -- on screen: " .. tostring(drawn.label)
					local chord = chordFor(drawn.label)
					if chord then
						what = what .. " (" .. chord .. ")"
					end
				end
				line(("%3d: %s"):format(slot, what))
			end
		end
		line(("-- %d filled"):format(filled))

		section("empty slots on screen")
		line("-- where a new action can go and be seen")
		local open = {}
		for slot = 1, LAST_ACTION_SLOT do
			local drawn = frames[slot]
			if drawn and drawn.visible and not slotHas(slot) then
				local chord = chordFor(drawn.label)
				open[#open + 1] = ("%d (%s%s)"):format(slot, tostring(drawn.label),
					chord and (", " .. chord) or "")
			end
		end
		line(#open > 0 and table.concat(open, ", ") or "none")

		section("controller")
		line("-- the chord for each bar. Buttons 1-4 are the d-pad left, up, right, down;")
		line("-- 5-8 the face buttons square, triangle, circle, cross (from each button's")
		line("-- icon). The modifier is learned by watching which triggers are held when a")
		line("-- button fires; '?' means not seen yet, and is not to be guessed")
		for _, bar in ipairs(GAMEPAD_BARS) do
			local name = barLabel(bar[1] .. "ActionButton1"):gsub(" 1$", "")
			local modifier, presses = barModifier(name)
			line(("%s: %s"):format(name, modifier and ("%s (seen %d times)"):format(modifier, presses) or "?"))
		end
		-- Measured, and corrected by the player: the frames named StanceBar are not
		-- a bar of their own. They are the in-form page of whichever bar the
		-- GamepadStanceBarOverride setting names (here the R2 bar), which is why they
		-- learn the same chord. Switching forms is the L1+L2 wheel, not a slot.
		local byModifier = {}
		for _, bar in ipairs(GAMEPAD_BARS) do
			local name = barLabel(bar[1] .. "ActionButton1"):gsub(" 1$", "")
			local modifier = barModifier(name)
			if modifier then
				byModifier[modifier] = byModifier[modifier] or {}
				table.insert(byModifier[modifier], name)
			end
		end
		for modifier, names in pairs(byModifier) do
			if #names > 1 then
				line(("-- %s is shared by %s: StanceBar is that bar's page while in a form"
					.. " (cat, bear); out of form it is the other"):format(modifier, table.concat(names, " and ")))
			end
		end
		local form = GetShapeshiftForm and GetShapeshiftForm() or 0
		line(("form at export: %s"):format(form == 0 and "none (caster)" or ("%d"):format(form)))
		line(("GamepadStanceBarOverride: %s (the setting that picks which bar shows form actions)")
			:format(tostring(cvar("GamepadStanceBarOverride"))))
		line("-- changing form is the L1+L2 wheel, not an action slot")
		local stats = WowCompanionDB.chordStats
		if stats then
			line(("-- %d d-pad/face presses watched, %d lit a bar button"):format(stats.presses, stats.lit))
		end
		local misses = WowCompanionDB.chordMisses
		if misses and #misses > 0 then
			line("-- presses that lit none of these bars, newest last:")
			for _, miss in ipairs(misses) do
				line("--   " .. (miss:gsub("PAD%u+", function(name) return PAD_WORDS[name] or name end)))
			end
		end
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

	section("modules")
	line("-- Lua the agent stored; each runs at every login")
	local stored = {}
	for name in pairs(WowCompanionDB.modules or {}) do
		stored[#stored + 1] = name
	end
	table.sort(stored)
	for _, name in ipairs(stored) do
		line(name .. ":")
		line("    " .. (tostring(WowCompanionDB.modules[name].code):gsub(newline, newline .. "    ")))
	end
	if #stored == 0 then
		line("none")
	end

	section("code runs")
	line("-- the last runs of agent code this session and before, oldest first")
	local runs = WowCompanionDB.runs or {}
	for at = math.max(1, #runs - 9), #runs do
		local run = runs[at]
		line(("%s %s: %s; taint %s"):format(date("%H:%M:%S", run.at or 0), tostring(run.label),
			tostring(run.outcome), tostring(run.taint or "unchecked")))
		if run.printed and run.printed ~= "" then
			line("    " .. (run.printed:gsub(newline, newline .. "    ")))
		end
	end
	if #runs == 0 then
		line("none")
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
	for slot = 1, LAST_ACTION_SLOT do
		local drawn = frames[slot] and frames[slot].visible
		if not slotHas(slot) then
			if drawn and not picked.emptyVisible then
				picked.emptyVisible = slot
			elseif not frames[slot] and slot <= 120 and not picked.emptyHidden then
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
		for slot = 1, LAST_ACTION_SLOT do
			local ok, kind, id = pcall(GetActionInfo, slot)
			if ok and kind == "macro" and id == index then
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

-- One per UI session. Taint lasts until /reload, so a second test inherits the
-- first one's damage and the hand check cannot tell them apart -- which is how the
-- first full run was spoiled: chatopen's taint was still live for every test after it.
local placeRan
-- the test in flight, so a blocked-action notice can be pinned to it
local placeEntry

-- "Interface action failed because of an AddOn" is shown by this function, and it
-- fires even when ADDON_ACTION_BLOCKED does not reach us. hooksecurefunc runs after
-- the original without tainting it. Every hit is kept with its time, so the hand
-- check stops being the only witness.
if hooksecurefunc and DisplayInterfaceActionBlockedMessage then
	hooksecurefunc("DisplayInterfaceActionBlockedMessage", function()
		WowCompanionDB.blockedNotices = WowCompanionDB.blockedNotices or {}
		local stamp = date("%H:%M:%S")
		table.insert(WowCompanionDB.blockedNotices, stamp)
		if placeEntry then
			placeEntry.notices = (placeEntry.notices or 0) + 1
		end
		remember("probe", "interface action failed notice at " .. stamp
			.. (placeEntry and (" during place " .. placeEntry.variant) or ""))
	end)
end

local function placeTest(variant)
	local act = placeVariants[variant]
	if not act then
		return "variants: " .. table.concat(PLACE_ORDER, ", ")
	end
	if InCombatLockdown() then
		return "refused: in combat"
	end
	if placeRan and variant ~= "clean" then
		return ("refused: %s already ran this session; /reload first"):format(placeRan)
	end
	placeRan = variant
	WowCompanionDB.placeTests = WowCompanionDB.placeTests or {}
	local before, checked = taintScan()
	local ok, result = pcall(act, pickSlots())
	if not ok then
		result = "error: " .. tostring(result)
	end
	local entry = { at = time(), variant = variant, result = result, checked = checked }
	placeEntry = entry
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

-- Put a spell, macro or item on a bar slot, or empty one.
--
-- Cleared by measurement, not assumed: PlaceAction and PutActionInSlot into the
-- slots the gamepad UI draws (189, 202) newly tainted 0 of ~265,000 variables and
-- raised no blocked-action notice. Configuration, out of combat, like a macro.
--
-- Whatever the slot held comes back on the cursor and is dropped. It leaves the bar
-- only: spells stay in the spellbook, macros in the macro list. The reply names it,
-- so "put it back" has something to go on.
local function describeSlot(slot)
	local ok, kind, id = pcall(GetActionInfo, slot)
	if not ok or not kind then
		return "nothing"
	end
	if kind == "spell" then
		return "spell " .. tostring(spellName(id) or id)
	elseif kind == "macro" then
		return "macro " .. tostring(GetMacroInfo(id) or id)
	elseif kind == "item" then
		return "item " .. tostring(itemName(id) or id)
	end
	return tostring(kind) .. " " .. tostring(id)
end

function handlers.bar(inbox)
	if InCombatLockdown() then
		return "refused: in combat"
	end
	local slot = tonumber(inbox.slot)
	if not slot or slot < 1 or slot > LAST_ACTION_SLOT or slot ~= math.floor(slot) then
		return "refused: no valid slot"
	end
	local before = describeSlot(slot)
	local what, name = inbox.what, inbox.name
	ClearCursor()
	if what == "empty" then
		PickupAction(slot)
		ClearCursor()
		remember("claude", ("slot %d emptied (held %s)"):format(slot, before))
		return ("slot %d emptied, held %s"):format(slot, before)
	elseif what == "spell" then
		C_Spell.PickupSpell(tonumber(name) or name)
	elseif what == "macro" then
		local index = GetMacroIndexByName(name or "")
		if not index or index == 0 then
			return ("refused: no macro named %q"):format(tostring(name))
		end
		PickupMacro(index)
	elseif what == "item" then
		C_Item.PickupItem(tonumber(name) or name)
	else
		return "refused: what must be spell, macro, item or empty"
	end
	-- nothing on the cursor means the name did not resolve: do not place nothing,
	-- which would just empty the slot
	if not GetCursorInfo() then
		return ("refused: could not pick up %s %q"):format(tostring(what), tostring(name))
	end
	PlaceAction(slot)
	ClearCursor()
	local after = describeSlot(slot)
	remember("claude", ("slot %d now %s (was %s)"):format(slot, after, before))
	return ("slot %d: %s, was %s"):format(slot, after, before)
end

-- from the helper too, so the bell path is measured and not just the slash command
function handlers.place(inbox)
	return placeTest(inbox.variant or "")
end

-- Code the agent writes, run here.
--
-- This replaces "the model never writes Lua" with something that holds up better
-- than a rule: the client's own security. Insecure addon code cannot cast, target,
-- move or use protected actions at all -- that is what protection is -- so code
-- from the agent can do no more for the player than any addon they install. What
-- is left to guard is what the client does *not* protect, and two failure modes we
-- have actually hit:
--
--  * Things an addon may do that are not ours to do: delete items, send chat as the
--    player, spend gold, leave groups. Those names are refused in the environment
--    the code runs in. This is a guard against mistakes, not an adversary: Lua has
--    ways around an environment, and getfenv/loadstring, the obvious ones, are shut.
--  * Taint and crashes. Every run is followed by the same issecurevariable diff as
--    /wc place, so code that would break A and B says so by name, and nothing runs
--    in combat. A C-level crash cannot be caught; see /wc alive.
--
-- Code arrives two ways: `lua` runs once and reports what it printed and returned;
-- `module` is also stored in SavedVariables and run again at every login, which is
-- as close to the agent writing its own addon as the client allows without a
-- restart (new addon folders are only seen at launch).

local REFUSED = {
	DeleteCursorItem = true, SendChatMessage = true, BNSendWhisper = true,
	BNSendGameData = true, SendMail = true, AcceptTrade = true, InitiateTrade = true,
	BuyMerchantItem = true, BuybackItem = true, RepairAllItems = true,
	PlaceAuctionBid = true, Logout = true, Quit = true, ForceQuit = true,
	LeaveParty = true, GuildLeave = true, GuildDisband = true, GuildUninvite = true,
	AbandonQuest = true, SetAbandonQuest = true,
	RunScript = true, loadstring = true, load = true, getfenv = true, setfenv = true,
	C_AuctionHouse = true, C_TradeInfo = true, C_Mail = true,
}
-- inside namespaces we otherwise allow
local REFUSED_IN = {
	C_ChatInfo = { SendAddonMessage = true, SendChatMessage = true },
	C_Container = { UseContainerItem = true },
	C_PartyInfo = { LeaveParty = true, ConfirmLeaveParty = true },
	C_Macro = { RunMacroText = true },
}

-- globals that modules created, so a module may update its own but never replace
-- one of Blizzard's: overwriting a Blizzard global is a textbook taint source
local moduleGlobals = {}

local function refuse(name)
	return function()
		error(("%s is not available to companion code"):format(name), 2)
	end
end

local function sandbox(output)
	local env = {}
	local wrapped = {}
	setmetatable(env, {
		__index = function(_, key)
			if key == "_G" then
				return env
			elseif key == "print" then
				return function(...)
					local parts = {}
					for i = 1, select("#", ...) do
						parts[#parts + 1] = tostring((select(i, ...)))
					end
					local text = table.concat(parts, " ")
					-- after the run, from a slash command or an event the code set up:
					-- nobody is collecting any more, so straight to the window
					if output.done then
						remember("probe", text)
					else
						output[#output + 1] = text
					end
				end
			end
			if REFUSED[key] then
				return refuse(key)
			end
			local value = _G[key]
			local blocked = REFUSED_IN[key]
			if blocked and type(value) == "table" then
				wrapped[key] = wrapped[key] or setmetatable({}, {
					__index = function(_, name)
						if blocked[name] then
							return refuse(key .. "." .. name)
						end
						return value[name]
					end,
				})
				return wrapped[key]
			end
			return value
		end,
		__newindex = function(_, key, value)
			if rawget(_G, key) ~= nil and not moduleGlobals[key] then
				error(("refusing to replace the global %s"):format(tostring(key)), 2)
			end
			moduleGlobals[key] = true
			rawset(_G, key, value)
		end,
	})
	return env
end

local function results(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[#parts + 1] = tostring((select(i, ...)))
	end
	return table.concat(parts, ", ")
end

-- Run one chunk. Returns the outcome line now and, a moment later, reports any
-- taint it caused. Everything lands in the window and in WowCompanionDB.runs, which
-- reaches disk at the next reload -- the agent's way of seeing what happened.
local function runCode(label, code, quiet)
	if InCombatLockdown() then
		return "refused: in combat"
	end
	local chunk, syntax = loadstring(code, "=" .. label)
	if not chunk then
		remember("probe", ("%s did not compile: %s"):format(label, tostring(syntax)))
		return "syntax error: " .. tostring(syntax)
	end
	local output = {}
	setfenv(chunk, sandbox(output))
	-- the scan costs about a second; a module replayed at login was scanned when it
	-- was first written, so it skips it
	local before = not quiet and taintScan() or nil
	local ok, outcome = (function(okay, ...)
		return okay, okay and results(...) or tostring((...))
	end)(pcall(chunk))
	output.done = true
	local line = ok and ("ran" .. (outcome ~= "" and (", returned " .. outcome) or ""))
		or ("failed: " .. outcome)
	for _, printed in ipairs(output) do
		remember("probe", label .. ": " .. printed)
	end
	if not quiet or not ok then
		remember("probe", ("%s %s"):format(label, line))
	end
	WowCompanionDB.runs = WowCompanionDB.runs or {}
	local run = { at = time(), label = label, outcome = line, printed = table.concat(output, "\n") }
	table.insert(WowCompanionDB.runs, run)
	while #WowCompanionDB.runs > 50 do
		table.remove(WowCompanionDB.runs, 1)
	end
	if not before then
		return line
	end
	C_Timer.After(1.5, function()
		local after = taintScan()
		local fresh = {}
		for name, by in pairs(after) do
			if before[name] == nil and not moduleGlobals[name] then
				fresh[#fresh + 1] = ("%s (by %s)"):format(name, by)
			end
		end
		table.sort(fresh)
		run.taint = #fresh == 0 and "none" or table.concat(fresh, "; ")
		if #fresh > 0 then
			remember("probe", ("%s tainted %d variable(s): %s -- /reload clears it"):format(
				label, #fresh, table.concat(fresh, "; ", 1, math.min(#fresh, 4))))
		end
	end)
	return line
end

function handlers.lua(inbox)
	return runCode("code", inbox.code or "")
end

function handlers.module(inbox)
	local name = tostring(inbox.name or "")
	if not name:match("^[%w_]+$") then
		return "refused: a module name is letters, digits and underscores"
	end
	WowCompanionDB.modules = WowCompanionDB.modules or {}
	if inbox.remove then
		WowCompanionDB.modules[name] = nil
		remember("claude", ("module %s removed; what it already did stays until /reload"):format(name))
		return "removed " .. name
	end
	WowCompanionDB.modules[name] = { code = inbox.code or "", at = time() }
	return runCode("module " .. name, inbox.code or "")
end

-- at login: every stored module, in name order so the order is stable
local function loadModules()
	local names = {}
	for name in pairs(WowCompanionDB.modules or {}) do
		names[#names + 1] = name
	end
	table.sort(names)
	for _, name in ipairs(names) do
		runCode("module " .. name, WowCompanionDB.modules[name].code, true)
	end
end

-- A path we have not measured gets the issecurevariable diff the first time it
-- runs in a session, and says so in the window if it tainted anything. Kept in
-- WowCompanionDB.pathTaint, so the verdict survives into the export.
local measured = {}
local function measureOnce(label, action)
	if measured[label] or InCombatLockdown() then
		return action()
	end
	measured[label] = true
	local before = taintScan()
	action()
	C_Timer.After(1.5, function()
		local after = taintScan()
		local fresh = {}
		for name, by in pairs(after) do
			if before[name] == nil and not moduleGlobals[name] then
				fresh[#fresh + 1] = ("%s (by %s)"):format(name, by)
			end
		end
		table.sort(fresh)
		WowCompanionDB.pathTaint = WowCompanionDB.pathTaint or {}
		WowCompanionDB.pathTaint[label] = #fresh == 0 and "none" or table.concat(fresh, "; ")
		if #fresh > 0 then
			remember("error", ("%s tainted %d variable(s): %s -- /reload clears it"):format(
				label, #fresh, table.concat(fresh, "; ", 1, math.min(#fresh, 4))))
		end
	end)
end

-- "/g hi" placed by SetText still says Say: the box only reads its slash command
-- when a space is typed (OnSpacePressed -> ParseText(0)) or on send. Run the same
-- parse, so the header shows the channel before the player presses send.
onDictated = function(box)
	local text = box:GetText() or ""
	if text:find("^/%S+ ") and box.ParseText then
		measureOnce("chat channel", function()
			pcall(box.ParseText, box, 0)
		end)
	end
end

-- The controller's cancel takes the box's focus away, and Blizzard closes it then
-- only if it is empty (ShouldDeactivateChatOnEditFocusLost: GetText() == ""), so a
-- draft lingered and came back glued to the next line. Escape clears it, but that
-- is not what cancel does. EventRegistry tells addons the moment focus goes,
-- before that check, so emptying the box there lets Blizzard's own code close it.
-- Not while the gamepad chat menu is open: that takes focus too, and means to
-- come back.
local draftOwner = {}
if EventRegistry and EventRegistry.RegisterCallback then
	EventRegistry:RegisterCallback("ChatFrame.OnEditBoxFocusLost", function(_, box)
		if WowCompanionDB and WowCompanionDB.keepChatDraft then
			return
		end
		if not (box and box.GetText and box.SetText) or (box:GetText() or "") == "" then
			return
		end
		local chat = box.chatFrame
		if chat and chat.IsGamepadMenuOpen and chat:IsGamepadMenuOpen() then
			return
		end
		measureOnce("draft clear", function()
			box:SetText("")
		end)
	end, draftOwner)
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
		-- after login settles: modules may build frames on top of Blizzard's
		C_Timer.After(2, loadModules)
		-- read-only: polls the pad and the buttons' pushed state, hooks nothing
		pcall(learnChords)
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
	elseif command == "alive" then
		surveyApi()
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
