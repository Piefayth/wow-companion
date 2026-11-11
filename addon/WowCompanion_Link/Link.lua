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
local BELLS = 8
local SIGNALS = "Interface\\AddOns\\WowCompanion_Link\\Signals\\"

WC.Saved("WowCompanion_Link", "WowCompanionLinkDB", function(db)
	WC.MoveSaved(db, { "loads", "leftAt", "slotCount", "channel", "talkKey", "chatChannel",
		"chatBoxTrace", "minimapAngle", "bridgeProbe", "keepChatDraft", "probe", "previous" })
end)

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

-- "m" names: see bell_name in src/main.rs
local function bellPath(n)
	return SIGNALS .. "m" .. ((n - 1) % BELLS + 1) .. ".wav"
end

-- catch-up bells: see catch_up_name in src/main.rs
local function catchUpPath(n)
	return SIGNALS .. "c" .. ((n - 1) % BELLS + 1) .. ".wav"
end

-- frame bells, on trial beside the message bells: see ring_frame_bell in src/channel.rs
local function frameBellPath(n)
	return SIGNALS .. "f" .. ((n - 1) % BELLS + 1) .. ".wav"
end

-- when this UI session began, to tell this session's messages from a slot's old one
local sessionStart = time()

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

-- Probing for a game -> PC channel that is not the pixel strip.
-- `LoggingChat(true)` makes the client write chat to Logs\WoWChatLog.txt, a plain
-- text file the helper can tail; the marker goes out two ways and the helper
-- reports which, if any, reached disk.
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
	return ("logging on: %s, marked %s"):format(tostring(LoggingChat()), nonce)
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

-- What the poll has seen, saved at every reload, so a stuck channel can be read
-- from the save file instead of guessed at.
local channel = { polls = 0, heard = 0, caughtUp = 0 }
-- which path took each slot first: frame, message or catchUp (a slot is taken once)
local function take(path, catchingUp)
	local taken = receive(catchingUp)
	if taken ~= false then
		channel.took = channel.took or {}
		channel.took[path] = (channel.took[path] or 0) + 1
	end
	return taken
end
local loadedAt = GetTime()
local catchUpTurn = 0

-- The message bell: one at a time, the next slot's, as on 2026-11-09. Polling
-- more message bells at once kept every bell file open in the game and the
-- companion could no longer write them (2026-11-10).
local function poll()
	channel.polls = channel.polls + 1
	channel.lastPoll = time()
	channel.waitingOn = nextSlot
	local waiting = nextSlot
	safely("bell poll", listen, bellPath(waiting), function(rang)
		if rang and nextSlot == waiting then
			channel.heard = channel.heard + 1
			safely("a message from the companion", take, "message")
		end
	end)
	-- The catch-up bells, beside the message bells: one per poll, in turn over
	-- this slot and the next 6 (never the 8th, which is the bell of the slot just
	-- taken, left ringing). Only after a message has been heard this session, or
	-- 10 s after loading: messages sent during a loading screen often miss their
	-- 2 s bell.
	if channel.heard > 0 or GetTime() - loadedAt > 10 then
		local ahead = catchUpTurn
		catchUpTurn = (catchUpTurn + 1) % (BELLS - 1)
		channel.catchUpPolls = (channel.catchUpPolls or 0) + 1
		safely("catch-up poll", listen, catchUpPath(waiting + ahead), function(rang)
			if rang then
				channel.catchUpRang = (channel.catchUpRang or 0) + 1
				channel.lastCatchUpRang = ("c%d while waiting on %d (next %d) at %s"):format(
					(waiting + ahead - 1) % BELLS + 1, waiting, nextSlot, date("%H:%M:%S"))
			end
			if rang and nextSlot == waiting then
				channel.caughtUp = channel.caughtUp + 1
				channel.lastCaughtUp = ("waiting on slot %d, took %d at %s"):format(waiting, ahead + 1, date("%H:%M:%S"))
				for _ = 0, ahead do
					local ok, taken = pcall(take, "catchUp", true)
					if not ok or taken == false then
						break
					end
				end
			end
		end)
	end
end

