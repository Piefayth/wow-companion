-- The window's model of your messages, pure: no frames, no timers, no game
-- calls. Everything it needs comes in as `deps`, so tools/test_jobs.py runs it
-- under Lua 5.1 against thousands of random schedules (delivery reordered,
-- repeated, dropped) and checks its invariants. Jobs.lua draws from it.
--
-- The design (docs/proposals/conversation-sync.md):
-- * Job states are a join-semilattice: hearing < queued < running < an end,
--   the first end wins. A message's state is taken only when it ranks higher.
--   Any order or repetition of delivery converges (a state-based CRDT).
-- * The window predicts only your own inputs (a clip let go, a cancel, a send
--   now), and drops each prediction when the PC acknowledges that input by its
--   identity; until then it is retried, and if the PC never answers it
--   settles to an honest "not confirmed" (client-side prediction with
--   reconciliation, as in networked games).
-- * A clip's identity is when it was let go. The game's clock is not the PC's
--   (2.3 s apart, measured 2026-11-10), so the offset is learned from each
--   clip the PC confirms and kept in the save file.
--
-- deps: now() game ms; command(verb, slot, id); remember(text, slot, job);
-- audit(what, slot, detail); store (a table kept across reloads); changed().

local M = {}
M.__index = M

local RANK = { hearing = 0, queued = 1, running = 2, answered = 3, cancelled = 3, failed = 3 }
M.RANK = RANK
local JOIN_MS = 1500        -- a clip let go this soon after the last joins it (src/jobs.rs JOIN)
local MATCH_MS = 1200       -- a calibrated release matches within this (src/jobs.rs)
local FIRST_MATCH_MS = 10000 -- before the clock offset is known: the oldest clip within this
local HEAR_MS = 25000       -- a clip whose words never came (the PC drops empty clips silently);
                            -- Whisper can take 12 s, gathering 0.5 s, the channel 4 s
local RETRY_MS, TRIES = 4000, 3

function M.new(deps)
	local m = setmetatable({ deps = deps, jobs = {}, clips = {} }, M)
	local store = deps.store or {}
	m.store = store
	store.jobs = store.jobs or {}
	m.offset = tonumber(store.offset)
	m.samples = {}
	-- the saved ledger: each job's state and whether you asked to cancel it
	local cutoff = deps.now() - 86400000
	for id, e in pairs(store.jobs) do
		if type(id) ~= "number" or id < cutoff or type(e) ~= "table" or not RANK[e.state] then
			store.jobs[id] = nil
		else
			m.jobs[id] = { id = id, slot = e.slot or "", state = e.state, asked = e.asked, heardCancel = e.heardCancel, logged = true }
		end
	end
	return m
end

function M:audit(what, slot, detail) if self.deps.audit then self.deps.audit(what, slot, detail) end end
function M:changed() if self.deps.changed then self.deps.changed() end end

function M:save(job)
	self.store.jobs[job.id] = { slot = job.slot, state = job.state, asked = job.asked or nil, heardCancel = job.heardCancel or nil }
end

local function ensure(m, id, slot)
	local job = m.jobs[id]
	if not job then
		job = { id = id, slot = slot or "" }
		m.jobs[id] = job
	end
	return job
end

-- the one way a job's state changes
function M:advance(id, slot, state)
	if not id or not RANK[state] then return false end
	local job = self.jobs[id]
	if job and job.state and RANK[job.state] >= RANK[state] then return false end
	job = ensure(self, id, slot)
	job.state = state
	if RANK[state] == 3 then
		job.cancel, job.sending = nil, nil
		job.endedAt = self.deps.now()
	end
	if state ~= "queued" then job.sending = nil end
	self:save(job)
	return true
end

-- clips ---------------------------------------------------------------------

function M:Clips(slot) return self.clips[slot or ""] or {} end

