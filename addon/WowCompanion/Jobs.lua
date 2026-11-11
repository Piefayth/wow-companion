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


-- `at`: the press, in seconds (the nonce opens with it; a hearing cancel is
-- matched to its clip by it, so a retry must carry the first press's time)
-- The game's half of the audit trail (src/audit.rs; tools/audit.py merges
-- both): what arrived, what was drawn, what the window predicted. Kept in the
-- save file, the newest 600 lines; readable after a reload.
local function wallMs() return time() * 1000 end
function WowCompanion_Audit(what, slot, detail)
	if type(WowCompanionDB) ~= "table" then return end
	local log = WowCompanionDB.audit or {}
	WowCompanionDB.audit = log
	local ms = WC.Jobs and WC.Jobs.NowMs and WC.Jobs.NowMs() or wallMs()
	log[#log + 1] = ("%.0f game %s %s %s"):format(ms, (slot == nil or slot == "") and "main" or slot, what, tostring(detail or ""))
	while #log > 600 do table.remove(log, 1) end
end
local function audit(what, slot, detail) pcall(WowCompanion_Audit, what, slot, detail) end

local function command(verb, slot, id, at)
	audit("draw", slot, ("%s%s%s"):format(verb, id and (" %.0f"):format(id) or "", at and (" press=" .. at) or ""))
	if not (WowCompanion_Strip and WowCompanion_Strip.Send) then return end
	WowCompanion_Strip.Send(("WCCMD %d%04d %s %s%s"):format(at or time(), math.random(0, 9999), verb,
		slot ~= "" and slot or "main", id and (" " .. ("%.0f"):format(id)) or ""), 2.5)
end

-- The wall clock in ms, the clock job ids are made of: time() gives seconds,
-- so its tick is caught once to line GetTime() up with it
local wallOffset
do
	local seen = time()
	local f = CreateFrame("Frame")
	f:SetScript("OnUpdate", function(self)
		if time() ~= seen then
			wallOffset = time() - GetTime()
			self:SetScript("OnUpdate", nil)
		end
	end)
end
local function nowMs()
	if wallOffset then return math.floor((GetTime() + wallOffset) * 1000) end
	return time() * 1000 + 500
end
WC.Jobs = WC.Jobs or {}
WC.Jobs.NowMs = nowMs

-- The model (JobsModel.lua) holds every job, every clip being heard, and every
-- decision about them; it is tested on its own (tools/test_jobs.py). This file
-- draws it. It is made once the save file is loaded (its ledger is kept there).
local model
local placeholders = {}
local function getModel()
	if model then return model end
	if type(WowCompanionDB) ~= "table" or not WC.JobsModel then return nil end
	WowCompanionDB.jobModel = WowCompanionDB.jobModel or { jobs = WowCompanionDB.jobs }
	WowCompanionDB.jobs = nil
	model = WC.JobsModel.new({
		now = nowMs,
		command = function(verb, slot, id) command(verb, slot, id) end,
		remember = function(text, slot, job, who)
			if job then
				WC.Companion.remember("you", "|cff9d9d9d" .. text .. "|r", nil, slot, nil, job)
			else
				WC.Companion.remember(who or "note", text, nil, slot)
			end
		end,
		audit = audit,
		store = WowCompanionDB.jobModel,
		changed = function() if WC.Jobs.Refresh then WC.Jobs.Refresh() end end,
	})
	jobs, placeholders = model.jobs, model.clips
	return model
end


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
	if job.placeholder then
		model:CancelClip(job.slot, job.placeholder)
	else
		model:CancelJob(job.id)
	end
end
local function sendNow(job)
	if job and getModel() then model:SendNow(job.id) end
end

function WC.Jobs.Running(slot) return getModel() and model:Running(slot) or false end
function WC.Jobs.Ended(id) return getModel() and model:Ended(id) or false end
function WC.Jobs.Apply(inbox) if getModel() then model:Apply(inbox) end end
function WC.Jobs.Claim(inbox, slot) if getModel() then return model:Claim(inbox, slot) end end
function WC.Jobs.Stopped(inbox) if getModel() then model:Stopped(inbox) end end
function WC.Jobs.Released(slot) if getModel() then model:Released(slot) end end
function WC.Jobs.DropHearing() if getModel() then model:DropHearing() end end

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
-- one X per clip being heard (the player, 2026-11-10: a second clip took
-- the first one's X away)
local hearXs = {}
local pairsPool = {}


refresh = function()
	local frame = WC.Companion.window()
	if not frame or not frame.messages or not frame.pending then return end
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
	local heard = model:Clips(view)
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
			ghosts[i] = { head = head, line = line }
		end
		transcript0.jobsGhosts = ghosts
	end
	local items = {}
	local dots = ("."):rep(math.floor(now * 2) % 4)
	local stamp = "  |cff5c6370" .. date("%H:%M") .. "|r"
	local entry = WC.Companion.working(view)
	-- a run whose every message is being cancelled shows no working line: the
	-- cancel is already the answer (the player, 2026-11-10)
	if entry then
		local live, cancelling = false, false
		for _, job in pairs(jobs) do
			if job.slot == view and job.state == "running" then
				if job.cancel or job.heardCancel then cancelling = true else live = true end
			end
		end
		if cancelling and not live then entry = nil end
	end
	-- the work in view: an entry added when it began, changed in place
	local live = transcript0.live
	if live and (live.slot ~= view or not entry) then
		local ended = model:Running(live.slot) and "stopped" or "answered below"
		for _, job in pairs(jobs) do
			if job.slot == live.slot and job.state == "cancelled" and (job.endedAt or 0) >= live.began then
				ended = "cancelled"
			end
		end
		transcript0:EndLive(live, GREY .. ended .. "|r")
		transcript0.live, live = nil, nil
	end
	if entry then
		local doing = tostring(entry.text or "thinking"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
		local text = ("%s%s  %ds"):format(doing, dots, now - (entry.since or now))
		if not live then
			live = transcript0:AddLive("|cffffd100Claude|r" .. stamp, text)
			live.slot, live.began = view, nowMs()
			transcript0.live = live
		else
			live.line.fs:SetText(text)
		end
	end
	for _, p in ipairs(heard) do
		if #items >= #ghosts then break end
		if p.cancelled then
			items[#items + 1] = { "|cff9ad5ffYou|r" .. stamp .. "  " .. GOOD .. "cancelled|r", GREY .. "(cancelled while it was still being heard)|r" }
		else
			items[#items + 1] = { "|cff9ad5ffYou|r" .. stamp, ("hearing you%s  %ds"):format(dots, (nowMs() - p.release) / 1000), hearing = true }
			items[#items].clip = p
		end
	end
	local base = transcript0.height or 0
	local width = transcript0.Width and transcript0:Width() or 300
	local y = base
	local hearingLines = {}
	for i, g in ipairs(ghosts) do
		local item = items[i]
		if item then
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
			if item.hearing then hearingLines[#hearingLines + 1] = { head = g.head, clip = item.clip } end
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
	for i, line in ipairs(hearingLines) do
		local x = hearXs[i]
		if not x then
			x = icon(transcript0.content, "cancel", CANCEL or "Cancel", cancel)
			hearXs[i] = x
		end
		x.job = { placeholder = line.clip, slot = view }
		x:ClearAllPoints()
		x:SetPoint("TOPRIGHT", transcript0.content, "TOPLEFT", width - 4, -(line.head.y - 3))
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
		local row = job.slot == view and job.state == "queued" and not job.cancel and not job.heardCancel
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
		if job.slot == view and job.state == "running" and not job.cancel and not job.heardCancel then running = job end
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
	if not state then
		local list = model:Clips(view)
		for i = #list, 1, -1 do
			if not list[i].cancelled then return { placeholder = list[i], slot = view } end
		end
	end
	local list = model:Ordered()
	for i = #list, 1, -1 do
		local job = list[i]
		if job.slot == view and not job.cancel and not job.heardCancel
			and (state and job.state == state or (not state and (job.state == "queued" or job.state == "running"))) then
			return job
		end
	end
end
-- the offered button (Companion.lua): shown in the window, with a press waiting
local function offerShown()
	local b = _G.WowCompanionDo
	return b and b:IsVisible() and b.slot ~= nil or false
end
local cancelKey = CreateFrame("Button", "WCJobsCancelKey", UIParent)
cancelKey:SetScript("OnClick", function() cancel(newest()) end)
local nowKey = CreateFrame("Button", "WCJobsNowKey", UIParent)
nowKey:SetScript("OnClick", function()
	local job = newest("queued")
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
