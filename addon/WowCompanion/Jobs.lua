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

-- small icon buttons on the lines that already say what is going on (the
-- player, 2026-11-10: "you could have just used little smaller icons and the
-- existing working/running paradigm"): the game's own art, named in a tooltip
-- one family of flat icons from the game's own common set (the player,
-- 2026-11-10: the glowing loot X beside a plain arrow did not match)
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
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	b:SetScript("OnClick", function(self) onClick(self.job) end)
	if not InCombatLockdown() and SmartNavigation_MarkFrameFocusable then
		pcall(SmartNavigation_MarkFrameFocusable, b)
	else
		b.unmarked = true
	end
	b:Hide()
	made[#made + 1] = b
	return b
end

local function cancel(job)
	if not job then return end
	if job.state == "hearing" then
		command("hear", job.slot)
		if core.setTranscribing then core.setTranscribing(job.slot, false) end
	else
		command("cancel", job.slot, job.req)
		local live = find(job.req)
		if live then live.state = "cancelling" end
	end
	refresh()
end
local function sendNow(job)
	if not job then return end
	command("now", job.slot, job.req)
	local live = find(job.req)
	if live then live.sending = true end
	refresh()
end

-- the waiting line (hearing you / working) gets an X at its end; each queued
-- message's own header line in the transcript gets a play and an X
local statusX
local pairsPool = {}

local function queuedRow(transcript, queueId)
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
		if job.state == "working" and not working[job.slot] and now - (job.at or now) > 3 then
			table.remove(jobs, i)
		end
	end
	-- the waiting line: hearing first (the newest thing), else the running request
	statusX = statusX or icon(frame, "cancel", CANCEL or "Cancel", cancel)
	local target
	local since = (core.transcribing or {})[view]
	if since then
		target = { state = "hearing", slot = view }
	else
		for _, job in ipairs(jobs) do
			if job.slot == view and job.state == "working" then target = job end
		end
	end
	if target and frame.pending:IsShown() then
		statusX.job = target
		statusX:ClearAllPoints()
		-- in the same column as the queued lines' icons (the player, 2026-11-10:
		-- aligned controls are easier to reach with the cursor)
		local scroll = frame.messages.scroll
		local right, left = scroll:GetRight(), frame:GetLeft()
		local _, y = frame.pending:GetCenter()
		local bottom = frame:GetBottom()
		if right and left and y and bottom then
			statusX:SetPoint("RIGHT", frame, "BOTTOMLEFT", right - left - 4, y - bottom)
		else
			statusX:SetPoint("LEFT", frame.pending, "RIGHT", 4, 0)
		end
		statusX:SetFrameLevel(frame:GetFrameLevel() + 10)
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
	for i = used + 1, #pairsPool do
		pairsPool[i].x:Hide()
		pairsPool[i].go:Hide()
	end
end

WC.Jobs = {}
WC.Jobs.Refresh = function() pcall(refresh) end

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
