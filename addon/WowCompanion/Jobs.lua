-- Your messages while something can still be done to them (the player,
-- 2026-11-10: "give the individual messages their own panel ... and once a
-- message doesn't have anything you can do to it anymore, the majigger goes
-- away"), shown on the lines that already say so: the waiting line (hearing
-- you, working) and each queued message's header. Reachable with the cursor:
--   hearing: Cancel (the words are dropped when they arrive)
--   queued:  Send now (ends the running request so this one starts), Cancel
--   working: Cancel (ends the agent)
-- The game cannot write to the PC while it runs, so a button draws a command on
-- the data strip ("WCCMD <nonce> <verb> <slot> [req]"), which the companion
-- watches (tools/strip.py --serve, src/requests.rs watch_commands).
-- Fed by Companion.lua: WC.Jobs.Note(inbox) for each log line, Started, Gone.

local core = WC.Core
local jobs = {} -- { req, slot, text, state = "queued" | "working" | "cancelling", at, queueId }
local made = {} -- every icon button, for marking after a fight

local function find(req)
	for i, job in ipairs(jobs) do
		if job.req == req then return job, i end
	end
end

local function command(verb, slot, req)
	if not (WowCompanion_Strip and WowCompanion_Strip.Send) then return end
	WowCompanion_Strip.Send(("WCCMD %d%04d %s %s%s"):format(time(), math.random(0, 9999), verb,
		slot ~= "" and slot or "main", req and (" " .. req) or ""), 2.5)
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

-- A cancel is only a request until the companion answers (the player,
-- 2026-11-10: "I'd like to truly know that it actually got cancelled"): the
-- message's header says "cancelling" at once, then what the PC answered, or
-- that it never did. The message stays as a tombstone, greyed
local CONFIRM_WITHIN = 12
local GREY, GOOD, BAD = "|cff9d9d9d", "|cff7fd27f", "|cffff7777"
local function mark(transcript, row, status, grey)
	if transcript and row and WC.Transcript.markRow then
		pcall(WC.Transcript.markRow, transcript, row, status, grey)
	end
end
local hearingAsked = {} -- slot -> GetTime() of a hearing cancel not yet answered
local function note(slot, text)
	if core.remember then core.remember("note", text, nil, slot) end
end
local function cancel(job)
	if not job then return end
	if job.state == "hearing" then
		command("hear", job.slot)
		if core.setTranscribing then core.setTranscribing(job.slot, false) end
		local asked = GetTime()
		hearingAsked[job.slot] = asked
		C_Timer.After(CONFIRM_WITHIN, function()
			if hearingAsked[job.slot] == asked then
				hearingAsked[job.slot] = nil
				note(job.slot, BAD .. "Cancel not confirmed: the companion never answered. Your words may still be sent.|r")
			end
		end)
	else
		local live = find(job.req)
		if not live or live.state == "cancelling" then return end
		local frame = core.logFrame and core.logFrame()
		local transcript = frame and frame.messages
		live.cancelRow = live.state == "queued" and live.queueId and transcript and queuedRow(transcript, live.queueId) or live.row
		live.cancelIn = transcript
		live.state = "cancelling"
		command("cancel", job.slot, job.req)
		mark(transcript, live.cancelRow, "  " .. GREY .. "cancelling...|r")
		C_Timer.After(CONFIRM_WITHIN, function()
			if live.state == "cancelling" and find(live.req) then
				mark(live.cancelIn, live.cancelRow, "  " .. BAD .. "cancel not confirmed|r")
				live.state = live.queueId and "queued" or "working"
				refresh()
			end
		end)
	end
	refresh()
end