-- The frame bell trial (the player's yes, 2026-11-11): the next slot's f bell,
-- played one frame and asked the next (IsPlaying says yes 2 ms after a ringing
-- bell starts; a check costs about a microsecond). One play in flight at a time.
-- A ring takes the slot with the catch-up path's session check. Off with
-- `/wc frames off` (saved), if the companion cannot write a bell the game holds.
local frameHandle, frameSlot, framePlayedAt
local function frameCheck()
	if frameHandle then
		local playing = C_Sound.IsPlaying(frameHandle)
		StopSound(frameHandle)
		if playing then
			if nextSlot == frameSlot then
				local lag = (GetTime() - framePlayedAt) * 1000
				local taken = take("frame", true)
				if taken == false then
					channel.frameEmpty = (channel.frameEmpty or 0) + 1
				else
					channel.frameHeard = (channel.frameHeard or 0) + 1
					channel.frameLagMs = (channel.frameLagMs or 0) + lag
					channel.frameLagMaxMs = math.max(channel.frameLagMaxMs or 0, math.floor(lag))
				end
			else
				-- rang for a slot another path took already
				channel.frameLate = (channel.frameLate or 0) + 1
			end
		end
	end
	frameHandle = nil
	if WowCompanionLinkDB.frameBells == false then return end
	channel.framePolls = (channel.framePolls or 0) + 1
	frameSlot, framePlayedAt = nextSlot, GetTime()
	local _, handle = PlaySoundFile(frameBellPath(frameSlot), "Master")
	frameHandle = handle
end

-- Polled from OnUpdate, which WoW keeps calling whatever happened the frame
-- before, rather than a C_Timer ticker, which a callback error may cancel for good.
local pollFrame = CreateFrame("Frame")
local polling = false
local function setPolling(on)
	polling = on
	local since = 0
	pollFrame:SetScript("OnUpdate", on and function(_, elapsed)
		safely("frame bell", frameCheck)
		since = since + elapsed
		if since >= 0.5 then
			since = 0
			poll()
		end
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
-- the frame bell trial's counts, said and drawn on the strip (read without a reload)
slash.frames = function(rest)
	if rest == "off" or rest == "on" then
		WowCompanionLinkDB.frameBells = rest == "on"
		say("frame bells " .. rest)
		return
	end
	local c, t = channel, channel.took or {}
	local text = ("frame bells %s: polls %d, heard %d, rang for a slot taken already %d, empty or stale %d, lag avg %.0f ms max %d ms; slots taken by frame %d, message %d, catch-up %d; message polls %d"):format(
		WowCompanionLinkDB.frameBells == false and "off" or "on", c.framePolls or 0, c.frameHeard or 0,
		c.frameLate or 0, c.frameEmpty or 0, (c.frameLagMs or 0) / math.max(1, c.frameHeard or 0),
		c.frameLagMaxMs or 0, t.frame or 0, t.message or 0, t.catchUp or 0, c.polls)
	say(text)
	if WowCompanion_Strip and WowCompanion_Strip.Send then WowCompanion_Strip.Send(text, 15) end
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
		-- the game saves before it reloads, so hold on to the session just read
		db.previous = db.probe
		db.probe = {}
		-- Messages sent during the loading screen belong to this session: its
		-- boundary is the save the reload wrote, not when this file ran.
		local left = tonumber(db.leftAt)
		if left and left <= sessionStart and sessionStart - left < 300 then
			sessionStart = left
		end
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
		WowCompanionLinkDB.leftAt = time()
	end
end)

WC.Link = {
	HELD = HELD,
	Handle = function(kind, fn) handlers[kind] = fn end,
	Run = function(step)
		local handler = handlers[step.kind or ""]
		if not handler or step.kind == "batch" then return false, "unknown kind" end
		return pcall(handler, step)
	end,
	Current = function() return current end,
	Slash = function(word, fn) slash[word] = fn end,
	say = say,
	record = record,
	-- listen for one of our signal sounds (Signals/<file>) playing
	ListenSignal = function(file, heard) return listen(SIGNALS .. file, heard) end,
	MessagesSent = function() return nextSlot - 1 end,
}
