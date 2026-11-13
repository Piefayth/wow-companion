-- What this needs from Agent.lua comes
-- through its named functions (WC.Companion.<verb>); what Agent.lua calls here is WC.Transcript.

local LOG_KEEP = WC.Companion.LOG_KEEP

-- The transcript, laid out like a document rather than a chat log: each turn
-- gets a small "Claude 20:45" header, and a reply is rendered from the little
-- markdown it carries. Blank lines are paragraph gaps, "#" lines headings,
-- "- " and "1." lines bullets with a hanging indent, ``` fences code on a
-- dark band, and `code` and **bold** inline colour. A ScrollingMessageFrame
-- cannot do any of that (one font, no hanging indent), so this is a scroll
-- frame of font strings, one per line, stacked top to bottom.
local TURN_GAP, PARA_GAP, LINE_SPACING = 14, 7, 2
-- The scroll frame is the chat well's transcript rect (Window.lua,
-- docs/ui-layout.md) and the backings fill it edge to edge; the text keeps
-- these margins inside it.
local PAD_L, PAD_R, PAD_TOP = 10, 10, 6
local BODY_FONT = ChatFontNormal and "ChatFontNormal" or "GameFontHighlight"
local NOTE_FONT = "GameFontHighlightSmall"

-- Every turn on our own stone (WC.Style.STONE): the replies on the lighter
-- one, the player's on the darker. Owners differ by value, never by hue.
-- Turns parted by the scroll bar's own divider (ScrollBar.lua), which joins its border.
local STONE = WC.Style.STONE
-- owner: whose turn, which picks the stone
local function ownBand(band, owner)
	band:SetTexture(STONE[owner] or STONE.claude, "REPEAT", "REPEAT")
	band:SetHorizTile(true)
	band:SetVertTile(true)
end
local function turnBand(content, owner)
	local band = content:CreateTexture(nil, "BACKGROUND", nil, -1)
	ownBand(band, owner)
	return band, WC.ScrollBar.Divider(content)
end

-- A conversation switch empties the transcript and fills it again, so a row's
-- parts are kept when it goes and handed to the next row: frames are never
-- freed, and making them anew at every switch hitched and grew without end.
-- One pool per kind of part, each part reset to what a new one would be.
local function take(pool, make)
	local part = table.remove(pool)
	if part then
		part:Show()
		return part
	end
	return make()
end
local function fontString(t, font)
	local fs = take(t.pool.text, function() return t.content:CreateFontString(nil, "OVERLAY") end)
	fs:SetFontObject(font)
	fs:SetTextColor(_G[font]:GetTextColor())
	return fs
end
local function turnParts(t, owner)
	local band = take(t.pool.turn, function() return t.content:CreateTexture(nil, "BACKGROUND", nil, -1) end)
	ownBand(band, owner)
	return band, take(t.pool.divider, function() return WC.ScrollBar.Divider(t.content) end)
end
local function codeBand(t)
	return take(t.pool.band, function()
		-- the ready check's backing, tiled
		local band = t.content:CreateTexture(nil, "BACKGROUND")
		band:SetTexture([[Interface\DialogFrame\UI-DialogBox-Background-Dark]], "REPEAT", "REPEAT")
		band:SetHorizTile(true)
		band:SetVertTile(true)
		band:SetAlpha(0.75)
		return band
	end)
end
-- a row leaves the transcript: its parts hidden and kept for the next
local function release(t, row)
	local pool = t.pool
	for _, part in ipairs({ { row.fs, pool.text }, { row.marker, pool.text }, { row.band, pool.band },
		{ row.turn, pool.turn }, { row.divider, pool.divider } }) do
		if part[1] then
			part[1]:Hide()
			part[1]:ClearAllPoints()
			table.insert(part[2], part[1])
		end
	end
end

local function inline(text)
	text = text:gsub("%*%*(.-)%*%*", "|cfff4ecdc%1|r")
	text = text:gsub("`([^`]+)`", "|cff9ad5ff%1|r")
	return text
end

local Transcript = {}
Transcript.__index = Transcript

-- A message's state after its header (a cancel leaves a tombstone that says
-- whether it really happened). `grey` dims the
-- message's own lines too
local function markRow(transcript, row, status, grey)
	row.base = row.base or row.fs:GetText()
	row.status = status
	row.fs:SetText(row.base .. (status or ""))
	if grey then
		local found
		for _, r in ipairs(transcript.rows) do
			if r == row then found = true
			elseif found then
				if r.header then break end
				r.fs:SetTextColor(0.45, 0.45, 0.45)
			end
		end
	end
end

local function newTranscript(parent)
	local scroll = CreateFrame("ScrollFrame", nil, parent)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(1, 1)
	scroll:SetScrollChild(content)
	local t = setmetatable({ scroll = scroll, content = content, rows = {}, height = PAD_TOP,
		pool = { text = {}, band = {}, turn = {}, divider = {} } }, Transcript)
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local range = self:GetVerticalScrollRange()
		local step = IsShiftKeyDown() and range or 48
		self:SetVerticalScroll(math.max(0, math.min(range, self:GetVerticalScroll() - delta * step)))
	end)
	-- wrapping depends on width, so a resize lays everything out again
	scroll:SetScript("OnSizeChanged", function() t:Layout() end)
	scroll:SetScript("OnShow", function() t:Layout() end)
	return t
