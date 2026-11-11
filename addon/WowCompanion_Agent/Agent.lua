-- WowCompanion_Agent: the agents' half. This file: the Companion window and
-- its conversations, the log, the board's rows, the conversation message kinds,
-- /wc's agent commands, and what the other files of this addon ask of it
-- (WC.Companion). Beside it: Stow.lua (the window in a fight), Offer.lua (the
-- offered button), Steps.lua (an answer's steps). The channel is Link's.

WC.Saved("WowCompanion_Agent", "WowCompanionAgentDB")

-- how much conversation to keep; it rides in SavedVariables, so not unbounded
local LOG_KEEP = 300

local logWindow
local pendingTicker
local say = WC.Link.say
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
		-- opening the window shows the conversation in view: its news is seen
		logWindow:HookScript("OnShow", function()
			WC.Companion.seen(WowCompanion_ViewSlot())
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

-- What each conversation is doing comes from the jobs (JobsModel.lua, Work):
-- the clip being heard, the run at work and its progress. One row per
-- conversation on the board, its seconds in the list, the work line in the
-- window (Jobs.lua). Nothing here keeps a state of its own.
-- "chat" is not a conversation: its row says a line is waiting for the chat box
local SLOT_ORDER = { "chat" }
for i, slot in ipairs(WC.Conversations.list) do table.insert(SLOT_ORDER, i, slot) end
local function slotLabel(slot)
	return slot == "chat" and "Chat" or WC.Conversations.Label(slot)
end
local renderPending
-- the last reply or error per conversation, shown in its row for a while
local recent, RECENT_FOR = {}, 30
-- opts (optional): state = the word shown instead of replied ("problem" is
-- drawn red), keep = no expiry. No text clears the row.
function WowCompanion_Recent(slot, text, opts)
	opts = type(opts) == "table" and opts or {}
	recent[slot or ""] = text and { text = text, at = GetTime(), state = opts.state, keep = opts.keep } or nil
	if renderPending then renderPending() end
end
local paintHook -- the conversation list's painter, set once it exists
local function work(slot)
	if WC.Jobs and WC.Jobs.Work then return WC.Jobs.Work(slot) end
end
local turn = 0
renderPending = function()
	local frame = logFrame()
	local lines = {}
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
		local heard, running = work(slot)
		local done = recent[slot]
		if done and not done.keep and now - done.at > RECENT_FOR then recent[slot] = nil done = nil end
		local line
		if heard then
			line = row(slot, "9ad5ff", ("hearing %ds"):format(WC.Jobs.Age(heard.since)), running and running.text)
		elseif running then
			line = row(slot, "ffd100", ("working %ds"):format(WC.Jobs.Age(running.since)), running.text .. dots)
		elseif done then
			line = row(slot, done.state == "problem" and "ff6060" or done.state and "ffd100" or "40ff40",
				done.state or "replied", done.text)
		end
		if line then lines[#lines + 1] = line end
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
-- the model changed: the board and list follow at once
if WC.Jobs then WC.Jobs.Changed = function() renderPending() end end

-- Kept in SavedVariables, so it is written on /reload or logout like everything else.
-- Conversations (the player, 2026-11-10): the talk button alone is the main one
-- (""), and with a trigger held each of L1, L2, R1, R2 is its own. Every line
-- remembers which it belongs to; the window shows one at a time, picked with the
-- buttons above the transcript, and a slot with news it has not shown glows.
local viewSlot = ""
-- which conversations have news not yet looked at, kept in SavedVariables so a
-- reload does not forget a reply waiting in another conversation (the player,
-- 2026-11-10). Read through this, since WowCompanionAgentDB exists only once loaded.
local function unreadSet()
	if type(WowCompanionAgentDB) ~= "table" then return {} end
	WowCompanionAgentDB.unread = WowCompanionAgentDB.unread or {}
	return WowCompanionAgentDB.unread
end
-- news seen or arrived: the minimap button (Link's Status.lua) hears it
local function setUnread(slot, on)
	unreadSet()[slot] = on or nil
	WC.Send("UNREAD", unreadSet())
end
local function paintConversations()
	local frame = logWindow
	if not (frame and frame.convButtons) then return end
	for key, button in pairs(frame.convButtons) do
		local label = slotLabel(key)
		-- each conversation shows its own progress in the list (the player,
		-- 2026-11-10): the seconds while its agent works, "new" once it answered
		local heard, running = work(key)
		if heard then
			-- Whisper still has this conversation's clip (the player, 2026-11-10)
			label = label .. "  |cff9ad5ff" .. WC.Jobs.Age(heard.since) .. "s|r"
		elseif running then
			label = label .. "  |cffb0b0b0" .. WC.Jobs.Age(running.since) .. "s|r"
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
		setUnread(slot, true)
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
	setUnread(viewSlot, false)
	-- the button follows the view: each conversation shows its own offer
	WC.Offer.Show(viewSlot)
	if renderPending then renderPending() end
	logFrame().messages:Clear()
	replayLog()
	paintConversations()
end

-- What the helper is allowed to ask for. A dispatch table rather than loadstring on
-- whatever arrives: the rule is configuration only, and this is where that rule lives.
local handlers = {}


-- A line for the conversation window. Opens it out of combat so a reply is not
-- missed, but never steals the screen mid-fight.
function handlers.log(inbox)
	local text = inbox.text or ""
	local who = inbox.who or "claude"
	local lines = 0
	-- every line names its conversation and its number (src/ledger.rs): one
	-- already held, from a slot or the mailbox, is not applied again
	local islot = inbox.slot or ""
	if WC.Jobs and not WC.Jobs.Hold(islot, inbox.n) then return WC.Link.HELD end
	-- An error about a clip that never ran (nothing heard, noise) is the
	-- player's own news, not a reply: it lights no tab. Read before its job's
	-- end is applied (after this handler, JOB_MESSAGE).
	local was = WC.Jobs and inbox.job and WC.Jobs.State(inbox.job)
	local quiet = who == "error" and was ~= "running"
	-- a reply arrives as one message but reads as many lines, and AddMessage takes
	-- one line at a time; blank lines are kept because they carry the paragraphs
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		remember(who, line, lines > 0, islot, lines == 0 and who == "you" and inbox.job or nil, quiet)
		lines = lines + 1
	end
	if lines == 0 then
		remember(who, text, nil, islot, who == "you" and inbox.job or nil, quiet)
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
			WowCompanion_Recent(islot, first, { state = "problem" })
		end
	end
	return ("logged %d line(s)"):format(lines)
end

-- Closing in combat (the player, 2026-11-10: "can't close the companion window
function WowCompanion_HideWindow()
	local frame = logWindow
	if not frame then return end
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

-- What the agent is doing right now, on the work line: "reading StanceBar.lua".
-- Not logged; the reply is what stays. Its job keeps it (JOB_MESSAGE).
function handlers.progress()
	return "progress"
end

-- The PC read a press (Send now): the window stops drawing it again.
function handlers.ack(inbox)
	if WC.Jobs and WC.Jobs.Model() then WC.Jobs.Model():Acked(inbox.verb, inbox.job) end
	return "ack"
end

-- The PC's answer to a cancel: the states of the jobs it touched (JOB_MESSAGE).
function handlers.stopped()
	return "stopped"
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
		C_Timer.After(0.2, function() pcall(WC.Export.NoteForms) end)
		return
	end
	if event == "PLAYER_LOGIN" then
		-- build the window and refill it before anything can write to it (the
		-- mailbox's lines come at PLAYER_ENTERING_WORLD, WowCompanion_Link)
		logFrame()
		replayLog()
		WC.Send("UNREAD", unreadSet())
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
					recent[slot] = { text = e.text, at = GetTime() - age, state = e.state }
				end
			end
			renderPending()
		end)
		-- after login settles: modules may build frames on top of Blizzard's
		C_Timer.After(2, loadModules)
		-- read-only: polls the pad and the buttons' pushed state, hooks nothing
		pcall(WC.Chords.learnChords)
	elseif event == "PLAYER_LOGOUT" then
		-- a failed export must not cost the rest of the save
		pcall(WC.Export.Context)
		-- the board lives in memory only; keep it for the next session to show
		pcall(function()
			local clock = GetTime()
			local board = { at = time(), recent = {} }
			for slot, done in pairs(recent) do
				board.recent[slot] = { text = done.text, age = clock - done.at, state = done.state }
			end
			WowCompanionAgentDB.board = board
		end)
	elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
		-- taint cascades, and the first block names the real culprit, so number them
		-- rather than letting each one overwrite the last
		-- kept for the agents (the export) and the Status tab, not said in the
		-- conversation: it is a diagnosis, not news for the player
		local addon, func = ...
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
-- a short tap of the talk button opens or closes the window (the game alone
-- decides a tap: the PC sends nothing for one)
bus:On("TALK_TAP", function() toggleWindow() end)
bus:On("TOGGLE_WINDOW", function() toggleWindow() end)
bus:On("LINK_FAILED", function(text) remember("error", text) end)
-- every job's state, as each message that names one is handled, and the
-- mailbox's at load: the model is the window's one truth of what runs
bus:On("JOB_MESSAGE", function(inbox) if WC.Jobs then pcall(WC.Jobs.Apply, inbox) end end)
bus:On("MAILBOX_JOBS", function(jobs) if WC.Jobs then pcall(WC.Jobs.Mail, jobs) end end)
WC.Board.poster = function(slot, text, opts) return WowCompanion_Recent(slot, text, opts) end
for kind, fn in pairs(handlers) do WC.Link.Handle(kind, fn) end

-- /wc's agent commands (WowCompanion_Link owns /wc and its talkkey, quiet, listen)
local slash = WC.Link.Slash
slash("context", function() say(("context: %d lines; /reload to write it to disk"):format(WC.Export.Context())) end)
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
	window = logFrame,              -- the Companion window, built on first use
	modules = effectiveModules,     -- every agent module, name -> code
	-- the window if it has been built, else nil (never builds it)
	built = function() return logWindow end,
	-- the conversation the message now being handled belongs to
	replySlot = replySlot,
	-- the conversation's news has been seen
	seen = function(slot) setUnread(slot or "", false) end,
}
