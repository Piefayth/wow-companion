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
-- Bus messages sent: TALK_TAP (a short press of the talk button), TALK_HELD(slot)
-- (a clip let go), LINK_STEP(step, ok, outcome) (a follow-up step ran),
-- LINK_FAILED(text), MAILBOX_JOBS(jobs).

local SLOTS_PREFIX = "WowCompanion"
local SIGNALS = "Interface\\AddOns\\WowCompanion_Link\\Signals\\"

WC.Saved("WowCompanion_Link", "WowCompanionLinkDB")

local nextSlot = 1

local function say(message)
	print("|cff66ccffCompanion|r " .. message)
end

local function record(key, value)
	-- storing nil would delete the key rather than save it, quietly losing the
	-- result instead of reporting that we got nothing
	WowCompanionLinkDB.probe = WowCompanionLinkDB.probe or {}
	WowCompanionLinkDB.probe[key] = value == nil and "nil" or value
	say(key .. ": " .. tostring(value))
end

local function slotName(n)
	return ("%s_S%03d"):format(SLOTS_PREFIX, n)
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

-- What the helper is allowed to ask for. A dispatch table rather than loadstring on
-- whatever arrives: the rule is configuration only, and this is where that rule lives.
local handlers = {}
-- the conversation of the message being handled, so what its steps report (code
-- ran, a button offered, a failure) lands in that conversation
local current

-- A clip let go, or a short tap: the talk button as the game hears it
-- (WowCompanion_TalkKey, the DualSense Create button PADSOCIAL by default).
-- Holding it is push-to-talk on the PC; a short press is a tap (TALK_TAP, the
-- Agent opens its window). The conversation follows the PC's rule (crates/voice
-- lib.rs): a trigger pulled any time during the hold counts, and a second
-- trigger upgrades L2/R2 to Quick and L1/R1 to dictation.
local TAP_MAX = 0.35
local tapButton = CreateFrame("Button", "WowCompanionTap", UIParent)
tapButton:RegisterForClicks("AnyDown", "AnyUp")
tapButton:SetScript("OnUpdate", function(self)
	if not self.downAt then return end
	local now = WowCompanion_PadSlot()
	local slot = self.slot or ""
	if slot == "" and now ~= "" then
		self.slot = now
	elseif now == "quick" and (slot == "l2" or slot == "r2") then
		self.slot = now
	elseif now == "say" and (slot == "l1" or slot == "r1") then
		self.slot = now
	end
end)
tapButton:SetScript("OnClick", function(self, _, down)
	if down then
		self.downAt = GetTime()
		self.slot = WowCompanion_PadSlot()
		return
	end
	local held = self.downAt and GetTime() - self.downAt
	self.downAt = nil
	if not held then return end
	if held > TAP_MAX then
		local slot = self.slot or WowCompanion_PadSlot()
		-- dictation (L1+R1) is no conversation's: its line arrives on its own
		if slot ~= "say" then WC.Send("TALK_HELD", slot) end
	else
		WC.Send("TALK_TAP")
	end
end)
-- Override bindings are an addon's own layer and only while it is loaded, so the
-- player's binding underneath is untouched.
local function bindTap()
	if InCombatLockdown() then return end
	ClearOverrideBindings(tapButton)
	SetOverrideBindingClick(tapButton, false, WowCompanion_TalkKey, "WowCompanionTap", "LeftButton")
end

-- `/wc talkkey`, then press the talk button: the game's name for it (PADSOCIAL,
-- PADBACK...) is learned and kept, so the tap and every prompt naming the
-- button follow any controller. The PC side learns its own view of the same
-- button in the setup window.
local talkKeyFrame
local function learnTalkKey()
	if not talkKeyFrame then
		talkKeyFrame = CreateFrame("Frame", nil, UIParent)
		talkKeyFrame:SetScript("OnGamePadButtonDown", function(self, button)
			self:EnableGamePadButton(false)
			WowCompanionLinkDB.talkKey = button
			WowCompanion_TalkKey = button
			pcall(bindTap)
			say(("talk button learned: %s (%s)"):format(WowCompanion_Glyph(button), button))
		end)
	end
	talkKeyFrame:EnableGamePadButton(true)
	say("press your talk button on the controller now")
end

-- With the agents off (dictation only), what would be a conversation line (a
-- clip that sent nothing, a reconnected headset, a crash) comes as a notice,
-- shown as Link shows its own problems. With the agents on it is never sent.
function handlers.notice(inbox)
	local text = tostring(inbox.text or "")
	WC.Board.toast("|cffff7777" .. text .. "|r", 1, 0.6, 0.6, 10)
	return "notice shown"