end

-- the text's width: the turns run the scroll frame's full width, the bar
-- standing over their right end, and the text keeps clear of it
function Transcript:Width()
	local width = self.scroll:GetWidth()
	width = width and width - WC.ScrollBar.ROOM
	return width and width > 60 and width or nil
end

-- place one row below the last; returns the new bottom
function Transcript:Place(row, y, width)
	local turnTop = y
	y = y + (y > PAD_TOP and row.gap or 0)
	if row.turn then
		-- the backing starts halfway into the gap above, so turns meet edge to edge
		local top = turnTop + math.floor((y - turnTop) / 2)
		row.turn:ClearAllPoints()
		row.turn:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, -top)
		-- the backings and dividers run on under the scroll bar to the well's edge
		row.turn:SetPoint("TOPRIGHT", self.content, "TOPRIGHT", 0, -top)
		row.turn:SetHeight(1)
		-- centred on the boundary with the turn above; none above the first
		row.divider:ClearAllPoints()
		row.divider:SetPoint("LEFT", row.turn, "TOPLEFT", 0, 0)
		row.divider:SetPoint("RIGHT", row.turn, "TOPRIGHT", 0, 0)
		row.divider:SetShown(self.turnBand ~= nil)
		self.turnBand, self.turnTop = row.turn, top
	end
	local fs = row.fs
	fs:ClearAllPoints()
	fs:SetPoint("TOPLEFT", self.content, "TOPLEFT", PAD_L + row.indent, -y)
	fs:SetWidth(width - PAD_L - PAD_R - row.indent)
	local height = fs:GetStringHeight()
	if row.marker then
		row.marker:ClearAllPoints()
		row.marker:SetPoint("TOPRIGHT", fs, "TOPLEFT", -5, 0)
	end
	if row.band then
		row.band:ClearAllPoints()
		row.band:SetPoint("TOPLEFT", self.content, "TOPLEFT", PAD_L + row.indent - 6, -y + 3)
		row.band:SetPoint("TOPRIGHT", self.content, "TOPRIGHT", -(PAD_R + WC.ScrollBar.ROOM) + 6, -y + 3)
		row.band:SetHeight(height + 6)
		height = height + 3
	end
	if self.turnBand then
		self.turnBand:SetHeight(y + height + math.floor(TURN_GAP / 2) - self.turnTop)
	end
	return y + height
end