-- the companion's answer to a cancel (Companion.lua handlers.stopped)
function WC.Jobs.Stopped(inbox)
	local slot = inbox.slot or ""
	if inbox.hearing then
		local asked = hearingAsked[slot]
		hearingAsked[slot] = nil
		if asked or inbox.nothing then
			note(slot, inbox.nothing and (GREY .. "Nothing left to cancel: that message was already answered.|r")
				or (GOOD .. "Cancelled|r " .. GREY .. "before it was sent.|r"))
		end
		return
	end
	local job = inbox.req and find(inbox.req)
	if not job then return end
	local frame = core.logFrame and core.logFrame()
	local transcript = job.cancelIn or (frame and frame.messages)
	local row = job.cancelRow or job.row
	if not row and job.queueId and transcript then row = queuedRow(transcript, job.queueId) end
	if inbox.tooLate then
		mark(transcript, row, "  " .. BAD .. "too late: already answered|r")
	elseif inbox.sendNow then
		-- not a cancel of this message: it was interrupted for the next one
		mark(transcript, row, "  " .. GREY .. "interrupted|r")
	else
		mark(transcript, row, "  " .. GOOD .. "cancelled|r", true)
	end
	if job.queueId and WC.Transcript.unqueueId then WC.Transcript.unqueueId(slot, job.queueId) end
end
local function sendNow(job)
	if not job then return end
	command("now", job.slot, job.req)
	-- every queued message goes in the same request, so one press sends them
	-- all: the other play buttons go too
	for _, other in ipairs(jobs) do
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
	-- a running job whose conversation stopped working (a reply or a failure
	-- that named no conversation) has nothing left to do
	for i = #jobs, 1, -1 do
		local job = jobs[i]
		-- a reply (or anything that ended the conversation's work) leaves
		-- nothing to cancel: gone within a second (the player, 2026-11-10: a
		-- Cancel stayed on an answered message)
		if job.state == "working" and not working[job.slot] and now - (job.at or now) > 1 then
			table.remove(jobs, i)
		end
	end
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
	local runningThere = false
	for _, job in ipairs(jobs) do
		if job.slot == view and job.state == "working" then runningThere = true end
	end
	for _, job in ipairs(jobs) do
		local row = job.slot == view and job.state == "queued" and job.queueId and queuedRow(transcript, job.queueId)
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
	for _, job in ipairs(jobs) do
		if job.slot == view and job.state == "working" then running = job end
	end
	-- bound once to the message it belongs to (your newest line when the work
	-- began), so it can never wander onto an older one
	local runRow
	if running and working[view] then
		if not (running.row and running.row.fs:IsShown()) then
			running.row = nil
			for i = #(transcript.rows or {}), 1, -1 do
				local row = transcript.rows[i]
				if row.you and not row.queued and row.fs:IsShown() then running.row = row break end
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
		pair.x:SetPoint("TOPRIGHT", runRow.fs, "TOPRIGHT", -4, 3)
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

-- a log line from the companion: a request's own line carries `req`
function WC.Jobs.Note(inbox)
	local slot = inbox.slot or ""
	if inbox.who == "you" and inbox.req then
		local job = find(inbox.req)
		if not job then
			job = { req = inbox.req, slot = slot, text = inbox.text, at = GetTime() }
			jobs[#jobs + 1] = job
		end
		job.text = inbox.text or job.text
		job.queueId = inbox.queueId or job.queueId
		job.state = inbox.queued and "queued" or "working"
		if job.state == "working" then job.at = GetTime() end
	elseif inbox.slot and not inbox.pending and inbox.who ~= "you" and not inbox.queued then
		-- the reply (or the error) ends the conversation's running request
		for i = #jobs, 1, -1 do
			if jobs[i].slot == slot and jobs[i].state ~= "queued" then table.remove(jobs, i) end
		end
	end
	WC.Jobs.Refresh()
end

-- a queued request began
function WC.Jobs.Started(req, slot)
	local job = req and find(req)
	if not job then
		for _, j in ipairs(jobs) do
			if j.slot == (slot or "") and j.state == "queued" then job = j break end
		end
	end
	if job then job.state = "working" job.at = GetTime() job.sending = nil end
	WC.Jobs.Refresh()
end

-- cancelled, interrupted or stopped: req, or every job of the slot
function WC.Jobs.Gone(req, slot, all)
	for i = #jobs, 1, -1 do
		local j = jobs[i]
		if (req and j.req == req) or (not req and all and j.slot == (slot or ""))
			or (not req and not all and j.slot == (slot or "") and j.state ~= "queued") then
			table.remove(jobs, i)
		end
	end
	WC.Jobs.Refresh()
end

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
	for i = #jobs, 1, -1 do
		local job = jobs[i]
		if job.slot == view and (state and job.state == state or (not state and job.state ~= "cancelling")) then
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
