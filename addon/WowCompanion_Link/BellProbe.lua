-- The bell probe (2026-11-13, docs/proposals/reliable-channel.md, "Finding the
-- bug first"): why the game sometimes hears an empty slot bell ring. A trial
-- beside the channel: the channel's own procedure (Link.lua, check), run on
-- bells no session reaches (slots 509-512 of each set, offered a Reload at 16
-- left, and never.wav), all empty since launch and written by nothing. It never
-- takes a slot.
--
-- Like the channel's cursor, it plays the same control every 0.1 s, asks
-- C_Sound.IsPlaying 20 ms later and stops it. A control answering "playing" is a
-- false ring: it is not stopped, it is asked again 0.02, 0.1, 0.3, 0.6 and 1 s
-- after it was played (how long the false ring lasts), and the probe moves to
-- the next control at once, as the channel's drain moves to the next slot (how
-- many asks one bad moment covers; at most RUN at once, since asked every frame
-- the game held its sound files). Every 5 s it plays always.wav, ten silent
-- seconds nothing rewrites, and asks it at once and at the same times: what a
-- real sound answers. `PlaySoundFile` says it will play an empty bell every time
-- (measured: 2,952 of 2,952), so only IsPlaying tells a ring.
-- Counts and false rings, with frame times, combat and the time since the last
-- loading screen, go to WowCompanionLinkDB.bellProbe (saved at reload, the last
-- few sessions kept) and are read live through the data strip.

local SIGNALS = "Interface\\AddOns\\WowCompanion_Link\\Signals\\"
local EVERY, ASK, REFERENCE_EVERY, RUN = 0.1, 0.02, 5, 10
local LATER = { 0.02, 0.1, 0.3, 0.6, 1.0 }
local KEPT_SESSIONS, KEPT_RINGS = 6, 400

local CONTROLS = { "never.wav" }
for set = 0, 2 do
	for slot = 509, 512 do CONTROLS[#CONTROLS + 1] = ("g%d-%03d.wav"):format(set, slot) end
end

local session -- this session's record in WowCompanionLinkDB.bellProbe.sessions
local enteredAt, loadedAt = 0, 0
local control, clock, run = 1, 0, 0
local asking -- the control being asked: { name, handle, playedAt, frame }
local follow = {} -- open follow-ups: { handle, playedAt, step, record }
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

local function step(elapsed)
	local now = GetTime()
	tickFollowUps(now)
	-- the reference: a real sound, asked the same way
	if now >= nextReference then
		nextReference = now + REFERENCE_EVERY
		local will, handle = PlaySoundFile(SIGNALS .. "always.wav", "Master")
		local record = { will = tostring(will) }
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
		local playing = asking.handle ~= nil and C_Sound.IsPlaying(asking.handle)
		session.asks = session.asks + 1
		count(("will=%s playing=%s"):format(tostring(asking.will), tostring(playing)))
		if playing then
			run = run + 1
			local record = {
				name = asking.name, handle = asking.handle,
				asked = ("%.3f"):format(now - asking.playedAt), frame = ("%.3f"):format(asking.frame),
				askFrame = ("%.3f"):format(elapsed), fps = math.floor(GetFramerate()),
				combat = InCombatLockdown() or nil, up = ("%.1f"):format(now - enteredAt),
				sinceLoad = ("%.1f"):format(now - loadedAt), time = time(), run = run,
			}
			local rings = session.rings
			if #rings < KEPT_RINGS then rings[#rings + 1] = record end
			session.ringCount = session.ringCount + 1
			followUp(asking.handle, asking.playedAt, record)
			-- the next control at once, as the channel's drain asks the next slot
			control = control % #CONTROLS + 1
			clock = run < RUN and EVERY or 0
		else
			if asking.handle then StopSound(asking.handle) end
			if run > 0 then session.runs[run] = (session.runs[run] or 0) + 1 end
			run = 0
		end
		asking = nil
	end
	if clock < EVERY then return end
	clock = 0
	local name = CONTROLS[control]
	local will, handle = PlaySoundFile(SIGNALS .. name, "Master")
	asking = { name = name, will = will, handle = handle, playedAt = GetTime(), frame = elapsed }
end

local probeFrame = CreateFrame("Frame")
local function stop(why)
	probeFrame:SetScript("OnUpdate", nil)
	if asking and asking.handle then StopSound(asking.handle) end
	asking = nil
	for _, f in ipairs(follow) do StopSound(f.handle) end
	follow = {}
	if session then session.stopped = why end
end

local function start()
	local db = WowCompanionLinkDB
	db.bellProbe = type(db.bellProbe) == "table" and db.bellProbe or {}
	local sessions = type(db.bellProbe.sessions) == "table" and db.bellProbe.sessions or {}
	db.bellProbe.sessions = sessions
	while #sessions >= KEPT_SESSIONS do table.remove(sessions, 1) end
	session = { loads = db.loads, started = time(), asks = 0, ringCount = 0, counts = {}, runs = {},
		rings = {}, references = {} }
	sessions[#sessions + 1] = session
	enteredAt = GetTime()
	nextReference = enteredAt + 1
	probeFrame:SetScript("OnUpdate", function(_, elapsed)
		local ok, err = pcall(step, elapsed)
		if not ok then stop("error: " .. tostring(err)) end
	end)
end

-- Start (a copy sent through the strip, replacing a running one) and Stop
WC.BellProbe = { Start = start, Stop = function() stop("stopped") end }

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("LOADING_SCREEN_DISABLED")
events:SetScript("OnEvent", function(_, event)
	loadedAt = GetTime()
	if event == "PLAYER_ENTERING_WORLD" and not session then start() end
end)