-- A resize rewraps every line, so the content gets shorter or taller under a
-- scroll offset measured against the old height: widening left the offset past
-- the new end and the window showed nothing. So keep the reader's place by
-- fraction, and stay pinned to the bottom if that is where they were.
function Transcript:Layout()
	if self.holding then return end
	local width = self:Width()
	if not width then return end
	local scroll = self.scroll
	local range = scroll:GetVerticalScrollRange()
	local offset = scroll:GetVerticalScroll()
	local following = range <= 0 or offset >= range - 4
	local fraction = range > 0 and offset / range or 1
	self.content:SetWidth(scroll:GetWidth())
	self.turnBand = nil
	local y = PAD_TOP
	for _, row in ipairs(self.rows) do
		y = self:Place(row, y, width)
	end
	self.height = y
	self.content:SetHeight(math.max(y, 1))
	scroll:UpdateScrollChildRect()
	if following then
		self:ToBottom()
	else
		scroll:SetVerticalScroll(math.floor(scroll:GetVerticalScrollRange() * fraction))
	end
end

function Transcript:ToBottom()
	local scroll = self.scroll
	scroll:UpdateScrollChildRect()
	scroll:SetVerticalScroll(scroll:GetVerticalScrollRange())
	-- the range settles a frame later; follow it there too
	C_Timer.After(0, function()
		scroll:UpdateScrollChildRect()
		scroll:SetVerticalScroll(scroll:GetVerticalScrollRange())
	end)
end

