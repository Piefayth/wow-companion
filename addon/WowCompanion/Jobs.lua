-- Your messages while something can still be done to them (the player,
-- 2026-11-10: "give the individual messages their own panel ... and once a
-- message doesn't have anything you can do to it anymore, the majigger goes
-- away"). A panel per message, docked under the transcript: being heard
-- (Whisper has the clip), queued behind another, or being worked on. Each has
-- its buttons, reachable with the controller cursor:
--   hearing: Cancel (the words are dropped when they arrive)
--   queued:  Send now (ends the running request so this one starts), Cancel
--   working: Cancel (ends the agent)
-- The game cannot write to the PC while it runs, so a button draws a command on
-- the data strip ("WCCMD <nonce> <verb> <slot> [req]"), which the companion
-- watches (tools/strip.py --serve, src/requests.rs watch_commands).
-- Fed by Companion.lua: WC.Jobs.Note(inbox) for each log line, Started, Gone.

local core = WC.Core
local jobs = {} -- { req, slot, text, state = "queued" | "working" | "cancelling", at }
local panels = {}
local MAX = 4
local PANEL_H = 46

local function label(slot)
	return slot == "" and "Main" or slot == "quick" and "Quick" or slot:upper()
end

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

local function clean(text)
	text = tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("^%[%u%d]+%]%s*", "")
	return (text:gsub("%s+", " "))
end

local refresh

local function build(i)
	local frame = core.logFrame()
	local well = frame.chatWell or frame
	local made, p = pcall(CreateFrame, "Frame", nil, well, "BackdropTemplate")
	p = made and p or CreateFrame("Frame", nil, well)
	p:SetHeight(PANEL_H)
	if p.SetBackdrop then
		-- the game's tooltip border: a small Blizzard-style card per message
		p:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 14,
			insets = { left = 4, right = 4, top = 4, bottom = 4 },
		})
		p:SetBackdropColor(0.05, 0.05, 0.08, 0.95)
		p:SetBackdropBorderColor(0.8, 0.7, 0.4, 1)
	end
	p:SetFrameLevel(well:GetFrameLevel() + 6)
	p.state = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	p.state:SetPoint("TOPLEFT", 10, -8)
	p.text = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	p.text:SetPoint("TOPLEFT", p.state, "BOTTOMLEFT", 0, -3)
	p.text:SetJustifyH("LEFT")
	p.text:SetWordWrap(false)
	-- small icon buttons (the player, 2026-11-10: "whole wordy buttons"): the
	-- game's own art, the name in a tooltip when the cursor lands on one
	local ICONS = {
		cancel = { "Interface\\Buttons\\UI-GroupLoot-Pass-Up", "Interface\\Buttons\\UI-GroupLoot-Pass-Down", "Interface\\Buttons\\UI-GroupLoot-Pass-Highlight" },
		now = { "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Down", "Interface\\Buttons\\UI-Common-MouseHilight" },
	}
	local function button(text, onClick, icon)
		local b = CreateFrame("Button", nil, p)
		b:SetSize(26, 26)
		local art = ICONS[icon]
		b:SetNormalTexture(art[1])
		b:SetPushedTexture(art[2])
		b:SetHighlightTexture(art[3], "ADD")
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText(text)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		b:SetScript("OnClick", function() onClick(p.job) end)
		if not InCombatLockdown() and SmartNavigation_MarkFrameFocusable then
			pcall(SmartNavigation_MarkFrameFocusable, b)
		else
			b.unmarked = true
		end
		return b
	end
	p.cancel = button(CANCEL or "Cancel", function(job)
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
	end, "cancel")
	p.cancel:SetPoint("RIGHT", -6, 0)
	p.now = button("Send now", function(job)
		if not job then return end
		command("now", job.slot, job.req)
		local live = find(job.req)
		if live then live.sending = true end
		refresh()
	end, "now")
	p.now:SetPoint("RIGHT", p.cancel, "LEFT", -2, 0)
	p.text:SetPoint("RIGHT", p.now, "LEFT", -8, 0)
	p:Hide()
	panels[i] = p
	return p
