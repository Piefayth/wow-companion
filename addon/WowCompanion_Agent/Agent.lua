-- WowCompanion_Agent: the agents' half. The Companion window and its
-- conversations, the waiting lines and the board's rows, the offered button,
-- the agents' message kinds (registered with WC.Link.Handle), /wc's agent
-- commands, and what the other files of this addon ask of it (WC.Companion).
-- The channel itself is WowCompanion_Link's.

WC.Saved("WowCompanion_Agent", "WowCompanionAgentDB")

-- how much conversation to keep; it rides in SavedVariables, so not unbounded
local LOG_KEEP = 300

local blocked = 0
local logWindow
local pendingTicker
local actionButton
-- One offered button per conversation (the player, 2026-11-10): a Reload from
-- one agent replaced the Quit another had just offered. Each keeps its own; the
-- one secure button shows the offer of the conversation in view.
local offers = {}
local say, record = WC.Link.say, WC.Link.record
-- the conversation of the message being handled (WowCompanion_Link), so what its
-- steps report lands in that conversation, not whichever one is in view
local function replySlot() return WC.Link.Current() end


-- Every module to run, name -> { code, disk }. modules/<Name>.lua in the repo is
-- the source of truth, reaching the game as Modules.lua (WowCompanion_DiskModules,
-- reread at every /reload); WowCompanionAgentDB.modules keeps a module sent
-- before its file landed. The file wins.
local function effectiveModules()
	local all = {}
	for name, entry in pairs(WowCompanionAgentDB and WowCompanionAgentDB.modules or {}) do
		if type(entry) == "table" and entry.code then all[name] = { code = entry.code } end
	end
	for name, code in pairs(type(WowCompanion_DiskModules) == "table" and WowCompanion_DiskModules or {}) do
		if type(code) == "string" then all[name] = { code = code, disk = true } end
	end
	return all
end

local function buildLog(...) return WC.Window.buildLog(...) end
local function logFrame()
	if not logWindow then
		logWindow = buildLog()
		-- who closed it, when it vanishes on its own (the player, 2026-11-10)
		-- opening the window shows the conversation in view: its news is seen
		logWindow:HookScript("OnShow", function()
			local unread = WowCompanion_Unread and WowCompanion_Unread()
			if unread and WowCompanion_ViewSlot then unread[WowCompanion_ViewSlot()] = nil end
		end)
		logWindow:HookScript("OnHide", function()
			WowCompanionAgentDB.windowCombat = WowCompanionAgentDB.windowCombat or {}
			WowCompanionAgentDB.windowCombat.lastOnHide = ("%s combat=%s by %s"):format(date("%H:%M:%S"),
				tostring(InCombatLockdown()), ((debugstack(3, 3, 0) or "?"):gsub("\n", " | ")):sub(1, 300))
		end)
	end
	return logWindow
end

local function toast(...) return WC.Board.toast(...) end
local function toastBoard(...) return WC.Board.toastBoard(...) end
local function toastIdleShown(...) return WC.Board.toastIdleShown(...) end
-- a UI panel, so the window joins the controller's focus cycle (WC.ShowPanel:
-- in a fight a plain Show, joining the cycle when it ends)
local function reveal(frame)
	toast(nil)
	WC.ShowPanel(frame)
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
		WowCompanionAgentDB.windowCombat = {
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

local function showLine(who, text, continued, at, job)
	logFrame().messages:Add(who, text, continued, at, job)
end

-- Spinning while the agent thinks. Several seconds of silence after you speak is
-- indistinguishable from a broken channel, which is the whole reason this exists.
-- One waiting line per conversation (the player, 2026-11-10): several agents can
-- work at once, and one shared line muddled them. Each slot keeps its own text
-- and start time; the toast shows a labelled line for every one at work, and
-- the window's line shows the conversation in view.
local working = {}
-- "chat" is not a conversation: its row says a line is waiting for the chat box
local SLOT_ORDER = { "", "l1", "l2", "r1", "r2", "quick", "chat" }
local function slotLabel(slot)
	return slot == "" and "Main" or slot == "quick" and "Quick" or slot == "chat" and "Chat" or slot:upper()
end
local renderPending
-- the last reply or error per conversation, shown in its row for a while
local recent, RECENT_FOR = {}, 30
-- opts (optional): state = the word shown instead of replied, keep = no expiry.
-- No text clears the row.
function WowCompanion_Recent(slot, text, opts)
	opts = type(opts) == "table" and opts or {}
	recent[slot or ""] = text and { text = text, at = GetTime(), state = opts.state, keep = opts.keep } or nil
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
-- "transcribing" lasts while a clip of the conversation is still being heard:
-- it gives way to the working line in the same message, never a gap between
-- (the player, 2026-11-11: the board flickered)
local function settleTranscribing(slot)
	if not (WC.Jobs and WC.Jobs.Hearing(slot)) then setTranscribing(slot, false) end
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
		if done and not done.keep and now - done.at > RECENT_FOR then recent[slot] = nil done = nil end
		local heard = transcribing[slot]
		if heard and now - heard > TRANSCRIBE_FOR then transcribing[slot] = nil heard = nil end
		local line
		if heard then
			line = row(slot, "9ad5ff", ("hearing %ds"):format(now - heard), entry and entry.text)
		elseif entry then
			line = row(slot, "ffd100", ("working %ds"):format(now - entry.since), entry.text .. dots)
		elseif done then
			local bad = done.text:find("ff7777", 1, true)
			line = row(slot, bad and "ff6060" or done.state and "ffd100" or "40ff40",
				bad and "problem" or done.state or "replied", done.text)
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
	if #lines > 0 then
		if not frame:IsShown() then
			toastBoard(lines,("tap %s to read"):format(WowCompanion_Glyph(WowCompanion_TalkKey)))
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
-- 2026-11-10). Read through this, since WowCompanionAgentDB exists only once loaded.
local function unreadSet()
	if type(WowCompanionAgentDB) ~= "table" then return {} end
	WowCompanionAgentDB.unread = WowCompanionAgentDB.unread or {}
	return WowCompanionAgentDB.unread
