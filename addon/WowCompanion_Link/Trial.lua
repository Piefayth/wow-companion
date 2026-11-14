-- The inbox on trial (docs/proposals/reliable-channel.md): one file that every
-- trial slot reads, beside the channel on files of its own, counted here and
-- never applied. The PC (src/inbox.rs) writes every batch it sends as write n
-- of this session into WowCompanion_Link\Inbox.lua, replaced whole, then rings
-- trial bell n (Signals\t<set>-<n>.wav). This asks the bell after the last
-- write it has seen as the channel asks its bells (Link.lua: played, asked 20
-- ms later, at the channel's interval); a ring loads the next trial slot
-- (WowCompanion_T001..., whose Slot.xml names that inbox) and counts the writes
-- newer than the last seen. A ring with none newer is a false one: a slot
-- spent, nothing lost. Every take goes in Link's audit ("trial"), the counts in
-- WowCompanionLinkDB.trial at every reload (tools/inbox_trial.py reads both).

local SIGNALS = "Interface\\AddOns\\WowCompanion_Link\\Signals\\"
-- trial bells per set, as many as trial slots (src/inbox.rs)
local BELLS = 256
local ASK = 0.02

-- rings: asks that read playing; fresh: rings that found newer writes; empty:
-- rings that found none (false rings); stale: an inbox from another session;
-- unread: a load that gave no inbox; gaps: write numbers missing from an inbox
local counts = { slots = 0, plays = 0, rings = 0, fresh = 0, empty = 0, stale = 0, unread = 0, gaps = 0, writes = 0, messages = 0, seen = 0 }
local session, set
local nextSlot, seen = 1, 0
local clock, handle, playedAt = 0, nil, 0
local frame = CreateFrame("Frame")

local function note(detail)
	WC.Link.Audit("trial", "", detail)
end

local function stop(why)
	counts.stopped = why
	note("stopped: " .. why)
	frame:SetScript("OnUpdate", nil)
end

local function take(bell)
	if nextSlot > counts.slots then return stop("every trial slot spent") end
	local slot = nextSlot
	nextSlot = nextSlot + 1
	WowCompanion_Trial = nil
	local loaded, reason = C_AddOns.LoadAddOn(("WowCompanion_T%03d"):format(slot))
	local inbox = WowCompanion_Trial
	WowCompanion_Trial = nil
	if not loaded or type(inbox) ~= "table" then
		counts.unread = counts.unread + 1
		return note(("T%03d unread (%s) %s"):format(slot, tostring(reason), bell))
	end
	if inbox.session ~= session then
		counts.stale = counts.stale + 1
		return note(("T%03d stale session=%s %s"):format(slot, tostring(inbox.session), bell))
	end
	local last = tonumber(inbox.bell) or 0
	if last <= seen then
		counts.empty = counts.empty + 1
		return note(("T%03d nothing newer than %d %s"):format(slot, seen, bell))
	end
	local got, kinds = {}, {}
	for _, write in ipairs(type(inbox.writes) == "table" and inbox.writes or {}) do
		if type(write) == "table" and type(write.n) == "number" and write.n > seen and write.n <= last then
			got[write.n] = true
			local names = {}
			for _, message in ipairs(type(write.messages) == "table" and write.messages or {}) do
				names[#names + 1] = type(message) == "table" and tostring(message.kind) or "?"
			end
			counts.messages = counts.messages + #names
			kinds[#kinds + 1] = write.n .. ":" .. table.concat(names, ",")
		end
	end
	local missing = {}
	for n = seen + 1, last do
		if got[n] then counts.writes = counts.writes + 1 else missing[#missing + 1] = n end
	end
	counts.gaps = counts.gaps + #missing
	counts.fresh = counts.fresh + 1
	note(("T%03d new %d-%d %s%s %s"):format(slot, seen + 1, last, table.concat(kinds, " "),
		#missing > 0 and (" MISSING " .. table.concat(missing, ",")) or "", bell))
	seen = last
	counts.seen = seen
	if seen >= BELLS then stop("every trial bell rung") end
end

local function check(elapsed)
	local every = WC.Link.Every()
	clock = clock + elapsed
	if handle then
		if clock < ASK then return end
		local playing = C_Sound.IsPlaying(handle)
		StopSound(handle)
		handle = nil
		if playing then
			counts.rings = counts.rings + 1
			take(("asked=%.3f frame=%.3f"):format(GetTime() - playedAt, elapsed))
			clock = every -- the next bell at once
		end
	end
	if clock < every or not frame:GetScript("OnUpdate") then return end
	clock = 0
	counts.plays = counts.plays + 1
	local _
	_, handle = PlaySoundFile(SIGNALS .. ("t%d-%03d.wav"):format(set, seen + 1), "Master")
	playedAt = GetTime()
end

-- an error stops the trial, said once in the audit: it must never cost the
-- channel anything
local function tick(_, elapsed)
	local ok, err = pcall(check, elapsed)
	if not ok then stop("error: " .. tostring(err)) end
end

frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_ENTERING_WORLD" and not session then
		session = WowCompanionLinkDB.loads
		set = session % 3
		-- the trial slots the client found at launch: none until a full restart
		-- after the install that made them
		for index = 1, C_AddOns.GetNumAddOns() do
			local name = C_AddOns.GetAddOnInfo(index)
			if name and name:find("^WowCompanion_T%d+$") then counts.slots = counts.slots + 1 end
		end
		note(("start session=%s set=%d slots=%d"):format(tostring(session), set, counts.slots))
		if counts.slots > 0 then frame:SetScript("OnUpdate", tick) end
	elseif event == "PLAYER_LOGOUT" then
		WowCompanionLinkDB.trial = counts
	end
end)
