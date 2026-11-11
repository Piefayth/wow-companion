-- Your messages while something can still be done to them (the player,
-- 2026-11-10: "give the individual messages their own panel ... and once a
-- message doesn't have anything you can do to it anymore, the majigger goes
-- away"), shown on the lines that already say so: the waiting line (hearing
-- you, working) and each queued message's header. Reachable with the cursor:
--   hearing: Cancel (the words are dropped when they arrive)
--   queued:  Send now (ends the running request so this one starts), Cancel
--   working: Cancel (ends the agent)
-- The game cannot write to the PC while it runs, so a button draws a command on
-- the data strip ("WCCMD <nonce> <verb> <slot> [job]"), which the companion
-- watches (tools/strip.py --serve, src/requests.rs watch_commands).
--
-- The PC's ledger (src/jobs.rs) is the truth: every request is a job whose id
-- never repeats, moving one way, hearing -> queued -> running -> answered |
-- cancelled | failed, and every message about one carries `job` and `state`.
-- Here the whole rule is: keep each job's state, and take a message's state
-- only when it ranks above what is held, never once an end is held. A late,
-- repeated or reordered message then changes nothing; none can undo another.
-- Everything shown (queued marks, the running X, tombstones) derives from it.
-- A cancel is a pending intent on top, resolved by whatever end the job reaches.

local core = WC.Core
local jobs = {} -- id -> { id, slot, state, text, queueId, row, at, cancel, sending, endedAt }
local made = {} -- every icon button, for marking after a fight
local RANK = { hearing = 0, queued = 1, running = 2, answered = 3, cancelled = 3, failed = 3 }

local function find(id)
	return id and jobs[id]
end

local function command(verb, slot, id)
	if not (WowCompanion_Strip and WowCompanion_Strip.Send) then return end
	WowCompanion_Strip.Send(("WCCMD %d%04d %s %s%s"):format(time(), math.random(0, 9999), verb,
		slot ~= "" and slot or "main", id and (" " .. ("%.0f"):format(id)) or ""), 2.5)
end