end

-- what to show: hearing first (a slot Whisper is busy with), then each message
local function rows()
	local out = {}
	local now = GetTime()
	-- only the conversation in view (the player, 2026-11-10: "in R1 I just see
	-- the R1 messages")
	local view = WowCompanion_ViewSlot and WowCompanion_ViewSlot() or ""
	for slot, since in pairs(core.transcribing or {}) do
		if slot == view then
			out[#out + 1] = { state = "hearing", slot = slot, text = "...", at = since }
		end
	end
	table.sort(out, function(a, b) return a.at < b.at end)
	-- a running job whose conversation stopped working (a reply or a failure
	-- that named no conversation) has nothing left to do
	local working = core.working or {}
	for i = #jobs, 1, -1 do
		local job = jobs[i]
		if job.state == "working" and not working[job.slot] and now - (job.at or now) > 3 then
			table.remove(jobs, i)
		end
	end
	for _, job in ipairs(jobs) do
		if job.slot == view then out[#out + 1] = job end
	end
	while #out > MAX do table.remove(out, #out) end
	return out, now
end

refresh = function()
	local frame = core.logFrame and core.logFrame()
	if not frame or not frame.messages then return end
	local list, now = rows()
	local well = frame.chatWell or frame
	local working = core.working or {}
	for i = 1, math.max(#list, #panels) do
		local job = list[i]
		local p = panels[i] or (job and build(i))
		if p then
			if job then
				p.job = job
				p:ClearAllPoints()
				p:SetPoint("BOTTOMLEFT", well, "BOTTOMLEFT", 8, 8 + (i - 1) * (PANEL_H + 4))
				p:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT", -8, 8 + (i - 1) * (PANEL_H + 4))
				local who = label(job.slot)
				local secs = math.floor(now - (job.at or now))
				local dots = ("."):rep(math.floor(now * 2) % 4)
				if job.state == "hearing" then
					p.state:SetText(("|cff9ad5ff%s  hearing you%s|r"):format(who, dots))
					p.text:SetText("|cff808080transcribing" .. dots .. "|r")
				elseif job.state == "queued" then
					p.state:SetText(("|cffb0b0b0%s  queued|r"):format(who))
					p.text:SetText(clean(job.text))
				elseif job.state == "cancelling" then
					p.state:SetText(("|cffff7777%s  cancelling%s|r"):format(who, dots))
					p.text:SetText(clean(job.text))
				else
					p.state:SetText(("|cffffd100%s  working %ds|r"):format(who, secs))
					local doing = working[job.slot] and working[job.slot].text
					p.text:SetText(clean(job.text) .. (doing and ("  |cff808080" .. clean(doing) .. "|r") or ""))
				end
				local runningThere = false
				for _, other in ipairs(jobs) do
					if other.slot == job.slot and other.state == "working" then runningThere = true end
				end
				p.cancel:SetShown(job.state ~= "cancelling")
				p.now:SetShown(job.state == "queued" and runningThere and not job.sending)
				if p.text.SetPoint then
					p.text:SetPoint("RIGHT", p.now:IsShown() and p.now or p.cancel, "LEFT", -8, 0)
				end
				p:Show()
			else
				p.job = nil
				p:Hide()
			end
		end
	end
	-- the transcript ends above the panels
	local shown = math.min(#list, MAX)
	local scroll = frame.messages.scroll
	if scroll and frame.chatWell then
		scroll:SetPoint("BOTTOMRIGHT", frame.chatWell, "BOTTOMRIGHT", -28, 8 + shown * (PANEL_H + 4))
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
	for _, p in ipairs(panels) do
		for _, b in ipairs({ p.cancel, p.now }) do
			if b.unmarked and SmartNavigation_MarkFrameFocusable then
				b.unmarked = nil
				pcall(SmartNavigation_MarkFrameFocusable, b)
			end
		end
	end
end)
