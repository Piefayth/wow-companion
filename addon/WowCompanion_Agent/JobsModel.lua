-- The window's model of your messages, pure: no frames, no timers, no game
-- calls. Everything it needs comes in as `deps`, so tools/test_jobs.py runs it
-- under Lua 5.1 against thousands of random schedules (delivery reordered,
-- repeated, dropped) and checks its invariants. Jobs.lua draws from it.
--
-- The design (docs/proposals/ledger.md, conversation-sync.md):
-- * Job states are a join-semilattice: hearing < queued < running < an end,
--   the first end wins. A message's state is taken only when it ranks higher.
--   Any order or repetition of delivery converges (a state-based CRDT).
-- * Every identity comes from the PC: a clip is named by its job id the moment
--   it is let go (`heard`), so a cancel names the job, exactly, like any other.
-- * Conversation lines are numbered per conversation; each is applied once,
--   whether it came in a slot or from the mailbox at load.
-- * The window predicts only your own presses (a cancel, a send now): retried
--   until the job moves, and settled to an honest "not confirmed" if it never does.
--
-- deps: now() ms (monotonic); wall() unix ms; command(verb, slot, id);
-- audit(what, slot, detail); store (kept across
-- reloads: its jobs); lines (kept across reloads: WowCompanionAgentDB.lines); changed().

local M = {}
M.__index = M

local RANK = { hearing = 0, queued = 1, running = 2, answered = 3, cancelled = 3, failed = 3 }
M.RANK = RANK
local RETRY_MS, TRIES = 4000, 3

function M.new(deps)
	local m = setmetatable({ deps = deps, jobs = {} }, M)
	-- both are saved tables the caller owns: a table made here would be lost at
	-- the next reload, and every line in the mailbox applied again
	local store = assert(deps.store, "JobsModel: no store")
	m.store = store
	store.jobs = store.jobs or {}
	m.lines = assert(deps.lines, "JobsModel: no lines")
	local cutoff = deps.wall() - 86400000
	for id, e in pairs(store.jobs) do
		if type(id) ~= "number" or id < cutoff or type(e) ~= "table" or not RANK[e.state] then
			store.jobs[id] = nil
		else
			m.jobs[id] = { id = id, slot = e.slot or "", state = e.state, asked = e.asked, at = deps.now(),
				since = e.since, text = e.text }
		end
	end
	return m
end

function M:audit(what, slot, detail) if self.deps.audit then self.deps.audit(what, slot, detail) end end
function M:changed() if self.deps.changed then self.deps.changed() end end

function M:save(job)
	self.store.jobs[job.id] = { slot = job.slot, state = job.state, asked = job.asked or nil,
		since = job.since, text = job.text }
end

-- the one way a job's state changes
function M:advance(id, slot, state)
	if not id or not RANK[state] then return false end
	local job = self.jobs[id]
	if job and RANK[job.state] >= RANK[state] then return false end
	if not job then
		job = { id = id, slot = slot or "", at = self.deps.now() }
		self.jobs[id] = job
	end
	job.state = state
	-- when it began being heard, or worked on (wall ms): the board's seconds
	if state == "hearing" or state == "running" then job.since = self.deps.wall() end
	if RANK[state] == 3 then
		job.cancel, job.sending = nil, nil
		job.endedAt = self.deps.now()
	end
	if state ~= "queued" then job.sending = nil end
	self:save(job)
	return true
end

-- lines ---------------------------------------------------------------------

-- A numbered line arrives (a slot or the mailbox): true to apply it, false when
-- it is held already. `lines[slot]` is the highest number held with none missing
-- below it, which the PC confirms by at each save; `lines.above[slot]` holds the
-- numbers past a gap, so a line from the mailbox after a reload is not applied twice.
function M:Hold(slot, n)
	n = tonumber(n)
	if not n then return true end
	slot = slot or ""
	local lines = self.lines
	lines.above = lines.above or {}
	local top = tonumber(lines[slot]) or 0
	local above = lines.above[slot] or {}
	if n <= top or above[n] then return false end
	above[n] = true
	while above[top + 1] do
		top = top + 1
		above[top] = nil
	end
	lines[slot] = top
	lines.above[slot] = next(above) and above or nil
	return true
end

-- messages ------------------------------------------------------------------