-- a clip let go (the game saw the talk button come up, held)
function M:Released(slot)
	slot = slot or ""
	local list = self.clips[slot] or {}
	self.clips[slot] = list
	local now = self.deps.now()
	local last = list[#list]
	if last and not last.cancelled and now - last.lastAt <= JOIN_MS then
		last.lastAt = now
		self:audit("predict", slot, ("clip %.0f joined"):format(last.release))
	else
		list[#list + 1] = { release = now, lastAt = now }
		self:audit("predict", slot, ("clip %.0f"):format(now))
	end
	self:changed()
end

-- the PC's clock for a game release, as far as it is known
function M:pcTime(release) return release + (self.offset or 0) end

local function learn(m, sample)
	local s = m.samples
	s[#s + 1] = sample
	if #s > 7 then table.remove(s, 1) end
	local sorted = {}
	for i, v in ipairs(s) do sorted[i] = v end
	table.sort(sorted)
	m.offset = sorted[math.floor((#sorted + 1) / 2)]
	m.store.offset = m.offset
end

-- the clip a job with this id (the PC's release) was heard as
function M:takeClip(slot, id, cancelledOnly)
	local list = self.clips[slot or ""]
	if not list then return end
	local best, bestGap
	for i, c in ipairs(list) do
		if not cancelledOnly or c.cancelled then
			local gap
			if self.offset then
				gap = math.abs(id - self:pcTime(c.release))
				if gap > MATCH_MS then gap = nil end
			else
				gap = math.abs(id - c.release)
				if gap > FIRST_MATCH_MS then gap = nil else gap = i end -- the oldest, uncalibrated
			end
			if gap and (not bestGap or gap < bestGap) then best, bestGap = i, gap end
		end
	end
	if not best then return end
	local c = table.remove(list, best)
	learn(self, id - c.release)
	return c
end

-- a notice that names no conversation ended whatever was being heard
function M:DropHearing()
	for _, list in pairs(self.clips) do
		for i = #list, 1, -1 do
			if not list[i].cancelled then table.remove(list, i) end
		end
	end
	self:changed()
end

-- cancel a clip still being heard: `clip` itself (its own X), or the newest
function M:CancelClip(slot, clip)
	local list = self.clips[slot or ""] or {}
	for i = #list, 1, -1 do
		local c = list[i]
		if not c.cancelled and (not clip or c == clip) then
			c.cancelled, c.tries, c.sentAt = true, 1, self.deps.now()
			self:audit("predict", slot, ("clip %.0f cancelled"):format(c.release))
			-- Named by its release only once the clock is known; before that no
			-- guess goes out: the cancel stays bound to the clip, and its line
			-- (Claim) cancels the job by its id, which is exact.
			if self.offset then self.deps.command("hear", slot, self:pcTime(c.release)) end
			self:changed()
			return c
		end
	end
end

-- messages ------------------------------------------------------------------

-- Your line arrives, before it is shown. Its job resolves the clip it was
-- heard as; if you cancelled that clip, the cancel is now this job's and the
-- words stay hidden ("hidden"). A job shown already is not shown again ("dup").
function M:Claim(inbox, slot)
	local id = tonumber(inbox.job)
	if not id or inbox.who ~= "you" then return end
	slot = slot or inbox.slot or ""
	local job = self.jobs[id]
	if job and job.logged then return "dup" end
	local c = self:takeClip(slot, id)
	self:audit("claim", slot, ("%.0f clip=%s%s offset=%s"):format(id, c and ("%.0f"):format(c.release) or "none",
		c and c.cancelled and " (cancelled: hidden)" or "", tostring(self.offset)))
	job = ensure(self, id, slot)
	job.logged = true
	if inbox.state then self:advance(id, slot, inbox.state) end
	self:save(job)
	self:changed()
	if c and c.cancelled then
		job.heardCancel, job.asked = true, true
		self:save(job)
		if RANK[job.state or "queued"] < 3 then
			job.cancel = { tries = 1, sentAt = self.deps.now() }
			self.deps.command("cancel", slot, id)
		end
		return "hidden"
	end
end

-- any message about jobs: its own `job` and `state`, and any `list`
function M:Apply(inbox)
	local slot = inbox.slot
	if inbox.job and inbox.state then
		local id = tonumber(inbox.job)
		self:advance(id, slot, inbox.state)
		local job = self.jobs[id]
		if job and inbox.queueId and not job.queueId then job.queueId = inbox.queueId end
		-- a reply names every message it answers in its `list` (src/requests.rs);
		-- nothing is inferred: one cancelled during the run stays cancelled
	end
	for _, e in ipairs(type(inbox.list) == "table" and inbox.list or {}) do
		if type(e) == "table" and tonumber(e.job) then self:advance(tonumber(e.job), e.slot or slot, e.state) end
	end
	self:changed()
end

-- the PC's answer to a cancel or a stop. A hearing cancel resolves the
-- cancelled clip by the job it hit; if its words were dropped no line comes,
-- so the tombstone is written here, where the clip was.
function M:Stopped(inbox)
	local slot = inbox.slot or ""
	self:Apply(inbox)
	if not inbox.hearing then return end
	local hit = false
	for _, e in ipairs(type(inbox.list) == "table" and inbox.list or {}) do
		local id = type(e) == "table" and tonumber(e.job)
		if id then
			hit = true
			local c = self:takeClip(slot, id, true)
			local job = self.jobs[id]
			if job and not job.logged and (c or job.state == "cancelled") then
				job.logged, job.heardCancel, job.asked = true, true, true
				self:save(job)
				self.deps.remember("(cancelled while it was still being heard)", slot, id)
			end
		end
	end
	if not hit then
		-- nothing to cancel: the oldest cancelled clip is answered
		local list = self.clips[slot] or {}
		for i, c in ipairs(list) do
			if c.cancelled then table.remove(list, i) break end
		end
	end
	self:changed()
end

-- buttons -------------------------------------------------------------------

function M:CancelJob(id)
	local job = self.jobs[id]
	if not job or job.cancel or RANK[job.state or "queued"] == 3 then return end
	job.cancel, job.asked, job.unconfirmed = { tries = 1, sentAt = self.deps.now() }, true, nil
	self:save(job)
	self.deps.command("cancel", job.slot, id)
	self:changed()
end

-- every queued message goes in one request, so one press sends them all
function M:SendNow(id)
	local job = self.jobs[id]
	if not job or job.state ~= "queued" then return end
	for _, other in pairs(self.jobs) do
		if other.slot == job.slot and other.state == "queued" then
			other.sending = { tries = 1, sentAt = self.deps.now(), lead = id }
		end
	end
	self.deps.command("now", job.slot, id)
	self:changed()
end

-- time passing: retries, and predictions that were never answered settle
function M:Tick()
	local now = self.deps.now()
	local moved = false
	for slot, list in pairs(self.clips) do
		for i = #list, 1, -1 do
			local c = list[i]
			if c.cancelled and not self.offset then
				-- waiting for its line; a clip that held no words never sends one
				if now - c.lastAt >= HEAR_MS then
					table.remove(list, i)
					self:audit("settle", slot, ("clip %.0f cancelled, no words came"):format(c.release))
					moved = true
				end
			elseif c.cancelled then
				if now - c.sentAt >= RETRY_MS then
					if c.tries < TRIES then
						c.tries, c.sentAt = c.tries + 1, now
						self.deps.command("hear", slot, self:pcTime(c.release))
					else
						table.remove(list, i)
						self:audit("settle", slot, ("clip %.0f cancel not confirmed"):format(c.release))
						self.deps.remember("Cancel not confirmed: the companion never answered. Your words may still be sent.", slot, nil, "error")
						moved = true
					end
				end
			elseif now - c.lastAt >= HEAR_MS then
				table.remove(list, i)
				self:audit("settle", slot, ("clip %.0f never came"):format(c.release))
				moved = true
			end
		end
	end
	for id, job in pairs(self.jobs) do
		local intent = job.cancel
		if intent and RANK[job.state or "queued"] < 3 and now - intent.sentAt >= RETRY_MS then
			if intent.tries < TRIES then
				intent.tries, intent.sentAt = intent.tries + 1, now
				self.deps.command("cancel", job.slot, id)
			else
				job.cancel, job.unconfirmed = nil, true
				self:audit("settle", job.slot, ("%.0f cancel not confirmed"):format(id))
				moved = true
			end
		end
		local s = job.sending
		if s and job.state == "queued" and s.lead == id and now - s.sentAt >= RETRY_MS then
			if s.tries < TRIES then
				s.tries, s.sentAt = s.tries + 1, now
				self.deps.command("now", job.slot, id)
			else
				for _, other in pairs(self.jobs) do
					if other.slot == job.slot then other.sending = nil end
				end
				moved = true
			end
		end
		-- a day of jobs is kept
		if job.endedAt and now - job.endedAt > 86400000 then self.jobs[id] = nil end
	end
	if moved then self:changed() end
end

-- queries -------------------------------------------------------------------

function M:Job(id) return id and self.jobs[id] end
function M:Running(slot)
	for _, job in pairs(self.jobs) do
		if job.slot == (slot or "") and job.state == "running" then return true end
	end
	return false
end
function M:Ended(id)
	local job = self.jobs[id]
	return job and job.state and RANK[job.state] == 3 or false
end
function M:Ordered()
	local list = {}
	for _, job in pairs(self.jobs) do list[#list + 1] = job end
	table.sort(list, function(a, b) return a.id < b.id end)
	return list
end
-- live: not being cancelled, by a press or by a cancelled clip
function M:Live(job) return not job.cancel and not job.heardCancel end

-- What a message's header says, from its job alone: "cancelled" (and grey),
-- "too late: already answered", "failed", "cancelling...", "cancel not
-- confirmed", "queued", or nothing
function M:StatusOf(job)
	local s = job.state
	if s == "cancelled" or (job.heardCancel and s ~= "answered" and s ~= "failed") then return "cancelled", true
	elseif s == "answered" and job.asked then return "too late"
	elseif s == "failed" then return "failed"
	elseif job.cancel then return "cancelling"
	elseif job.unconfirmed and RANK[s or "queued"] < 3 then return "not confirmed"
	elseif s == "queued" then return "queued"
	end
end

WC = WC or {}
WC.JobsModel = M
return M
