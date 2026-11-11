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
-- watches (src/strip.rs serve, src/requests.rs watch_commands).
--
-- The PC's ledger (src/jobs.rs) is the truth: every request is a job whose id
-- never repeats, moving one way, hearing -> queued -> running -> answered |
-- cancelled | failed, and every message about one carries `job` and `state`.
-- Here the whole rule is: keep each job's state, and take a message's state
-- only when it ranks above what is held, never once an end is held. A late,
-- repeated or reordered message then changes nothing; none can undo another.
-- Everything shown (queued marks, the running X, tombstones) derives from it.
-- A cancel is a pending intent on top, resolved by whatever end the job reaches.

local jobs = {} -- the model's jobs (JobsModel.lua), once it is made
local made = {} -- every icon button, for marking after a fight


-- The game's half of the audit trail (src/audit.rs; tools/audit.py merges
-- both): what arrived, what was drawn, what the window predicted. Kept in the
-- save file, the newest 600 lines; readable after a reload.
local function wallMs() return time() * 1000 end
function WowCompanion_Audit(what, slot, detail)
	if type(WowCompanionAgentDB) ~= "table" then return end
	local log = WowCompanionAgentDB.audit or {}
	WowCompanionAgentDB.audit = log
	log[#log + 1] = ("%.0f game %s %s %s"):format(wallMs(), (slot == nil or slot == "") and "main" or slot, what, tostring(detail or ""))
	while #log > 600 do table.remove(log, 1) end
end
local function audit(what, slot, detail) pcall(WowCompanion_Audit, what, slot, detail) end

local function command(verb, slot, id)
	audit("draw", slot, ("%s%s"):format(verb, id and (" %.0f"):format(id) or ""))
	if not (WowCompanion_Strip and WowCompanion_Strip.Send) then return end
	WowCompanion_Strip.Send(("WCCMD %d%04d %s %s%s"):format(time(), math.random(0, 9999), verb,
		slot ~= "" and slot or "main", id and (" " .. ("%.0f"):format(id)) or ""), 2.5)
end

local function nowMs() return GetTime() * 1000 end
WC.Jobs = WC.Jobs or {}

-- The model (JobsModel.lua) holds every job and every decision about them; it is tested on its own (tools/test_jobs.py). This file
-- draws it. It is made once the save file is loaded (its ledger is kept there).
local model
local function getModel()
	if model then return model end
	if type(WowCompanionAgentDB) ~= "table" or not WC.JobsModel then return nil end
	WowCompanionAgentDB.jobModel = WowCompanionAgentDB.jobModel or { jobs = WowCompanionAgentDB.jobs }
	WowCompanionAgentDB.jobs = nil
	WowCompanionAgentDB.lines = WowCompanionAgentDB.lines or {}
	model = WC.JobsModel.new({
		now = nowMs,
		wall = wallMs,
		command = command,
		audit = audit,
		store = WowCompanionAgentDB.jobModel,
		lines = WowCompanionAgentDB.lines,
		changed = function() if WC.Jobs.Refresh then WC.Jobs.Refresh() end end,
	})
	jobs = model.jobs
	return model
end


local RANK_LIVE = { hearing = true, queued = true, running = true }
local refresh
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
	WC.MarkFocusable(b)
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
	local frame = WC.Companion.window()
	return frame and frame.messages
end
local function rowOf(job)
	if job.row and job.row.fs:IsShown() then return job.row end
	local transcript = transcriptNow()
	if not transcript then return end
	-- each message line carries its job's id (Transcript.lua), saved with it
	for i = #(transcript.rows or {}), 1, -1 do
		local row = transcript.rows[i]
		if row.job == job.id and row.fs:IsShown() then return row end
	end
end

-- What a message's header says, derived from its job alone (the player,
-- 2026-11-10: one source of truth, and a cancel must survive a reload)
local WORDS = {
	["cancelled"] = GOOD .. "cancelled|r", ["too late"] = BAD .. "too late: already answered|r",
	["failed"] = BAD .. "failed|r", ["cancelling"] = GREY .. "cancelling...|r",
	["not confirmed"] = BAD .. "cancel not confirmed|r", ["queued"] = GREY .. "queued|r",
}
local function statusOf(job, row)
	local word, grey = model:StatusOf(job)
	return word and ("  " .. WORDS[word]) or nil, grey
end
local function paint(job)
	local transcript = transcriptNow()
	local row = rowOf(job)
	if not (transcript and row and WC.Transcript.markRow) then return end
	local status, grey = statusOf(job, row)
	if row.status ~= status or (grey and not row.greyed) then
		row.greyed = row.greyed or grey
		pcall(WC.Transcript.markRow, transcript, row, status, grey)
	end
end

local function cancel(job)
	if not job or not getModel() then return end
	model:CancelJob(job.id)