-- any message about jobs: its own `job` and `state`, and any `list`; what a
-- running job is doing (a `progress` text, a line's `pending`), and for how
-- long (`since`: seconds it has already run, retold after a reload)
function M:Apply(inbox)
	local slot = inbox.slot
	local id = tonumber(inbox.job)
	if id and inbox.state then self:advance(id, slot, inbox.state) end
	for _, e in ipairs(type(inbox.list) == "table" and inbox.list or {}) do
		if type(e) == "table" and tonumber(e.job) then self:advance(tonumber(e.job), e.slot or slot, e.state) end
	end
	local job = id and self.jobs[id]
	local doing = inbox.kind == "progress" and inbox.text or inbox.pending
	if job and RANK[job.state] < 3 and doing then
		job.text = tostring(doing)
		if tonumber(inbox.since) then job.since = self.deps.wall() - tonumber(inbox.since) * 1000 end
		self:save(job)
	end
	self:changed()
end

-- The mailbox's job states at load, merged forward.
function M:Mail(jobs)
	for _, e in ipairs(type(jobs) == "table" and jobs or {}) do
		local id = type(e) == "table" and tonumber(e.job)
		if id then self:advance(id, e.slot, e.state) end
	end
	self:changed()
end

-- buttons -------------------------------------------------------------------

function M:CancelJob(id)
	local job = self.jobs[id]
	if not job or job.cancel or RANK[job.state] == 3 then return end
	-- `asked`: the state it was cancelled from; a running job's cancel shows on
	-- the work it stopped, an earlier one's on the message (StatusOf)
	job.cancel, job.asked, job.unconfirmed = { tries = 1, sentAt = self.deps.now() }, job.state, nil
	self:save(job)
	self.deps.command("cancel", job.slot, id)
	self:changed()
end

-- every queued message goes in one request, so one press sends them all
-- the PC read a Send now press: no more redraws; the press stays pending (no
-- second Send now offered) until the run it starts takes the queued messages
function M:Acked(verb, id)
	local job = self.jobs[id]
	if verb ~= "now" or not job then return end
	for _, other in pairs(self.jobs) do
		if other.slot == job.slot and other.sending then other.sending.acked = true end
	end
	self:changed()
end

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

-- time passing: retries, and presses that were never answered settle
function M:Tick()
	local now = self.deps.now()
	local moved = false
	for id, job in pairs(self.jobs) do
		local intent = job.cancel
		if intent and RANK[job.state] < 3 and now - intent.sentAt >= RETRY_MS then
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
		if s and not s.acked and job.state == "queued" and s.lead == id and now - s.sentAt >= RETRY_MS then
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
	return job and RANK[job.state] == 3 or false
end
function M:Ordered()
	local list = {}
	for _, job in pairs(self.jobs) do list[#list + 1] = job end
	table.sort(list, function(a, b) return a.id < b.id end)
	return list
end
-- the clips being heard in a conversation, oldest first
function M:Hearing(slot)
	local list = {}
	for _, job in ipairs(self:Ordered()) do
		if job.slot == (slot or "") and job.state == "hearing" then list[#list + 1] = job end
	end
	return list
end

-- What a conversation is doing, for the board, the list and the work line:
-- the clip being heard longest (a job), and the work: { since, text, ids }
-- over its running jobs (one run takes the queued ones together), or nil.
function M:Work(slot)
	slot = slot or ""
	local hearing = self:Hearing(slot)[1]
	local work
	for _, job in ipairs(self:Ordered()) do
		if job.slot == slot and job.state == "running" then
			work = work or { ids = {} }
			work.ids[#work.ids + 1] = job.id
			if not work.since or (job.since or 0) < work.since then work.since = job.since end
			if job.text then work.text = job.text end
		end
	end
	if work then work.text = work.text or "thinking" end
	return hearing, work
end

-- How a run that has stopped running ended, from its jobs (Work's ids):
-- "cancelled", "too late" (answered after you cancelled it), "answered",
-- "failed", or nil while one still runs (Send now keeps the run's job running).
function M:EndOf(ids)
	local seen = {}
	for _, id in ipairs(ids or {}) do
		local job = self.jobs[id]
		if job and RANK[job.state] < 3 then return nil end
		if job then
			local word = job.state
			if job.asked == "running" and word == "answered" then word = "too late" end
			seen[word] = true
		end
	end
	for _, word in ipairs({ "cancelled", "too late", "failed", "answered" }) do
		if seen[word] then return word end
	end
end

-- What a message's header says, from its job alone: "cancelled" (and grey),
-- "too late: already answered", "failed", "cancelling...", "cancel not
-- confirmed", "queued", or nothing
-- What a message's own line says. A job cancelled while it ran says it on its
-- work line instead (Jobs.lua, WorkStatus), and its message stays as said (the
-- player, 2026-11-11).
function M:StatusOf(job)
	local s = job.state
	if job.asked == "running" then
		if s == "failed" then return "failed" end
		return nil
	end
	if s == "cancelled" then return "cancelled", true
	elseif s == "answered" and job.asked then return "too late"
	elseif s == "failed" then return "failed"
	elseif job.cancel then return "cancelling"
	elseif job.unconfirmed and RANK[s] < 3 then return "not confirmed"
	elseif s == "queued" then return "queued"
	end
end

-- What the work line of a conversation says about a cancel pressed on it:
-- "cancelling", "not confirmed", or nil.
function M:WorkStatus(slot)
	for _, job in pairs(self.jobs) do
		if job.slot == slot and job.asked == "running" and RANK[job.state] < 3 then
			if job.cancel then return "cancelling" end
			if job.unconfirmed then return "not confirmed" end
		end
	end
end

WC = WC or {}
WC.JobsModel = M
return M
