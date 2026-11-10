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
	if not logWindow then
		logWindow = buildLog()
		-- who closed it, when it vanishes on its own (the player, 2026-11-10)
		logWindow:HookScript("OnHide", function()
			WowCompanionDB.windowCombat = WowCompanionDB.windowCombat or {}
			WowCompanionDB.windowCombat.lastOnHide = ("%s combat=%s by %s"):format(date("%H:%M:%S"),
				tostring(InCombatLockdown()), ((debugstack(3, 3, 0) or "?"):gsub("\n", " | ")):sub(1, 300))
		end)
	end
	return logWindow
end

-- moved to Board.lua
local function toast(...) return WC.Board.toast(...) end
local function toastBoard(...) return WC.Board.toastBoard(...) end
local function toastIdleShown(...) return WC.Board.toastIdleShown(...) end
-- ShowUIPanel, so the window joins the controller's focus cycle (see buildLog).
-- It is refused in combat, where a plain Show at least puts the text in front of
-- them; the manager is not told, so nothing is left for it to forget.
local shownInCombat = false
local function reveal(frame)
	toast(nil)
	if not InCombatLockdown() and UIPanelWindows and UIPanelWindows["WowCompanionLog"] then
		ShowUIPanel(frame)
	end
	if not frame:IsShown() then
		frame:Show()
		shownInCombat = InCombatLockdown() and true or false
	end
end

