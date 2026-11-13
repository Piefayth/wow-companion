-- WowCompanion_Link: the bridge to the companion on the PC. The helper writes Lua
-- into load-on-demand slot addons (WowCompanion_S001...) and "rings" a bell
-- sound file; we hear the bell and load the next slot. Every message is handed
-- to the handler registered for its kind (WC.Link.Handle): this file handles the
-- channel's own and the chat box's (Chat.lua); WowCompanion_Agent registers the
-- agents'. With the agents off, Core and Link are the dictation product.
--   WC.Link.Handle(kind, fn)    fn(inbox) -> outcome string
--   WC.Link.Run(step)           a step through its handler: ok, outcome
--   WC.Link.Current()           the conversation slot of the message being handled
--   WC.Link.Slash(word, fn)     a /wc subcommand
--   WC.Link.Settings()          the companion's settings as its last status said
--                               (talk, and the chords l1, l2, r1, r2, quick, say,
--                               as WoW names joined with +; feedback, speech, mic,
--                               engines, mics: the inputs Windows lists now), or
--                               nil while it has said none
--   WC.Link.Status()            that last status message itself
-- Bus messages sent: TALK_TAP (a tap of the talk button), TALK_DOWN and
-- TALK_UP (its press and release), TALK_HOLD (the press outlasted a tap),
-- JOB_MESSAGE(inbox) (a handled message that names a job or lists jobs: their
-- states for whoever keeps them), LINK_STEP(step, ok, outcome) (a follow-up step
-- ran), LINK_FAILED(text), MAILBOX_JOBS(jobs), COMPANION_STATUS(inbox).

local SLOTS_PREFIX = "WowCompanion"
local SIGNALS = "Interface\\AddOns\\WowCompanion_Link\\Signals\\"

WC.Saved("WowCompanion_Link", "WowCompanionLinkDB")

local nextSlot = 1
-- the poll's counts, saved at every reload; and when this session's polling began
local channel = { plays = 0, taken = 0, slowed = 0, stale = 0 }
local enteredAt = 0

local function say(message)
	print("|cff66ccffCompanion|r " .. message)
end

-- a message that could not be handled, said in chat
local function report(key, value)
	say(key .. ": " .. tostring(value))
end

local function slotName(n)
	return ("%s_S%03d"):format(SLOTS_PREFIX, n)
end