end
local function sendNow(job)
	if job and getModel() then model:SendNow(job.id) end
end

function WC.Jobs.Running(slot) return getModel() and model:Running(slot) or false end
function WC.Jobs.State(id) local job = getModel() and model:Job(id) return job and job.state end
function WC.Jobs.Hearing(slot) return getModel() and #model:Hearing(slot) > 0 or false end
function WC.Jobs.Ended(id) return getModel() and model:Ended(id) or false end
function WC.Jobs.Apply(inbox) if getModel() then model:Apply(inbox) end end
-- a numbered line: true to apply it, false when it is held already
function WC.Jobs.Hold(slot, n) if getModel() then return model:Hold(slot, n) end return true end
function WC.Jobs.Mail(jobs) if getModel() then model:Mail(jobs) end end

-- time passing: the model's retries and settling, in combat too
local ticker = CreateFrame("Frame")
local tickAt = 0
ticker:SetScript("OnUpdate", function(_, dt)
	tickAt = tickAt + dt
	if tickAt < 0.2 then return end
	tickAt = 0
	if getModel() then pcall(model.Tick, model) end
end)

-- the waiting line (hearing you / working) gets an X at its end; each queued
-- message's own header line in the transcript gets a play and an X
-- one X per clip being heard, cancelling its job
local hearXs = {}
local pairsPool = {}