-- The window in combat (the player, 2026-11-10: "randomly disappearing and
-- sometimes showing up in combat is completely useless"). A secure button
-- inside a frame makes that frame protected, and a protected frame cannot be
-- shown or hidden by an addon mid-fight: that was the whole mess. So the
-- window's secure buttons (the offered press, Reload) are stowed in a hidden
-- holder of their own as combat begins (PLAYER_REGEN_DISABLED runs just before
-- the lockdown, the last moment protected frames can move), which leaves the
-- window an ordinary frame: a tap opens and closes it all fight long. They go
-- back when the fight ends, and a window opened mid-fight becomes a panel again
-- so the controller's focus cycle reaches it.
local stowed = {}
local extraStowed = {}
local stash = CreateFrame("Frame", "WowCompanionStash", UIParent)
stash:Hide()
local combatNote
local function noteCombat(inCombat)
	local frame = logWindow
	if not frame then return end
	if not combatNote then
		combatNote = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		combatNote:SetPoint("BOTTOM", frame, "BOTTOM", 0, 14)
		combatNote:SetText("In combat: reading only. Buttons come back when the fight ends.")
	end
	combatNote:SetShown(inCombat and true or false)
end
local stowWatch = CreateFrame("Frame")
stowWatch:RegisterEvent("PLAYER_REGEN_DISABLED")
stowWatch:RegisterEvent("PLAYER_REGEN_ENABLED")
stowWatch:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_REGEN_DISABLED" then
		for button in pairs(stowed) do
			pcall(function()
				button:ClearAllPoints()
				button:SetParent(stash)
				button:SetPoint("CENTER")
			end)
		end
		-- anything else secure inside the window (a button another file added)
		-- would keep it protected and bring back the vanishing: stow those too,
		-- with their anchors, and write down who they were
		local frame = logWindow
		local found = {}
		local function walk(f)
			for _, child in ipairs({ f:GetChildren() }) do
				if child:IsProtected() and not stowed[child] then
					local points = {}
					for i = 1, child:GetNumPoints() do points[i] = { child:GetPoint(i) } end
					local parent = child:GetParent()
					local ok = pcall(function()
						child:ClearAllPoints()
						child:SetParent(stash)
						child:SetPoint("CENTER")
					end)
					if ok then
						extraStowed[child] = { parent = parent, points = points }
						found[#found + 1] = tostring(child:GetName() or child:GetObjectType())
					end
				else
					walk(child)
				end
			end
		end
		if frame then pcall(walk, frame) end
		WowCompanionDB.windowCombat = {
			at = time(), stowedExtra = table.concat(found, ", "),
			protectedAfter = frame and frame:IsProtected() or nil,
		}
		noteCombat(true)
		return
	end
	for button, restore in pairs(stowed) do pcall(restore, button) end
	for child, was in pairs(extraStowed) do
		pcall(function()
			child:SetParent(was.parent)
			child:ClearAllPoints()
			for _, pt in ipairs(was.points) do child:SetPoint(unpack(pt)) end
		end)
	end
	wipe(extraStowed)
	noteCombat(false)
	local frame = logWindow
	if shownInCombat and frame and frame:IsShown() and UIPanelWindows and UIPanelWindows["WowCompanionLog"] then
		-- a plain Show never joined the focus cycle; join it now, in one frame
		frame:Hide()
		ShowUIPanel(frame)
	end
	shownInCombat = false
end)
-- button: a secure button that lives in the window; restore(button) puts it back
local function stow(button, restore)
	stowed[button] = restore
	if InCombatLockdown() then
		-- built mid-fight cannot happen (secure buttons are built out of combat),
		-- but say so rather than leave the window protected without knowing
		say("stow: " .. tostring(button:GetName()) .. " registered in combat")
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
local transcribing, TRANSCRIBE_FOR = {}, 15 -- Whisper takes 1-3 s; a dropped clip should not linger
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
	-- Each conversation keeps its own LOG_KEEP lines, so a busy one never pushes
	-- out a quiet one; when one fills, its oldest third is compacted into one
	-- line that keeps what was asked, not dropped (the player, 2026-11-10).
	local key = slot ~= "" and slot or nil
	local count = 0
	for _, e in ipairs(entries) do
		if e.slot == key then count = count + 1 end
	end
	if count > LOG_KEEP then
		local fold, asked, first, last, at = math.floor(LOG_KEEP / 3), {}, nil, nil, nil
		local i, taken = 1, 0
		while i <= #entries and taken < fold do
			local e = entries[i]
			if e.slot == key then
				at = at or i
				first = first or e.at
				last = e.at
				if e.who == "you" and not e.continued and type(e.text) == "string" then
					local t = e.text:gsub("%s+", " ")
					asked[#asked + 1] = "- " .. (#t > 90 and (t:sub(1, 87) .. "...") or t)
				elseif e.who == "summary" and type(e.text) == "string" then
					asked[#asked + 1] = e.text
				end
				table.remove(entries, i)
				taken = taken + 1
			else
				i = i + 1
			end
		end
		local head = ("Earlier, %s to %s, compacted: what you asked"):format(
			first and date("%b %d %H:%M", first) or "?", last and date("%H:%M", last) or "?")
		local body = table.concat(asked, "\n")
		if #body > 3000 then body = "...\n" .. body:sub(-3000):gsub("^[^\n]*\n", "") end
		table.insert(entries, at or 1, { at = first or time(), who = "summary", slot = key,
			text = head .. "\n" .. body })
	end
	-- a hard ceiling over all conversations, so the save file stays bounded
	while #entries > LOG_KEEP * 8 do
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
		local function place(b)
			b:SetParent(frame)
			b:ClearAllPoints()
			local last = frame.convButtons and (frame.convButtons.quick or frame.convButtons.r2)
			if last then
				b:SetSize(last:GetWidth(), 24)
				b:SetPoint("TOP", last, "BOTTOM", 0, -10)
				b:SetFrameLevel(last:GetFrameLevel() + 2)
			else
				b:SetSize(150, 22)
				b:SetPoint("BOTTOMRIGHT", -18, 8)
			end
		end
		place(actionButton)
		stow(actionButton, place)
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

	-- No pad key is bound to it any more (the player, 2026-11-10: "just let me
	-- navigate to it and click it"): the window is in the focus cycle, so the
	-- cursor reaches the button like any other. A binding left from an older
	-- build is cleared.
	local bound = "nothing"
	if ClearOverrideBindings then ClearOverrideBindings(actionButton) end
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
	remember("claude", ("button |cffffffff%s|r runs |cff9ad5ff%s|r — it is in the window")
		:format(label, macro), nil, slot)
	toast(("|cffffd100Claude|r  a button in the window: |cffffffff%s|r"):format(label), 0.8, 0.8, 0.8, 30)
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
-- Closing in combat (the player, 2026-11-10: "can't close the companion window
-- during combat"). The offered button (WowCompanionDo) is a secure button inside
-- the window, which makes the window protected, and Hide on a protected frame is
-- refused in combat. Alpha is not restricted: in combat the window goes
-- invisible and stops listening, and the real Hide happens when the fight ends.
local combatHidden = false
local combatCloser = CreateFrame("Frame")
combatCloser:SetScript("OnEvent", function(self)
	self:UnregisterEvent("PLAYER_REGEN_ENABLED")
	if combatHidden and logWindow then
		combatHidden = false
		logWindow:Hide()
		logWindow:SetAlpha(1)
	end
end)
function WowCompanion_HideWindow()
	local frame = logWindow
	if not frame then return end
	WowCompanionDB.windowCombat = WowCompanionDB.windowCombat or {}
	WowCompanionDB.windowCombat.lastHide = ("%s combat=%s protected=%s"):format(date("%H:%M:%S"),
		tostring(InCombatLockdown()), tostring(frame:IsProtected()))
	if InCombatLockdown() and frame:IsProtected() then
		frame:SetAlpha(0)
		combatHidden = true
		-- the manager hears when the fight ends (FrameHidden from addon code in
		-- a fight is "Interface action failed")
		WC.FrameHidden(frame)
		combatCloser:RegisterEvent("PLAYER_REGEN_ENABLED")
		return
	end
	frame:Hide() -- plain Hide; see the /wc log note on HideUIPanel
end
local function windowOpen()
	return logWindow and logWindow:IsShown() and not combatHidden
end
local function toggleWindow()
	local frame = logFrame()
	if windowOpen() then
		WowCompanion_HideWindow()
	elseif combatHidden then
		combatHidden = false
		frame:SetAlpha(1)
	elseif InCombatLockdown() and frame:IsProtected() then
		-- the offer button makes the window protected: Show is refused mid-fight
		-- (an "interface action failed", 2026-11-10); say so instead
		toast("|cffffd100Companion|r  opens when this fight ends", 0.8, 0.8, 0.8, 3)
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

-- moved to Tests.lua
local function placeTest(...) return WC.Tests.placeTest(...) end
local function placeVerdict(...) return WC.Tests.placeVerdict(...) end
local function probeChat(...) return WC.Tests.probeChat(...) end
local function probeMacro(...) return WC.Tests.probeMacro(...) end
local function taintScan(...) return WC.Tests.taintScan(...) end
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

-- moved to Sandbox.lua
local function loadModules(...) return WC.Sandbox.loadModules(...) end
local function measureOnce(...) return WC.Sandbox.measureOnce(...) end
local function results(...) return WC.Sandbox.results(...) end
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
		-- kept for the agents (the export) and the Status tab, not said in the
		-- conversation: it is a diagnosis, not news for the player (2026-11-10)
		local addon, func = ...
		blocked = blocked + 1
		local list = WowCompanionDB.blocked or {}
		WowCompanionDB.blocked = list
		local last = list[#list]
		local what = ("%s called %s"):format(tostring(addon), tostring(func))
		if last and last.what == what and last.event == event then
			last.count, last.at = (last.count or 1) + 1, time()
		else
			list[#list + 1] = { at = time(), event = event, what = what, count = 1, combat = InCombatLockdown() or nil }
			while #list > 20 do table.remove(list, 1) end
		end
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
		-- plain Hide, not HideUIPanel: a programmatic HideUIPanel from a click
		-- handler is the exact path that taints gamepad navigation on this client.
		-- OnHide tells the gamepad manager, which is what Hide alone never did.
		-- toggleWindow also handles combat (WowCompanion_HideWindow).
		toggleWindow()
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
WC.Core.stow = stow
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


-- for Tests.lua
WC.Core = WC.Core or {}
WC.Core.LAST_ACTION_SLOT = LAST_ACTION_SLOT
WC.Core.actionFrames = actionFrames
WC.Core.activeEditBox = activeEditBox
WC.Core.slotHas = slotHas


-- for Sandbox.lua
WC.Core = WC.Core or {}
WC.Core.handlers = handlers
WC.Core.taintScan = taintScan
WC.Core.replySlot_get = function() return replySlot end