-- The game's half of the audit trail (src/audit.rs; tools/audit.py merges
-- both): what arrived, what was drawn, what the window predicted. Kept in
-- WowCompanionLinkDB.audit, the newest 600 lines, readable after a reload.
local function audit(what, slot, detail)
	if type(WowCompanionLinkDB) ~= "table" then return end
	local log = WowCompanionLinkDB.audit or {}
	WowCompanionLinkDB.audit = log
	log[#log + 1] = ("%.0f game %s %s %s"):format(time() * 1000, WC.Conversations.Wire(slot), what, tostring(detail or ""))
	while #log > 600 do table.remove(log, 1) end
end

-- What the helper is allowed to ask for. A dispatch table rather than loadstring on
-- whatever arrives: the rule is configuration only, and this is where that rule lives.
local handlers = {}
-- the conversation of the message being handled, so what its steps report (code
-- ran, a button offered, a failure) lands in that conversation
local current

-- The talk button in the game. The companion holds which button it is
-- (settings.talk in its status, set on our settings page,
-- docs/proposals/settings-in-game.md); WoW's binding of it to our button is a
-- copy we write (writeTalkBinding below), never in WoW's Keybindings screen,
-- where a change would come with no press for the companion to see. It runs on
-- press and release, so a tap is told from a hold: a tap sends TALK_TAP (the
-- Agent opens or closes its window), a hold does nothing here (the PC's
-- push-to-talk, its clip named by the PC's `heard`). TALK_DOWN and TALK_UP go
-- out on both edges (the chat wheel's ring), TALK_HOLD once a press has
-- outlasted a tap (the PC's own line, crates/voice TAP: it is talking now).
local TAP_MAX = 0.35
local downAt
local function talkEdge(keystate)
	if keystate == "down" then
		local at = GetTime()
		downAt = at
		WC.Send("TALK_DOWN")
		C_Timer.After(TAP_MAX, function()
			if downAt == at then WC.Send("TALK_HOLD") end
		end)
		return
	end
	local held = downAt and GetTime() - downAt
	downAt = nil
	WC.Send("TALK_UP")
	if held and held <= TAP_MAX then WC.Send("TALK_TAP") end
end
local talkButton = _G["WCTalkKey"] or CreateFrame("Button", "WCTalkKey", UIParent)
talkButton:RegisterForClicks("AnyDown", "AnyUp")
talkButton:SetScript("OnClick", function(_, _, down) talkEdge(down and "down" or "up") end)
local TALK_ACTION = "CLICK WCTalkKey:LeftButton"

-- A clip let go, named by the job the PC made for it: its state goes out as
-- every job's does (JOB_MESSAGE), to the window's model and dictation's wait.
function handlers.heard()
	return "heard"
end

-- WoW's binding of the talk button, written from the companion's settings.talk
-- (out of combat): the button the companion reports, and no other, clicks ours.
-- A key that holds ours and is no longer the talk button is cleared; a key
-- holding something else is overwritten only when it is the talk button.
local function writeTalkBinding(talk)
	local changed = false
	for _, key in ipairs({ GetBindingKey(TALK_ACTION) }) do
		if key ~= talk then
			SetBinding(key)
			changed = true
		end
	end
	if talk and GetBindingAction(talk) ~= TALK_ACTION then
		SetBindingClick(talk, "WCTalkKey")
		changed = true
	end
	if changed then SaveBindings(GetCurrentBindingSet()) end
end

-- The companion's state, its last `status` (docs/proposals/settings-in-game.md,
-- Protocol): `mic` false while the chosen microphone is gone (unplugged, or the
-- headset taken by a phone), assumed there at every load until the companion
-- says otherwise (Status.lua draws it); `settings` the values it runs with (none
-- until it has reported them: our settings page says so); `binding`, `bind`,
-- `set` its answers to the page's bind and set commands.
local mic = true
local lastStatus = {}
function handlers.status(inbox)
	if inbox.mic ~= nil then mic = inbox.mic and true or false end
	lastStatus = inbox
	local talk = type(inbox.settings) == "table" and inbox.settings.talk
	if talk then WC.AfterCombat(function() writeTalkBinding(talk) end) end
	WC.Send("COMPANION_STATUS", inbox)
	return "status: mic " .. tostring(mic)
end

-- With the agents off (dictation only), what would be a conversation line (a
-- clip that sent nothing, a reconnected headset, a crash) comes as a notice,
-- shown as Link shows its own problems. With the agents on it is never sent.
function handlers.notice(inbox)
	local text = tostring(inbox.text or "")
	WC.Board.toast("|cffff7777" .. text .. "|r", 1, 0.6, 0.6, 10)
	return "notice shown"
end

-- One message, as if it had come alone (from a slot's list or the mailbox).
-- A handler returning WC.Link.HELD (a line held already) ends it there: its
-- steps ran when it first came.
local HELD = "held already"
local function dispatch(inbox, label)
	local handler = handlers[inbox.kind or ""]
	if not handler then
		report(label, "unknown kind: " .. tostring(inbox.kind))
		return
	end
	current = inbox.slot
	do
		local list = {}
		for _, e in ipairs(type(inbox.list) == "table" and inbox.list or {}) do
			if type(e) == "table" then list[#list + 1] = ("%.0f=%s"):format(tonumber(e.job) or 0, tostring(e.state)) end
		end
		audit("recv", inbox.slot, ("%s%s%s%s%s%s"):format(tostring(inbox.kind),
			inbox.job and (" job=%.0f"):format(inbox.job) or "", inbox.state and (" " .. inbox.state) or "",
			inbox.who and (" who=" .. inbox.who) or "", #list > 0 and (" list{" .. table.concat(list, ",") .. "}") or "",
			inbox.text and (" " .. tostring(inbox.text):sub(1, 60)) or ""))
	end
	local ok, result = pcall(handler, inbox)
	if not ok then report(label, "error: " .. tostring(result)) end
	if result == HELD then
		current = nil
		return
	end
	if inbox.job or inbox.list then WC.Send("JOB_MESSAGE", inbox) end
	-- A reply and the action it describes are one thought, so they ride in one
	-- message: two sends would mean two bells and two seconds of waiting between
	-- reading the answer and being offered the button.
	local following = inbox.andThen
	if following and handlers[following.kind or ""] then
		local done, outcome = pcall(handlers[following.kind], following)
		if not done then
			report(label .. " follow-up", "error: " .. tostring(outcome))
		end
		WC.Send("LINK_STEP", following, done, outcome)
	end
	current = nil
end

-- The next slot, loaded and its messages handled.
-- `bell` is what the poll saw when it took the slot (check). Every take is
-- audited with it, and with whether the inbox was written for this session: a
-- slot taken before the companion wrote it holds an earlier session's message,
-- which is how dictated lines were lost (2026-11-13). Counted, not refused, until
-- the evidence says which bell readings to trust.
local function receive(bell)
	local slot = nextSlot
	nextSlot = nextSlot + 1
	local loaded, reason = C_AddOns.LoadAddOn(slotName(slot))
	local inbox = WowCompanion_Inbox
	WowCompanion_Inbox = nil
	local ours = type(inbox) == "table" and inbox.session == WowCompanionLinkDB.loads
	if not ours then channel.stale = channel.stale + 1 end
	audit("take", "", ("slot=%d %s %s"):format(slot, ours and "fresh" or ("STALE session=" .. tostring(type(inbox) == "table" and inbox.session)), bell))
	if not loaded or not inbox then
		report("slot " .. slot, "failed: " .. tostring(reason))
		return
	end
	if inbox.kind ~= "list" or type(inbox.messages) ~= "table" then
		report("slot " .. slot, "not a list: " .. tostring(inbox.kind))
		return
	end
	for _, message in ipairs(inbox.messages) do
		if type(message) == "table" then dispatch(message, "slot " .. slot) end
	end
end

-- An error anywhere in polling or handling a message is caught, said once, and
-- polling goes on. Unguarded, one error could stop the companion hearing
-- anything until a /reload.
local reportedFailures = {}
local function safely(label, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		local key = label .. tostring(err)
		if not reportedFailures[key] then
			reportedFailures[key] = true
			local text = ("%s failed: %s"):format(label, tostring(err))
			WC.Board.toast("|cffff7777" .. text .. "|r", 1, 0.6, 0.6, 10)
			WC.Send("LINK_FAILED", text)
		end
	end
end

-- The slot bells (docs/proposals/slot-bells.md): a bell per slot, a set per
-- session (loads % 3), each empty until the PC writes that slot, never emptied
-- while its session runs. Every 0.1 s the next slot's bell is played and asked
-- 20 ms later (the short bell plays within 2 ms); a ring takes the slot, and the
-- slot after it is asked at once, so a burst drains a message per check.
-- Asked every frame, the game holds its sound files open; at 0.1 s it does
-- not. While the heartbeat is stale (Status.lua), which is what
-- held files look like, it asks every 0.5 s. Polled from
-- OnUpdate, which WoW keeps calling whatever happened the frame before, rather
-- than a C_Timer ticker, which a callback error may cancel for good.
local EVERY, SLOW, ASK = 0.1, 0.5, 0.02
local set -- this session's set, from ADDON_LOADED
local every = EVERY
local clock, handle, willPlay, playedAt = 0, nil, nil, 0
local function bellPath(n)
	return SIGNALS .. ("g%d-%03d.wav"):format(set, n)
end
local function check(elapsed)
	clock = clock + elapsed
	if handle then
		if clock < ASK then return end
		local playing = C_Sound.IsPlaying(handle)
		StopSound(handle)
		local bell = ("will=%s handle=%s asked=%.3f frame=%.3f up=%.1f"):format(tostring(willPlay), tostring(handle),
			GetTime() - playedAt, elapsed, GetTime() - enteredAt)
		handle = nil
		if playing then
			channel.taken = channel.taken + 1
			safely("a message from the companion", receive, bell)
			clock = every -- the next slot at once
		end
	end
	if clock < every then return end
	clock = 0
	channel.plays = channel.plays + 1
	willPlay, handle = PlaySoundFile(bellPath(nextSlot), "Master")
	playedAt = GetTime()
end
local function heartbeat(fresh)
	local was = every
	every = fresh and EVERY or SLOW
	if not fresh and was ~= SLOW then
		channel.slowed = channel.slowed + 1
		WC.Send("LINK_FAILED", "the heartbeat went stale, so the game may be holding sound files: checking for messages every 0.5 s until it is back")
	end
end

local pollFrame = CreateFrame("Frame")
local polling = false
local function setPolling(on)
	polling = on
	pollFrame:SetScript("OnUpdate", on and function(_, elapsed)
		safely("slot bells", check, elapsed)
	end or nil)
end

-- /wc: subcommands registered by Link and the Agent
local slash = {}
SLASH_WOWCOMPANION1 = "/wc"
SlashCmdList.WOWCOMPANION = function(command)
	local word, rest = command:match("^(%S*)%s*(.-)$")
	local fn = slash[word]
	if fn then return fn(rest, command) end
	local words = {}
	for w in pairs(slash) do if w ~= "" then words[#words + 1] = "/wc " .. w end end
	table.sort(words)
	say(table.concat(words, ", "))
end
-- the bell poll is the only thing the bridge does continuously
slash.quiet = function()
	setPolling(false)
	say("bell poll stopped; nothing from the helper will arrive until /wc listen")
end
slash.listen = function()
	if not polling then setPolling(true) end
	say("bell poll running")
end
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
-- fires on /reload as well as logout, just before SavedVariables is written
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" and ... == "WowCompanion_Link" then
		local db = WowCompanionLinkDB
		-- loads of this save, counted here only: 1 after a higher count means the
		-- save was lost and the addon loaded empty (read by src/backups.rs)
		db.loads = (db.loads or 0) + 1
		set = db.loads % 3
		db.previous, db.probe = nil, nil
	elseif event == "PLAYER_ENTERING_WORLD" and not polling then
		-- after every addon's PLAYER_LOGIN (the Agent's window is built and
		-- refilled by then): the mailbox (WowCompanion_Mailbox, src/ledger.rs),
		-- every line the game has not saved yet, applied as a slot's would be;
		-- then the bells
		local mail = WowCompanion_Mail
		WowCompanion_Mail = nil
		if type(mail) == "table" then
			for _, line in ipairs(type(mail.lines) == "table" and mail.lines or {}) do
				if type(line) == "table" then dispatch(line, "mailbox") end
			end
			WC.Send("MAILBOX_JOBS", mail.jobs)
		end
		enteredAt = GetTime()
		setPolling(true)
	elseif event == "PLAYER_LOGOUT" then
		-- how many slots this game session can see (folders made after launch
		-- are invisible until a restart): the companion sends no further than this
		pcall(function()
			local seen = 0
			for index = 1, C_AddOns.GetNumAddOns() do
				local name = C_AddOns.GetAddOnInfo(index)
				if name and name:find("^" .. SLOTS_PREFIX .. "_S%d+$") then
					seen = seen + 1
				end
			end
			WowCompanionLinkDB.slotCount = seen
		end)
		WowCompanionLinkDB.channel = channel
	end
end)

WC.Link = {
	-- Status.lua: the heartbeat went stale (false) or fresh again (true)
	Heartbeat = heartbeat,
	HELD = HELD,
	Handle = function(kind, fn) handlers[kind] = fn end,
	Run = function(step)
		local handler = handlers[step.kind or ""]
		if not handler or step.kind == "batch" then return false, "unknown kind" end
		return pcall(handler, step)
	end,
	Current = function() return current end,
	-- run fn(...) as part of the conversation `slot`, as a message of it would be
	As = function(slot, fn, ...)
		local was = current
		current = slot
		local ok, err = pcall(fn, ...)
		current = was
		if not ok then error(err, 0) end
	end,
	Slash = function(word, fn) slash[word] = fn end,
	say = say,
	MessagesSent = function() return nextSlot - 1 end,
	Audit = audit,
	-- the talk button by WoW's name, for prompts that name it, or nil while the
	-- companion has reported none
	TalkKey = function() return type(lastStatus.settings) == "table" and lastStatus.settings.talk or nil end,
	Settings = function() return type(lastStatus.settings) == "table" and lastStatus.settings or nil end,
	Status = function() return lastStatus end,
	-- false while the companion has no microphone (handlers.status)
	Mic = function() return mic end,
}