refresh = function()
	local frame = WC.Companion.window()
	if not frame or not frame.messages then return end
	local now = GetTime()
	local view = WowCompanion_ViewSlot and WowCompanion_ViewSlot() or ""
	if not getModel() then return end
	-- every message line's status comes from its job
	for _, row in ipairs(frame.messages.rows or {}) do
		local job = row.job and jobs[row.job]
		if job and row.fs:IsShown() then
			if not job.row then job.row = row end
			paint(job)
		end
	end
	-- the waiting line: hearing first (the newest thing), else the running request
	-- only a clip still being heard has no line of its own yet: its X sits
	-- on the waiting line; a request being worked on has it on its own line
	-- the clips being heard in view, oldest first; drop ones whose words never
	-- came (the PC drops a clip that held nothing, without a word)
	local heard = model:Hearing(view)
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
		for i = 1, 4 do
			local head = transcript0.content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			head:SetJustifyH("LEFT")
			local line = transcript0.content:CreateFontString(nil, "OVERLAY", body)
			line:SetJustifyH("LEFT")
			line:SetWordWrap(false)
			line:SetTextColor(0.6, 0.6, 0.6)
			head:Hide() line:Hide()
			-- each pending line is a turn like any other: its backing and divider
			local band, divider = WC.Transcript.turnBand(transcript0.content, "you")
			band:Hide() divider:Hide()
			ghosts[i] = { head = head, line = line, band = band, divider = divider }
		end
		transcript0.jobsGhosts = ghosts
	end
	local items = {}
	local dots = ("."):rep(math.floor(now * 2) % 4)
	local stamp = "  |cff5c6370" .. date("%H:%M") .. "|r"
	local entry = WC.Companion.working(view)
	-- a message cancelled before its run began never gets a working line: the
	-- cancel on the message is the answer. One cancelled while it ran keeps its
	-- line, which says so (the player, 2026-11-11)
	if entry then
		local live, early = false, false
		for _, job in pairs(jobs) do
			if job.slot == view and RANK_LIVE[job.state] then
				if not job.cancel then live = true
				elseif job.asked ~= "running" then early = true end
			end
		end
		if early and not live and not model:WorkStatus(view) then entry = nil end
	end
	-- the work in view: an entry added when it began, changed in place
	local live = transcript0.live
	if live and (live.slot ~= view or not entry) then
		local answered = not model:Running(live.slot)
		local ended = GREY .. (answered and "answered below" or "stopped") .. "|r"
		for _, job in pairs(jobs) do
			if job.slot == live.slot and (job.endedAt or 0) >= live.began and job.asked == "running" then
				if job.state == "cancelled" then ended, answered = WORDS["cancelled"], false
				elseif job.state == "answered" then ended = WORDS["too late"] end
			elseif job.slot == live.slot and job.state == "cancelled" and (job.endedAt or 0) >= live.began then
				ended, answered = WORDS["cancelled"], false
			end
		end
		transcript0:EndLive(live, ended, answered)
		transcript0.live, live = nil, nil
	end
	if entry then
		local doing = tostring(entry.text or "thinking"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
		local text = ("%s%s  %ds"):format(doing, dots, now - (entry.since or now))
		local work = model:WorkStatus(view)
		if work then text = WORDS[work] end
		if not live then
			live = transcript0:AddLive("|cffffd100Claude|r" .. stamp, text)
			live.slot, live.began = view, nowMs()
			transcript0.live = live
		else
			live.line.fs:SetText(text)
		end
	end
	for _, job in ipairs(heard) do
		if #items >= #ghosts then break end
		local word = job.cancel and (GREY .. "cancelling|r") or ("hearing you%s  %ds"):format(dots, (nowMs() - job.at) / 1000)
		items[#items + 1] = { "|cff9ad5ffYou|r" .. stamp, word, hearing = not job.cancel, job = job }
	end
	local base = transcript0.height or 0
	local width = transcript0.Width and transcript0:Width() or 300
	local y = base
	local hearingLines = {}
	for i, g in ipairs(ghosts) do
		local item = items[i]
		if item then
			local top = y + math.floor(WC.Transcript.TURN_GAP / 2)
			y = y + WC.Transcript.TURN_GAP
			g.head:ClearAllPoints()
			g.head:SetPoint("TOPLEFT", transcript0.content, "TOPLEFT", WC.Transcript.PAD_L, -y)
			g.head:SetText(item[1])
			g.head:Show()
			g.head.y = y
			y = y + g.head:GetStringHeight() + 3
			g.line:ClearAllPoints()
			g.line:SetPoint("TOPLEFT", transcript0.content, "TOPLEFT", WC.Transcript.PAD_L, -y)
			g.line:SetWidth(math.max(50, width - WC.Transcript.PAD_L - WC.Transcript.PAD_R))
			g.line:SetText(item[2])
			g.line:Show()
			y = y + g.line:GetStringHeight()
			local gutter = transcript0.Gutter and transcript0:Gutter() or WC.Transcript.PAD_R
			WC.Transcript.ownBand(g.band, item[1]:find("You", 1, true) and "you" or "claude")
			g.band:ClearAllPoints()
			g.band:SetPoint("TOPLEFT", transcript0.content, "TOPLEFT", 0, -top)
			g.band:SetPoint("TOPRIGHT", transcript0.content, "TOPRIGHT", -gutter, -top)
			g.band:SetHeight(y + math.floor(WC.Transcript.TURN_GAP / 2) - top)
			g.divider:ClearAllPoints()
			g.divider:SetPoint("LEFT", g.band, "TOPLEFT", 0, 0)
			g.divider:SetPoint("RIGHT", g.band, "TOPRIGHT", 0, 0)
			g.band:Show() g.divider:Show()
			if item.hearing then hearingLines[#hearingLines + 1] = { head = g.head, job = item.job } end
		else
			g.head:Hide()
			g.line:Hide()
			g.band:Hide() g.divider:Hide()
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
	for i, line in ipairs(hearingLines) do
		local x = hearXs[i]
		if not x then
			x = icon(transcript0.content, "cancel", CANCEL or "Cancel", cancel)
			hearXs[i] = x
		end
		x.job = line.job
		x:ClearAllPoints()
		x:SetPoint("TOPRIGHT", transcript0.content, "TOPLEFT", width - WC.Transcript.PAD_R, -(line.head.y - 3))
		x:SetFrameLevel(transcript0.content:GetFrameLevel() + 5)
		x:Show()
	end
	for i = #hearingLines + 1, #hearXs do
		hearXs[i].job = nil
		hearXs[i]:Hide()
	end
	-- queued messages, on their own lines
	local transcript = frame.messages
	local used = 0
	local runningThere = WC.Jobs.Running(view)
	local list = model:Ordered()
	for _, job in ipairs(list) do
		local row = job.slot == view and job.state == "queued" and not job.cancel
			and rowOf(job)
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
				if row.you and row.fs:IsShown() and not taken[row] then running.row = row break end
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
		local head = transcript0.live and transcript0.live.head
		if head and head.fs:IsShown() then
			pair.x:SetPoint("TOPRIGHT", head.fs, "TOPRIGHT", -4, 3)
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

-- not re-entered: adding the work's entry adds rows, and rows ask to refresh
local refreshing = false
WC.Jobs.Refresh = function()
	if refreshing then return end
	refreshing = true
	pcall(refresh)
	refreshing = false
	if WC.Jobs.Chain then pcall(WC.Jobs.Chain) end
end

-- the old entry points, kept so callers cost nothing: each message's `job`
-- and `state` carry everything
function WC.Jobs.Note(inbox) WC.Jobs.Apply(inbox) end
WC.Jobs.Model = getModel
function WC.Jobs.Started() WC.Jobs.Refresh() end
function WC.Jobs.Gone() WC.Jobs.Refresh() end


-- Shortcuts while the Companion window has the controller's focus (the
-- player, 2026-11-10): square cancels, triangle sends now, each acting on the
-- newest message of the conversation in view. Live only while the UI is
-- focused on our window (Blizzard's FrameControlsManager.isUIFocused and
-- focusedFrame, read, never set): the d-pad and face buttons belong to the
-- cursor then anyway, so nothing of the bars is taken. Set and cleared out of
-- combat only; the window cannot hold focus in a fight.
local function newest(state)
	local view = WowCompanion_ViewSlot and WowCompanion_ViewSlot() or ""
	if not getModel() then return end
	local list = model:Ordered()
	for i = #list, 1, -1 do
		local job = list[i]
		if job.slot == view and not job.cancel
			and (state and job.state == state or (not state and RANK_LIVE[job.state])) then
			return job
		end
	end
end
-- what Send now would send: the newest queued message of the view, only while
-- something there runs (nothing to interrupt otherwise) and no press is pending
local function sendable()
	local job = newest("queued")
	if job and not job.sending and model:Running(job.slot) then return job end
end
-- the offered button (Agent.lua): shown in the window, with a press waiting
local function offerShown()
	local b = _G.WowCompanionDo
	return b and b:IsVisible() and b.slot ~= nil or false
end
local cancelKey = CreateFrame("Button", "WCJobsCancelKey", UIParent)
cancelKey:SetScript("OnClick", function() cancel(newest()) end)
local nowKey = CreateFrame("Button", "WCJobsNowKey", UIParent)
nowKey:SetScript("OnClick", function()
	local job = sendable()
	if job then sendNow(job) end
end)
local keyOwner = CreateFrame("Frame", "WCJobsKeys", UIParent)
local bound = nil
local elapsed = 0
local lastTab
keyOwner:SetScript("OnUpdate", function(_, dt)
	elapsed = elapsed + dt
	-- a tab change redraws at once, in step with the tab (the player,
	-- 2026-11-10: the legend lagged a beat behind); otherwise five times a second
	local frame = WC.Companion.window()
	local tab = frame and frame:IsShown() and frame.currentTab or 0
	if elapsed < 0.2 and tab == lastTab then return end
	lastTab = tab
	elapsed = 0
	if InCombatLockdown() then return end
	local window = WC.Companion.window()
	local focused = window and WC.IsFocused(window) or false
	-- only on the Chat tab, where the messages they act on are (the player,
	-- 2026-11-10: on Errands, "square to cancel, cancel what?")
	if window and (window.currentTab or 1) ~= 1 then focused = false end
	-- the legend: what square and triangle do right now, shown only while
	-- they work (the player, 2026-11-10: "no input legend")
	if window then
		-- one line with the game's own button glyphs inline, in the panel's
		-- bottom strip under the chat well, shown only with prompts
		if not window.jobsLegend then
			local fs = window:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			-- centred in the 26-px strip under the wells (ButtonFrameTemplate)
			fs:SetPoint("RIGHT", window.chatWell or window, "BOTTOMRIGHT", -4, -13)
			fs:SetJustifyH("RIGHT")
			window.jobsLegend = fs
		end
		local function glyph(key) return WowCompanion_Glyph(key) end
		local parts = {}
		if focused and newest() then parts[#parts + 1] = glyph("PAD3") .. " Cancel newest" end
		if focused and sendable() then parts[#parts + 1] = glyph("PAD4") .. " Send queued now" end
		if focused and offerShown() then parts[#parts + 1] = glyph("PADLSTICK") .. " " .. (_G.WowCompanionDo:GetText() or "Press") end
		window.jobsLegend:SetText(table.concat(parts, "     "))
		window.jobsLegend:SetShown(#parts > 0)
		if window.jobsCancelPrompt then window.jobsCancelPrompt:Hide() window.jobsNowPrompt:Hide() end
	end
	-- what is bound follows what the legend shows; rebound only on a change
	local want = focused and (offerShown() and "offer" or "jobs") or nil
	if want ~= bound then
		ClearOverrideBindings(keyOwner)
		if want then
			SetOverrideBindingClick(keyOwner, true, "PAD3", "WCJobsCancelKey")
			SetOverrideBindingClick(keyOwner, true, "PAD4", "WCJobsNowKey")
		end
		-- L3 presses the offered button (the player, 2026-11-10: a prompt for
		-- it, on L3, which they never use in menus); autorun comes back when
		-- the window lets go. The button itself is secure and the press is theirs
		if want == "offer" then
			SetOverrideBindingClick(keyOwner, true, "PADLSTICK", "WowCompanionDo", "LeftButton")
		end
		bound = want
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
	local frame = WC.Companion.window()
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
	-- nothing between the arrows: no links, the cursor chooses as before
	local column = { top }
	for _, b in ipairs(icons) do column[#column + 1] = b end
	column[#column + 1] = bottom
	local linked = #icons > 0
	for i, b in ipairs(column) do
		WC.SetVerticalNav(b, linked and column[i - 1] or nil, linked and column[i + 1] or nil)
	end
end
