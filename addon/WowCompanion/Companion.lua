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
-- One offered button per conversation (the player, 2026-11-10): a Reload from
-- one agent replaced the Quit another had just offered. Each keeps its own; the
-- one secure button shows the offer of the conversation in view.
local offers = {}
-- the conversation of the message being handled, for the steps it carries
local offerSlot
-- the conversation of the message being handled, so what its steps report (code
-- ran, module ran, a failure) lands in that conversation, not whichever one is in
-- view: the main agent's results showed up in R2 (2026-11-10)
local replySlot
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

-- "m" names: see bell_name in src/main.rs
local function bellPath(n)
	return SIGNALS .. "m" .. ((n - 1) % BELLS + 1) .. ".wav"
end

-- catch-up bells: see catch_up_name in src/main.rs
local function catchUpPath(n)
	return SIGNALS .. "c" .. ((n - 1) % BELLS + 1) .. ".wav"
end

-- when this UI session began, to tell this session's messages from a slot's old one
local sessionStart = time()

-- The engine, the style helpers and the rest live in their own files (Engine.lua,
-- Style.lua, Pins.lua, Strip.lua, Bags.lua; the .toc's order). If one of them
-- failed to load, the channel here must still work: these keep it standing.
WC = WC or {}
WowCompanion_TalkKey = WowCompanion_TalkKey or "PADSOCIAL"
WowCompanion_Glyph = WowCompanion_Glyph or function(key) return key end


-- Every module to run, name -> { code, disk }. modules/<Name>.lua in the repo is
-- the source of truth, reaching the game as Modules.lua (WowCompanion_DiskModules,
-- reread at every /reload); WowCompanionDB.modules is the old store, kept for a
-- module sent before its file landed. The file wins (the player, 2026-11-10).
local function effectiveModules()
	local all = {}
	for name, entry in pairs(WowCompanionDB and WowCompanionDB.modules or {}) do
		if type(entry) == "table" and entry.code then all[name] = { code = entry.code } end
	end
	for name, code in pairs(type(WowCompanion_DiskModules) == "table" and WowCompanion_DiskModules or {}) do
		if type(code) == "string" then all[name] = { code = code, disk = true } end
	end
	return all
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

-- moved to Transcript.lua
local function newTranscript(...) return WC.Transcript.newTranscript(...) end
local function queueRequest(...) return WC.Transcript.queueRequest(...) end
local function queuedSlots(...) return WC.Transcript.queuedSlots(...) end
local function unqueue(...) return WC.Transcript.unqueue(...) end
-- moved to Window.lua
local function buildLog(...) return WC.Window.buildLog(...) end
local function logFrame()
	logWindow = logWindow or buildLog()
	return logWindow
end

-- moved to Board.lua
local function toast(...) return WC.Board.toast(...) end
local function toastBoard(...) return WC.Board.toastBoard(...) end
local function toastIdleShown(...) return WC.Board.toastIdleShown(...) end
-- ShowUIPanel, so the window joins the controller's focus cycle (see buildLog).
-- It is refused in combat, where a plain Show at least puts the text in front of
-- them; the manager is not told, so nothing is left for it to forget.
local function reveal(frame)
	toast(nil)
	if not InCombatLockdown() and UIPanelWindows and UIPanelWindows["WowCompanionLog"] then
		ShowUIPanel(frame)
	end
	if not frame:IsShown() then
		frame:Show()
	end
end

local function colouredFor(who)
	if who == "you" then
		return "|cff9ad5ff"
	elseif who == "error" then
		return "|cffff7777"
	end
	return "|cffffe08a"
end

local function showLine(who, text, continued, at, queued)
	logFrame().messages:Add(who, text, continued, at, queued)
end

-- Spinning while the agent thinks. Several seconds of silence after you speak is
-- indistinguishable from a broken channel, which is the whole reason this exists.
-- when the current wait began: kept across progress updates, so the count is the
-- whole request, not the time since the last "reading ..."
local pendingSince
-- One waiting line per conversation (the player, 2026-11-10): several agents can
-- work at once, and one shared line muddled them. Each slot keeps its own text
-- and start time; the toast shows a labelled line for every one at work, and
-- the window's line shows the conversation in view.
local working = {}
local SLOT_ORDER = { "", "l1", "l2", "r1", "r2", "quick" }
local function slotLabel(slot) return slot == "" and "Main" or slot == "quick" and "Quick" or slot:upper() end
local renderPending
-- the last reply or error per conversation, shown in its row for a while
local recent, RECENT_FOR = {}, 30
function WowCompanion_Recent(slot, text)
	recent[slot or ""] = { text = text, at = GetTime() }
	if renderPending then renderPending() end
end
local paintHook -- the conversation list's painter, set once it exists
-- A clip on its way through Whisper, per conversation (the player, 2026-11-10):
-- the list, the waiting line and the toast show it beside the agent's own
-- progress. Started by a `transcribing` message the moment the pad is released;
-- ended by what the words became (the request's own line, a chat line, a
-- dropped-clip notice), or after TRANSCRIBE_FOR in case that line never comes.
local transcribing, TRANSCRIBE_FOR = {}, 60
local function setTranscribing(slot, on)
	if slot then
		transcribing[slot] = on and (transcribing[slot] or GetTime()) or nil
	else
		wipe(transcribing)
	end
	if renderPending then renderPending() end
end
-- `age`: seconds the work has already run, when the companion retells it after a
-- reload, so the board shows the real time instead of starting over at 0
local function setPending(text, slot, age)
	slot = slot or ""
	if text then
		local entry = working[slot] or { since = GetTime() - (tonumber(age) or 0) }
		entry.text = text
		working[slot] = entry
	else
		working[slot] = nil
	end
	renderPending()
end
local turn = 0
renderPending = function()
	local frame = logFrame()
	local lines, view = {}, nil
	turn = turn + 1
	local dots = ("."):rep(turn % 4)
	local now = GetTime()
	-- One row per conversation with something going on, readable at a glance
	-- (the player, 2026-11-10): the name in its state's colour, the state and
	-- its seconds, then the detail in grey. Blue is hearing you (Whisper has the
	-- clip), gold is working, green has answered, red went wrong.
	local function clip(text, n)
		text = tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
		if #text > n then text = text:sub(1, n - 3) .. "..." end
		return text
	end
	local function row(slot, colour, state, detail)
		local r = tonumber(colour:sub(1, 2), 16) / 255
		local g = tonumber(colour:sub(3, 4), 16) / 255
		local b = tonumber(colour:sub(5, 6), 16) / 255
		return { slotLabel(slot), state, clip(detail, 90), r, g, b }
	end
	for _, slot in ipairs(SLOT_ORDER) do
		local entry = working[slot]
		local done = recent[slot]
		if done and now - done.at > RECENT_FOR then recent[slot] = nil done = nil end
		local heard = transcribing[slot]
		if heard and now - heard > TRANSCRIBE_FOR then transcribing[slot] = nil heard = nil end
		local line
		if heard then
			line = row(slot, "9ad5ff", ("hearing %ds"):format(now - heard), entry and entry.text)
		elseif entry then
			line = row(slot, "ffd100", ("working %ds"):format(now - entry.since), entry.text .. dots)
		elseif done then
			local bad = done.text:find("ff7777", 1, true)
			line = row(slot, bad and "ff6060" or "40ff40", bad and "problem" or "replied", done.text)
		end
		if line then
			lines[#lines + 1] = line
			if (heard or entry) and slot == (WowCompanion_ViewSlot and WowCompanion_ViewSlot() or "") then
				view = entry and ("%s%s  %ds"):format(entry.text, dots, now - entry.since)
					or ("hearing you  %ds"):format(now - heard)
			end
		end
	end
	if paintHook then paintHook() end
	pendingSince = view and GetTime() or nil
	frame.pendingShown = view ~= nil
	if view then
		frame.pending:SetText(view)
		if (frame.currentTab or 1) == 1 then frame.pending:Show() end
	else
		frame.pending:Hide()
	end
	if #lines > 0 then
		if not frame:IsShown() then
			toastBoard(lines)
		end
		if not pendingTicker then pendingTicker = C_Timer.NewTicker(0.4, function() renderPending() end) end
	else
		if pendingTicker then pendingTicker:Cancel() pendingTicker = nil end
		if toastIdleShown() then toast(nil) end
	end
end

-- Kept in SavedVariables, so it is written on /reload or logout like everything else.
-- Conversations (the player, 2026-11-10): the talk button alone is the main one
-- (""), and with a trigger held each of L1, L2, R1, R2 is its own. Every line
-- remembers which it belongs to; the window shows one at a time, picked with the
-- buttons above the transcript, and a slot with news it has not shown glows.
local CONVERSATIONS = { "", "l1", "l2", "r1", "r2", "quick" }
local viewSlot = ""
-- which conversations have news not yet looked at, kept in SavedVariables so a
-- reload does not forget a reply waiting in another conversation (the player,
-- 2026-11-10). Read through this, since WowCompanionDB exists only once loaded.
local function unreadSet()
	if type(WowCompanionDB) ~= "table" then return {} end
	WowCompanionDB.unread = WowCompanionDB.unread or {}
	return WowCompanionDB.unread
end
local function paintConversations()
	local frame = logWindow
	if not (frame and frame.convButtons) then return end
	for key, button in pairs(frame.convButtons) do
		local label = slotLabel(key)
		-- each conversation shows its own progress in the list (the player,
		-- 2026-11-10): the seconds while its agent works, "new" once it answered
		local entry = working[key]
		local heard = transcribing[key]
		if heard then
			-- Whisper still has this conversation's clip (the player, 2026-11-10)
			label = label .. "  |cff9ad5ff" .. math.floor(GetTime() - heard) .. "s|r"
		elseif entry then
			label = label .. "  |cffb0b0b0" .. math.floor(GetTime() - entry.since) .. "s|r"
		elseif unreadSet()[key] then
			label = "|cff40ff40" .. label .. "  new|r"
		end
		button:SetText(label)
		if button.selected then button.selected:SetShown(key == viewSlot) end
	end
end

paintHook = paintConversations

local function remember(who, text, continued, slot, queued)
	slot = slot or replySlot or viewSlot
	WowCompanionDB.log = WowCompanionDB.log or {}
	local entries = WowCompanionDB.log
	entries[#entries + 1] = { at = time(), who = who, text = text, continued = continued or nil,
		slot = slot ~= "" and slot or nil, queued = queued }
	while #entries > LOG_KEEP do
		table.remove(entries, 1)
	end
	if slot == viewSlot then
		showLine(who, text, continued, entries[#entries].at, queued)
	elseif not continued and who ~= "you" then
		unreadSet()[slot] = true
		paintConversations()
	end
end

local function replayLog()
	local messages = logFrame().messages
	messages:Hold(true)
	for _, entry in ipairs(WowCompanionDB.log or {}) do
		if (entry.slot or "") == viewSlot then
			showLine(entry.who or "claude", entry.text or "", entry.continued, entry.at, entry.queued)
		end
	end
	messages:Hold(false)
end

function WowCompanion_ViewSlot() return viewSlot end

function WowCompanion_SetConversation(slot)
	viewSlot = slot or ""
	unreadSet()[viewSlot] = nil
	-- the button follows the view: each conversation shows its own offer
	if WowCompanion_ShowOffer then WowCompanion_ShowOffer(viewSlot) end
	if renderPending then renderPending() end
	logFrame().messages:Clear()
	replayLog()
	paintConversations()
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
local function buildActionButton()
	local frame = logFrame()
	if not actionButton then
		local made, button = pcall(CreateFrame, "Button", "WowCompanionDo", frame,
			"SecureActionButtonTemplate, UIPanelButtonTemplate")
		if not made or not button then
			return "could not build the button: " .. tostring(button)
		end
		actionButton = button
		-- at the foot of the conversation list, the list's width, under its
		-- buttons (the player, 2026-11-10): it belongs to the conversation in view
		local last = frame.convButtons and (frame.convButtons.quick or frame.convButtons.r2)
		if last then
			actionButton:SetSize(last:GetWidth(), 24)
			actionButton:SetPoint("TOP", last, "BOTTOM", 0, -10)
			actionButton:SetFrameLevel(last:GetFrameLevel() + 2)
		else
			actionButton:SetSize(150, 22)
			actionButton:SetPoint("BOTTOMRIGHT", -18, 8)
		end
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
			if self.slot then offers[self.slot] = nil end
			self:Hide()
		end)
	end
	return frame
end

-- Put the view's offer on the button, or take the button away when it has none.
-- Secure attributes cannot change in combat; the button then stays as it was
-- until the next switch.
local function showOffer(slot)
	if InCombatLockdown() then return "in combat" end
	local held = offers[slot]
	if not held then
		if actionButton then
			if ClearOverrideBindings then ClearOverrideBindings(actionButton) end
			actionButton.slot = nil
			actionButton:Hide()
		end
		return "nothing"
	end
	local label, macro = held.label, held.macro
	buildActionButton()
	if not actionButton then return "nothing" end
	actionButton.slot = slot
	actionButton:SetAttribute("macrotext", macro)
	actionButton:SetText(label)
	actionButton:Show()

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
	return bound
end
WowCompanion_ShowOffer = showOffer

local function offer(label, macro, slot)
	-- attributes on a secure frame cannot be set in combat, and this is
	-- configuration anyway
	if InCombatLockdown() then
		return "refused: in combat"
	end
	slot = slot or offerSlot or viewSlot
	offers[slot] = { label = label, macro = macro }
	local where = slotLabel(slot)
	if slot ~= viewSlot then
		-- the view never jumps on its own: the button waits in its conversation
		remember("claude", ("button |cffffffff%s|r runs |cff9ad5ff%s|r — it waits in this conversation")
			:format(label, macro), nil, slot)
		toast(("|cffffd100%s|r  has a button for you: |cffffffff%s|r (open %s)"):format(where, label, where),
			0.8, 0.8, 0.8, 30)
		return ("offering %q in %s, not in view"):format(label, where)
	end
	local bound = showOffer(slot)
	-- show the macro, not just the label: the player is the one authorising this, and
	-- "Do it" tells them nothing about what they would be running
	remember("claude", ("button |cffffffff%s|r runs |cff9ad5ff%s|r — %s or click it")
		:format(label, macro, bound ~= "nothing" and ("press " .. bound) or "mouse"), nil, slot)
	toast(("|cffffd100Claude|r  %s: |cffffffff%s|r"):format(
		bound ~= "nothing" and ("press " .. bound) or "open the window", label), 0.8, 0.8, 0.8, 30)
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
-- channel slash commands as said aloud, for the send preview and the chat line
local CHANNEL_NAMES = {
	["/p"] = "party", ["/g"] = "guild", ["/o"] = "officer", ["/raid"] = "raid",
	["/rw"] = "raid warning", ["/i"] = "instance", ["/s"] = "say", ["/y"] = "yell",
	["/r"] = "your last whisper", ["/e"] = "emote",
	["/1"] = "General", ["/2"] = "Trade", ["/4"] = "Looking For Group",
}

-- moved to Chat.lua
local function showPreview(...) return WC.Chat.showPreview(...) end
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
	-- a line spoken with a channel goes to the send preview, chat box or not
	do
		local text = inbox.text or ""
		local slash, rest = text:match("^(/%w+)%s+(.+)")
		if slash and inbox.raw and inbox.raw ~= text and not InCombatLockdown() then
			local line, heading, shown = text, "Send to " .. (CHANNEL_NAMES[slash] or slash), rest
			if slash == "/w" or slash == "/whisper" then
				local target, message, label = WowCompanion_ResolveWhisper(rest)
				if not target then
					remember("error", "Whisper not ready: " .. message .. ".")
					return "refused: " .. message
				end
				line, heading, shown = "/w " .. target .. " " .. message, "Whisper to " .. label, message
			end
			if #line <= 255 and showPreview(line, heading, shown) then
				return ("preview: %q"):format(line)
			end
		end
	end
	-- Any text box the player put the cursor in takes dictation: the auction
	-- house search, a mail recipient, a search field. They focused it, so setting
	-- its text is what typing would do, as with chat. Other boxes get the words
	-- as said; only chat gets them as a slash command ("guild bank" stays that in
	-- a search box, and becomes /g bank only in chat).
	local focused = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
	local chatBox = activeEditBox()
	if focused and focused ~= chatBox and focused.SetText and focused.GetText
		and focused.IsObjectType and focused:IsObjectType("EditBox") and focused:IsVisible() then
		focused:SetText((focused:GetText() or "") .. (inbox.raw or inbox.text or ""))
		return ("%s holds %q"):format(tostring(focused:GetName() or "a text box"), focused:GetText())
	end
	local box = chatBox
	if not box or not box:IsVisible() then
		-- in the window, where it is seen: opening the box ourselves is what broke
		-- A and B, so the player opens it and speaks again
		remember("error", "No text box open, so nothing was written. Open chat or click into a search box, then speak.")
		return "refused: no text box open"
	end
	-- append, so speaking twice builds a line instead of replacing it. Not echoed
	-- into the window: that is the conversation with the agent, and dictation is
	-- the player talking to other players
	local text = inbox.text or ""
	local rest = text:match("^/w%s+(.+)") or text:match("^/whisper%s+(.+)")
	if rest then
		local target, message, label = WowCompanion_ResolveWhisper(rest)
		if not target then
			remember("error", "Whisper not written: " .. message .. ".")
			return "refused: " .. message
		end
		text = "/w " .. target .. " " .. message
		toast("|cffffd100Whisper|r to " .. label .. ": press send when it reads right", 0.9, 0.9, 0.9, 8)
	end
	box:SetText((box:GetText() or "") .. text)
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
	-- the conversation a line belongs to; lines that name none (chat lines,
	-- notices) go to whichever is in view
	local islot = inbox.slot or viewSlot
	-- the view never jumps on its own (the player, 2026-11-10): a reply in
	-- another conversation lights it up in the list, and what you said does not
	-- `pending` starts this conversation's waiting line; a line without it ends it
	-- a queued request leaves the running one's waiting line alone
	local queued = inbox.queued and queueRequest(islot) or nil
	if (inbox.slot or inbox.pending) and not queued then setPending(inbox.pending, islot) end
	-- what a clip became ends its "transcribing": the request's own line in its
	-- conversation, or a line that names none (a chat line, a dropped-clip
	-- notice), which cannot say whose clip it was and so ends them all
	if inbox.slot then
		if who == "you" then setTranscribing(inbox.slot, false) end
	elseif who == "you" or who == "error" then
		setTranscribing(nil)
	end
	-- "got it, transcribing" from an older helper has no conversation yet:
	-- whatever line comes next (the request in its slot, a chat line, a
	-- dropped-clip notice) ends it
	if islot ~= "" or not inbox.slot then
		local early = working[""]
		if early and early.text == "got it, transcribing" and not (inbox.slot == "" and inbox.pending) then
			setPending(nil, "")
		end
	end
	-- a reply arrives as one message but reads as many lines, and AddMessage takes
	-- one line at a time; blank lines are kept because they carry the paragraphs
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		remember(who, line, lines > 0, islot, lines == 0 and queued or nil)
		lines = lines + 1
	end
	if lines == 0 then
		remember(who, text, nil, islot, queued)
	end
	-- reveal, not Show: ShowUIPanel returns at once for a frame already shown, so a
	-- window opened by a plain Show never becomes a panel and the controller's
	-- window toggle cannot reach it until it is closed and opened again
	-- never opens the window: a reply's first line shows as a toast, errors in
	-- red, and step results and code output only go in the log
	if not (logWindow and logWindow:IsShown()) then
		local first = text:match("^%s*([^\n]+)") or ""
		first = first:gsub("%*%*", ""):gsub("`", "")
		if #first > 110 then first = first:sub(1, 107) .. "..." end
		-- a row of its own in the toast, under its conversation's label, so
		-- the other agents' rows stay visible beside it
		if who == "claude" and first ~= "" then
			WowCompanion_Recent(islot, first)
		elseif who == "error" and first ~= "" then
			WowCompanion_Recent(islot, "|cffff7777" .. first .. "|r")
		end
	end
	return ("logged %d line(s)"):format(lines)
end

-- A tap of the ask button (minus) opens the window, as a panel so the
-- controller's focus cycle reaches it. In combat it is a plain Show (see reveal).
-- The game hears the minus button itself (the DualSense Create button is
-- PADSOCIAL), so a tap toggles the window at once instead of waiting a second for
-- the helper's message. Holding minus is still push-to-talk on the PC, so only a
-- short press toggles: down and up are timed, and a hold does nothing here.
-- Override bindings are an addon's own layer and only while it is loaded, so the
-- player's binding underneath is untouched.
local TAP_MAX = 0.35
local nativeToggleAt = 0
local function toggleWindow()
	local frame = logFrame()
	if frame:IsShown() then
		frame:Hide() -- plain Hide; see the /wc log note on HideUIPanel
	else
		reveal(frame)
	end
end
local tapButton = CreateFrame("Button", "WowCompanionTap", UIParent)
tapButton:RegisterForClicks("AnyDown", "AnyUp")
tapButton:SetScript("OnClick", function(self, _, down)
	if down then
		self.downAt = GetTime()
		self.slot = WowCompanion_PadSlot and WowCompanion_PadSlot() or nil
	elseif self.downAt and GetTime() - self.downAt > TAP_MAX then
		-- a hold is a clip on its way to Whisper: show it as transcribing the
		-- moment the button comes up, instead of after the PC's message lands
		-- (the player, 2026-11-10). The PC's own messages take over from here.
		local slot = self.slot or (WowCompanion_PadSlot and WowCompanion_PadSlot()) or ""
		self.downAt = nil
		if setTranscribing then setTranscribing(slot, true) end
		if renderPending then renderPending() end
	elseif self.downAt and GetTime() - self.downAt <= TAP_MAX then
		self.downAt = nil
		nativeToggleAt = GetTime()
		toggleWindow()
	else
		self.downAt = nil
	end
end)
local function bindTap()
	if InCombatLockdown() or not SetOverrideBindingClick then return end
	ClearOverrideBindings(tapButton)
	SetOverrideBindingClick(tapButton, false, WowCompanion_TalkKey, "WowCompanionTap", "LeftButton")
end

-- `/wc talkkey`, then press the talk button: the game's name for it (PADSOCIAL,
-- PADBACK...) is learned and kept, so the tap that opens the window, and every
-- prompt naming the button, follow any controller. The PC side learns its own
-- view of the same button in the setup window.
local talkKeyFrame
local function learnTalkKey()
	if not talkKeyFrame then
		talkKeyFrame = CreateFrame("Frame", nil, UIParent)
		talkKeyFrame:SetScript("OnGamePadButtonDown", function(self, button)
			self:EnableGamePadButton(false)
			WowCompanionDB.talkKey = button
			WowCompanion_TalkKey = button
			pcall(bindTap)
			say(("talk button learned: %s (%s)"):format(WowCompanion_Glyph(button), button))
		end)
	end
	talkKeyFrame:EnableGamePadButton(true)
	say("press your talk button on the controller now")
end

-- The helper's own tap message, about a second later: ignored when the game
-- already handled that tap, or it would undo the toggle.
function handlers.show()
	if GetTime() - nativeToggleAt < 4 then
		return "already toggled in game"
	end
	reveal(logFrame())
	return "shown"
end

-- What the agent is doing right now, on the waiting line: "reading StanceBar.lua".
-- Not logged; the reply is what stays.
function handlers.progress(inbox)
	-- the agent took the oldest queued request of this conversation
	if inbox.started then unqueue(inbox.slot) end
	setPending(inbox.text or "thinking", inbox.slot, inbox.since)
	return "progress"
end

-- After a reload the companion says which conversations are still working
-- (`resync` in src/main.rs). It is the whole truth: one restored from the save
-- but not listed here has finished since, and is cleared.
function handlers.board(inbox)
	local listed = {}
	for _, e in ipairs(inbox.working or {}) do
		if type(e) == "table" and e.slot then
			listed[e.slot] = true
			setPending(e.text or "thinking", e.slot, e.since)
		end
	end
	for slot in pairs(working) do
		if not listed[slot] then working[slot] = nil end
	end
	-- nothing running in a conversation: nothing in it is still queued
	for slot in pairs(queuedSlots()) do
		if not listed[slot] then unqueue(slot, true) end
	end
	renderPending()
	return "board"
end

-- A clip released and handed to Whisper, for the conversation it belongs to
-- ("" is the main one): shown in the list and on the waiting line until the
-- words arrive.
function handlers.transcribing(inbox)
	setTranscribing(inbox.slot or "", true)
	return "transcribing"
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
function handlers.reload(inbox)
	return offer("Reload UI", "/reload", inbox and inbox.slot)
end

-- Whatever the helper asks for, as a button the player presses. The macro text is
-- the limit of what this can do, which is also the limit of what the player could
-- type themselves -- so it grants no power they did not already have.
function handlers.press(inbox)
	return offer(inbox.label or "Do it", inbox.macro or "", inbox.slot)
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

-- `catchingUp`: the slot was taken on a catch-up bell, so it must have been
-- written this session; one left from an earlier session is skipped, not run.
-- Returns false when the slot was not taken.
local function receive(catchingUp)
	local slot = nextSlot
	nextSlot = nextSlot + 1
	local loaded, reason = C_AddOns.LoadAddOn(slotName(slot))
	local inbox = WowCompanion_Inbox
	local sent = WowCompanion_Sent
	WowCompanion_Inbox = nil
	WowCompanion_Sent = nil
	if not loaded or not inbox then
		record("slot " .. slot, "failed: " .. tostring(reason))
		return false
	end
	if catchingUp and (type(sent) ~= "number" or sent < sessionStart - 5) then
		record("slot " .. slot, "catch-up found an earlier session's message; skipped")
		return false
	end
	local handler = handlers[inbox.kind or ""]
	if not handler then
		record("slot " .. slot, "unknown kind: " .. tostring(inbox.kind))
		return
	end
	replySlot = inbox.slot
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
		-- a button among the follow-up's steps belongs to the reply's conversation
		offerSlot = inbox.slot
		local done, outcome = pcall(handlers[following.kind], following)
		offerSlot = nil
		if not done then
			record("slot " .. slot .. " follow-up", "error: " .. tostring(outcome))
		end
		report(following, done, outcome)
	end
	replySlot = nil
end

-- An error anywhere in polling or handling a message is caught, said once in the
-- window, and polling goes on. Unguarded, one error could stop the companion
-- hearing anything until a /reload, which is what "the communication layer is
-- broken again" looked like from the player's side.
local reportedFailures = {}
local function safely(label, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		local key = label .. tostring(err)
		if not reportedFailures[key] then
			reportedFailures[key] = true
			pcall(remember, "error", ("%s failed: %s"):format(label, tostring(err)))
		end
	end
end


-- What the poll has seen, exported at every reload, so a stuck channel can be
-- read from the save file instead of guessed at.
local channel = { polls = 0, heard = 0, caughtUp = 0 }
local loadedAt = GetTime()
local catchUpTurn = 0

-- The message bell: one at a time, the next slot's, as on 2026-11-09. Polling
-- more message bells at once (the next one, then all eight) kept every bell file
-- open in the game and the companion could no longer write them (2026-11-10).
local function poll()
	channel.polls = channel.polls + 1
	channel.lastPoll = time()
	channel.waitingOn = nextSlot
	local waiting = nextSlot
	safely("bell poll", listen, bellPath(waiting), function(rang)
		if rang and nextSlot == waiting then
			channel.heard = channel.heard + 1
			safely("a message from the companion", receive)
		end
	end)
	-- The catch-up bells, beside the message bells: one per poll, in turn over
	-- this slot and the next 6 (never the 8th, which is the bell of the slot just
	-- taken, left ringing). Only after a message has been heard this session, when
	-- the companion has cleared the last session's catch-up bells (its heartbeat
	-- does within 4 s of the save), or 10 s after loading: messages sent during a
	-- loading screen often miss their 2 s bell, and waiting for a first one heard
	-- left those lost.
	if channel.heard > 0 or GetTime() - loadedAt > 10 then
		local ahead = catchUpTurn
		catchUpTurn = (catchUpTurn + 1) % (BELLS - 1)
		channel.catchUpPolls = (channel.catchUpPolls or 0) + 1
		safely("catch-up poll", listen, catchUpPath(waiting + ahead), function(rang)
			if rang then
				-- every ring, taken or not, so a catch-up that should have fired can be told apart
				channel.catchUpRang = (channel.catchUpRang or 0) + 1
				channel.lastCatchUpRang = ("c%d while waiting on %d (next %d) at %s"):format(
					(waiting + ahead - 1) % BELLS + 1, waiting, nextSlot, date("%H:%M:%S"))
			end
			if rang and nextSlot == waiting then
				channel.caughtUp = channel.caughtUp + 1
				channel.lastCaughtUp = ("waiting on slot %d, took %d at %s"):format(waiting, ahead + 1, date("%H:%M:%S"))
				for _ = 0, ahead do
					local ok, taken = pcall(receive, true)
					if not ok or taken == false then
						break
					end
				end
			end
		end)
	end
end

-- Polled from OnUpdate, which WoW keeps calling whatever happened the frame
-- before, rather than a C_Timer ticker, which a callback error may cancel for
-- good. `ticker` keeps its shape (truthy while polling, :Cancel() to stop) so
-- /wc quiet and /wc listen are unchanged.
local pollFrame = CreateFrame("Frame")
local sincePoll = 0
local function startPolling()
	sincePoll = 0
	pollFrame:SetScript("OnUpdate", function(_, elapsed)
		sincePoll = sincePoll + elapsed
		if sincePoll >= 0.5 then
			sincePoll = 0
			poll()
		end
	end)
	return {
		Cancel = function()
			pollFrame:SetScript("OnUpdate", nil)
		end,
	}
end

-- moved to Probes.lua
local function cvar(...) return WC.Probes.cvar(...) end
local function dumpApi(...) return WC.Probes.dumpApi(...) end
local function dumpDocs(...) return WC.Probes.dumpDocs(...) end
local function probeApi(...) return WC.Probes.probeApi(...) end
local function probeGamepad(...) return WC.Probes.probeGamepad(...) end
local function probeSound(...) return WC.Probes.probeSound(...) end
local function surveyApi(...) return WC.Probes.surveyApi(...) end
-- moved to Chords.lua
local LAST_ACTION_SLOT = 1024
local function actionFrames(...) return WC.Chords.actionFrames(...) end
local function itemName(...) return WC.Chords.itemName(...) end
local function learnChords(...) return WC.Chords.learnChords(...) end
local function slotHas(...) return WC.Chords.slotHas(...) end
local function spellName(...) return WC.Chords.spellName(...) end
local function spoken(...) return WC.Chords.spoken(...) end
local function noteForms() return WC.Export.NoteForms() end
local function exportContext() return WC.Export.Context() end

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
	-- C functions that take or return a vector or a color look its mixin up in
	-- the calling code's environment directly, so the proxy below is not
	-- enough: "unable to find mixin or metatable (Vector2DMixin)". Put the
	-- mixins the API needs into the environment itself.
	for _, name in ipairs({ "Vector2DMixin", "Vector3DMixin", "ColorMixin", "ItemLocationMixin",
		"ItemTransmogInfoMixin", "PlayerLocationMixin", "TransmogLocationMixin" }) do
		if _G[name] ~= nil then rawset(env, name, _G[name]) end
	end
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
	local whose = replySlot
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
				label, #fresh, table.concat(fresh, "; ", 1, math.min(#fresh, 4))), nil, whose)
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
	local all = effectiveModules()
	local names = {}
	for name in pairs(all) do
		names[#names + 1] = name
	end
	table.sort(names)
	for _, name in ipairs(names) do
		runCode("module " .. name, all[name].code, true)
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
		-- the chat frames' fade clock is written by every line any addon prints to
		-- chat, and nothing protected reads it; it stays in pathTaint for the
		-- export, but is not worth a red line in the window every session
		local shown = {}
		for _, entry in ipairs(fresh) do
			if not entry:find("%.oldestFadingLineTimestamp ") then
				shown[#shown + 1] = entry
			end
		end
		if #shown > 0 then
			remember("error", ("%s tainted %d variable(s): %s -- /reload clears it"):format(
				label, #shown, table.concat(shown, "; ", 1, math.min(#shown, 4))))
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

-- Lua errors, so the agent sees what its code broke instead of writing blind.
-- Blizzard's own hook for this (AddLuaErrorHandler) is secure-only, and replacing
-- the error handler would run Blizzard's error window tainted. A post-hook on the
-- method its handler ends in (ScriptErrors:AddUnhandledError) gets the message,
-- the stack and the locals without touching that path. Only errors whose stack
-- names a non-Blizzard addon are kept: Blizzard's own are not ours to fix.
local ERRORS_KEPT = 25
local function keepError(_, message, stack)
	message = tostring(message or "")
	stack = tostring(stack or "")
	local where = message .. "\n" .. stack
	local foreign = false
	for addon in where:gmatch("AddOns[/\\]([%w_%-]+)") do
		if not addon:find("^Blizzard_") then
			foreign = true
			break
		end
	end
	if not foreign then
		return
	end
	WowCompanionDB.errors = WowCompanionDB.errors or {}
	local errors = WowCompanionDB.errors
	for _, seen in ipairs(errors) do
		if seen.message == message then
			seen.count = (seen.count or 1) + 1
			seen.at = time()
			return
		end
	end
	-- the first lines of a stack say where; the rest is the engine's frames
	local lines, kept = {}, 0
	for text in stack:gmatch("[^\n]+") do
		kept = kept + 1
		if kept > 8 then
			break
		end
		lines[#lines + 1] = text
	end
	errors[#errors + 1] = { at = time(), count = 1, message = message:sub(1, 400), stack = table.concat(lines, "\n") }
	while #errors > ERRORS_KEPT do
		table.remove(errors, 1)
	end
end

local function watchErrors()
	if ScriptErrors and ScriptErrors.AddUnhandledError then
		hooksecurefunc(ScriptErrors, "AddUnhandledError", function(...)
			pcall(keepError, ...)
		end)
		-- hooked once: from here on this does nothing
		watchErrors = function() end
	end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
-- fires on /reload as well as logout, just before SavedVariables is written: the
-- one moment worth exporting at, since nothing reaches disk any other time
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("ADDON_ACTION_BLOCKED")
frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
-- the spellbook shows a form's own spells only while in it
frame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
frame:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		-- Blizzard_ScriptErrors may load before or after us
		pcall(watchErrors)
	end
	if event == "UPDATE_SHAPESHIFT_FORM" then
		-- a moment later, once the book has swapped its entries
		C_Timer.After(0.2, function() pcall(noteForms) end)
		return
	end
	if event == "ADDON_LOADED" and ... == ADDON then
		WowCompanionDB = WowCompanionDB or {}
		-- the game saves before it reloads, so hold on to the session we just read
		-- from disk or a second /reload discards the run we were trying to measure
		WowCompanionDB.previous = WowCompanionDB.probe
		WowCompanionDB.probe = {}
		-- Messages sent during the loading screen belong to this session: its
		-- boundary is the save the reload wrote, not when this file ran. A load
		-- slower than 5 s had a catch-up skip them as an earlier session's
		-- (seen 2026-11-10: replies written 1 and 4 s after the save).
		local left = tonumber(WowCompanionDB.leftAt)
		if left and left <= sessionStart and sessionStart - left < 300 then
			sessionStart = left
		end
	elseif event == "PLAYER_LOGIN" then
		-- the talk button as this player's controller reports it (/wc talkkey)
		if type(WowCompanionDB.talkKey) == "string" then
			WowCompanion_TalkKey = WowCompanionDB.talkKey
		end
		pcall(bindTap)
		local version, build, _, toc = GetBuildInfo()
		record("client", ("%s.%s, toc %d"):format(version, build, toc))
		-- build the window and refill it before anything can write to it
		logFrame()
		replayLog()
		-- The board as it stood when the reload saved (the player, 2026-11-10:
		-- after a reload every agent looked idle until its next update). Shown at
		-- once; the companion's `board` message corrects it a few seconds later.
		pcall(function()
			local board = WowCompanionDB.board
			WowCompanionDB.board = nil
			if type(board) ~= "table" then return end
			local gone = time() - (tonumber(board.at) or 0)
			if gone < 0 or gone > 300 then return end
			for slot, e in pairs(board.working or {}) do
				if type(e) == "table" and e.text then
					setPending(e.text, slot, (tonumber(e.age) or 0) + gone)
				end
			end
			for slot, e in pairs(board.recent or {}) do
				local age = type(e) == "table" and (tonumber(e.age) or 0) + gone
				if age and e.text and age < RECENT_FOR then
					recent[slot] = { text = e.text, at = GetTime() - age }
				end
			end
			renderPending()
		end)
		probeSound()
		-- after login settles: modules may build frames on top of Blizzard's
		C_Timer.After(2, loadModules)
		-- read-only: polls the pad and the buttons' pushed state, hooks nothing
		pcall(learnChords)
		ticker = startPolling()
	elseif event == "PLAYER_LOGOUT" then
		-- a failed export must not cost the rest of the save
		pcall(exportContext)
		-- how many slots this game session can see (folders made after launch
		-- are invisible until a restart): the companion sends no further than this
		pcall(function()
			local seen = 0
			for index = 1, C_AddOns.GetNumAddOns() do
				local name = C_AddOns.GetAddOnInfo(index)
				if name and name:find("^" .. ADDON .. "_S%d+$") then
					seen = seen + 1
				end
			end
			WowCompanionDB.slotCount = seen
		end)
		WowCompanionDB.channel = channel
		-- the board lives in memory only; keep it for the next session to show
		pcall(function()
			local now, clock = time(), GetTime()
			local board = { at = now, working = {}, recent = {} }
			for slot, entry in pairs(working) do
				board.working[slot] = { text = entry.text, age = clock - entry.since }
			end
			for slot, done in pairs(recent) do
				board.recent[slot] = { text = done.text, age = clock - done.at }
			end
			WowCompanionDB.board = board
			WowCompanionDB.leftAt = now
		end)
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
	elseif command == "talkkey" then
		learnTalkKey()
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
			ticker = startPolling()
		end
		say("bell poll running")
	elseif command == "log" then
		local frame = logFrame()
		if frame:IsShown() then
			-- plain Hide, not HideUIPanel: a programmatic HideUIPanel from a click
			-- handler is the exact path that taints gamepad navigation on this client.
			-- OnHide tells the gamepad manager, which is what Hide alone never did.
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


-- for Probes.lua
WC.Core = WC.Core or {}
WC.Core.SIGNALS = SIGNALS
WC.Core.listen = listen
WC.Core.logFrame = logFrame
WC.Core.record = record
WC.Core.results = results
WC.Core.say = say
WC.Core.actionButton_get = function() return actionButton end
WC.Core.blocked_get = function() return blocked end


-- for Chords.lua
WC.Core = WC.Core or {}
WC.Core.cvar = cvar
WC.Core.effectiveModules = effectiveModules


-- for Chat.lua
WC.Core = WC.Core or {}
WC.Core.remember = remember
WC.Core.spoken = spoken
WC.Core.toast = toast


-- for Board.lua
WC.Core = WC.Core or {}
WC.Core.working = working


-- for Transcript.lua
WC.Core = WC.Core or {}
WC.Core.LOG_KEEP = LOG_KEEP


-- for Window.lua
WC.Core = WC.Core or {}
WC.Core.frame = frame
WC.Core.newTranscript = newTranscript
WC.Core.nextSlot_get = function() return nextSlot end
