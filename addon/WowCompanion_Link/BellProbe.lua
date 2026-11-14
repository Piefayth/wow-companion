-- The bell probe (2026-11-13, docs/proposals/reliable-channel.md, "Finding the
-- bug first"): why the game sometimes hears an empty slot bell ring. A trial
-- beside the channel: it asks bells no slot reaches and never takes a slot.
--
-- Every 0.1 s it plays one control, an empty bell that existed at launch (slots
-- 509-512 of each set, which no session reaches: Reload is offered at 16 left;
-- and never.wav), and asks C_Sound.IsPlaying 20 ms later, as the channel does
-- (Link.lua, check). A control answering anything but "will not play" is an
-- anomaly: it is not stopped, and is asked again 0.02, 0.1, 0.3, 0.6 and 1 s
-- after it was played, to see how long it lasts. The next control is then
-- asked at once, as the channel's drain does after a take, to see how many asks
-- one bad moment covers (at most RUN in a row, so the probe never asks every
-- frame for long: asked every frame, the game held its sound files).
-- Every 5 s it plays always.wav, ten silent seconds nothing rewrites, and asks
-- it at once and at the same times: what a real sound answers.
-- Counts and anomalies, with frame times, combat and the time since the last
-- loading screen, go to WowCompanionLinkDB.bellProbe (saved at reload, the
-- last few sessions kept) and are read live through the data strip. Nothing
-- else reads them.

local SIGNALS = "Interface\\AddOns\\WowCompanion_Link\\Signals\\"
local EVERY, ASK, REFERENCE_EVERY, RUN = 0.1, 0.02, 5, 10
local LATER = { 0.02, 0.1, 0.3, 0.6, 1.0 }
local KEPT_SESSIONS, KEPT_ANOMALIES = 6, 400

local CONTROLS = { "never.wav" }
for set = 0, 2 do
	for slot = 509, 512 do CONTROLS[#CONTROLS + 1] = ("g%d-%03d.wav"):format(set, slot) end
end

local session -- this session's record in WowCompanionLinkDB.bellProbe.sessions
local enteredAt, loadedAt = 0, 0
local nextControl, clock, run = 1, 0, 0
local asking -- the control being asked: { name, handle, will, playedAt, frame }
local follow = {} -- open follow-ups: { handle, playedAt, times, results, record }
local nextReference = 0

local function count(key)
	session.counts[key] = (session.counts[key] or 0) + 1
end

-- ask a handle at each of LATER after it was played, then stop it
local function followUp(handle, playedAt, record)
	follow[#follow + 1] = { handle = handle, playedAt = playedAt, step = 1, record = record }
end

local function tickFollowUps(now)
	for i = #follow, 1, -1 do
		local f = follow[i]
		local at = LATER[f.step]
		if at and now - f.playedAt >= at then
			f.record.later = (f.record.later or "") .. (C_Sound.IsPlaying(f.handle) and "P" or ".")
			f.step = f.step + 1
		end
		if not LATER[f.step] then
			StopSound(f.handle)
			table.remove(follow, i)
		end
	end
end

local function play(name)
	local willPlay, handle = PlaySoundFile(SIGNALS .. name, "Master")
	return willPlay, handle
end

local function step(elapsed)
	local now = GetTime()
	tickFollowUps(now)
	-- the reference: a real sound, asked the same way
	if now >= nextReference then
		nextReference = now + REFERENCE_EVERY
		local will, handle = play("always.wav")
		local record = { will = tostring(will), at = ("%.3f"):format(now - enteredAt) }
		if handle then
			record.first = C_Sound.IsPlaying(handle) and "P" or "."
			followUp(handle, now, record)
		end
		local refs = session.references
		if #refs < 40 then refs[#refs + 1] = record end
	end
	clock = clock + elapsed
	if asking then
		if now - asking.playedAt < ASK then return end
		local playing = asking.handle and C_Sound.IsPlaying(asking.handle) or false
		session.asks = session.asks + 1
		count(("will=%s playing=%s"):format(tostring(asking.will), tostring(playing)))
		if asking.will or playing then
			run = run + 1
			local record = {
				name = asking.name, will = tostring(asking.will), playing = playing,
				asked = ("%.3f"):format(now - asking.playedAt), frame = ("%.3f"):format(asking.frame),
				askFrame = ("%.3f"):format(elapsed), fps = math.floor(GetFramerate()),
				combat = InCombatLockdown() or nil, up = ("%.1f"):format(now - enteredAt),
				sinceLoad = ("%.1f"):format(now - loadedAt), time = time(), run = run,
			}
			local anomalies = session.anomalies
			if #anomalies < KEPT_ANOMALIES then anomalies[#anomalies + 1] = record end
			session.anomalyCount = session.anomalyCount + 1
			if asking.handle then
				followUp(asking.handle, asking.playedAt, record)
			end
			-- the next control at once, as the channel's drain asks the next slot
			clock = run < RUN and EVERY or 0
		else
			if asking.handle then StopSound(asking.handle) end
			if run > 0 then
				session.runs[run] = (session.runs[run] or 0) + 1
			end
			run = 0
		end
		asking = nil
	end
	if clock < EVERY then return end
	clock = 0
	local name = CONTROLS[nextControl]
	nextControl = nextControl % #CONTROLS + 1
	local will, handle = play(name)
	asking = { name = name, will = will, handle = handle, playedAt = GetTime(), frame = elapsed }
end

local probeFrame = CreateFrame("Frame")
local function stop(why)
	probeFrame:SetScript("OnUpdate", nil)
	for _, f in ipairs(follow) do StopSound(f.handle) end
	follow = {}
	if session then session.stopped = why end
end

WC.BellProbe = { Stop = function() stop("stopped") end }

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("LOADING_SCREEN_DISABLED")
events:SetScript("OnEvent", function(_, event)
	loadedAt = GetTime()
	if event ~= "PLAYER_ENTERING_WORLD" or session then return end
	local db = WowCompanionLinkDB
	db.bellProbe = type(db.bellProbe) == "table" and db.bellProbe or {}
	local sessions = type(db.bellProbe.sessions) == "table" and db.bellProbe.sessions or {}
	db.bellProbe.sessions = sessions
	while #sessions >= KEPT_SESSIONS do table.remove(sessions, 1) end
	session = { loads = db.loads, started = time(), asks = 0, anomalyCount = 0, counts = {}, runs = {},
		anomalies = {}, references = {} }
	sessions[#sessions + 1] = session
	enteredAt = GetTime()
	nextReference = enteredAt + 1
	probeFrame:SetScript("OnUpdate", function(_, elapsed)
		local ok, err = pcall(step, elapsed)
		if not ok then stop("error: " .. tostring(err)) end
	end)
end)