-- the jobs in order (ids are clock-based, so oldest first)
local function ordered()
	local list = {}
	for _, job in pairs(jobs) do list[#list + 1] = job end
	table.sort(list, function(a, b) return a.id < b.id end)
	return list
end

local refresh
local queuedRow
WC.Jobs = WC.Jobs or {}

-- small icon buttons on the lines that already say what is going on (the
-- player, 2026-11-10: "you could have just used little smaller icons and the
-- existing working/running paradigm"): the game's own art, named in a tooltip
-- one family of flat icons from the game's own common set (the player,
-- 2026-11-10: the glowing loot X beside a plain arrow did not match)
local orig = getmetatable(CreateFrame("Button")).__index
local ICONS = { cancel = "common-icon-redx", now = "common-icon-forwardarrow" }
local function icon(parent, kind, tip, onClick)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(20, 20)
	b:SetSize(16, 16)
	b:SetNormalAtlas(ICONS[kind])
	b:SetPushedAtlas(ICONS[kind])
	b:GetPushedTexture():SetVertexColor(0.7, 0.7, 0.7)
	b:SetHighlightAtlas(ICONS[kind], "ADD")
	b:GetHighlightTexture():SetAlpha(0.4)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(tip)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function(self)
		GameTooltip:Hide()
		self.hovered = false
		if self.stale then self.stale = false orig.Hide(self) WC.Jobs.Refresh() end
	end)
	b:HookScript("OnEnter", function(self) self.hovered = true end)
	b:SetScript("OnClick", function(self) if self.job then onClick(self.job) end end)
	-- hiding the button under the cursor left the cursor aiming at nothing
	-- (the player, 2026-11-10): it stays, dimmed and spent, until the cursor
	-- moves off it. Blizzard's own focus code is never called
	b.Hide = function(self)
		if self.hovered and orig.IsShown(self) then
			self.stale, self.job = true, nil
			self:SetAlpha(0.35)
			return
		end
		orig.Hide(self)
	end
	b.Show = function(self) self.stale = false self:SetAlpha(1) orig.Show(self) end
	b.SetShown = function(self, on) if on then self:Show() else self:Hide() end end
	if not InCombatLockdown() and SmartNavigation_MarkFrameFocusable then
		pcall(SmartNavigation_MarkFrameFocusable, b)
	else
		b.unmarked = true
	end
	b:Hide()
	made[#made + 1] = b
	return b
end

-- A cancel is a pending intent (the player, 2026-11-10: "I'd like to truly
-- know that it actually got cancelled"): the header says "cancelling" at once,
-- the command is drawn again every few seconds while the job has not ended
-- (the strip can be missed; the PC takes repeats as one), and the job's end
-- resolves it: cancelled, too late (answered), or failed. The message stays
-- as a tombstone
local RETRY_EVERY, TRIES = 4, 3
local GREY, GOOD, BAD = "|cff9d9d9d", "|cff7fd27f", "|cffff7777"
local function transcriptNow()
	local frame = core.logFrame and core.logFrame()
	return frame and frame.messages
end
local function rowOf(job)
	if job.row and job.row.fs:IsShown() then return job.row end
	local transcript = transcriptNow()
	if job.queueId and transcript and queuedRow then return queuedRow(transcript, job.queueId) end
end
local function mark(job, status, grey)
	local row, transcript = rowOf(job), transcriptNow()
	if transcript and row and WC.Transcript.markRow then
		pcall(WC.Transcript.markRow, transcript, row, status, grey)
	end
end
local hearingAsked = {} -- slot -> GetTime() of a hearing cancel not yet answered
local function note(slot, text)
	if core.remember then core.remember("note", text, nil, slot) end
end

-- the one way a job's state changes; true when it did
local function apply(id, slot, state, text)
	if not id or not RANK[state] then return false end
	local job = jobs[id]
	if job and RANK[job.state] >= RANK[state] then return false end
	if not job then
		job = { id = id, slot = slot or "", at = GetTime() }
		jobs[id] = job
	end
	if text then job.text = text end
	job.state = state
	if state ~= "queued" and job.queueId and WC.Transcript.unqueueId then
		WC.Transcript.unqueueId(job.slot, job.queueId)
	end
	if state == "running" then
		job.at, job.sending = GetTime(), nil
		if not job.row then job.row = rowOf(job) end
	end
	if RANK[state] == 3 then
		job.endedAt = GetTime()
		if state == "cancelled" then
			mark(job, "  " .. GOOD .. "cancelled|r", true)
		elseif job.cancel and state == "answered" then
			mark(job, "  " .. BAD .. "too late: already answered|r")
		elseif state == "failed" then
			mark(job, "  " .. BAD .. "failed|r")
		end
		job.cancel = nil
	end
	return true
end

local function cancel(job)
	if not job then return end
	if job.state == "hearing" and not job.id then
		command("hear", job.slot)
		if core.setTranscribing then core.setTranscribing(job.slot, false) end
		local asked = GetTime()
		hearingAsked[job.slot] = asked
		C_Timer.After(RETRY_EVERY * TRIES, function()
			if hearingAsked[job.slot] == asked then
				hearingAsked[job.slot] = nil
				note(job.slot, BAD .. "Cancel not confirmed: the companion never answered. Your words may still be sent.|r")
			end
		end)
		refresh()
		return
	end
	local live = find(job.id)
	if not live or live.cancel or RANK[live.state] == 3 then return end
	if not live.row then live.row = rowOf(live) end
	local intent = { tries = 1 }
	live.cancel = intent
	command("cancel", live.slot, live.id)
	mark(live, "  " .. GREY .. "cancelling...|r")
	local function again()
		if live.cancel ~= intent then return end -- resolved by the job's end
		if intent.tries < TRIES then
			intent.tries = intent.tries + 1
			command("cancel", live.slot, live.id)
			C_Timer.After(RETRY_EVERY, again)
		else
			live.cancel = nil
			mark(live, "  " .. BAD .. "cancel not confirmed|r")
			refresh()
		end
	end
	C_Timer.After(RETRY_EVERY, again)
	refresh()
end

-- whether a conversation has a job running (the board and the waiting line)
function WC.Jobs.Running(slot)
	for _, job in pairs(jobs) do
		if job.slot == (slot or "") and job.state == "running" then return true end
	end
	return false
end

function WC.Jobs.Ended(id)
	local job = jobs[id]
	return job and RANK[job.state] == 3 or false
end

-- A message from the PC about jobs: its own `job` and `state`, and any `list`
-- of { job, slot, state } (stopped, the board's resync), merged by one rule.
function WC.Jobs.Apply(inbox)
	local slot = inbox.slot
	if inbox.job and inbox.state then
		apply(inbox.job, slot, inbox.state, inbox.who == "you" and inbox.text or nil)
		local job = jobs[inbox.job]
		-- Cancel was pressed while this was still being heard, and the words won
		-- the race (the player, 2026-11-10: they "pop in on top of my
		-- cancellation" and lag through cancelling): the line arrives already
		-- cancelled. The cancel goes for this job too; its real end still decides
		local slotKey = job and job.slot
		if job and inbox.who == "you" and hearingAsked[slotKey] and not job.cancel and RANK[job.state] < 3 then
			hearingAsked[slotKey] = nil
			job.queueId = job.queueId or inbox.queueId
			if not job.row then
				job.row = rowOf(job)
				local transcript = transcriptNow()
				local view = WowCompanion_ViewSlot and WowCompanion_ViewSlot() or ""
				if not job.row and transcript and slotKey == view then
					for i = #(transcript.rows or {}), 1, -1 do
						local row = transcript.rows[i]
						if row.you and row.fs:IsShown() then job.row = row break end
					end
				end
			end
			job.cancel = { tries = TRIES, hearing = true }
			command("cancel", slotKey, job.id)
			mark(job, "  " .. GOOD .. "cancelled|r", true)
		end
		if job and inbox.queueId and not job.queueId then
			job.queueId = inbox.queueId
			-- the line came after its job moved on: no queued mark to keep
			if job.state ~= "queued" and WC.Transcript.unqueueId then WC.Transcript.unqueueId(job.slot, job.queueId) end
		end
		-- one run per conversation: a reply or a failure ends every job of it
		-- still running (messages said together run as one)
		if job and RANK[inbox.state] == 3 and inbox.who ~= "you" then
			for _, other in pairs(jobs) do
				if other ~= job and other.slot == job.slot and other.state == "running" then
					apply(other.id, other.slot, inbox.state)
				end
			end
		end
	end
	for _, e in ipairs(type(inbox.list) == "table" and inbox.list or {}) do
		if type(e) == "table" and e.job then apply(e.job, e.slot or slot, e.state) end
	end
	-- ends older than a quarter hour have nothing left to show
	local now = GetTime()
	for id, job in pairs(jobs) do
		if job.endedAt and now - job.endedAt > 900 then jobs[id] = nil end
	end
	WC.Jobs.Refresh()
end

-- the PC's answer to a cancel or a stop (Companion.lua handlers.stopped)
function WC.Jobs.Stopped(inbox)
	local slot = inbox.slot or ""
	local asked = hearingAsked[slot]
	hearingAsked[slot] = nil
	local shown = false
	for _, e in ipairs(type(inbox.list) == "table" and inbox.list or {}) do
		if type(e) == "table" and jobs[e.job] and rowOf(jobs[e.job]) then shown = true end
	end
	WC.Jobs.Apply(inbox)
	-- a hearing cancel whose job had no line of its own yet: say what happened
	if inbox.hearing and (asked or inbox.nothing) and not shown then
		note(slot, inbox.nothing and (GREY .. "Nothing left to cancel: that message was already answered.|r")
			or (GOOD .. "Cancelled|r " .. GREY .. "before it was sent.|r"))
	end
end

local function sendNow(job)
	if not job then return end
	command("now", job.slot, job.id)
	-- every queued message goes in the same request, so one press sends them
	-- all: the other play buttons go too
	for _, other in pairs(jobs) do
		if other.slot == job.slot and other.state == "queued" then other.sending = true end
	end
	refresh()
end

-- the waiting line (hearing you / working) gets an X at its end; each queued
-- message's own header line in the transcript gets a play and an X
local statusX
local pairsPool = {}

function queuedRow(transcript, queueId)
	for _, row in ipairs(transcript.rows or {}) do
		if row.queued == queueId and row.fs:IsShown() then return row end
	end
end

refresh = function()
	local frame = core.logFrame and core.logFrame()
	if not frame or not frame.messages or not frame.pending then return end
	local now = GetTime()
	local view = WowCompanion_ViewSlot and WowCompanion_ViewSlot() or ""
	local working = core.working or {}
	-- the waiting line: hearing first (the newest thing), else the running request
	statusX = statusX or icon(frame, "cancel", CANCEL or "Cancel", cancel)
	-- only a clip still being heard has no line of its own yet: its X sits
	-- on the waiting line; a request being worked on has it on its own line
	local target
	local since = (core.transcribing or {})[view]
	if since then target = { state = "hearing", slot = view } end
	-- In the chat itself (the player, 2026-11-10): the states the footer line
	-- used to carry are lines at the end of the conversation, where the reply
	-- will appear: the agent working, then your next clip being heard.
	local transcript0 = frame.messages
	-- each state laid out as a message (the player, 2026-11-10: "spaced like a
	-- message"): the name and time as a header, what is happening under it
	local ghosts = transcript0.jobsGhosts
	if not ghosts then
		ghosts = {}
		local body = ChatFontNormal and "ChatFontNormal" or "GameFontHighlight"
		for i = 1, 2 do
			local head = transcript0.content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			head:SetJustifyH("LEFT")
			local line = transcript0.content:CreateFontString(nil, "OVERLAY", body)
			line:SetJustifyH("LEFT")
			line:SetWordWrap(false)
			line:SetTextColor(0.6, 0.6, 0.6)
			head:Hide() line:Hide()
			ghosts[i] = { head = head, line = line }
		end
		transcript0.jobsGhosts = ghosts
	end
	local items = {}
	local dots = ("."):rep(math.floor(now * 2) % 4)
	local stamp = "  |cff5c6370" .. date("%H:%M") .. "|r"
	local entry = working[view]
	-- a run whose every message is being cancelled shows no working line: the
	-- cancel is already the answer (the player, 2026-11-10)
	if entry then
		local live, cancelling = false, false
		for _, job in pairs(jobs) do
			if job.slot == view and job.state == "running" then
				if job.cancel then cancelling = true else live = true end
			end
		end
		if cancelling and not live then entry = nil end
	end
	if entry then
		local doing = tostring(entry.text or "thinking"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
		items[#items + 1] = { "|cffffd100Claude|r" .. stamp, ("%s%s  %ds"):format(doing, dots, now - (entry.since or now)) }
	end
	if since then
		items[#items + 1] = { "|cff9ad5ffYou|r" .. stamp, ("hearing you%s  %ds"):format(dots, now - since), hearing = true }
	end
	local base = transcript0.height or 0
	local width = transcript0.Width and transcript0:Width() or 300
	-- The working line belongs right after the message being worked on, not
	-- after the queued ones (the player, 2026-11-10: "your thinking got
	-- pushed"): room is kept open above the first of your messages after it.
	local rows = transcript0.rows or {}
	local runIndex, afterIndex
	for i = #rows, 1, -1 do
		if rows[i].you and not rows[i].queued then runIndex = i break end
	end
	if entry and runIndex then
		for i = runIndex + 1, #rows do
			if rows[i].you then afterIndex = i break end
		end
	end
	local GHOST_H = 46
	local relayout = false
	for i, row in ipairs(rows) do
		local want = (i == afterIndex) and GHOST_H or nil
		if row.extra ~= want then row.extra = want relayout = true end
	end
	if relayout and transcript0.Layout then
		transcript0:Layout()
		base = transcript0.height or base
	end
	local insertY
	if afterIndex then
		local _, _, _, _, oy = rows[afterIndex].fs:GetPoint(1)
		if oy then insertY = -oy - (rows[afterIndex].gap or 0) - GHOST_H end
	end
	local y = base
	local hearingLine
	for i, g in ipairs(ghosts) do
		local item = items[i]
		if item then
			if i == 1 and entry and insertY then
				-- the working line, in the room kept for it
				local saved = y
				y = insertY + 14
				g.head:ClearAllPoints()
				g.head:SetPoint("TOPLEFT", transcript0.content, "TOPLEFT", 0, -y)
				g.head:SetText(item[1])
				g.head:Show()
				g.head.y = y
				y = y + g.head:GetStringHeight() + 3
				g.line:ClearAllPoints()
				g.line:SetPoint("TOPLEFT", transcript0.content, "TOPLEFT", 0, -y)
				g.line:SetWidth(math.max(50, width - 4))
				g.line:SetText(item[2])
				g.line:Show()
				y = saved
			else
			y = y + 14 -- TURN_GAP, as Transcript.lua spaces a new message
			g.head:ClearAllPoints()
			g.head:SetPoint("TOPLEFT", transcript0.content, "TOPLEFT", 0, -y)
			g.head:SetText(item[1])
			g.head:Show()
			g.head.y = y
			y = y + g.head:GetStringHeight() + 3
			g.line:ClearAllPoints()
			g.line:SetPoint("TOPLEFT", transcript0.content, "TOPLEFT", 0, -y)
			g.line:SetWidth(math.max(50, width - 4))
			g.line:SetText(item[2])
			g.line:Show()
			y = y + g.line:GetStringHeight()
			end
			if item.hearing then hearingLine = g.head end
		else
			g.head:Hide()
			g.line:Hide()
		end
	end
	local scroll = transcript0.scroll
	local following = scroll:GetVerticalScroll() >= scroll:GetVerticalScrollRange() - 30
	-- a scroll frame only redraws its child's new area when told (the
	-- player, 2026-11-10: "doesn't update till I move my cursor")
	local want = math.max(y, base, 1)
	if math.abs((transcript0.content:GetHeight() or 0) - want) > 0.5 then
		transcript0.content:SetHeight(want)
		scroll:UpdateScrollChildRect()
		if following and y > base then scroll:SetVerticalScroll(scroll:GetVerticalScrollRange()) end
	end
	if target and hearingLine and hearingLine:IsShown() then
		statusX.job = target
		statusX:SetParent(transcript0.content)
		statusX:ClearAllPoints()
		statusX:SetPoint("TOPRIGHT", transcript0.content, "TOPLEFT", width - 4, -(hearingLine.y - 3))
		statusX:SetFrameLevel(transcript0.content:GetFrameLevel() + 5)
		statusX:Show()
	else
		statusX.job = nil
		statusX:Hide()
	end
	-- queued messages, on their own lines
	local transcript = frame.messages
	local used = 0
	local runningThere = WC.Jobs.Running(view)
	local list = ordered()
	for _, job in ipairs(list) do
		local row = job.slot == view and job.state == "queued" and not job.cancel and job.queueId
			and queuedRow(transcript, job.queueId)
		if row then
			used = used + 1
			local pair = pairsPool[used]
			if not pair then
				pair = { x = icon(transcript.content, "cancel", CANCEL or "Cancel", cancel),
					go = icon(transcript.content, "now", "Send now", sendNow) }
				pairsPool[used] = pair
			end
			pair.x.job, pair.go.job = job, job
			pair.x:ClearAllPoints()
			pair.x:SetPoint("TOPRIGHT", row.fs, "TOPRIGHT", -4, 3)
			pair.x:Show()
			pair.go:ClearAllPoints()
			pair.go:SetPoint("RIGHT", pair.x, "LEFT", -2, 0)
			pair.go:SetShown(runningThere and not job.sending)
		end
	end
	-- the request being worked on: an X on its own line, the newest of yours
	-- that is not queued (the player, 2026-11-10: "on the chat message like it
	-- is for everything else")
	local running
	for _, job in ipairs(list) do
		if job.slot == view and job.state == "running" and not job.cancel then running = job end
	end
	-- bound once to the message it belongs to (its queued line, or your newest
	-- line not bound to another job), so it can never wander onto an older one
	local runRow
	if running then
		running.row = rowOf(running)
		if not running.row then
			local taken = {}
			for _, job in pairs(jobs) do if job.row then taken[job.row] = true end end
			for i = #(transcript.rows or {}), 1, -1 do
				local row = transcript.rows[i]
				if row.you and not row.queued and row.fs:IsShown() and not taken[row] then running.row = row break end
			end
		end
		runRow = running.row
	end
	if runRow then
		used = used + 1
		local pair = pairsPool[used]
		if not pair then
			pair = { x = icon(transcript.content, "cancel", CANCEL or "Cancel", cancel),
				go = icon(transcript.content, "now", "Send now", sendNow) }
			pairsPool[used] = pair
		end
		pair.x.job = running
		pair.x:ClearAllPoints()
		-- on the thinking line, the work it cancels (the player, 2026-11-10:
		-- an X on a message already sent read as cancelling the message); the
		-- message itself still carries the tombstone
		local head = entry and ghosts[1] and ghosts[1].head
		if head and head:IsShown() and head.y then
			pair.x:SetPoint("TOPRIGHT", transcript0.content, "TOPLEFT", width - 4, -(head.y - 3))
		else
			pair.x:SetPoint("TOPRIGHT", runRow.fs, "TOPRIGHT", -4, 3)
		end
		pair.x:Show()
		pair.go:Hide()
	end
	for i = used + 1, #pairsPool do
		pairsPool[i].x:Hide()
		pairsPool[i].go:Hide()
	end
	-- an icon scrolled out of the view is clipped but still a button: the
	-- cursor went to Xs drawn below the window (the player, 2026-11-10).
	-- Hide what lies outside the visible part, so the cursor can't reach it
	local top, bottom = scroll:GetTop(), scroll:GetBottom()
	if top and bottom then
		for _, b in ipairs(made) do
			if b:IsShown() then
				local bt, bb = b:GetTop(), b:GetBottom()
				if bt and bb and (bb < bottom - 2 or bt > top + 2) then b:Hide() end
			end
		end
	end
	if not scroll.wcJobsHooked then
		scroll.wcJobsHooked = true
		local busy
		scroll:HookScript("OnVerticalScroll", function()
			if busy then return end
			busy = true
			WC.Jobs.Refresh()
			busy = false
		end)
	end
end

WC.Jobs.Refresh = function() pcall(refresh) if WC.Jobs.Chain then pcall(WC.Jobs.Chain) end end

-- the old entry points, kept so callers cost nothing: each message's `job`
-- and `state` carry everything
function WC.Jobs.Note(inbox) WC.Jobs.Apply(inbox) end
function WC.Jobs.Started() WC.Jobs.Refresh() end
function WC.Jobs.Gone() WC.Jobs.Refresh() end

-- buttons made in a fight could not be marked for the cursor: mark them now
local marker = CreateFrame("Frame")
marker:RegisterEvent("PLAYER_REGEN_ENABLED")
marker:SetScript("OnEvent", function()
	for _, b in ipairs(made) do
		if b.unmarked and SmartNavigation_MarkFrameFocusable then
			b.unmarked = nil
			pcall(SmartNavigation_MarkFrameFocusable, b)
		end
	end
end)

-- Shortcuts while the Companion window has the controller's focus (the
-- player, 2026-11-10): square cancels, triangle sends now, each acting on the
-- newest message of the conversation in view. Live only while the UI is
-- focused on our window (Blizzard's FrameControlsManager.isUIFocused and
-- focusedFrame, read, never set): the d-pad and face buttons belong to the
-- cursor then anyway, so nothing of the bars is taken. Set and cleared out of
-- combat only; the window cannot hold focus in a fight.
local function newest(state)
	local view = WowCompanion_ViewSlot and WowCompanion_ViewSlot() or ""
	if not state and (core.transcribing or {})[view] then return { state = "hearing", slot = view } end
	local list = ordered()
	for i = #list, 1, -1 do
		local job = list[i]
		if job.slot == view and not job.cancel
			and (state and job.state == state or (not state and (job.state == "queued" or job.state == "running"))) then
			return job
		end
	end
end
local cancelKey = CreateFrame("Button", "WCJobsCancelKey", UIParent)
cancelKey:SetScript("OnClick", function() cancel(newest()) end)
local nowKey = CreateFrame("Button", "WCJobsNowKey", UIParent)
nowKey:SetScript("OnClick", function()
	local job = newest("queued")
	if job then sendNow(job) end
end)
local keyOwner = CreateFrame("Frame", "WCJobsKeys", UIParent)
local bound = false
local elapsed = 0
keyOwner:SetScript("OnUpdate", function(_, dt)
	elapsed = elapsed + dt
	if elapsed < 0.2 then return end
	elapsed = 0
	if InCombatLockdown() then return end
	local mgr = GamepadMode and GamepadMode.FrameControlsManager
	local window = core.logFrame and core.logFrame()
	local focused = mgr and mgr.isUIFocused and window and mgr.focusedFrame == window and window:IsShown() or false
	-- only on the Chat tab, where the messages they act on are (the player,
	-- 2026-11-10: on Errands, "square to cancel, cancel what?")
	if window and (window.currentTab or 1) ~= 1 then focused = false end
	-- the legend: what square and triangle do right now, shown only while
	-- they work (the player, 2026-11-10: "no input legend")
	if window then
		-- one line of small text with the game's own button glyphs inline (the
		-- player, 2026-11-10: the prompt widgets did not fit the panel)
		if not window.jobsLegend then
			local fs = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			fs:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -24, 16)
			fs:SetJustifyH("RIGHT")
			window.jobsLegend = fs
		end
		local function glyph(key) return WowCompanion_Glyph(key) end
		local parts = {}
		if focused and newest() then parts[#parts + 1] = glyph("PAD3") .. " Cancel newest" end
		if focused and newest("queued") then parts[#parts + 1] = glyph("PAD4") .. " Send queued now" end
		window.jobsLegend:SetText(table.concat(parts, "     "))
		window.jobsLegend:SetShown(#parts > 0)
		if window.jobsCancelPrompt then window.jobsCancelPrompt:Hide() window.jobsNowPrompt:Hide() end
	end
	if focused and not bound then
		SetOverrideBindingClick(keyOwner, true, "PAD3", "WCJobsCancelKey")
		SetOverrideBindingClick(keyOwner, true, "PAD4", "WCJobsNowKey")
		bound = true
	elseif not focused and bound then
		ClearOverrideBindings(keyOwner)
		bound = false
	end
end)

-- The cursor and the icon column (the player, 2026-11-10: from the scroll
-- arrow, up did not reach Cancel). SmartNavigation picks the nearest button in
-- the direction pressed, and the arrows sit a little right of the icons, so up
-- from the bottom arrow went to the top arrow. Static jump overrides chain them:
-- top arrow, the icons top to bottom, bottom arrow. Blizzard's API for this,
-- set only out of combat (Utility.lua: "may be set without causing taint").
local chained = ""
function WC.Jobs.Chain()
	if InCombatLockdown() or not SmartNavigation_AddJumpNavigationOverride then return end
	local frame = core.logFrame and core.logFrame()
	if not frame or not frame.chatParts then return end
	local arrows = {}
	for _, part in ipairs(frame.chatParts) do
		if part.GetObjectType and part:GetObjectType() == "Button" then arrows[#arrows + 1] = part end
	end
	if #arrows < 2 then return end
	table.sort(arrows, function(a, b) return (a:GetTop() or 0) > (b:GetTop() or 0) end)
	local top, bottom = arrows[1], arrows[#arrows]
	local icons = {}
	for _, b in ipairs(made) do
		if b:IsVisible() and b:GetTop() then icons[#icons + 1] = b end
	end
	table.sort(icons, function(a, b) return a:GetTop() > b:GetTop() end)
	local key = {}
	for i, b in ipairs(icons) do key[i] = tostring(b) .. math.floor(b:GetTop()) end
	key = table.concat(key, ",")
	if key == chained then return end
	chained = key
	local D = SMART_NAV_INPUT_DIRECTION
	local column = { top }
	for _, b in ipairs(icons) do column[#column + 1] = b end
	column[#column + 1] = bottom
	for i, b in ipairs(column) do
		pcall(SmartNavigation_ClearJumpNavigationOverridesInDirection, b, D.UP)
		pcall(SmartNavigation_ClearJumpNavigationOverridesInDirection, b, D.DOWN)
		if i > 1 then pcall(SmartNavigation_AddJumpNavigationOverride, b, D.UP, column[i - 1]) end
		if i < #column then pcall(SmartNavigation_AddJumpNavigationOverride, b, D.DOWN, column[i + 1]) end
	end
	-- nothing between the arrows: let the cursor choose as before
	if #icons == 0 then
		pcall(SmartNavigation_ClearJumpNavigationOverridesInDirection, top, D.DOWN)
		pcall(SmartNavigation_ClearJumpNavigationOverridesInDirection, bottom, D.UP)
	end
end