-- owner (optional): this row begins a turn, on that owner's backing. Made
-- here, before the row is placed: an appended row is placed at once, and a
-- backing added after that stretched the turn before it instead.
function Transcript:Row(font, text, indent, gap, r, g, b, owner)
	local fs = fontString(self, font)
	fs:SetJustifyH("LEFT")
	fs:SetJustifyV("TOP")
	fs:SetWordWrap(true)
	fs:SetNonSpaceWrap(true)
	fs:SetSpacing(LINE_SPACING)
	if r then fs:SetTextColor(r, g, b) end
	fs:SetText(text)
	local row = { fs = fs, indent = indent or 0, gap = self.gap or gap or 0,
		header = owner and true or nil }
	if owner then row.turn, row.divider = turnParts(self, owner) end
	self.gap = nil
	-- Confirmed lines are only ever appended, so the conversation never jumps. What is still to come is shown
	-- below, as the waiting lines (Jobs.lua), and replaced there in place.
	self.rows[#self.rows + 1] = row
	-- appended rows are placed alone; only a resize walks them all
	local width = not self.holding and self:Width()
	if width then
		local scroll = self.scroll
		local following = scroll:GetVerticalScroll() >= scroll:GetVerticalScrollRange() - 4
		self.height = self:Place(row, self.height, width)
		self.content:SetHeight(math.max(self.height, 1))
		if following then self:ToBottom() end
		-- the progress lines after the last message move down at once, not
		-- on the next tick, so none covers the agent's working line
		if self.jobsGhosts and WC.Jobs and WC.Jobs.Refresh then WC.Jobs.Refresh() end
	end
	return row
end

-- one line of a reply or of what you said
function Transcript:Markdown(line, r, g, b)
	if line:match("^%s*```") then
		self.code = not self.code
		self.gap = self.gap or 4
		return
	end
	if self.code then
		local row = self:Row(BODY_FONT, (line:gsub("|", "||")), 14, 0, 0.74, 0.86, 0.74)
		row.band = codeBand(self)
		return
	end
	if line:match("^%s*$") then
		self.gap = PARA_GAP
		return
	end
	local hashes, heading = line:match("^(#+)%s+(.+)$")
	if heading then
		self:Row(#hashes == 1 and "GameFontNormalLarge" or "GameFontNormal", inline(heading), 0,
			PARA_GAP + 2)
		self.gap = 3
		return
	end
	local lead, mark, rest = line:match("^(%s*)([-*])%s+(.+)$")
	if not mark then
		lead, mark, rest = line:match("^(%s*)(%d+[.)])%s+(.+)$")
	end
	if mark then
		local indent = 18 + math.floor(#lead / 2) * 16
		local row = self:Row(BODY_FONT, inline(rest), indent, 3, r, g, b)
		row.marker = fontString(self, BODY_FONT)
		row.marker:SetText((mark == "-" or mark == "*") and "|cffffd100•|r" or ("|cffffd100%s|r"):format(mark))
		return
	end
	self:Row(BODY_FONT, inline(line), 0, 2, r, g, b)
end

local WHO = {
	you = { "You", "|cff9ad5ff", 0.74, 0.84, 0.96 },
	-- a soft warm off-white, not white: near-white on near-black glows
	-- (halation) and tires on a TV
	claude = { "Claude", "|cffffd100", 0.86, 0.83, 0.76 },
}

function Transcript:Add(who, text, continued, at, job)
	local voice = WHO[who]
	if not continued then
		self.code = false
		if voice then
			local stamp = date("%H:%M", at or time())
			local header = ("%s%s|r  |cff5c6370%s|r"):format(voice[2], voice[1], stamp)
			local row = self:Row("GameFontNormalSmall", header, 0, TURN_GAP, nil, nil, nil, who)
			-- your own message's header carries its controls (Jobs.lua)
			if who == "you" then row.you = true end
			row.job = job
			self.gap = 3
		end
	end
	if voice then
		self:Markdown(text, voice[3], voice[4], voice[5])
	else
		-- what a step did, a probe found, or an error: small notes under the reply
		local row = self:Row(NOTE_FONT, inline(text), 14, continued and 1 or 5,
			who == "error" and 1 or 0.72, who == "error" and 0.47 or 0.74, who == "error" and 0.47 or 0.78)
		row.marker = fontString(self, NOTE_FONT)
		row.marker:SetText(who == "error" and "|cffff7777!|r" or "|cff5c6370›|r")
	end
	-- a long session would grow without end; keep the newest rows
	if #self.rows > LOG_KEEP * 3 then
		for i = 1, LOG_KEEP do
			release(self, table.remove(self.rows, 1))
		end
		self:Layout()
	end
end

-- The agent at work, as an entry of the conversation (one order, nothing
-- jumps): added at the moment the work
-- began, like any line, and only ever changed in place. Its text updates as
-- the work goes on; at the end it is taken away if nothing came after it
-- (the reply takes its place), else it says how the work ended and stays.
function Transcript:AddLive(header, text)
	local head = self:Row("GameFontNormalSmall", header, 0, TURN_GAP, nil, nil, nil, "claude")
	self.gap = 3
	local line = self:Row(BODY_FONT, text, 0, 2, 0.6, 0.6, 0.6)
	return { head = head, line = line }
end
-- The work entry ends with `text`. `answered`: the reply follows it, so an
-- entry still last is taken out and the reply stands in its place; any other
-- end (cancelled, stopped) stays, saying so.
function Transcript:EndLive(live, text, answered)
	local n = #self.rows
	if answered and self.rows[n] == live.line and self.rows[n - 1] == live.head then
		release(self, live.head)
		release(self, live.line)
		self.rows[n] = nil
		self.rows[n - 1] = nil
		self:Layout()
	else
		live.line.fs:SetText(text)
	end
end

-- replaying hundreds of saved lines places them once at the end, not one by one
function Transcript:Hold(holding)
	self.holding = holding or nil
	if not holding then
		self:Layout()
		self:ToBottom()
	end
end

function Transcript:Clear()
	for _, row in ipairs(self.rows) do release(self, row) end
	self.turnBand = nil
	self.rows, self.height, self.code, self.gap = {}, PAD_TOP, false, nil
	self.live = nil
	self.content:SetHeight(1)
end


WC.Transcript = WC.Transcript or {}
WC.Transcript.newTranscript = newTranscript
WC.Transcript.PAD_L, WC.Transcript.PAD_R = PAD_L, PAD_R
-- the pending lines (Jobs.lua) are turns too: the same backing and divider
WC.Transcript.turnBand = turnBand
WC.Transcript.ownBand = ownBand
WC.Transcript.TURN_GAP = TURN_GAP
WC.Transcript.markRow = markRow