end

function handlers.probe(inbox)
	WowCompanionLinkDB.probe = WowCompanionLinkDB.probe or {}
	WowCompanionLinkDB.probe.received = (WowCompanionLinkDB.probe.received or 0) + 1
	return ("message %d, %ds after the helper wrote it"):format(inbox.n, time() - inbox.sent)
end

-- One message, as if it had come alone (from a slot's list or the mailbox).
-- A handler returning WC.Link.HELD (a line held already) ends it there: its
-- steps ran when it first came.
local HELD = "held already"
local function dispatch(inbox, label)
	local handler = handlers[inbox.kind or ""]
	if not handler then
		record(label, "unknown kind: " .. tostring(inbox.kind))
		return
	end
	current = inbox.slot
	if WowCompanion_Audit then
		local list = {}
		for _, e in ipairs(type(inbox.list) == "table" and inbox.list or {}) do
			if type(e) == "table" then list[#list + 1] = ("%.0f=%s"):format(tonumber(e.job) or 0, tostring(e.state)) end
		end
		WowCompanion_Audit("recv", inbox.slot, ("%s%s%s%s%s%s"):format(tostring(inbox.kind),
			inbox.job and (" job=%.0f"):format(inbox.job) or "", inbox.state and (" " .. inbox.state) or "",
			inbox.who and (" who=" .. inbox.who) or "", #list > 0 and (" list{" .. table.concat(list, ",") .. "}") or "",
			inbox.text and (" " .. tostring(inbox.text):sub(1, 60)) or ""))
	end
	local ok, result = pcall(handler, inbox)
	-- only probe traffic is worth narrating in chat
	if inbox.kind == "probe" or not ok then
		record(label, ok and tostring(result) or ("error: " .. tostring(result)))
	end
	if result == HELD then
		current = nil
		return
	end
	-- A reply and the action it describes are one thought, so they ride in one
	-- message: two sends would mean two bells and two seconds of waiting between
	-- reading the answer and being offered the button.
	local following = inbox.andThen
	if following and handlers[following.kind or ""] then
		local done, outcome = pcall(handlers[following.kind], following)
		if not done then
			record(label .. " follow-up", "error: " .. tostring(outcome))
		end
		WC.Send("LINK_STEP", following, done, outcome)
	end
	current = nil
end

-- The next slot, loaded and its messages handled.
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
	if inbox.kind ~= "list" or type(inbox.messages) ~= "table" then
		record("slot " .. slot, "not a list: " .. tostring(inbox.kind))
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
-- Played every frame, bells made the game hold its sound files (2026-11-11); at
-- 0.1 s it never did. While the heartbeat is stale (Status.lua), which is what
-- held files look like, it asks every 0.5 s, the old rate. Polled from
-- OnUpdate, which WoW keeps calling whatever happened the frame before, rather
-- than a C_Timer ticker, which a callback error may cancel for good.
-- The counts are saved at every reload.
local EVERY, SLOW, ASK = 0.1, 0.5, 0.02
local channel = { plays = 0, taken = 0, slowed = 0 }
local set -- this session's set, from ADDON_LOADED
local every = EVERY
local clock, handle = 0, nil
local function bellPath(n)
	return SIGNALS .. ("g%d-%03d.wav"):format(set, n)
end
local function check(elapsed)
	clock = clock + elapsed
	if handle then
		if clock < ASK then return end
		local playing = C_Sound.IsPlaying(handle)
		StopSound(handle)
		handle = nil
		if playing then
			channel.taken = channel.taken + 1
			safely("a message from the companion", receive)
			clock = every -- the next slot at once
		end
	end
	if clock < every then return end
	clock = 0
	channel.plays = channel.plays + 1
	local _, played = PlaySoundFile(bellPath(nextSlot), "Master")
	handle = played
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
slash.talkkey = learnTalkKey
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
frame:RegisterEvent("PLAYER_LOGIN")
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
		-- the game saves before it reloads, so hold on to the session just read
		db.previous = db.probe
		db.probe = {}
	elseif event == "PLAYER_LOGIN" then
		if type(WowCompanionLinkDB.talkKey) == "string" then
			WowCompanion_TalkKey = WowCompanionLinkDB.talkKey
		end
		pcall(bindTap)
		local version, build, _, toc = GetBuildInfo()
		record("client", ("%s.%s, toc %d"):format(version, build, toc))
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
	record = record,
	-- listen for one of our signal sounds (Signals/<file>) playing
	ListenSignal = function(file, heard) return listen(SIGNALS .. file, heard) end,
	MessagesSent = function() return nextSlot - 1 end,
}