end
-- for the minimap button: the conversations with news not yet looked at
function WowCompanion_Unread() return unreadSet() end
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
	-- each message's panel, with its Cancel and Send now (Jobs.lua)
	if WC.Jobs then WC.Jobs.Refresh() end
end

paintHook = paintConversations

-- Asks the companion to stop a conversation (the player, 2026-11-10). The game
-- cannot write to the PC while it runs, so the request is drawn on the data
-- strip, which the companion watches (src/strip.rs serve); it ends the agent,
-- drops what was queued, and answers with a `stopped` message.
-- `sendNow`: interrupt the running request; it and the queued ones run together.
function WowCompanion_Stop(slot, sendNow)
	slot = slot or viewSlot
	if not (WowCompanion_Strip and WowCompanion_Strip.Send) then return end
	WowCompanion_Strip.Send(("WCCMD %d%04d %s %s"):format(time(), math.random(0, 9999),
		sendNow and "now" or "stop", slot ~= "" and slot or "main"), 2.5)
	setPending("stopping", slot)
end

-- `quiet`: not news (a notice about the player's own clip), so it lights nothing
local function remember(who, text, continued, slot, job, quiet)
	slot = slot or replySlot() or viewSlot
	WowCompanionAgentDB.log = WowCompanionAgentDB.log or {}
	local entries = WowCompanionAgentDB.log
	entries[#entries + 1] = { at = time(), who = who, text = text, continued = continued or nil,
		slot = slot ~= "" and slot or nil, job = job }
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
		showLine(who, text, continued, entries[#entries].at, job)
	end
	-- news nobody has seen yet: a reply in another conversation, or in this one
	-- while the window is closed (the player, 2026-11-10: replies waited unseen
	-- unless they checked); the minimap button shows it (Status.lua)
	if not continued and not quiet and (who == "claude" or who == "error")
		and (slot ~= viewSlot or not (logWindow and logWindow:IsShown())) then
		unreadSet()[slot] = true
		paintConversations()
	end
end

local function replayLog()
	local messages = logFrame().messages
	messages:Hold(true)
	for _, entry in ipairs(WowCompanionAgentDB.log or {}) do
		if (entry.slot or "") == viewSlot then
			showLine(entry.who or "claude", entry.text or "", entry.continued, entry.at, entry.job)
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

		-- the cursor can land on it, and goes to it when the window takes focus
		WC.MarkFocusable(actionButton)
		WC.SetFocusButton(frame, actionButton)
		actionButton:SetScript("PostClick", function(self)
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
	-- the cursor reaches it, and L3 presses it while the window has focus
	-- (Jobs.lua); nothing else is bound to it
	return "shown"
end
WowCompanion_ShowOffer = showOffer

local function offer(label, macro, slot)
	-- attributes on a secure frame cannot be set in combat, and this is
	-- configuration anyway
	if InCombatLockdown() then
		return "refused: in combat"
	end
	slot = slot or replySlot() or viewSlot
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


-- A line for the conversation window. Opens it out of combat so a reply is not
-- missed, but never steals the screen mid-fight.
function handlers.log(inbox)
	local text = inbox.text or ""
	local who = inbox.who or "claude"
	-- the voice loop's notices (a dropped clip) end a dictation's wait
	if who == "error" and WC.ChatChannel and WC.ChatChannel.Dropped then WC.ChatChannel.Dropped(text) end
	local lines = 0
	-- every line names its conversation and its number (src/ledger.rs): one
	-- already held, from a slot or the mailbox, is not applied again
	local islot = inbox.slot or ""
	if WC.Jobs and not WC.Jobs.Hold(islot, inbox.n) then return WC.Link.HELD end
	-- An error about a clip that never ran (nothing heard, noise) is the
	-- player's own news, not a reply: it lights no tab and leaves the work alone.
	-- Read before its job's end is applied below.
	local was = WC.Jobs and inbox.job and WC.Jobs.State(inbox.job)
	local quiet = who == "error" and was ~= "running"
	-- The waiting line follows the jobs (the ledger's truth): once this line's
	-- job ends are applied, it ends when nothing of the conversation runs, before
	-- the words go in, so a reply takes the work entry's place instead of
	-- landing under it.
	if inbox.slot and not inbox.pending and inbox.state ~= "queued" then
		if WC.Jobs then pcall(WC.Jobs.Note, inbox) end
		if not (WC.Jobs and WC.Jobs.Running(islot)) then setPending(nil, islot) end
	end
	-- a reply arrives as one message but reads as many lines, and AddMessage takes
	-- one line at a time; blank lines are kept because they carry the paragraphs
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		remember(who, line, lines > 0, islot, lines == 0 and who == "you" and inbox.job or nil, quiet)
		lines = lines + 1
	end
	if lines == 0 then
		remember(who, text, nil, islot, who == "you" and inbox.job or nil, quiet)
	end
	-- the job's state, once its line is in the transcript to carry its controls
	if WC.Jobs then pcall(WC.Jobs.Note, inbox) end
	-- a line with `pending` starts the waiting line after its words, so the work
	-- entry comes below what it answers (2026-11-11)
	if inbox.pending and inbox.state ~= "queued" then setPending(inbox.pending, islot) end
	settleTranscribing(islot)
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

-- when the game itself last toggled the window on a tap (TALK_TAP)
local nativeToggleAt = 0
-- Closing in combat (the player, 2026-11-10: "can't close the companion window
function WowCompanion_HideWindow()
	local frame = logWindow
	if not frame then return end
	WowCompanionAgentDB.windowCombat = WowCompanionAgentDB.windowCombat or {}
	WowCompanionAgentDB.windowCombat.lastHide = ("%s combat=%s protected=%s"):format(date("%H:%M:%S"),
		tostring(InCombatLockdown()), tostring(frame:IsProtected()))
	frame:Hide() -- plain Hide; see the /wc log note on HideUIPanel
end
local function windowOpen()
	return logWindow and logWindow:IsShown()
end
local function toggleWindow()
	local frame = logFrame()
	if windowOpen() then
		WowCompanion_HideWindow()
	else
		reveal(frame)
	end
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

-- A clip let go, named by the job the PC made for it (src/jobs.rs): the
-- hearing line is drawn from it and its X cancels that job.
function handlers.heard(inbox)
	if WC.Jobs then WC.Jobs.Apply(inbox) end
	setTranscribing(inbox.slot or "", true)
	return "heard"
end

-- What the agent is doing right now, on the waiting line: "reading StanceBar.lua".
-- Not logged; the reply is what stays.
function handlers.progress(inbox)
	-- a late progress line of a job that has ended must not bring its working
	-- line back
	if inbox.job and WC.Jobs and WC.Jobs.Ended and WC.Jobs.Ended(inbox.job) then return "progress: ended" end
	-- the agent took the oldest queued request of this conversation
	-- its job's state (Jobs.lua takes the queued mark off the right message)
	if inbox.job and WC.Jobs and WC.Jobs.Apply then pcall(WC.Jobs.Apply, inbox) end
	setPending(inbox.text or "thinking", inbox.slot, inbox.since)
	return "progress"
end

-- The PC read a press (Send now): the window stops drawing it again.
function handlers.ack(inbox)
	if WC.Jobs and WC.Jobs.Model() then WC.Jobs.Model():Acked(inbox.verb, inbox.job) end
	return "ack"
end

-- The PC's answer to a cancel or a stop: the states of the jobs it touched.
function handlers.stopped(inbox)
	local slot = inbox.slot or ""
	if WC.Jobs then WC.Jobs.Apply(inbox) end
	settleTranscribing(slot)
	-- the conversation works while a job of it runs (the ledger says)
	if WC.Jobs and WC.Jobs.Running and not WC.Jobs.Running(slot) then setPending(nil, slot) end
	-- a cancel shows on the message itself; a stop of the whole conversation says so
	if inbox.dropped then
		remember("claude", "Stopped. Anything queued behind it was dropped.", nil, slot)
	end
	return "stopped"
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


-- What a step did, in the window, so a refusal ("in combat", "no macro named")
-- is seen rather than silently dropped. Only kinds whose result is news: chat,
-- lua and press already show themselves.
-- a lua or module step reports itself when it has run (Sandbox.lua)
local REPORTED = { bar = true, macro = true }
local function report(step, ok, outcome)
	if not ok then
		remember("error", ("%s failed: %s"):format(tostring(step.kind), tostring(outcome)))
	elseif REPORTED[step.kind] and type(outcome) == "string" then
		remember(outcome:find("^refused") and "error" or "game", outcome)
	end
end

-- Several steps from one answer, in order, each reported. One failing does not
-- stop the rest: they were asked for together, but each stands on its own, and
-- the report says which landed. Agent code runs after a taint scan spread over
-- frames (Sandbox.lua), so the steps after it wait for it, in the same
-- conversation.
function handlers.batch(inbox)
	local slot = WC.Link.Current()
	local steps = inbox.steps or {}
	local function from(first)
		for at = first, #steps do
			if WC.Sandbox.Busy() then
				WC.Sandbox.Queue(function(done)
					WC.Link.As(slot, from, at)
					done()
				end)
				return
			end
			report(steps[at], WC.Link.Run(steps[at]))
		end
	end
	from(1)
end

local function dumpApi(...) return WC.Probes.dumpApi(...) end
local function dumpDocs(...) return WC.Probes.dumpDocs(...) end
local function probeApi(...) return WC.Probes.probeApi(...) end
local function probeGamepad(...) return WC.Probes.probeGamepad(...) end
local function probeSound(...) return WC.Probes.probeSound(...) end
local function surveyApi(...) return WC.Probes.surveyApi(...) end
-- moved to Chords.lua
local function itemName(...) return WC.Chords.itemName(...) end
local function learnChords(...) return WC.Chords.learnChords(...) end
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
	if not slot or slot < 1 or slot > WC.Chords.LAST_ACTION_SLOT or slot ~= math.floor(slot) then
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

local function loadModules(...) return WC.Sandbox.loadModules(...) end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
-- fires on /reload as well as logout, just before SavedVariables is written: the
-- one moment worth exporting at, since nothing reaches disk any other time
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("ADDON_ACTION_BLOCKED")
frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
-- the spellbook shows a form's own spells only while in it
frame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
frame:SetScript("OnEvent", function(_, event, ...)
	if event == "UPDATE_SHAPESHIFT_FORM" then
		-- a moment later, once the book has swapped its entries
		C_Timer.After(0.2, function() pcall(noteForms) end)
		return
	end
	if event == "PLAYER_LOGIN" then
		-- build the window and refill it before anything can write to it (the
		-- mailbox's lines come at PLAYER_ENTERING_WORLD, WowCompanion_Link)
		logFrame()
		replayLog()
		-- the last reply per conversation, as it stood when the reload saved
		pcall(function()
			local board = WowCompanionAgentDB.board
			WowCompanionAgentDB.board = nil
			if type(board) ~= "table" then return end
			local gone = time() - (tonumber(board.at) or 0)
			if gone < 0 then return end
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
	elseif event == "PLAYER_LOGOUT" then
		-- a failed export must not cost the rest of the save
		pcall(exportContext)
		-- the board lives in memory only; keep it for the next session to show
		pcall(function()
			local clock = GetTime()
			local board = { at = time(), recent = {} }
			for slot, done in pairs(recent) do
				board.recent[slot] = { text = done.text, age = clock - done.at }
			end
			WowCompanionAgentDB.board = board
		end)
	elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
		-- taint cascades, and the first block names the real culprit, so number them
		-- rather than letting each one overwrite the last
		-- kept for the agents (the export) and the Status tab, not said in the
		-- conversation: it is a diagnosis, not news for the player
		local addon, func = ...
		blocked = blocked + 1
		local list = WowCompanionAgentDB.blocked or {}
		WowCompanionAgentDB.blocked = list
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

-- what WowCompanion_Link and the other addons say on the bus
local bus = WC.Module("Agent")
-- a short tap of the talk button: the window, at once, instead of waiting a
-- second for the helper's own `show`
bus:On("TALK_TAP", function()
	nativeToggleAt = GetTime()
	toggleWindow()
end)
-- a hold let go: a clip on its way to Whisper shows as hearing at once
bus:On("TALK_HELD", function(slot)
	setTranscribing(slot, true)
	renderPending()
end)
bus:On("TOGGLE_WINDOW", function() toggleWindow() end)
bus:On("LINK_STEP", function(step, ok, outcome) report(step, ok, outcome) end)
bus:On("LINK_FAILED", function(text) remember("error", text) end)
-- the mailbox's jobs: the conversations at work are the ones with a job running
bus:On("MAILBOX_JOBS", function(jobs)
	if not WC.Jobs then return end
	pcall(WC.Jobs.Mail, jobs)
	for _, slot in ipairs(SLOT_ORDER) do
		local running = WC.Jobs.Running(slot)
		if running and not working[slot] then setPending("thinking", slot)
		elseif not running and working[slot] then setPending(nil, slot) end
	end
end)
WC.Board.poster = function(slot, text, opts) return WowCompanion_Recent(slot, text, opts) end
for kind, fn in pairs(handlers) do WC.Link.Handle(kind, fn) end

-- /wc's agent commands (WowCompanion_Link owns /wc and its talkkey, quiet, listen)
local slash = WC.Link.Slash
slash("chat", function() probeChat() end)
slash("macro", function() probeMacro() end)
slash("sound", function() probeSound() end)
slash("gamepad", function() probeGamepad() end)
slash("api", function() probeApi() end)
slash("dump", function() dumpApi() end)
slash("docs", function() dumpDocs() end)
slash("alive", function() surveyApi() end)
slash("context", function() say(("context: %d lines; /reload to write it to disk"):format(exportContext())) end)
slash("place", function(variant)
	-- deferred a tick: the Enter that submitted this is still unwinding
	C_Timer.After(0.1, function() say(placeTest(variant or "")) end)
end)
slash("verdict", function(which) say(placeVerdict(which)) end)
slash("taint", function()
	say("scanning, over a few seconds")
	taintScan(function(tainted, checked)
		local names = WC.Tests.fresh({}, tainted)
		WowCompanionAgentDB.taint = table.concat(names, "\n")
		say(("%d tainted of %d checked; /reload to write the list"):format(#names, checked))
	end)
end)
-- the macro test target: no side effects, and unmistakable when it fires.
-- remember() rather than say(), so the answer survives to SavedVariables
slash("ping", function()
	remember("probe", "pong at " .. date("%H:%M:%S") .. " -- the macro ran")
	record("macrotext runs", "yes, at " .. date("%H:%M:%S"))
end)
-- point the button at our own slash command: pong appearing means macrotext runs
slash("test", function() say(offer("Run /wc ping", "/wc ping")) end)
slash("button", function() say(offer("Reload UI", "/reload")) end)
-- plain Hide, not HideUIPanel (WowCompanion_HideWindow)
slash("log", function() toggleWindow() end)
slash("clear", function()
	WowCompanionAgentDB.log = {}
	logFrame().messages:Clear()
	say("conversation cleared")
end)


-- What the other files may ask of this one, by name. Nothing reads its
-- locals: a file that needs something here calls one of these.
WC.Companion = {
	LOG_KEEP = LOG_KEEP,
	remember = remember,            -- a line in the conversation window
	say = say,                      -- a line in the chat frame
	record = record,                -- a probe result, kept in the save file
	window = logFrame,              -- the Companion window, built on first use
	activeEditBox = function() return WC.Chat.ActiveBox() end, -- the chat box the player has open, or nil
	modules = effectiveModules,     -- every agent module, name -> code
	stow = stow,                    -- a secure button out of the window for a fight
	-- the waiting entry of a conversation ("" is Main): { text, since, ... } or nil
	working = function(slot) return working[slot or ""] end,
	-- listen for one of our signal sounds (Signals/<file>) playing
	listenSignal = function(file, heard) return WC.Link.ListenSignal(file, heard) end,
	offerButton = function() return actionButton end,
	blockedCount = function() return blocked end,
	messagesSent = function() return WC.Link.MessagesSent() end,
	-- the conversation the message now being handled belongs to
	replySlot = replySlot,
	-- a message kind fn(inbox) handles
	addHandler = function(kind, fn) WC.Link.Handle(kind, fn) end,
}
