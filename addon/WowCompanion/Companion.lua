-- The in-game half. The helper writes Lua into load-on-demand slot addons and
-- "rings" a bell sound file; we hear the bell and load the next slot.
-- Right now it only probes whether that channel, and the APIs we need, work.
-- Probe results land in WowCompanionDB.probe once you /reload.

local ADDON = "WowCompanion"
local BELLS = 8
local SIGNALS = "Interface\\AddOns\\WowCompanion\\Signals\\"

-- how much conversation to keep; it rides in SavedVariables, so not unbounded
local LOG_KEEP = 300

local nextSlot = 1
local blocked = 0
local ticker
local logWindow
local pendingTicker
local actionButton
-- which pad key the offer button binds to; set with /wc key <PADNAME>
local offerKey

local function say(message)
	print("|cff66ccffCompanion|r " .. message)
end

local function record(key, value)
	-- storing nil would delete the key rather than save it, quietly losing the
	-- result instead of reporting that we got nothing
	WowCompanionDB.probe[key] = value == nil and "nil" or value
	say(key .. ": " .. tostring(value))
end

local function slotName(n)
	return ("%s_S%03d"):format(ADDON, n)
end

local function bellPath(n)
	return SIGNALS .. ((n - 1) % BELLS + 1) .. ".wav"
end

-- PlaySoundFile claims every file will play, even empty ones, so only IsPlaying counts
local function listen(path, heard)
	local _, handle = PlaySoundFile(path, "Master")
	C_Timer.After(0.15, function()
		local playing = handle ~= nil and C_Sound.IsPlaying(handle)
		if handle then
			StopSound(handle)
		end
		heard(playing)
	end)
end

local function activeEditBox()
	local get = ChatEdit_GetActiveWindow or (ChatFrameUtil and ChatFrameUtil.GetActiveWindow)
	return get and get()
end

-- The transcript, laid out like a document rather than a chat log: each turn
-- gets a small "Claude 20:45" header, and a reply is rendered from the little
-- markdown it carries. Blank lines are paragraph gaps, "#" lines headings,
-- "- " and "1." lines bullets with a hanging indent, ``` fences code on a
-- dark band, and `code` and **bold** inline colour. A ScrollingMessageFrame
-- cannot do any of that (one font, no hanging indent), so this is a scroll
-- frame of font strings, one per line, stacked top to bottom.
local TURN_GAP, PARA_GAP, LINE_SPACING = 14, 7, 2
local BODY_FONT = ChatFontNormal and "ChatFontNormal" or "GameFontHighlight"
local NOTE_FONT = "GameFontHighlightSmall"

local function inline(text)
	text = text:gsub("%*%*(.-)%*%*", "|cffffffff%1|r")
	text = text:gsub("`([^`]+)`", "|cff9ad5ff%1|r")
	return text
end

local Transcript = {}
Transcript.__index = Transcript

local function newTranscript(parent)
	local scroll = CreateFrame("ScrollFrame", nil, parent)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(1, 1)
	scroll:SetScrollChild(content)
	local t = setmetatable({ scroll = scroll, content = content, rows = {}, height = 0 }, Transcript)
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

function Transcript:Width()
	local width = self.scroll:GetWidth()
	return width and width > 60 and width or nil
end

-- place one row below the last; returns the new bottom
function Transcript:Place(row, y, width)
	y = y + (y > 0 and row.gap or 0)
	local fs = row.fs
	fs:ClearAllPoints()
	fs:SetPoint("TOPLEFT", self.content, "TOPLEFT", row.indent, -y)
	fs:SetWidth(width - row.indent - 4)
	local height = fs:GetStringHeight()
	if row.marker then
		row.marker:ClearAllPoints()
		row.marker:SetPoint("TOPRIGHT", fs, "TOPLEFT", -5, 0)
	end
	if row.band then
		row.band:ClearAllPoints()
		row.band:SetPoint("TOPLEFT", self.content, "TOPLEFT", row.indent - 6, -y + 3)
		row.band:SetPoint("TOPRIGHT", self.content, "TOPRIGHT", 0, -y + 3)
		row.band:SetHeight(height + 6)
		height = height + 3
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
	self.content:SetWidth(width)
	local y = 0
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

function Transcript:Row(font, text, indent, gap, r, g, b)
	local fs = self.content:CreateFontString(nil, "OVERLAY", font)
	fs:SetJustifyH("LEFT")
	fs:SetJustifyV("TOP")
	fs:SetWordWrap(true)
	fs:SetNonSpaceWrap(true)
	fs:SetSpacing(LINE_SPACING)
	if r then fs:SetTextColor(r, g, b) end
	fs:SetText(text)
	local row = { fs = fs, indent = indent or 0, gap = self.gap or gap or 0 }
	self.gap = nil
	self.rows[#self.rows + 1] = row
	-- appended rows are placed alone; only a resize walks them all
	local width = not self.holding and self:Width()
	if width then
		local scroll = self.scroll
		local following = scroll:GetVerticalScroll() >= scroll:GetVerticalScrollRange() - 4
		self.height = self:Place(row, self.height, width)
		self.content:SetHeight(math.max(self.height, 1))
		if following then self:ToBottom() end
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
		row.band = self.content:CreateTexture(nil, "BACKGROUND")
		row.band:SetColorTexture(1, 1, 1, 0.06)
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
		row.marker = self.content:CreateFontString(nil, "OVERLAY", BODY_FONT)
		row.marker:SetText((mark == "-" or mark == "*") and "|cffffd100•|r" or ("|cffffd100%s|r"):format(mark))
		return
	end
	self:Row(BODY_FONT, inline(line), 0, 2, r, g, b)
end

local WHO = {
	you = { "You", "|cff9ad5ff", 0.74, 0.84, 0.96 },
	claude = { "Claude", "|cffffd100", 0.93, 0.93, 0.93 },
}

function Transcript:Add(who, text, continued, at)
	local voice = WHO[who]
	if not continued then
		self.code = false
		if voice then
			local stamp = date("%H:%M", at or time())
			self:Row("GameFontNormalSmall", ("%s%s|r  |cff5c6370%s|r"):format(voice[2], voice[1], stamp),
				0, TURN_GAP)
			self.gap = 3
		end
	end
	if voice then
		self:Markdown(text, voice[3], voice[4], voice[5])
	else
		-- what a step did, a probe found, or an error: small notes under the reply
		local row = self:Row(NOTE_FONT, inline(text), 14, continued and 1 or 5,
			who == "error" and 1 or 0.62, who == "error" and 0.47 or 0.65, who == "error" and 0.47 or 0.70)
		row.marker = self.content:CreateFontString(nil, "OVERLAY", NOTE_FONT)
		row.marker:SetText(who == "error" and "|cffff7777!|r" or "|cff5c6370›|r")
	end
	-- a long session would grow without end; keep the newest rows
	if #self.rows > LOG_KEEP * 3 then
		for i = 1, LOG_KEEP do
			local row = table.remove(self.rows, 1)
			row.fs:Hide()
			if row.marker then row.marker:Hide() end
			if row.band then row.band:Hide() end
		end
		self:Layout()
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
	for _, row in ipairs(self.rows) do
		row.fs:Hide()
		if row.marker then row.marker:Hide() end
		if row.band then row.band:Hide() end
	end
	self.rows, self.height, self.code, self.gap = {}, 0, false, nil
	self.content:SetHeight(1)
end

-- Tabs along the bottom edge, as Blizzard's own panels have them
-- (PanelTabButtonTemplate, PanelTemplates_SetTab), picked with the controller
-- cursor. No shoulder buttons: L1 and R1 are talk-button slots.
local TAB_NAMES = { "Chat", "Tools", "Status" }
local function buildTabs(frame, messages, pending)
	local pages = {}
	local function page()
		local p = CreateFrame("Frame", nil, frame)
		p:SetPoint("TOPLEFT", 20, -42)
		p:SetPoint("BOTTOMRIGHT", -20, 34)
		p:Hide()
		return p
	end
	pages[2], pages[3] = page(), page()

	-- Tools: everyday buttons, Blizzard's red panel buttons in a column, each
	-- with a line saying what it does
	local tools = pages[2]
	local y = 0
	local function note(b, text)
		local fs = tools:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetPoint("LEFT", b, "RIGHT", 12, 0)
		fs:SetPoint("RIGHT", tools, "RIGHT", 0, 0)
		fs:SetJustifyH("LEFT")
		fs:SetText(text)
	end
	local function button(label, text, onClick)
		local made, b = pcall(CreateFrame, "Button", nil, tools, "UIPanelButtonTemplate")
		if not made or not b then return end
		b:SetSize(170, 26)
		b:SetPoint("TOPLEFT", 0, -y)
		b:SetText(label)
		b:SetScript("OnClick", onClick)
		note(b, text)
		if SmartNavigation_MarkFrameFocusable then pcall(SmartNavigation_MarkFrameFocusable, b) end
		y = y + 34
		return b
	end
	-- The reload is protected, so it is a secure button the player presses. Built
	-- out of combat only: a secure frame's attributes cannot be set in one.
	local reloadY = y
	y = y + 34
	local function makeReload()
		if frame.reloadButton or InCombatLockdown() then return end
		local made, b = pcall(CreateFrame, "Button", "WowCompanionReload", tools,
			"SecureActionButtonTemplate, UIPanelButtonTemplate")
		if not made or not b then return end
		b:SetSize(170, 26)
		b:SetPoint("TOPLEFT", 0, -reloadY)
		b:SetText("Reload UI")
		b:SetAttribute("type", "macro")
		b:SetAttribute("macrotext", "/reload")
		b:RegisterForClicks("AnyDown") -- see CLAUDE.md, "Register a secure button for AnyDown"
		note(b, "Lets me see what changed, and clears any taint.")
		if SmartNavigation_MarkFrameFocusable then pcall(SmartNavigation_MarkFrameFocusable, b) end
		frame.reloadButton = b
	end
	makeReload()
	local sizeButton = button("Size: " .. ({ "Small", "Medium", "Large" })[WowCompanionDB.windowSize or 2],
		"The size the window opens at. The corner grip changes it just for now.")
	if sizeButton then
		sizeButton:SetScript("OnClick", function(self)
			self:SetText("Size: " .. frame.CycleDefaultSize())
		end)
	end
	button("Clear map pins", "Remove every pin I put on your minimap and world map.", function()
		if WCPins and WCPins.Clear then WCPins.Clear() end
		frame.SelectTab(3)
	end)
	button("Clear transcript", "Empty this window. The conversation itself carries on.", function()
		WowCompanionDB.log = {}
		messages:Clear()
		frame.SelectTab(1)
	end)

	-- Status: what is running, read fresh while the tab is looked at
	local status = pages[3]:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	status:SetPoint("TOPLEFT")
	status:SetPoint("TOPRIGHT")
	status:SetJustifyH("LEFT")
	status:SetJustifyV("TOP")
	status:SetSpacing(5)
	local function refreshStatus()
		local gold, grey = "|cffffd100", "|cff9d9d9d"
		local lines = {}
		local function add(label, value) lines[#lines + 1] = gold .. label .. "|r   " .. value end
		local up = WowCompanion_IsUp and WowCompanion_IsUp()
		add("Companion app", up and "|cff40ff40connected|r"
			or "|cffff6060not heard from|r " .. grey .. "(is it running on the PC?)|r")
		add("Messages this session", ("%d of 64 %s(a reload resets it)|r"):format(nextSlot - 1, grey))
		local pins = WowCompanionDB.pins and #WowCompanionDB.pins or 0
		add("Map pins", pins == 0 and "none" or tostring(pins))
		local wheels = {}
		for key, wheel in pairs(WowCompanionWheelDB and WowCompanionWheelDB.wheels or {}) do
			wheels[#wheels + 1] = (wheel.label or key) .. " " .. grey .. "(" .. #(wheel.slots or {}) .. ")|r"
		end
		table.sort(wheels)
		add("Wheels", #wheels > 0 and table.concat(wheels, ", ") or "none")
		local modules = {}
		for name in pairs(WowCompanionDB.modules or {}) do modules[#modules + 1] = name end
		table.sort(modules)
		add("My modules", #modules > 0 and table.concat(modules, ", ") or "none")
		add("Combat", InCombatLockdown() and "|cffff6060yes|r " .. grey .. "(changes wait until it ends)|r" or "no")
		status:SetText(table.concat(lines, "\n"))
	end
	local since = 0
	pages[3]:SetScript("OnShow", function() since = 0 refreshStatus() end)
	pages[3]:SetScript("OnUpdate", function(_, dt)
		since = since + dt
		if since > 1 then since = 0 refreshStatus() end
	end)

	-- The conversation picker: a well on the right, the auction house's category
	-- list art (auctionhouse-nav-button, -select, -highlight, the categories
	-- background, an inset border). Chat tab only.
	local WELL = 130
	local made, well = pcall(CreateFrame, "Frame", nil, frame, "InsetFrameTemplate")
	if not made or not well then well = CreateFrame("Frame", nil, frame) end
	well:SetPoint("TOPRIGHT", -16, -40)
	well:SetPoint("BOTTOMRIGHT", -16, 32)
	well:SetWidth(WELL)
	local back = well:CreateTexture(nil, "BACKGROUND", nil, 1)
	back:SetAtlas("auctionhouse-background-categories")
	back:SetPoint("TOPLEFT", 3, -3)
	back:SetPoint("BOTTOMRIGHT", -3, 3)
	frame.chatParts = frame.chatParts or {}
	table.insert(frame.chatParts, well)
	-- The transcript sits in a well of its own, an inset like the conversation
	-- list's, with its scroll arrows inside it; the raised frame around them
	-- keeps only the waiting line (the player, 2026-11-10).
	local madeChat, chatWell = pcall(CreateFrame, "Frame", nil, frame, "InsetFrameTemplate")
	if not madeChat or not chatWell then chatWell = CreateFrame("Frame", nil, frame) end
	chatWell:SetPoint("TOPLEFT", 16, -40)
	chatWell:SetPoint("BOTTOMRIGHT", -(16 + WELL + 6), 32)
	table.insert(frame.chatParts, chatWell)
	messages.scroll:ClearAllPoints()
	messages.scroll:SetPoint("TOPLEFT", chatWell, "TOPLEFT", 10, -8)
	messages.scroll:SetPoint("BOTTOMRIGHT", chatWell, "BOTTOMRIGHT", -28, 8)
	messages.scroll:SetFrameLevel(chatWell:GetFrameLevel() + 2)
	if frame.chatParts[1] and frame.chatParts[2] then
		frame.chatParts[1]:ClearAllPoints()
		frame.chatParts[1]:SetPoint("TOPRIGHT", chatWell, "TOPRIGHT", -5, -6)
		frame.chatParts[1]:SetFrameLevel(chatWell:GetFrameLevel() + 3)
		frame.chatParts[2]:ClearAllPoints()
		frame.chatParts[2]:SetPoint("BOTTOMRIGHT", chatWell, "BOTTOMRIGHT", -5, 6)
		frame.chatParts[2]:SetFrameLevel(chatWell:GetFrameLevel() + 3)
	end
	frame.convButtons = {}
	local LABELS = { [""] = "Main", l1 = "L1", l2 = "L2", r1 = "R1", r2 = "R2" }
	for i, key in ipairs({ "", "l1", "l2", "r1", "r2" }) do
		local b = CreateFrame("Button", nil, well)
		b:SetSize(WELL - 10, 24)
		b:SetPoint("TOP", well, "TOP", 0, -6 - (i - 1) * 26)
		local normal = b:CreateTexture(nil, "BACKGROUND")
		normal:SetAtlas("auctionhouse-nav-button")
		normal:SetAllPoints()
		local selected = b:CreateTexture(nil, "ARTWORK")
		selected:SetAtlas("auctionhouse-nav-button-select")
		selected:SetBlendMode("ADD")
		selected:SetAllPoints()
		selected:Hide()
		b.selected = selected
		local glow = b:CreateTexture(nil, "HIGHLIGHT")
		glow:SetAtlas("auctionhouse-nav-button-highlight")
		glow:SetBlendMode("ADD")
		glow:SetAllPoints()
		local text = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		text:SetPoint("LEFT", 12, 0)
		text:SetPoint("RIGHT", -8, 0)
		text:SetJustifyH("LEFT")
		b:SetFontString(text)
		b:SetText(LABELS[key])
		b:SetScript("OnClick", function() WowCompanion_SetConversation(key) end)
		if SmartNavigation_MarkFrameFocusable then pcall(SmartNavigation_MarkFrameFocusable, b) end
		frame.convButtons[key] = b
	end
	frame.convButtons[""].selected:Show()

	-- the tabs, hanging under the bottom edge like the character sheet's
	for i, name in ipairs(TAB_NAMES) do
		local made, tab = pcall(CreateFrame, "Button", nil, frame, "PanelTabButtonTemplate")
		if not made or not tab then return end
		tab:SetID(i)
		tab:SetText(name)
		if i == 1 then
			tab:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 14, 6)
		else
			tab:SetPoint("TOPLEFT", frame.Tabs[i - 1], "TOPRIGHT", 3, 0)
		end
		tab:SetScript("OnClick", function(self) frame.SelectTab(self:GetID()) end)
		if SmartNavigation_MarkFrameFocusable then pcall(SmartNavigation_MarkFrameFocusable, tab) end
	end
	PanelTemplates_SetNumTabs(frame, #TAB_NAMES)

	function frame.SelectTab(id)
		id = ((id - 1) % #TAB_NAMES) + 1
		frame.currentTab = id
		PanelTemplates_SetTab(frame, id)
		local chat = id == 1
		messages.scroll:SetShown(chat)
		for _, part in ipairs(frame.chatParts or {}) do part:SetShown(chat) end
		if not chat then pending:Hide() elseif frame.pendingShown then pending:Show() end
		for i, p in pairs(pages) do p:SetShown(i == id) end
		if id == 2 then makeReload() end
	end
	frame.SelectTab(1)

	-- Tabs are picked with the controller cursor. L1 and R1 used to page them,
	-- but they are talk-button slots now (the player, 2026-11-10), so the window
	-- binds nothing. The reload button waits out combat, being secure.
	local keys = CreateFrame("Frame")
	keys:RegisterEvent("PLAYER_REGEN_ENABLED")
	keys:SetScript("OnEvent", function() makeReload() end)
end

-- The conversation window. Chat lines scroll away and cannot be scrolled back
-- through, so replies live in their own frame and in SavedVariables, which is what
-- makes history survive a /reload.
--
-- Deliberately not registered in UISpecialFrames: Escape handling is where the
-- gamepad taint lives, and this frame has a close button instead.
local function buildLog()
	-- the game's own dialog art, so it sits in the UI rather than on top of it.
	-- CreateFrame throws on a template this build lacks, and an ugly window beats
	-- an addon that fails to load.
	local made, frame = pcall(CreateFrame, "Frame", "WowCompanionLog", UIParent, "BackdropTemplate")
	if not made or not frame then
		frame = CreateFrame("Frame", "WowCompanionLog", UIParent)
	end
	frame:SetSize(560, 340)
	-- top left, where Blizzard docks its own left panels (the character sheet,
	-- the spellbook); the panel manager places it there on every open
	frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -116)
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)
	frame:Hide()
	if frame.SetBackdrop then
		frame:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			edgeSize = 32,
			insets = { left = 11, right = 12, top = 12, bottom = 11 },
		})
	end

	-- the header strip is the drag handle, so a drag inside the transcript is free
	-- to select text instead of hauling the window around
	local header = CreateFrame("Frame", nil, frame)
	header:SetPoint("TOPLEFT", 12, -12)
	header:SetPoint("TOPRIGHT", -12, -12)
	header:SetHeight(26)
	header:EnableMouse(true)
	header:RegisterForDrag("LeftButton")
	frame:SetMovable(true)
	header:SetScript("OnDragStart", function() frame:StartMoving() end)
	header:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)

	local crest = header:CreateTexture(nil, "ARTWORK")
	crest:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
	crest:SetPoint("TOP", frame, "TOP", 0, 12)
	crest:SetSize(230, 64)
	local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOP", crest, "TOP", 0, -14)
	title:SetText("Companion")

	local closed, close = pcall(CreateFrame, "Button", nil, frame, "UIPanelCloseButton")
	if closed and close then
		close:SetPoint("TOPRIGHT", -6, -6)
		close:SetScript("OnClick", function() frame:Hide() end)
		-- the controller's back button (circle) closes a focused window by clicking
		-- its frame.CloseButton (SmartNavigation:AttemptClose), so name it that
		frame.CloseButton = close
	end

	-- the waiting line: the agent takes seconds, and silence reads as broken
	local pending = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	-- A fixed box, text pinned left and never wrapping: with one anchor the region
	-- resized to its text on every tick, so the dots coming and going made the
	-- line jump. Now only the dots move.
	pending:SetPoint("BOTTOMLEFT", 18, 16)
	pending:SetPoint("BOTTOMRIGHT", -180, 16)
	pending:SetJustifyH("LEFT")
	pending:SetWordWrap(false)
	pending:Hide()
	frame.pending = pending

	local messages = newTranscript(frame)
	messages.scroll:SetPoint("TOPLEFT", 20, -42)
	messages.scroll:SetPoint("BOTTOMRIGHT", -40, 34)
	-- Scrolling on a controller without taking the right stick (the camera):
	-- Blizzard's own scroll arrows on the right edge, which the cursor reaches
	-- like any button and A presses. Each press moves most of a page.
	local function scrollBy(pages)
		local sc = messages.scroll
		local step = math.max(40, (sc:GetHeight() or 200) * 0.75)
		local range = sc:GetVerticalScrollRange()
		sc:SetVerticalScroll(math.max(0, math.min(range, sc:GetVerticalScroll() + pages * step)))
	end
	for _, spec in ipairs({ { "UIPanelScrollUpButtonTemplate", -1, "TOPRIGHT", -16, -44 },
		{ "UIPanelScrollDownButtonTemplate", 1, "BOTTOMRIGHT", -16, 36 } }) do
		local made, arrow = pcall(CreateFrame, "Button", nil, frame, spec[1])
		if made and arrow then
			frame.chatParts = frame.chatParts or {}
			table.insert(frame.chatParts, arrow)
			arrow:SetPoint(spec[3], frame, spec[3], spec[4], spec[5])
			arrow:SetScript("OnClick", function() scrollBy(spec[2]) end)
		end
	end
	frame.messages = messages

	-- 1.60.1 added a SmartNavigation API for exactly this: an addon can mark its own
	-- frames focusable by the gamepad cursor, so the window is reachable on a
	-- controller instead of needing a mouse.
	if SmartNavigation_MarkFrameFocusable then
		pcall(SmartNavigation_MarkFrameFocusable, frame)
	end
	-- A real UI panel, so the controller's focus-cycle button reaches it like any
	-- of the game's own windows: that cycle walks the panels FrameControlsManager
	-- was told about, and ShowUIPanel is what tells it.
	--
	-- The catch, read in Blizzard_GamepadSharedUtility/FrameControlsManager.lua: a
	-- shown panel turns on the "fallthrough catcher" binding group, which takes the
	-- d-pad and face buttons away from the bars, and only FrameHidden turns it off.
	-- HideUIPanel sends that; a plain Hide (our close button, /wc log) does not, so
	-- the manager kept a closed window in its list and the bars stayed dead after
	-- it was gone. That is why it broke with the window shut. Blizzard's own
	-- non-panel windows (ColorPickerFrame, BuffFrame) call FrameHidden from OnHide,
	-- and it is wrapped by SecureHelper for exactly such callers, so we do the same:
	-- however the window goes away, the manager hears about it.
	if UIPanelWindows then
		UIPanelWindows["WowCompanionLog"] = {
			area = "left",
			pushable = 1, -- another left panel opening pushes it right, as Blizzard's do
			whileDead = 1,
			allowOtherPanels = 1,
		}
	end
	-- The right stick scrolls a panel's text once SmartNavigation is told which
	-- scroll frame belongs to it, as the chat frame and Blizzard's own dialogs do
	-- (FloatingChatFrame.lua, SocialContract.lua). It is SecureHelper-wrapped for
	-- such callers. Deferred a tick, so the panel is registered first.
	frame:SetScript("OnShow", function(self)
		C_Timer.After(0, function()
			-- the transcript is text, no buttons: without this flag a right-stick
			-- scroll went looking for a button inside it, found none, and left the
			-- cursor drawn on the close button while nothing was selected
			-- (UpdateScrollSelection; the flag is Blizzard's, for "message text")
			if SmartNavigation_MarkScrollFrameMaintainPreviousButtonOnScroll and self.messages then
				pcall(SmartNavigation_MarkScrollFrameMaintainPreviousButtonOnScroll, self.messages.scroll)
			end
			-- not handed to SmartNavigation any more: that gave it the right stick
			-- and took the camera away while the window had focus; the arrows scroll
		end)
	end)
	frame:SetScript("OnHide", function(self)
		if GamepadMode and GamepadMode.FrameControlsManager
			and InputUtil and InputUtil.IsGamepadUIEnabled() then
			GamepadMode.FrameControlsManager:FrameHidden(self)
		end
	end)

	frame:SetResizable(true)
	if frame.SetResizeBounds then
		frame:SetResizeBounds(320, 180)
	end
	local grip = CreateFrame("Button", nil, frame)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -8, 8)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	-- A mouse drags it; the controller can only click it, which used to do
	-- nothing. So a click that did not resize steps through three sizes. A drag
	-- also ends in a click, which is why the size at mouse-down is compared.
	local SIZES = { { 560, 340 }, { 760, 520 }, { 980, 700 } }
	local sizeBefore
	grip:SetScript("OnMouseDown", function()
		sizeBefore = frame:GetWidth() .. "x" .. frame:GetHeight()
		frame:StartSizing("BOTTOMRIGHT")
	end)
	grip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing() end)
	grip:SetScript("OnClick", function()
		if sizeBefore and sizeBefore ~= frame:GetWidth() .. "x" .. frame:GetHeight() then
			sizeBefore = nil
			return
		end
		sizeBefore = nil
		frame.CycleSize()
	end)
	-- The corner grip steps the size for now; the Tools tab's button sets the
	-- default the window opens at, kept in WowCompanionDB.windowSize (the player,
	-- 2026-11-10: medium unless they pick otherwise).
	local function applySize(index)
		local pick = SIZES[index] or SIZES[2]
		-- grow from the top-left corner, so the window stays where it is
		local left, top = frame:GetLeft(), frame:GetTop()
		frame:SetSize(pick[1], pick[2])
		if left and top then
			frame:ClearAllPoints()
			frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
		end
	end
	function frame.CycleSize()
		local width = frame:GetWidth()
		local index = 1
		for i, size in ipairs(SIZES) do
			if size[1] > width + 10 then
				index = i
				break
			end
		end
		applySize(index)
	end
	frame.SIZE_NAMES = { "Small", "Medium", "Large" }
	function frame.CycleDefaultSize()
		local index = ((WowCompanionDB.windowSize or 2) % #SIZES) + 1
		WowCompanionDB.windowSize = index
		applySize(index)
		return frame.SIZE_NAMES[index]
	end
	applySize(WowCompanionDB.windowSize or 2)

	buildTabs(frame, messages, pending)
	return frame
end

local function logFrame()
	logWindow = logWindow or buildLog()
	return logWindow
end

-- ShowUIPanel, so the window joins the controller's focus cycle (see buildLog).
-- It is refused in combat, where a plain Show at least puts the text in front of
-- them; the manager is not told, so nothing is left for it to forget.
-- A one-line notice at the top of the screen, instead of opening the window:
-- the window only opens when the player asks for it (a minus tap, /wc log).
-- It cannot take the mouse or the gamepad focus, so it never gets in the way,
-- and in combat it holds what arrives until the fight is over.
local toastFrame, toastHeld, toastTimer
local function toast(text, r, g, b, hold)
	if not toastFrame then
		-- bottom left, flush with the screen's corner, under the chat box; the
		-- game's tooltip border and dark dialog backing, like Blizzard's own UI
		local made, frame = pcall(CreateFrame, "Frame", nil, UIParent, "BackdropTemplate")
		toastFrame = made and frame or CreateFrame("Frame", nil, UIParent)
		toastFrame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
		local chat = ChatFrame1 and ChatFrame1:GetWidth()
		toastFrame:SetSize(math.max(380, (chat or 430) + 40), 34)
		toastFrame:SetFrameStrata("HIGH")
		toastFrame:EnableMouse(false)
		if toastFrame.SetBackdrop then
			toastFrame:SetBackdrop({
				bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
				edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
				tile = true, tileSize = 16, edgeSize = 16,
				insets = { left = 4, right = 4, top = 4, bottom = 4 },
			})
			toastFrame:SetBackdropBorderColor(0.8, 0.8, 0.8, 1)
		end
		toastFrame.text = toastFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		toastFrame.text:SetPoint("LEFT", 12, 0)
		toastFrame.text:SetPoint("RIGHT", -12, 0)
		toastFrame.text:SetJustifyH("LEFT")
		toastFrame.text:SetWordWrap(false)
		toastFrame.text:SetSpacing(3)
		toastFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
		toastFrame:SetScript("OnEvent", function()
			if toastHeld then
				local held = toastHeld
				toastHeld = nil
				toast(unpack(held))
			end
		end)
	end
	if not text then
		toastFrame:Hide()
		return
	end
	if InCombatLockdown() then
		toastHeld = { text, r, g, b, hold }
		toastFrame:Hide()
		return
	end
	toastFrame.text:SetText(text)
	-- one row per line: several agents at work show one each
	local rows = select(2, text:gsub("\n", "")) + 1
	toastFrame:SetHeight(20 + rows * 14 + (rows - 1) * 3)
	toastFrame.text:SetTextColor(r or 1, g or 1, b or 1)
	toastFrame:SetAlpha(1)
	toastFrame:Show()
	if toastTimer then toastTimer:Cancel() end
	toastTimer = nil
	if hold then
		toastTimer = C_Timer.NewTimer(hold, function() toastFrame:Hide() end)
	end
end

local function reveal(frame)
	toast(nil)
	if not InCombatLockdown() and UIPanelWindows and UIPanelWindows["WowCompanionLog"] then
		ShowUIPanel(frame)
	end
	if not frame:IsShown() then
		frame:Show()
	end
end

local function colouredFor(who)
	if who == "you" then
		return "|cff9ad5ff"
	elseif who == "error" then
		return "|cffff7777"
	end
	return "|cffffe08a"
end

local function showLine(who, text, continued, at)
	logFrame().messages:Add(who, text, continued, at)
end

-- Spinning while the agent thinks. Several seconds of silence after you speak is
-- indistinguishable from a broken channel, which is the whole reason this exists.
-- when the current wait began: kept across progress updates, so the count is the
-- whole request, not the time since the last "reading ..."
local pendingSince
-- One waiting line per conversation (the player, 2026-11-10): several agents can
-- work at once, and one shared line muddled them. Each slot keeps its own text
-- and start time; the toast shows a labelled line for every one at work, and
-- the window's line shows the conversation in view.
local working = {}
local SLOT_ORDER = { "", "l1", "l2", "r1", "r2" }
local function slotLabel(slot) return slot == "" and "Main" or slot:upper() end
local renderPending
local paintHook -- the conversation list's painter, set once it exists
local function setPending(text, slot)
	slot = slot or ""
	if text then
		local entry = working[slot] or { since = GetTime() }
		entry.text = text
		working[slot] = entry
	else
		working[slot] = nil
	end
	renderPending()
end
local turn = 0
renderPending = function()
	local frame = logFrame()
	local lines, view = {}, nil
	turn = turn + 1
	local dots = ("."):rep(turn % 4)
	for _, slot in ipairs(SLOT_ORDER) do
		local entry = working[slot]
		if entry then
			local line = ("%s%s  %ds"):format(entry.text, dots, GetTime() - entry.since)
			lines[#lines + 1] = ("|cffffd100%s|r  %s"):format(slotLabel(slot), line)
			if slot == (WowCompanion_ViewSlot and WowCompanion_ViewSlot() or "") then view = line end
		end
	end
	if paintHook then paintHook() end
	pendingSince = view and GetTime() or nil
	frame.pendingShown = view ~= nil
	if view then
		frame.pending:SetText(view)
		if (frame.currentTab or 1) == 1 then frame.pending:Show() end
	else
		frame.pending:Hide()
	end
	if #lines > 0 then
		if not frame:IsShown() then
			toast(table.concat(lines, "\n"), 0.8, 0.8, 0.8)
		end
		if not pendingTicker then pendingTicker = C_Timer.NewTicker(0.4, function() renderPending() end) end
	else
		if pendingTicker then pendingTicker:Cancel() pendingTicker = nil end
		if toastFrame and toastFrame:IsShown() and not toastTimer then toast(nil) end
	end
end

-- Kept in SavedVariables, so it is written on /reload or logout like everything else.
-- Conversations (the player, 2026-11-10): the talk button alone is the main one
-- (""), and with a trigger held each of L1, L2, R1, R2 is its own. Every line
-- remembers which it belongs to; the window shows one at a time, picked with the
-- buttons above the transcript, and a slot with news it has not shown glows.
local CONVERSATIONS = { "", "l1", "l2", "r1", "r2" }
local viewSlot = ""
local unread = {}
local function paintConversations()
	local frame = logWindow
	if not (frame and frame.convButtons) then return end
	for key, button in pairs(frame.convButtons) do
		local label = key == "" and "Main" or key:upper()
		-- each conversation shows its own progress in the list (the player,
		-- 2026-11-10): the seconds while its agent works, "new" once it answered
		local entry = working[key]
		if entry then
			label = label .. "  |cffb0b0b0" .. math.floor(GetTime() - entry.since) .. "s|r"
		elseif unread[key] then
			label = "|cff40ff40" .. label .. "  new|r"
		end
		button:SetText(label)
		if button.selected then button.selected:SetShown(key == viewSlot) end
	end
end

paintHook = paintConversations

local function remember(who, text, continued, slot)
	slot = slot or viewSlot
	WowCompanionDB.log = WowCompanionDB.log or {}
	local entries = WowCompanionDB.log
	entries[#entries + 1] = { at = time(), who = who, text = text, continued = continued or nil,
		slot = slot ~= "" and slot or nil }
	while #entries > LOG_KEEP do
		table.remove(entries, 1)
	end
	if slot == viewSlot then
		showLine(who, text, continued, entries[#entries].at)
	elseif not continued then
		unread[slot] = true
		paintConversations()
	end
end

local function replayLog()
	local messages = logFrame().messages
	messages:Hold(true)
	for _, entry in ipairs(WowCompanionDB.log or {}) do
		if (entry.slot or "") == viewSlot then
			showLine(entry.who or "claude", entry.text or "", entry.continued, entry.at)
		end
	end
	messages:Hold(false)
end

function WowCompanion_ViewSlot() return viewSlot end

function WowCompanion_SetConversation(slot)
	viewSlot = slot or ""
	unread[viewSlot] = nil
	if renderPending then renderPending() end
	logFrame().messages:Clear()
	replayLog()
	paintConversations()
end

-- A button in the Companion window, retargeted on demand.
--
-- Protected calls are refused from insecure code, but a hardware button press is
-- trusted -- so for anything we cannot do ourselves, we put a button in front of the
-- player and they press it. It lives inside the window rather than on an action bar
-- so the gamepad cursor has a normal piece of UI to land on, and because it costs no
-- binding and no bar slot.
--
-- SecureActionButtonTemplate for the secure path, UIPanelButtonTemplate so it looks
-- like the game's own. Macro text is the limit of what it can do, which is also the
-- limit of what the player could type -- it grants no power they lacked.
local function offer(label, macro)
	-- attributes on a secure frame cannot be set in combat, and this is
	-- configuration anyway
	if InCombatLockdown() then
		return "refused: in combat"
	end
	local frame = logFrame()
	if not actionButton then
		local made, button = pcall(CreateFrame, "Button", "WowCompanionDo", frame,
			"SecureActionButtonTemplate, UIPanelButtonTemplate")
		if not made or not button then
			return "could not build the button: " .. tostring(button)
		end
		actionButton = button
		actionButton:SetSize(150, 24)
		actionButton:SetPoint("BOTTOMRIGHT", -32, 12)
		-- Measured, one variable at a time. "AnyUp": the wrapper runs -- PreClick and
		-- PostClick both fire -- and the macro does not, which reads exactly like a
		-- permissions refusal and is not one. Both edges: runs, but twice, once down
		-- and once up. "AnyDown" alone: runs once. That is the answer.
		--
		-- Attributes are still set first, which is cheap and conventional, but the
		-- edge is what decides whether the macro fires at all.
		actionButton:SetAttribute("type", "macro")
		actionButton:RegisterForClicks("AnyDown")

		-- make the cursor able to land on it, and tell SmartNavigation this frame is
		-- where the window's focusable button lives
		if SmartNavigation_MarkFrameFocusable then
			pcall(SmartNavigation_MarkFrameFocusable, actionButton)
		end
		if SmartNavigation_SetButtonFrame then
			pcall(SmartNavigation_SetButtonFrame, actionButton)
		end
		if SmartNavigation_SetReturnFrameFocusButton then
			pcall(SmartNavigation_SetReturnFrameFocusButton, frame, actionButton)
		end
		actionButton:SetScript("PostClick", function(self)
			if ClearOverrideBindings then
				ClearOverrideBindings(self)
			end
			self:Hide()
		end)
	end
	actionButton:SetAttribute("macrotext", macro)
	actionButton:SetText(label)
	actionButton:Show()

	-- The window is not a frame the gamepad cursor will focus, so instead of making
	-- it focusable we bind a pad button straight to clicking this one. The binding
	-- exists only while a button is pending and is cleared the moment it is pressed,
	-- so it costs nothing the rest of the time.
	local bound = "nothing"
	if SetOverrideBindingClick then
		ClearOverrideBindings(actionButton)
		-- built without holes: ipairs stops at the first nil, so a nil offerKey at the
		-- front meant this loop never ran once and every key looked unbindable
		local candidates = {}
		if offerKey then
			candidates[#candidates + 1] = offerKey
		end
		-- names taken from the client's own config, not guessed
		for _, fallback in ipairs({ "PADDRIGHT", "PADDUP", "PADRSHOULDER" }) do
			candidates[#candidates + 1] = fallback
		end
		for _, key in ipairs(candidates) do
			if key and SetOverrideBindingClick(actionButton, true, key, "WowCompanionDo") ~= false then
				bound = key
				break
			end
		end
	end
	-- show the macro, not just the label: the player is the one authorising this, and
	-- "Do it" tells them nothing about what they would be running
	remember("claude", ("button |cffffffff%s|r runs |cff9ad5ff%s|r — %s or click it")
		:format(label, macro, bound ~= "nothing" and ("press " .. bound) or "mouse"))
	toast(("|cffffd100Claude|r  %s: |cffffffff%s|r"):format(
		bound ~= "nothing" and ("press " .. bound) or "open the window", label), 0.8, 0.8, 0.8, 30)
	return ("offering %q which runs %q, bound to %s"):format(label, macro, bound)
end

-- What the helper is allowed to ask for. A dispatch table rather than loadstring on
-- whatever arrives: the rule is configuration only, and this is where that rule lives.
local handlers = {}
-- set further down, once taintScan exists: what follows a dictated line
local onDictated

-- Writes into a chat box the player already opened, and never opens one itself.
-- That distinction is the whole point: when we called ChatFrame_OpenChat, the
-- gamepad focus restore on close came back blocked and the A and B buttons died.
-- A box the player opened was activated by real hardware input, so the secure path
-- stays intact and we only set text on it. Refuses rather than opening one, because
-- opening one is the thing that broke the controller.
-- Whispers by the name the player knows someone by. "whisper Sage, on my way"
-- arrives as "/w Sage, on my way"; this finds who Sage is among the people the
-- game can see (Battle.net friends by BattleTag or the character they are on,
-- character friends, the guild, the group) and writes the name the way
-- Blizzard's own whisper menus do, which is the part a spoken name gets wrong:
-- names here are first and last, and UnitName gives only the first, so a
-- whisper to "Pietra" came back "no player named Pietra". The unit popup joins
-- name and surname with CHARACTERNAME_SURNAME_SEPARATOR when regional unique
-- names are on (UnitPopupUtils.lua, GetFullPlayerName); so do we.
local function plain(text)
	return (text or ""):lower():gsub("[^%w]", "")
end

local function fullUnitName(unit)
	local name, surname = UnitName(unit)
	if not name then return nil end
	if surname and surname ~= "" then
		local seps = Constants and Constants.CharacterNameSeparatorConsts
		if RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled() and seps then
			return name .. seps.CHARACTERNAME_SURNAME_SEPARATOR .. surname
		elseif seps then
			return name .. seps.CHARACTERNAME_REALMNAME_SEPARATOR .. surname
		end
	end
	return name
end

-- every person we could mean: { keys = {...}, target = what goes after /w, label }
local function people()
	local list = {}
	local function add(target, label, ...)
		if not target or target == "" then return end
		local keys = {}
		for _, key in ipairs({ ... }) do
			key = plain(key)
			if key ~= "" then keys[#keys + 1] = key end
		end
		list[#list + 1] = { target = target, label = label, keys = keys }
	end
	-- Battle.net friends, online: their BattleTag and the character they are on
	if BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendAccountInfo then
		local count = BNGetNumFriends() or 0
		for i = 1, count do
			local ok, info = pcall(C_BattleNet.GetFriendAccountInfo, i)
			-- offline ones too: a whisper is how the player finds out whether a
			-- friend is really away or only appearing offline. Resolution prefers
			-- whoever is online (see WowCompanion_ResolveWhisper)
			if ok and info and info.accountName then
				local game = info.gameAccountInfo
				local online = game and game.isOnline
				local tag = info.battleTag and info.battleTag:match("^[^#]+")
				local character = online and game.characterName or nil
				add(info.accountName, (tag or "?") .. (character and (" (on " .. character .. ")") or "")
					.. (online and "" or " (offline)"), tag, character)
				list[#list].online = online and true or false
				list[#list].seen = (info.lastOnlineTime or 0) > 0
			end
		end
	end
	-- character friends
	if C_FriendList and C_FriendList.GetNumFriends then
		for i = 1, C_FriendList.GetNumFriends() or 0 do
			local info = C_FriendList.GetFriendInfoByIndex(i)
			if info and info.connected and info.name then
				add(info.name, info.name, info.name, info.name:match("^[^%-%s]+"))
			end
		end
	end
	-- the guild, online
	if IsInGuild and IsInGuild() and GetNumGuildMembers then
		for i = 1, GetNumGuildMembers() or 0 do
			local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
			if name and online then
				add(name, name .. " (guild)", name, name:match("^[^%-%s]+"))
			end
		end
	end
	-- the group
	local prefix, size = IsInRaid() and "raid" or "party", IsInRaid() and GetNumGroupMembers() or GetNumSubgroupMembers()
	for i = 1, size or 0 do
		local unit = prefix .. i
		if UnitExists(unit) and UnitIsPlayer(unit) and not UnitIsUnit(unit, "player") then
			local full = fullUnitName(unit)
			add(full, full .. " (group)", full, (UnitName(unit)))
		end
	end
	return list
end

-- "/w sage on my way" -> target, message; or nil and why. Tries the first one to
-- three words as the name, longest first, so a two-word name wins over its
-- first word.
function WowCompanion_ResolveWhisper(rest)
	local words = {}
	for word in rest:gmatch("%S+") do words[#words + 1] = word end
	local everyone = people()
	for take = math.min(3, #words), 1, -1 do
		local spoken = plain(table.concat(words, " ", 1, take))
		local hits, seen = {}, {}
		for _, person in ipairs(everyone) do
			for _, key in ipairs(person.keys) do
				if key == spoken and not seen[person.target] then
					seen[person.target] = true
					hits[#hits + 1] = person
					break
				end
			end
		end
		-- several people by one name: whoever is online, else whoever has ever
		-- been seen online (a friend who never logged in has no last-online time)
		for _, keep in ipairs({ "online", "seen" }) do
			if #hits > 1 then
				local narrowed = {}
				for _, hit in ipairs(hits) do
					if hit[keep] ~= false then narrowed[#narrowed + 1] = hit end
				end
				if #narrowed >= 1 and #narrowed < #hits then hits = narrowed end
			end
		end
		if #hits == 1 then
			local message = table.concat(words, " ", take + 1):gsub("^[,:%.%-%s]+", "")
			return hits[1].target, message, hits[1].label
		elseif #hits > 1 then
			local labels = {}
			for _, hit in ipairs(hits) do labels[#labels + 1] = hit.label end
			return nil, "more than one person is called that: " .. table.concat(labels, ", ")
		end
	end
	local names = {}
	for i, person in ipairs(everyone) do
		if i > 12 then break end
		names[#names + 1] = person.label
	end
	return nil, "I don't see anyone called " .. (words[1] or "that") .. " online. "
		.. (#names > 0 and ("I can see: " .. table.concat(names, ", ")) or "Nobody on your friends list, guild or group is online.")
end

-- The send preview (the player, 2026-11-10). A dictated line with a channel
-- ("party, pulling now", "whisper Sage, on my way") no longer needs the chat box
-- at all: it shows here, and the Send button is a secure macro button whose
-- macro is the line itself, so the player's press is the send. Nothing of
-- Blizzard's is opened or touched, which is what broke A and B before. It opens
-- because the player just spoke a line meant to go out; nothing else opens it.
local CHANNEL_NAMES = {
	["/p"] = "party", ["/g"] = "guild", ["/o"] = "officer", ["/raid"] = "raid",
	["/rw"] = "raid warning", ["/i"] = "instance", ["/s"] = "say", ["/y"] = "yell",
	["/r"] = "your last whisper", ["/e"] = "emote",
	["/1"] = "General", ["/2"] = "Trade", ["/4"] = "Looking For Group",
}
local PREVIEW_CHAT_TYPES = {
	["/p"] = "PARTY", ["/g"] = "GUILD", ["/o"] = "OFFICER", ["/raid"] = "RAID",
	["/rw"] = "RAID_WARNING", ["/i"] = "INSTANCE_CHAT", ["/s"] = "SAY", ["/y"] = "YELL",
	["/e"] = "EMOTE", ["/w"] = "WHISPER", ["/r"] = "WHISPER",
	["/1"] = "CHANNEL1", ["/2"] = "CHANNEL2", ["/4"] = "CHANNEL4",
}
local preview
local function buildPreview()
	local made, frame = pcall(CreateFrame, "Frame", "WowCompanionPreview", UIParent, "BackdropTemplate")
	if not made or not frame then return nil end
	frame:SetSize(460, 150)
	frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 16, 260)
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)
	frame:Hide()
	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 22, -20)
	title:SetPoint("TOPRIGHT", -40, -20)
	title:SetJustifyH("LEFT")
	frame.title = title
	local body = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	body:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
	body:SetPoint("RIGHT", -22, 0)
	body:SetJustifyH("LEFT")
	body:SetJustifyV("TOP")
	body:SetMaxLines(4)
	frame.body = body

	local send = CreateFrame("Button", "WowCompanionPreviewSend", frame,
		"SecureActionButtonTemplate, UIPanelButtonTemplate")
	send:SetSize(130, 26)
	send:SetPoint("BOTTOMRIGHT", -22, 18)
	send:SetText("Send")
	send:SetAttribute("type", "macro")
	send:RegisterForClicks("AnyDown") -- the only edge that runs the macro once
	send:SetScript("PostClick", function()
		-- not "Sent": the press is all we know here. Macro chat is restricted only
		-- during instance encounters (ChatConstants, RestrictedForMacroChatMessages).
		-- A Battle.net whisper to an offline friend fails without a chat line, so
		-- that one is reported from BN_CHAT_WHISPER_UNDELIVERABLE below.
		toast("|cffffd100Pressed|r  check chat to see it went out", 0.8, 0.8, 0.8, 4)
		frame:Hide()
	end)
	frame.send = send

	-- the edit path is the voice: the preview cannot tell the PC anything, but
	-- the PC remembers the line it put here
	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("BOTTOMLEFT", 22, 22)
	hint:SetText("To change it: \"edit, ...\"")

	local cancel = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	cancel:SetSize(110, 26)
	cancel:SetPoint("RIGHT", send, "LEFT", -10, 0)
	cancel:SetText("Don't send")
	cancel:SetScript("OnClick", function() frame:Hide() end)

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)
	close:SetScript("OnClick", function() frame:Hide() end)
	-- circle closes a focused window by clicking this (SmartNavigation:AttemptClose)
	frame.CloseButton = close

	if SmartNavigation_MarkFrameFocusable then
		pcall(SmartNavigation_MarkFrameFocusable, frame)
		pcall(SmartNavigation_MarkFrameFocusable, send)
		pcall(SmartNavigation_MarkFrameFocusable, cancel)
	end
	if UIPanelWindows then
		UIPanelWindows["WowCompanionPreview"] = { area = "center", pushable = 0, whileDead = 1, allowOtherPanels = 1 }
	end
	frame:SetScript("OnHide", function(self)
		if GamepadMode and GamepadMode.FrameControlsManager
			and InputUtil and InputUtil.IsGamepadUIEnabled() then
			GamepadMode.FrameControlsManager:FrameHidden(self)
		end
	end)
	return frame
end

-- line is the full slash line ("/w Name text"); heading says where it goes
local function showPreview(line, heading, shown)
	if InCombatLockdown() then return false end -- a secure button cannot be set in combat
	preview = preview or buildPreview()
	if not preview then return false end
	preview.title:SetText(heading)
	preview.body:SetText(shown)
	-- in the channel's own chat colour, read from Blizzard's ChatTypeInfo (the
	-- player's colour settings), so guild is guild green, raid is raid orange
	local slash = line:match("^(/%w+)")
	local chatType = PREVIEW_CHAT_TYPES[slash]
	if slash == "/w" and line:find("|K", 1, true) then chatType = "BN_WHISPER" end
	local info = chatType and ChatTypeInfo and ChatTypeInfo[chatType]
	local r, g, b = 1, 1, 1
	if info and info.r then r, g, b = info.r, info.g, info.b end
	preview.title:SetTextColor(r, g, b)
	preview.body:SetTextColor(r, g, b)
	preview.send:SetAttribute("macrotext", line)
	if UIPanelWindows and UIPanelWindows["WowCompanionPreview"] then
		ShowUIPanel(preview)
	end
	if not preview:IsShown() then preview:Show() end
	return true
end
-- Blizzard's chat prints nothing when a Battle.net whisper cannot be delivered
-- (the friend is offline, or appearing offline), so say it ourselves
do
	local undeliverable = CreateFrame("Frame")
	undeliverable:RegisterEvent("BN_CHAT_WHISPER_UNDELIVERABLE")
	undeliverable:SetScript("OnEvent", function()
		toast("|cffff7777Battle.net could not deliver that whisper|r: they are offline, or appearing offline", 1, 0.6, 0.6, 10)
		remember("error", "Battle.net could not deliver that whisper: the friend is offline, or appearing offline.")
	end)
end

-- The item viewer (the player, 2026-11-10): an item someone linked, shown in a
-- window the controller can focus, closed with a button or circle, with
-- Previous / Next through the links remembered from chat (WowCompanionDB.links,
-- filled by the LinkCatcher module). The tooltip is our own GameTooltip, a
-- child of this window, so nothing of Blizzard's is shown or touched.
local viewer
local function buildViewer()
	local made, frame = pcall(CreateFrame, "Frame", "WowCompanionItemView", UIParent, "BackdropTemplate")
	if not made or not frame then return nil end
	frame:SetSize(340, 200)
	frame:SetPoint("CENTER", UIParent, "CENTER", 220, 60)
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)
	frame:Hide()
	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	local caption = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	caption:SetPoint("TOPLEFT", 20, -18)
	caption:SetPoint("TOPRIGHT", -36, -18)
	caption:SetJustifyH("LEFT")
	frame.caption = caption

	local tip = CreateFrame("GameTooltip", "WowCompanionItemViewTip", frame, "GameTooltipTemplate")
	frame.tip = tip

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)
	close:SetScript("OnClick", function() frame:Hide() end)
	frame.CloseButton = close -- circle clicks this (SmartNavigation:AttemptClose)

	local function button(label, width)
		local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		b:SetSize(width, 24)
		b:SetText(label)
		if SmartNavigation_MarkFrameFocusable then pcall(SmartNavigation_MarkFrameFocusable, b) end
		return b
	end
	frame.closeButton = button("Close", 90)
	frame.closeButton:SetPoint("BOTTOMRIGHT", -20, 16)
	frame.closeButton:SetScript("OnClick", function() frame:Hide() end)
	frame.nextButton = button("Older", 80)
	frame.nextButton:SetPoint("RIGHT", frame.closeButton, "LEFT", -8, 0)
	frame.nextButton:SetScript("OnClick", function() WowCompanion_ShowItem((frame.index or 1) + 1) end)
	frame.prevButton = button("Newer", 80)
	frame.prevButton:SetPoint("RIGHT", frame.nextButton, "LEFT", -8, 0)
	frame.prevButton:SetScript("OnClick", function() WowCompanion_ShowItem((frame.index or 1) - 1) end)

	if SmartNavigation_MarkFrameFocusable then pcall(SmartNavigation_MarkFrameFocusable, frame) end
	if UIPanelWindows then
		UIPanelWindows["WowCompanionItemView"] = { area = "center", pushable = 0, whileDead = 1, allowOtherPanels = 1 }
	end
	frame:SetScript("OnHide", function(self)
		self.tip:Hide()
		if GamepadMode and GamepadMode.FrameControlsManager
			and InputUtil and InputUtil.IsGamepadUIEnabled() then
			GamepadMode.FrameControlsManager:FrameHidden(self)
		end
	end)
	return frame
end

-- what: an index into the remembered links (1 = newest) or an item link
function WowCompanion_ShowItem(what)
	local links = WowCompanionDB.links or {}
	local index, entry
	if type(what) == "string" then
		entry = { link = what }
	else
		index = math.max(1, math.min(tonumber(what) or 1, #links))
		entry = links[index]
	end
	if not entry then
		remember("error", "No item link remembered yet: link one in chat, then ask again.")
		return false
	end
	viewer = viewer or buildViewer()
	if not viewer then return false end
	viewer.index = index
	viewer.caption:SetText(entry.from and ("Linked by %s in %s%s"):format(entry.from, entry.where or "chat",
		index and ("  (%d of %d)"):format(index, #links) or "") or "")
	viewer.prevButton:SetEnabled(index ~= nil and index > 1)
	viewer.nextButton:SetEnabled(index ~= nil and index < #links)
	local tip = viewer.tip
	tip:SetOwner(viewer, "ANCHOR_NONE")
	tip:ClearAllPoints()
	tip:SetPoint("TOPLEFT", viewer, "TOPLEFT", 14, -34)
	tip:SetHyperlink(entry.link)
	tip:Show()
	-- the window wraps the tooltip, with room for the caption and the buttons
	viewer:SetSize(math.max(300, tip:GetWidth() + 28), tip:GetHeight() + 34 + 52)
	if not InCombatLockdown() and UIPanelWindows and UIPanelWindows["WowCompanionItemView"] then
		ShowUIPanel(viewer)
	end
	if not viewer:IsShown() then viewer:Show() end
	return true
end

-- for agent code: show a line in the send preview (line, heading, shown text)
WowCompanion_Preview = showPreview

function handlers.chat(inbox)
	-- The controller's cancel unfocuses the box but keeps its text, and dictation
	-- appends, so a discarded line would come back glued to the next one. Clearing
	-- reaches the box whether or not it still has focus, and only sets its text:
	-- showing or hiding Blizzard's frame is what broke A and B.
	if inbox.clear then
		local box = activeEditBox() or LAST_ACTIVE_CHAT_EDIT_BOX or ChatFrame1EditBox
		if box and box.SetText then
			box:SetText("")
			return "chat box cleared"
		end
		return "refused: no chat box to clear"
	end
	-- a line spoken with a channel goes to the send preview, chat box or not
	do
		local text = inbox.text or ""
		local slash, rest = text:match("^(/%w+)%s+(.+)")
		if slash and inbox.raw and inbox.raw ~= text and not InCombatLockdown() then
			local line, heading, shown = text, "Send to " .. (CHANNEL_NAMES[slash] or slash), rest
			if slash == "/w" or slash == "/whisper" then
				local target, message, label = WowCompanion_ResolveWhisper(rest)
				if not target then
					remember("error", "Whisper not ready: " .. message .. ".")
					return "refused: " .. message
				end
				line, heading, shown = "/w " .. target .. " " .. message, "Whisper to " .. label, message
			end
			if #line <= 255 and showPreview(line, heading, shown) then
				return ("preview: %q"):format(line)
			end
		end
	end
	-- Any text box the player put the cursor in takes dictation: the auction
	-- house search, a mail recipient, a search field. They focused it, so setting
	-- its text is what typing would do, as with chat. Other boxes get the words
	-- as said; only chat gets them as a slash command ("guild bank" stays that in
	-- a search box, and becomes /g bank only in chat).
	local focused = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
	local chatBox = activeEditBox()
	if focused and focused ~= chatBox and focused.SetText and focused.GetText
		and focused.IsObjectType and focused:IsObjectType("EditBox") and focused:IsVisible() then
		focused:SetText((focused:GetText() or "") .. (inbox.raw or inbox.text or ""))
		return ("%s holds %q"):format(tostring(focused:GetName() or "a text box"), focused:GetText())
	end
	local box = chatBox
	if not box or not box:IsVisible() then
		-- in the window, where it is seen: opening the box ourselves is what broke
		-- A and B, so the player opens it and speaks again
		remember("error", "No text box open, so nothing was written. Open chat or click into a search box, then speak.")
		return "refused: no text box open"
	end
	-- append, so speaking twice builds a line instead of replacing it. Not echoed
	-- into the window: that is the conversation with the agent, and dictation is
	-- the player talking to other players
	local text = inbox.text or ""
	local rest = text:match("^/w%s+(.+)") or text:match("^/whisper%s+(.+)")
	if rest then
		local target, message, label = WowCompanion_ResolveWhisper(rest)
		if not target then
			remember("error", "Whisper not written: " .. message .. ".")
			return "refused: " .. message
		end
		text = "/w " .. target .. " " .. message
		toast("|cffffd100Whisper|r to " .. label .. ": press send when it reads right", 0.9, 0.9, 0.9, 8)
	end
	box:SetText((box:GetText() or "") .. text)
	if onDictated then
		onDictated(box)
	end
	return ("chat box holds %q"):format(box:GetText())
end

-- A line for the conversation window. Opens it out of combat so a reply is not
-- missed, but never steals the screen mid-fight.
function handlers.log(inbox)
	local text = inbox.text or ""
	local who = inbox.who or "claude"
	local lines = 0
	-- `pending` starts the waiting line; any message without it clears it, so the
	-- reply arriving is what stops the spinner
	-- the conversation a line belongs to; lines that name none (chat lines,
	-- notices) go to whichever is in view
	local islot = inbox.slot or viewSlot
	-- speaking into a conversation brings it up
	if who == "you" and islot ~= viewSlot then
		WowCompanion_SetConversation(islot)
	end
	-- `pending` starts this conversation's waiting line; a line without it ends it
	if inbox.slot or inbox.pending then setPending(inbox.pending, islot) end
	-- "got it, transcribing" has no conversation yet: whatever line comes next
	-- (the request in its slot, a chat line, a dropped-clip notice) ends it
	if islot ~= "" or not inbox.slot then
		local early = working[""]
		if early and early.text == "got it, transcribing" and not (inbox.slot == "" and inbox.pending) then
			setPending(nil, "")
		end
	end
	-- a reply arrives as one message but reads as many lines, and AddMessage takes
	-- one line at a time; blank lines are kept because they carry the paragraphs
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		remember(who, line, lines > 0, islot)
		lines = lines + 1
	end
	if lines == 0 then
		remember(who, text, nil, islot)
	end
	-- reveal, not Show: ShowUIPanel returns at once for a frame already shown, so a
	-- window opened by a plain Show never becomes a panel and the controller's
	-- window toggle cannot reach it until it is closed and opened again
	-- never opens the window: a reply's first line shows as a toast, errors in
	-- red, and step results and code output only go in the log
	if not (logWindow and logWindow:IsShown()) then
		local first = text:match("^%s*([^\n]+)") or ""
		first = first:gsub("%*%*", ""):gsub("`", "")
		if #first > 110 then first = first:sub(1, 107) .. "..." end
		if who == "claude" and first ~= "" then
			toast(("|cffffd100Claude|r  %s  |cff808080(minus to read)|r"):format(first), 0.9, 0.9, 0.9, 10)
		elseif who == "error" then
			toast("|cffff7777" .. first .. "|r", 1, 0.5, 0.5, 10)
		end
	end
	return ("logged %d line(s)"):format(lines)
end

-- A tap of the ask button (minus) opens the window, as a panel so the
-- controller's focus cycle reaches it. In combat it is a plain Show (see reveal).
-- The game hears the minus button itself (the DualSense Create button is
-- PADSOCIAL), so a tap toggles the window at once instead of waiting a second for
-- the helper's message. Holding minus is still push-to-talk on the PC, so only a
-- short press toggles: down and up are timed, and a hold does nothing here.
-- Override bindings are an addon's own layer and only while it is loaded, so the
-- player's binding underneath is untouched.
local TAP_MAX = 0.35
local nativeToggleAt = 0
local function toggleWindow()
	local frame = logFrame()
	if frame:IsShown() then
		frame:Hide() -- plain Hide; see the /wc log note on HideUIPanel
	else
		reveal(frame)
	end
end
local tapButton = CreateFrame("Button", "WowCompanionTap", UIParent)
tapButton:RegisterForClicks("AnyDown", "AnyUp")
tapButton:SetScript("OnClick", function(self, _, down)
	if down then
		self.downAt = GetTime()
	elseif self.downAt and GetTime() - self.downAt <= TAP_MAX then
		self.downAt = nil
		nativeToggleAt = GetTime()
		toggleWindow()
	else
		self.downAt = nil
	end
end)
local function bindTap()
	if InCombatLockdown() or not SetOverrideBindingClick then return end
	ClearOverrideBindings(tapButton)
	SetOverrideBindingClick(tapButton, false, "PADSOCIAL", "WowCompanionTap", "LeftButton")
end

-- The helper's own tap message, about a second later: ignored when the game
-- already handled that tap, or it would undo the toggle.
function handlers.show()
	if GetTime() - nativeToggleAt < 4 then
		return "already toggled in game"
	end
	reveal(logFrame())
	return "shown"
end

-- What the agent is doing right now, on the waiting line: "reading StanceBar.lua".
-- Not logged; the reply is what stays.
function handlers.progress(inbox)
	setPending(inbox.text or "thinking", inbox.slot)
	return "progress"
end

function handlers.macro(inbox)
	if InCombatLockdown() then
		return "refused: in combat"
	end
	if not inbox.name then
		return "refused: no macro name"
	end
	local index = GetMacroIndexByName(inbox.name)
	if index and index > 0 then
		EditMacro(index, inbox.name, inbox.icon, inbox.body)
		return ("edited macro %s at %d"):format(inbox.name, index)
	end
	index = CreateMacro(inbox.name, inbox.icon or "INV_MISC_QUESTIONMARK", inbox.body, false)
	-- deliberately not placed on a bar: PlaceAction taints the UI, so bar edits are
	-- their own operation followed by a reload
	return index and ("created macro %s at %d"):format(inbox.name, index) or "CreateMacro failed"
end

-- Probing for a game -> PC channel that is not the pixel strip we ruled out.
--
-- `LoggingChat(true)` makes the client write chat to Logs\WoWChatLog.txt, a plain
-- text file the helper can tail. The open question is what counts as chat: the log
-- may capture only server CHAT_MSG_* events, in which case an addon's own print
-- never appears and this whole idea is dead. So emit the marker three ways and let
-- the helper report which, if any, reached disk.
function handlers.bridge(inbox)
	local running, failed = pcall(LoggingChat, true)
	if not running then
		return "LoggingChat failed: " .. tostring(failed)
	end
	local nonce = tostring(inbox.nonce or "?")
	print(("WCBRIDGE-print %s"):format(nonce))
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage(("WCBRIDGE-frame %s"):format(nonce))
	end
	-- There was a self-whisper here, addressed by UnitName("player"). Names on this
	-- client are first and last ("Pietra Fayth"); UnitName gives only the first,
	-- and the server answered "No player named Pietra is currently playing".
	-- Addressing a player needs the full name in a form not yet measured
	-- (C_NameUtil mentions a surname separator), so the whisper is gone.
	return ("logging on: %s, marked %s"):format(tostring(LoggingChat()), nonce)
end

-- A reload clears taint, flushes SavedVariables and resets the slot cursor. We
-- cannot do it ourselves: ReloadUI wraps a protected call, and asking from insecure
-- code comes back as "WowCompanion called Reload()".
--
-- A real button press is a hardware event, and that is the one path the client
-- trusts. So build a secure button on the fly, point it at a macro, and let the
-- player press it: the click runs through the secure path, taints nothing, and is
-- never blocked. Anything expressible as a macro can go through here.
function handlers.reload()
	return offer("Reload UI", "/reload")
end

-- Whatever the helper asks for, as a button the player presses. The macro text is
-- the limit of what this can do, which is also the limit of what the player could
-- type themselves -- so it grants no power they did not already have.
function handlers.press(inbox)
	return offer(inbox.label or "Do it", inbox.macro or "")
end

function handlers.probe(inbox)
	WowCompanionDB.probe.received = (WowCompanionDB.probe.received or 0) + 1
	return ("message %d, %ds after the helper wrote it"):format(inbox.n, time() - inbox.sent)
end

-- What a step did, in the window, so a refusal ("in combat", "no macro named")
-- is seen rather than silently dropped. Only kinds whose result is news: chat,
-- lua and press already show themselves.
local REPORTED = { bar = true, macro = true, module = true }
local function report(step, ok, outcome)
	if not ok then
		remember("error", ("%s failed: %s"):format(tostring(step.kind), tostring(outcome)))
	elseif REPORTED[step.kind] and type(outcome) == "string" then
		remember(outcome:find("^refused") and "error" or "game", outcome)
	end
end

-- Several steps from one answer, in order, each reported. One failing does not
-- stop the rest: they were asked for together, but each stands on its own, and
-- the report says which landed.
function handlers.batch(inbox)
	for _, step in ipairs(inbox.steps or {}) do
		local handler = handlers[step.kind or ""]
		if not handler or step.kind == "batch" then
			report(step, false, "unknown kind")
		else
			report(step, pcall(handler, step))
		end
	end
end

local function receive()
	local slot = nextSlot
	nextSlot = nextSlot + 1
	local loaded, reason = C_AddOns.LoadAddOn(slotName(slot))
	local inbox = WowCompanion_Inbox
	WowCompanion_Inbox = nil
	if not loaded or not inbox then
		record("slot " .. slot, "failed: " .. tostring(reason))
		return
	end
	local handler = handlers[inbox.kind or ""]
	if not handler then
		record("slot " .. slot, "unknown kind: " .. tostring(inbox.kind))
		return
	end
	local ok, result = pcall(handler, inbox)
	-- only probe traffic is worth narrating in chat; the window is where the rest goes
	if inbox.kind == "probe" or not ok then
		record("slot " .. slot, ok and tostring(result) or ("error: " .. tostring(result)))
	end
	-- A reply and the action it describes are one thought, so they ride in one
	-- message: two sends would mean two bells and two seconds of waiting between
	-- reading the answer and being offered the button.
	local following = inbox.andThen
	if following and handlers[following.kind or ""] then
		local done, outcome = pcall(handlers[following.kind], following)
		if not done then
			record("slot " .. slot .. " follow-up", "error: " .. tostring(outcome))
		end
		report(following, done, outcome)
	end
end

-- An error anywhere in polling or handling a message is caught, said once in the
-- window, and polling goes on. Unguarded, one error could stop the companion
-- hearing anything until a /reload, which is what "the communication layer is
-- broken again" looked like from the player's side.
local reportedFailures = {}
local function safely(label, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		local key = label .. tostring(err)
		if not reportedFailures[key] then
			reportedFailures[key] = true
			pcall(remember, "error", ("%s failed: %s"):format(label, tostring(err)))
		end
	end
end


-- What the poll has seen, exported at every reload, so a stuck channel can be
-- read from the save file instead of guessed at.
local channel = { polls = 0, heard = 0, caughtUp = 0 }

-- Each message's bell rings for about two seconds. Missing that window once (a
-- hitch, a locked file) used to leave the addon waiting on that slot forever
-- while the companion moved on to the next ones: every later message lost until
-- a reload, which is what "broken again" was. So the next slot's bell is checked
-- too: if it rings, the missed slot (still on disk, never loaded) is taken first,
-- then this one. Late and in order, never lost.
local function poll()
	channel.polls = channel.polls + 1
	channel.lastPoll = time()
	channel.waitingOn = nextSlot
	local waiting = nextSlot
	safely("bell poll", listen, bellPath(waiting), function(rang)
		if rang and nextSlot == waiting then
			channel.heard = channel.heard + 1
			safely("a message from the companion", receive)
		end
	end)
	safely("bell poll ahead", listen, bellPath(waiting + 1), function(rang)
		if rang and nextSlot == waiting then
			channel.caughtUp = channel.caughtUp + 1
			channel.lastCaughtUp = ("slot %d missed, taken late at %s"):format(waiting, date("%H:%M:%S"))
			safely("a missed message from the companion", receive)
			safely("a message from the companion", receive)
		end
	end)
end

-- Polled from OnUpdate, which WoW keeps calling whatever happened the frame
-- before, rather than a C_Timer ticker, which a callback error may cancel for
-- good. `ticker` keeps its shape (truthy while polling, :Cancel() to stop) so
-- /wc quiet and /wc listen are unchanged.
local pollFrame = CreateFrame("Frame")
local sincePoll = 0
local function startPolling()
	sincePoll = 0
	pollFrame:SetScript("OnUpdate", function(_, elapsed)
		sincePoll = sincePoll + elapsed
		if sincePoll >= 0.5 then
			sincePoll = 0
			poll()
		end
	end)
	return {
		Cancel = function()
			pollFrame:SetScript("OnUpdate", nil)
		end,
	}
end

local function cvar(name)
	local get = C_CVar and C_CVar.GetCVar or GetCVar
	return get and get(name) or "?"
end

-- controls: a long silent file should play, an empty one shouldn't.
-- an unfocused game mutes everything, so both come back false if you alt-tabbed away;
-- the cvars tell that case apart from a bell that genuinely didn't play
local function probeSound()
	record("sound enabled", cvar("Sound_EnableAllSound"))
	record("background sound", cvar("Sound_EnableSoundWhenGameIsInBG"))
	record("master volume", cvar("Sound_MasterVolume"))
	listen(SIGNALS .. "always.wav", function(playing)
		record("always.wav plays (want true)", playing)
	end)
	listen(SIGNALS .. "never.wav", function(playing)
		record("never.wav plays (want false)", playing)
	end)
end

-- What the gamepad UI gives us to work with. Controller focus matters well beyond
-- one button, and the client's own Lua is not on disk to read, so ask the client.
local function probeGamepad()
	for _, name in ipairs({
		"C_GamePad",
		"SmartNavigation",
		"GamePadSmartNavigation",
		"UIPanelWindows",
		"SetOverrideBinding",
		"GetBindingKey",
		"C_GamePad.GetActiveDeviceID",
		"C_GamePad.GetDeviceMappedState",
		"C_GamePad.SetVibration",
		"SmartNavigationFrameMixin",
		"GamePadCursorMixin",
	}) do
		local holder, member = name:match("^(%w+)%.(%w+)$")
		local found
		if holder then
			local parent = _G[holder]
			found = type(parent) == "table" and parent[member] ~= nil
		else
			found = _G[name] ~= nil
		end
		record("has " .. name, found and "yes" or "no")
	end
	record("interface style", cvar("InputDeviceInterfaceStyle"))

	-- SmartNavigation exists; find out whether it will let us register a frame
	if type(SmartNavigation) == "table" then
		local members = {}
		for key, value in pairs(SmartNavigation) do
			members[#members + 1] = ("%s(%s)"):format(tostring(key), type(value))
		end
		table.sort(members)
		record("SmartNavigation members", table.concat(members, " "))
	end

	-- which pad key names this build will actually accept for an override binding
	local usable = {}
	if SetOverrideBindingClick and actionButton then
		for _, key in ipairs({
			"PAD1", "PAD2", "PAD3", "PAD4",
			"PADDUP", "PADDDOWN", "PADDLEFT", "PADDRIGHT",
			"PADLSHOULDER", "PADRSHOULDER", "PADLSTICK", "PADRSTICK",
			"PADFORWARD", "PADBACK", "PADSYSTEM", "PADSOCIAL",
		}) do
			local ok = pcall(SetOverrideBindingClick, actionButton, true, key, "WowCompanionDo")
			if ok and GetBindingByKey and GetBindingByKey(key) then
				usable[#usable + 1] = key
			elseif ok then
				usable[#usable + 1] = key .. "?"
			end
		end
		ClearOverrideBindings(actionButton)
	end
	record("pad keys accepted", #usable > 0 and table.concat(usable, " ") or "none")

	-- 1.60.1's SmartNavigation_* globals are the documented way in. Mark the window,
	-- then ask whether it took: the API can answer for itself, so there is no need
	-- to infer it from whether the cursor happens to land.
	local frame = logFrame()
	if SmartNavigation_MarkFrameFocusable then
		pcall(SmartNavigation_MarkFrameFocusable, frame)
	end
	for _, check in ipairs({ "SmartNavigation_IsFrameFocusable", "SmartNavigation_CanFocusFrame" }) do
		local probe = _G[check]
		if probe then
			local ok, answer = pcall(probe, frame)
			record(check, ok and tostring(answer) or "errored")
		else
			record(check, "missing")
		end
	end
	if actionButton and SmartNavigation_IsFrameFocusable then
		local ok, answer = pcall(SmartNavigation_IsFrameFocusable, actionButton)
		record("button focusable", ok and tostring(answer) or "errored")
	end
end

-- Can the client tell us its own API? That would beat any external reference, which
-- is written about WoW in general while this is one specific build -- and version
-- drift is exactly what has caught us out repeatedly.
local function probeApi()
	for _, name in ipairs({
		"APIDocumentation",
		"C_ApiDocumentation",
		"GetAPIDocumentation",
		"APIDocumentationMixin",
		"ApiDocumentation",
	}) do
		record("has " .. name, _G[name] ~= nil and type(_G[name]) or "no")
	end

	-- failing that, the globals themselves are a complete list of what exists
	local functions, namespaces, members = 0, 0, 0
	local biggest, biggestCount = "none", 0
	for key, value in pairs(_G) do
		if type(value) == "function" then
			functions = functions + 1
		elseif type(value) == "table" and type(key) == "string" and key:match("^C_%w+$") then
			namespaces = namespaces + 1
			local count = 0
			for _, member in pairs(value) do
				if type(member) == "function" then
					count = count + 1
				end
			end
			members = members + count
			if count > biggestCount then
				biggest, biggestCount = key, count
			end
		end
	end
	record("global functions", functions)
	record("C_ namespaces", namespaces)
	record("C_ functions", members)
	record("largest namespace", ("%s (%d)"):format(biggest, biggestCount))
end

-- Everything this build can call, as one string.
--
-- The client ships no API documentation tables, so signatures are not available
-- locally -- but the *names* are, exhaustively and exactly for this build. That is
-- the half that matters: the agent's failure mode is not forgetting what a function
-- does, it is confidently calling something that exists in retail and not here.
--
-- One string rather than a nested table because the helper has to parse this back
-- out of SavedVariables without a Lua parser.
local function dumpApi()
	local lines, namespaces = {}, 0
	for key, value in pairs(_G) do
		if type(key) == "string" then
			if type(value) == "function" then
				lines[#lines + 1] = key
			elseif type(value) == "table" and key:match("^C_%w+$") then
				namespaces = namespaces + 1
				for name, member in pairs(value) do
					if type(member) == "function" and type(name) == "string" then
						lines[#lines + 1] = key .. "." .. name
					end
				end
			end
		end
	end
	table.sort(lines)
	local version, build = GetBuildInfo()
	-- built with an explicit newline rather than an escape: the escapes in this file
	-- have been through a shell and a script, and one of them arrived as a literal
	-- line break inside a string literal
	local newline = string.char(10)
	WowCompanionDB.api = ("-- World of Warcraft %s build %s%s%s%s"):format(
		tostring(version), tostring(build), newline, table.concat(lines, newline), newline)
	say(("dumped %d names across %d namespaces; /reload to write it to disk")
		:format(#lines, namespaces))
end

-- Signatures, if the client will give them up. The name index came from _G, but
-- retail keeps documentation in a load-on-demand Blizzard addon, and this build has
-- APIDocumentation_LoadUI -- so the table may only be absent because nothing has
-- loaded it yet. Kept separate from dumpApi so a failure here costs nothing.
-- the fields every function entry has; anything else is a flag worth keeping, and
-- the flags are where the documentation says what is restricted
local SHAPE = { Name = true, Type = true, Arguments = true, Returns = true,
	Documentation = true, System = true }

local function describe(fields)
	local parts = {}
	for _, field in ipairs(fields or {}) do
		parts[#parts + 1] = ("%s: %s%s"):format(
			tostring(field.Name), tostring(field.Type), field.Nilable and "?" or "")
	end
	return table.concat(parts, ", ")
end

local function loadDocs()
	if not APIDocumentation then
		for _, loader in ipairs({
			function() APIDocumentation_LoadUI() end,
			function() C_AddOns.LoadAddOn("Blizzard_APIDocumentationGenerated") end,
			function() C_AddOns.LoadAddOn("Blizzard_APIDocumentation") end,
		}) do
			pcall(loader)
			if APIDocumentation then
				break
			end
		end
	end
	if type(APIDocumentation) ~= "table" or type(APIDocumentation.systems) ~= "table" then
		record("api docs", "unavailable: APIDocumentation " .. type(APIDocumentation))
		return false
	end
	return true
end

local function dumpDocs()
	if not loadDocs() then
		return
	end
	local newline = string.char(10)
	local lines, systems = {}, 0
	for _, system in ipairs(APIDocumentation.systems) do
		systems = systems + 1
		local prefix = system.Namespace and (system.Namespace .. ".") or ""
		for _, fn in ipairs(system.Functions or {}) do
			local returns = describe(fn.Returns)
			local flags = {}
			for key, value in pairs(fn) do
				if not SHAPE[key] and type(value) ~= "table" and type(value) ~= "function" then
					flags[#flags + 1] = ("%s=%s"):format(tostring(key), tostring(value))
				end
			end
			table.sort(flags)
			lines[#lines + 1] = ("%s%s(%s)%s%s"):format(prefix, tostring(fn.Name),
				describe(fn.Arguments), returns ~= "" and (" -> " .. returns) or "",
				#flags > 0 and (" [" .. table.concat(flags, " ") .. "]") or "")
		end
		for _, event in ipairs(system.Events or {}) do
			lines[#lines + 1] = ("event %s(%s)"):format(
				tostring(event.LiteralName or event.Name), describe(event.Payload))
		end
		-- the signatures are only half an answer without these: a function that
		-- returns SpellBookItemInfo tells you nothing about what to read off it,
		-- and an argument typed SpellBookSpellBank tells you nothing about what to
		-- pass. Enumerations carry their values, so this is also where the magic
		-- numbers stop being magic.
		for _, entry in ipairs(system.Tables or {}) do
			local kind = tostring(entry.Type)
			if kind == "Enumeration" or kind == "Constants" then
				local values = {}
				for _, value in ipairs(entry.Values or entry.Fields or {}) do
					values[#values + 1] = ("%s = %s"):format(
						tostring(value.Name),
						tostring(value.EnumValue ~= nil and value.EnumValue or value.Value))
				end
				lines[#lines + 1] = ("%s %s { %s }"):format(
					kind == "Enumeration" and "enum" or "constants",
					tostring(entry.Name), table.concat(values, ", "))
			else
				lines[#lines + 1] = ("struct %s { %s }"):format(
					tostring(entry.Name), describe(entry.Fields))
			end
		end
	end
	table.sort(lines)
	WowCompanionDB.apidocs = table.concat(lines, newline) .. newline
	record("api docs", ("%d entries from %d systems; /reload to write"):format(#lines, systems))
end

-- Which documented functions actually answer on this client.
--
-- Documented is not working: Forever carries retail's namespaces, and a function can
-- exist, be documented, and return nothing. Calling it is the only test, and calling
-- blind is only safe for one kind -- a read that needs no arguments. So: every
-- documented function whose name starts Get/Is/Has/Can/Should/Are/Does and whose
-- arguments are all optional is called once, under pcall, and sorted by what came
-- back. Anything that changes state is left alone; those need a test of their own.
--
-- Batched across frames so a few thousand calls do not hitch the game.
--
-- The first version called every such read in the client, and one of them crashed
-- it outright: ACCESS_VIOLATION reading address 0 inside Wow.exe, from a plain pcall
-- -- pcall catches Lua errors, not a C null dereference. Seven others were refused
-- as ADDON_ACTION_FORBIDDEN. The crash report named only "call 58 of a batch". So:
-- only the namespaces this project would use, nothing the docs flag as restricted,
-- and the name of each function in a plain local while it runs, because the crash
-- report prints the locals of the Lua frame that was executing.
-- "%u" after the verb: "^Can" alone matched CancelEmote, which is not a read
local READS = { "^Get%u", "^Is%u", "^Has%u", "^Can%u", "^Should%u", "^Are%u", "^Does%u" }
local SURVEYED = {
	C_ActionBar = true, C_Macro = true, C_Spell = true, C_SpellBook = true,
	C_ClassTalents = true, C_Traits = true, C_SpecializationInfo = true,
	C_EquipmentSet = true, C_CVar = true, C_KeyBindings = true, C_ChatInfo = true,
	C_GamePad = true, C_Container = true, C_Item = true, C_PlayerInfo = true,
	C_UnitAuras = true, C_PetInfo = true, C_MountJournal = true, C_ToyBox = true,
}

local function verdict(ok, ...)
	if not ok then
		return "error"
	end
	local count = select("#", ...)
	if count == 0 then
		return "nothing"
	end
	local first = ...
	if first == nil then
		return "nil"
	elseif type(first) == "table" then
		return next(first) == nil and "empty" or "value"
	elseif first == 0 or first == false or first == "" then
		return "zero"
	end
	return "value"
end

local function surveyApi()
	if InCombatLockdown() then
		say("leave combat first")
		return
	end
	if not loadDocs() then
		return
	end
	local queue = {}
	for _, system in ipairs(APIDocumentation.systems) do
		-- widget methods (frame:Show and friends) need an object; only namespaces
		-- and plain globals can be called bare
		local owner = system.Namespace and SURVEYED[system.Namespace] and _G[system.Namespace] or nil
		for _, fn in ipairs(system.Functions or {}) do
			local name = tostring(fn.Name)
			local read = false
			for _, pattern in ipairs(READS) do
				read = read or name:find(pattern) ~= nil
			end
			local optional = true
			for _, arg in ipairs(fn.Arguments or {}) do
				optional = optional and (arg.Nilable or arg.Default ~= nil)
			end
			if read and optional and owner and not fn.HasRestrictions then
				queue[#queue + 1] = {
					label = (system.Namespace and (system.Namespace .. ".") or "") .. name,
					owner = owner,
					name = name,
				}
			end
		end
	end
	local results, tally, at = {}, {}, 0
	local function batch()
		for _ = 1, 150 do
			at = at + 1
			local job = queue[at]
			if not job then
				table.sort(results)
				local summary = {}
				for kind, count in pairs(tally) do
					summary[#summary + 1] = ("%s %d"):format(kind, count)
				end
				table.sort(summary)
				local newline = string.char(10)
				WowCompanionDB.alive = ("-- %d no-argument reads called: %s"):format(#queue,
					table.concat(summary, ", ")) .. newline .. table.concat(results, newline) .. newline
				record("api survey", table.concat(summary, ", ") .. "; /reload to write")
				return
			end
			local kind
			local fn = type(job.owner) == "table" and rawget(job.owner, job.name)
			-- read by the crash reporter, not by us: see the note above
			local survey_calling = job.label
			if type(fn) ~= "function" then
				kind = "absent"
			else
				local refusedBefore = blocked
				kind = verdict(pcall(fn))
				if blocked ~= refusedBefore then
					kind = "forbidden"
				end
			end
			survey_calling = nil
			tally[kind] = (tally[kind] or 0) + 1
			results[#results + 1] = ("%s %s"):format(kind, job.label)
		end
		C_Timer.After(0, batch)
	end
	say(("calling %d documented no-argument reads..."):format(#queue))
	batch()
end

-- Name lookups, asked rather than assumed.
--
-- This client is 1.60.1: not retail, and not any Classic we have a reference for.
-- GetSpellInfo has been removed, restored and reshaped across builds, so which of
-- these exists -- and whether it returns a string or a table -- is a runtime
-- question. Each is tried in turn and the first that answers wins.
local function spellName(id)
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, id)
		if ok and type(info) == "table" and info.name then
			return info.name
		end
	end
	if GetSpellInfo then
		local ok, name = pcall(GetSpellInfo, id)
		if ok then
			if type(name) == "table" then
				return name.name
			elseif type(name) == "string" then
				return name
			end
		end
	end
	return nil
end

-- Written as two ifs rather than a loop over { C_Item and ..., GetItemInfo }:
-- ipairs stops at the first nil, so if the namespaced form were missing the loop
-- would never reach the global one. That exact hole cost us an afternoon already.
local function itemName(id)
	if C_Item and C_Item.GetItemInfo then
		local ok, name = pcall(C_Item.GetItemInfo, id)
		if ok and type(name) == "string" then
			return name
		end
	end
	if GetItemInfo then
		local ok, name = pcall(GetItemInfo, id)
		if ok and type(name) == "string" then
			return name
		end
	end
	return nil
end

-- The action slot space is not 1..120 on this client. The classic bars use the
-- low numbers, but the gamepad UI draws 181..272 (top 181-184, left 185-192, right
-- 193-200, bottom 201-208, stance 265-272) and the extra action button sits at 397.
-- Measured from the live UI. Scan well past that; an invalid slot just errors.
local LAST_ACTION_SLOT = 1024

local function slotHas(slot)
	local ok, has = pcall(HasAction, slot)
	return ok and has
end

-- "GamepadMainActionBarFramePageUnitLeftCenteredAnchorLeftBarActionButton3" -> "LeftBar 3"
local function barLabel(name)
	return (tostring(name):gsub("^GamepadMainActionBarFramePageUnit", "")
		:gsub("^%a-CenteredAnchor", ""):gsub("ActionButton(%d+)$", " %1"))
end

-- Which chord fires which button.
--
-- Not in the bindings: GetBindingKey("ACTIONBUTTON189") is empty for every gamepad
-- button, and no frame field names the trigger. What is measurable is each button's
-- icon -- its SlotArt atlas names the base input, the same eight on every bar
-- (1-4 the d-pad left, up, right, down; 5-8 the face buttons) -- and, by watching,
-- which modifiers are held when a button goes into its pushed state. So the base
-- comes from the art and the modifier is learned from play, keyed by bar position
-- rather than slot, because druid forms page the slots under the same buttons.
local GAMEPAD_BARS = {
	{ "TopCenteredAnchorTopBar", 4 },
	{ "LeftCenteredAnchorLeftBar", 8 },
	{ "RightCenteredAnchorRightBar", 8 },
	{ "BottomCenteredAnchorBottomBar", 8 },
	{ "TopCenteredAnchorStanceBar", 8 },
}
local ART_INPUT = {
	dpadleft = "left", dpadup = "up", dpadright = "right", dpaddown = "down",
	["ps%-square"] = "square", ["ps%-triangle"] = "triangle",
	["ps%-circle"] = "circle", ["ps%-cross"] = "cross",
}

-- { frame, label = "LeftBar 3", bar = "LeftBar", base = "right" } for each button
local padButtons
local function gamepadButtons()
	if padButtons then
		return padButtons
	end
	padButtons = {}
	for _, bar in ipairs(GAMEPAD_BARS) do
		for i = 1, bar[2] do
			local name = "GamepadMainActionBarFramePageUnit" .. bar[1] .. "ActionButton" .. i
			local button = _G[name]
			if button then
				local art = button.SlotArt and button.SlotArt.GetAtlas and button.SlotArt:GetAtlas() or ""
				local base
				for pattern, input in pairs(ART_INPUT) do
					if art:find(pattern) then
						base = input
					end
				end
				local label = barLabel(name)
				padButtons[#padButtons + 1] = {
					frame = button, label = label, bar = label:gsub(" %d+$", ""), base = base,
				}
			end
		end
	end
	return padButtons
end

-- The pad as the client maps it: modifiers held (triggers, shoulders, sticks,
-- sorted) and the d-pad and face buttons held. nil when there is no pad to read.
local function padState()
	if not (C_GamePad and C_GamePad.GetDeviceMappedState and C_GamePad.ButtonIndexToBinding) then
		return nil
	end
	local ok, state = pcall(C_GamePad.GetDeviceMappedState)
	if not ok or type(state) ~= "table" or type(state.buttons) ~= "table" then
		return nil
	end
	local modifiers, bases = {}, {}
	for index, down in pairs(state.buttons) do
		if down then
			-- state.buttons is a Lua array, from 1; ButtonIndexToBinding counts from 0.
			-- Measured: without the -1, L2 read as R2 and R2 as PADLSTICKUP.
			local name = C_GamePad.ButtonIndexToBinding(index - 1)
			if name then
				if name:find("^PADD") or name:find("^PAD%d") then
					bases[name] = true
				else
					modifiers[#modifiers + 1] = name
				end
			end
		end
	end
	table.sort(modifiers)
	return modifiers, bases
end

-- WowCompanionDB.chords[bar] = { [modifier] = presses }. chordStats counts every
-- d-pad or face press and how many lit an action button within a few frames: if
-- "lit" stays at zero, the pushed state is the wrong signal, and the export says so
-- instead of quietly learning nothing.
local CHORD_WINDOW = 0.25

-- The first learner read every button one place off (see padState). Its record is
-- still good once renamed: what it called R2 was L2, and PADLSTICKUP was R2.
local function fixFirstChords()
	if not WowCompanionDB.chords or WowCompanionDB.chordsFixed then
		WowCompanionDB.chordsFixed = true
		return
	end
	local renamed = { PADRTRIGGER = "PADLTRIGGER", PADLSTICKUP = "PADRTRIGGER" }
	for bar, seen in pairs(WowCompanionDB.chords) do
		local fixed = {}
		for chord, count in pairs(seen) do
			local parts = {}
			for part in chord:gmatch("[^+]+") do
				parts[#parts + 1] = renamed[part] or part
			end
			table.sort(parts)
			local key = table.concat(parts, "+")
			fixed[key] = (fixed[key] or 0) + count
		end
		WowCompanionDB.chords[bar] = fixed
	end
	WowCompanionDB.chordsFixed = true
end

-- every pushed button the UI has, by name: what lit when none of ours did
local function pushedElsewhere()
	local found = {}
	local frame, walked = EnumerateFrames(), 0
	while frame and walked < 50000 and #found < 4 do
		walked = walked + 1
		if frame.GetButtonState then
			local ok, state = pcall(frame.GetButtonState, frame)
			if ok and state == "PUSHED" then
				local named = frame.GetName and frame:GetName()
				found[#found + 1] = ("%s (action %s)"):format(tostring(named or frame:GetDebugName()), tostring(frame.action))
			end
		end
		frame = EnumerateFrames(frame)
	end
	return #found > 0 and table.concat(found, ", ") or "nothing pushed"
end

-- the presses that taught nothing, newest last, so the next reload shows why
local function missedChord(press)
	-- a face button alone is jump or interact, never a bar; twenty jumps would
	-- push out the one miss worth reading
	if press.chord == "none" and tostring(press.base):find("^PAD%d") then
		return
	end
	WowCompanionDB.chordMisses = WowCompanionDB.chordMisses or {}
	local misses = WowCompanionDB.chordMisses
	local form = GetShapeshiftForm and GetShapeshiftForm() or "?"
	misses[#misses + 1] = ("%s + %s, form %s, page %s: %s"):format(press.chord, press.base,
		tostring(form), tostring(C_ActionBar and C_ActionBar.GetActionBarPage and C_ActionBar.GetActionBarPage()),
		press.scanned or "not scanned")
	while #misses > 20 do
		table.remove(misses, 1)
	end
end

local function learnChords()
	fixFirstChords()
	local watcher = CreateFrame("Frame")
	local was, wasBase = {}, {}
	local pending -- the modifiers of the last base press, until a button lights or it expires
	watcher:SetScript("OnUpdate", function()
		local modifiers, bases = padState()
		if not modifiers then
			return
		end
		WowCompanionDB.chordStats = WowCompanionDB.chordStats or { presses = 0, lit = 0 }
		local stats = WowCompanionDB.chordStats
		for name in pairs(bases) do
			if not wasBase[name] then
				stats.presses = stats.presses + 1
				pending = {
					chord = #modifiers > 0 and table.concat(modifiers, "+") or "none",
					base = name, at = GetTime(), frames = 0,
				}
			end
		end
		wasBase = bases
		if pending then
			pending.frames = pending.frames + 1
			-- two frames and none of our buttons lit: look at everything once, while
			-- whatever did light is still held down
			-- (13,000 frames is a visible hitch; never in combat, and a jump is a miss too)
			if pending.frames == 3 and not pending.scanned and not InCombatLockdown() then
				pending.scanned = pushedElsewhere()
			end
			if GetTime() - pending.at > CHORD_WINDOW then
				missedChord(pending)
				pending = nil
			end
		end
		for _, entry in ipairs(gamepadButtons()) do
			local ok, state = pcall(entry.frame.GetButtonState, entry.frame)
			local pushed = ok and state == "PUSHED"
			if pushed and not was[entry.label] and pending then
				stats.lit = stats.lit + 1
				WowCompanionDB.chords = WowCompanionDB.chords or {}
				local bar = WowCompanionDB.chords[entry.bar] or {}
				bar[pending.chord] = (bar[pending.chord] or 0) + 1
				WowCompanionDB.chords[entry.bar] = bar
				pending = nil
			end
			was[entry.label] = pushed
		end
	end)
end

-- "L2+R2" from "PADLTRIGGER+PADRTRIGGER": the words the player says
local PAD_WORDS = {
	PADLTRIGGER = "L2", PADRTRIGGER = "R2", PADLSHOULDER = "L1", PADRSHOULDER = "R1",
	PADLSTICK = "L3", PADRSTICK = "R3",
}
local function spoken(chord)
	if chord == "none" then
		return "no modifier"
	end
	return (chord:gsub("PAD%u+", function(name) return PAD_WORDS[name] or name end))
end

-- bar -> modifier words, from the most-seen chord, or nil while none is learned
local function barModifier(bar)
	local seen = WowCompanionDB.chords and WowCompanionDB.chords[bar]
	if not seen then
		return nil
	end
	local best, most = nil, 0
	for chord, count in pairs(seen) do
		if count > most then
			best, most = chord, count
		end
	end
	return best and spoken(best), most
end

-- "L2+R2 + right", or "? + right" while the bar's modifier is unlearned
local function chordFor(label)
	for _, entry in ipairs(gamepadButtons()) do
		if entry.label == label then
			local modifier = barModifier(entry.bar)
			if modifier == "no modifier" then
				return entry.base or "?"
			end
			return ("%s + %s"):format(modifier or "?", entry.base or "?")
		end
	end
	return nil
end

-- slot -> { visible = bool, label = "LeftBar 3" } for every slot some frame draws.
-- The label is the first visible frame's, since several frames (edit mode, the
-- hidden classic bars) can point at the same slot.
local function actionFrames()
	local slots = {}
	if not EnumerateFrames then
		return slots
	end
	local frame, walked = EnumerateFrames(), 0
	while frame and walked < 50000 do
		walked = walked + 1
		local slot = type(frame.action) == "number" and frame.action or nil
		if not slot and frame.GetAttribute then
			local ok, value = pcall(frame.GetAttribute, frame, "action")
			if ok and type(value) == "number" then
				slot = value
			end
		end
		if slot and slot > 0 then
			local entry = slots[slot] or { visible = false }
			local shown = frame.IsVisible and frame:IsVisible() or false
			if shown and not entry.visible then
				entry.label = barLabel(frame.GetName and frame:GetName())
			end
			entry.visible = entry.visible or shown
			slots[slot] = entry
		end
		frame = EnumerateFrames(frame)
	end
	return slots
end

-- What the agent needs to know about this character, as one string.
--
-- The same shape as dumpApi and for the same reason: the helper has no Lua parser,
-- so one string it can slice out of SavedVariables beats a nested table. Sections
-- are marked "== name ==" so either side can take just the part it needs -- the
-- whole thing is too big for every prompt, but "macros" or "action slots" is not.
--
-- Two sections answer open questions rather than feed the agent. "action buttons on
-- screen" walks every frame in the UI looking for one bound to an action slot,
-- which is how we learn which of the flat 1..120 space the gamepad UI actually
-- draws -- measured from the live UI instead of guessed from the classic bar
-- layout. "bindings" is the other half: what the controller can already press, and
-- therefore what is left for us.
-- Every spell the player can cast, and where each one can be pressed.
--
-- The spellbook lists what it shows in the form you are in: Feral Charge reads
-- "(Bear)" out of form and is a different spell in cat, and a layout designed from
-- one export left the cat one off the bars. So each walk records what every entry
-- turns into in the current form (its override, and the name the book shows), and
-- keeps the union across forms in SavedVariables, refreshed whenever the form
-- changes. A flyout ("Shapeshift") is opened up into its spells. The reach section
-- then checks each castable one against the bar pages, wheels and macros, so a
-- spell nothing can press is listed by name instead of quietly missing.
local function bookEntries()
	local found = {}
	if not (C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines) then
		return found
	end
	local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
	local flyoutType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Flyout
	for tab = 1, C_SpellBook.GetNumSpellBookSkillLines() do
		local info = C_SpellBook.GetSpellBookSkillLineInfo(tab)
		local offset = info and info.itemIndexOffset or 0
		for at = offset + 1, offset + (info and info.numSpellBookItems or 0) do
			local item = C_SpellBook.GetSpellBookItemInfo(at, bank)
			if item and item.name then
				if flyoutType and item.itemType == flyoutType and GetFlyoutInfo and GetFlyoutSlotInfo then
					-- called the way Blizzard's SpellFlyout.lua calls them
					local _, _, numSlots = GetFlyoutInfo(item.actionID)
					for i = 1, numSlots or 0 do
						local spellID, overrideID, known, name = GetFlyoutSlotInfo(item.actionID, i)
						if spellID and known then
							found[#found + 1] = { id = spellID, override = overrideID,
								name = name or spellName(spellID), flyout = item.name }
						end
					end
				elseif item.spellID then
					found[#found + 1] = { id = item.spellID, name = item.name, passive = item.isPassive or nil }
				end
			end
		end
	end
	return found
end

local function noteForms()
	if InCombatLockdown() then
		return
	end
	WowCompanionDB.spellForms = WowCompanionDB.spellForms or {}
	local store = WowCompanionDB.spellForms
	local form = tostring(GetShapeshiftForm and GetShapeshiftForm() or 0)
	for _, entry in ipairs(bookEntries()) do
		local key = tostring(entry.id)
		local known = store[key] or { forms = {} }
		known.name = known.name or entry.name
		known.passive = entry.passive
		known.flyout = entry.flyout
		local override = entry.override
		if (not override or override == 0) and C_Spell and C_Spell.GetOverrideSpell then
			local ok, id = pcall(C_Spell.GetOverrideSpell, entry.id)
			override = ok and id or nil
		end
		local shown = entry.name
		if override and override ~= 0 and override ~= entry.id then
			shown = spellName(override) or shown
		else
			override = nil
		end
		known.forms[form] = { id = override or entry.id, name = shown }
		store[key] = known
	end
end

local function trim(text)
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function reachLines(line, frames)
	pcall(noteForms)
	local store = WowCompanionDB.spellForms or {}
	local where = {}
	local function reach(name, place)
		if type(name) == "string" and name ~= "" then
			local key = name:lower()
			where[key] = where[key] or place
		end
	end
	-- a slot counts if it is drawn now or sits on a gamepad bar or form page
	local function pageOf(slot)
		local drawn = frames and frames[slot]
		if drawn and drawn.visible then
			return tostring(drawn.label)
		end
		if (slot >= 181 and slot <= 208) or (slot >= 265 and slot <= 288) then
			return "slot " .. slot .. " (form page)"
		end
	end
	local function fromMacroBody(body, place)
		for verb, rest in (body or ""):gmatch("/(%a+)%s+([^\n]+)") do
			verb = verb:lower()
			if verb == "cast" or verb == "use" or verb == "castsequence" then
				rest = rest:gsub("%b[]", "")
				for name in rest:gmatch("[^,;]+") do
					name = trim(name):gsub("^reset=%S+%s*", ""):gsub("^!", "")
					reach(trim(name), place)
				end
			end
		end
	end
	for slot = 1, LAST_ACTION_SLOT do
		local place = pageOf(slot)
		if place and HasAction(slot) then
			local kind, id = GetActionInfo(slot)
			if kind == "spell" then
				local held = spellName(id)
				reach(held, place)
				-- a slot holding the base spell fires its form's version too. The slot
				-- reports whichever version the current form shows, so "Feral Charge"
				-- (1238122) in caster is "Feral Charge (Cat)" (414924) in cat: match on
				-- the shared base spell, or on the name with a "(Form)" suffix
				local function baseOf(spell)
					local ok, base = pcall(C_SpellBook.FindBaseSpellByID, spell)
					return ok and base or spell
				end
				local heldBase = C_SpellBook and C_SpellBook.FindBaseSpellByID and baseOf(id) or id
				-- in cat the slot reads "Feral Charge (Cat)"; its bear twin shares the stem
				local stem = held and held:gsub("%s*%b()$", "")
				local prefix = stem and (stem:lower() .. " (")
				for key, known in pairs(store) do
					local match = tonumber(key) == id
					for _, variant in pairs(known.forms or {}) do
						if variant.id == id then match = true end
						if variant.id and C_SpellBook and C_SpellBook.FindBaseSpellByID
							and baseOf(variant.id) == heldBase then
							match = true
						end
						if prefix and type(variant.name) == "string"
							and variant.name:lower():sub(1, #prefix) == prefix then
							match = true
						end
					end
					if match then
						for _, variant in pairs(known.forms or {}) do
							reach(variant.name, place)
						end
					end
				end
			elseif kind == "macro" then
				-- a macro with #showtooltip reports its spell's ID here, not its
				-- index, so find it by the name the slot shows
				-- and that spell is what the macro casts now, so it counts as reached
				if id and spellName(id) then
					reach(spellName(id), place .. " via macro")
				end
				local index = id
				local named = GetActionText and GetActionText(slot)
				if named and GetMacroIndexByName then
					local found = GetMacroIndexByName(named)
					if found and found > 0 then index = found end
				end
				local _, _, body = GetMacroInfo(index)
				fromMacroBody(body, place .. " via macro")
			end
		end
	end
	local wheels = WowCompanionWheelDB and WowCompanionWheelDB.wheels or {}
	for wheel, def in pairs(wheels) do
		for _, slot in ipairs(def.slots or {}) do
			if slot.spell then
				local name = tonumber(slot.spell) and spellName(tonumber(slot.spell)) or tostring(slot.spell)
				reach(name, "wheel " .. wheel)
			elseif slot.macro then
				local _, _, body = GetMacroInfo(slot.macro)
				fromMacroBody(body, "wheel " .. wheel .. " via macro")
			elseif slot.macrotext then
				fromMacroBody(slot.macrotext, "wheel " .. wheel)
			end
		end
	end

	local keys = {}
	for key in pairs(store) do keys[#keys + 1] = key end
	table.sort(keys, function(a, b) return (store[a].name or "") < (store[b].name or "") end)
	local rows, missing, done, formsSeen = {}, {}, {}, {}
	for _, key in ipairs(keys) do
		local known = store[key]
		local variants = {}
		for form, variant in pairs(known.forms or {}) do
			formsSeen[form] = true
			variants[#variants + 1] = ("form %s: %s (%s)"):format(form, variant.name, tostring(variant.id))
		end
		table.sort(variants)
		if not known.passive then
			local names = {}
			for _, variant in pairs(known.forms or {}) do
				if not done[variant.name] then
					done[variant.name] = true
					names[#names + 1] = variant.name
				end
			end
			table.sort(names)
			for _, name in ipairs(names) do
				local at = where[name:lower()]
				if not at and (known.flyout or name:find(" Form$")) then
					at = "the L1+L2 form wheel"
				end
				rows[#rows + 1] = ("%s: %s%s"):format(name, at or "NOT REACHABLE",
					#variants > 1 and ("  [" .. table.concat(variants, "; ") .. "]") or "")
				if not at then
					missing[#missing + 1] = name
				end
			end
		end
	end
	local list = {}
	for form in pairs(formsSeen) do list[#list + 1] = form end
	table.sort(list)
	line("-- every castable spell (passives left out) and what presses it. Spells turn")
	line("-- into other spells in a form, and the book shows only the current form's,")
	line("-- so this is the union over forms recorded so far: " .. table.concat(list, ", ")
		.. " (0 is caster); a form not listed has not been entered since this began.")
	line("-- A layout must give every line a place: a bar slot, a wheel, or a macro.")
	for _, row in ipairs(rows) do
		line(row)
	end
	line(("-- %d not reachable%s"):format(#missing,
		#missing > 0 and (": " .. table.concat(missing, ", ")) or ""))
end

local function exportContext()
	local newline = string.char(10)
	local out = {}
	local function line(text)
		out[#out + 1] = text
	end
	local function section(name)
		line("")
		line("== " .. name .. " ==")
	end

	local version, build = GetBuildInfo()
	line(("-- WowCompanion context, %s, client %s build %s")
		:format(date("%Y-%m-%d %H:%M:%S"), tostring(version), tostring(build)))

	section("character")
	line(("name: %s"):format(tostring(UnitName("player"))))
	line(("level: %s"):format(tostring(UnitLevel("player"))))
	line(("class: %s"):format(tostring(UnitClass("player"))))
	line(("race: %s"):format(tostring(UnitRace("player"))))
	line(("faction: %s"):format(tostring(UnitFactionGroup("player"))))
	if GetSpecialization and GetSpecializationInfo then
		local index = GetSpecialization()
		if index then
			local _, specName = GetSpecializationInfo(index)
			line(("spec: %s"):format(tostring(specName)))
		end
	end
	if GetMoney then
		line(("copper: %s"):format(tostring(GetMoney())))
	end

	section("action slots")
	line("-- addressed by number; empty slots omitted. 'on screen' names the bar that")
	line("-- draws it now; anything without it is stored but not shown")
	if HasAction and GetActionInfo then
		local frames = actionFrames()
		local filled = 0
		for slot = 1, LAST_ACTION_SLOT do
			if slotHas(slot) then
				filled = filled + 1
				local kind, id, subType = GetActionInfo(slot)
				local what
				if kind == "spell" then
					what = ("spell %s (%s)"):format(tostring(id), tostring(spellName(id) or "?"))
				elseif kind == "macro" then
					local name = GetMacroInfo and GetMacroInfo(id)
					if not name and GetActionText then
						name = GetActionText(slot)
					end
					what = ("macro %s (%s)"):format(tostring(id), tostring(name or "?"))
				elseif kind == "item" then
					what = ("item %s (%s)"):format(tostring(id), tostring(itemName(id) or "?"))
				else
					what = ("%s %s"):format(tostring(kind), tostring(id))
				end
				if subType and subType ~= "" then
					what = what .. " [" .. tostring(subType) .. "]"
				end
				local drawn = frames[slot]
				if drawn and drawn.visible then
					what = what .. " -- on screen: " .. tostring(drawn.label)
					local chord = chordFor(drawn.label)
					if chord then
						what = what .. " (" .. chord .. ")"
					end
				end
				line(("%3d: %s"):format(slot, what))
			end
		end
		line(("-- %d filled"):format(filled))

		section("empty slots on screen")
		line("-- where a new action can go and be seen")
		local open = {}
		for slot = 1, LAST_ACTION_SLOT do
			local drawn = frames[slot]
			if drawn and drawn.visible and not slotHas(slot) then
				local chord = chordFor(drawn.label)
				open[#open + 1] = ("%d (%s%s)"):format(slot, tostring(drawn.label),
					chord and (", " .. chord) or "")
			end
		end
		line(#open > 0 and table.concat(open, ", ") or "none")

		section("controller")
		line("-- the chord for each bar. Buttons 1-4 are the d-pad left, up, right, down;")
		line("-- 5-8 the face buttons square, triangle, circle, cross (from each button's")
		line("-- icon). The modifier is learned by watching which triggers are held when a")
		line("-- button fires; '?' means not seen yet, and is not to be guessed")
		for _, bar in ipairs(GAMEPAD_BARS) do
			local name = barLabel(bar[1] .. "ActionButton1"):gsub(" 1$", "")
			local modifier, presses = barModifier(name)
			line(("%s: %s"):format(name, modifier and ("%s (seen %d times)"):format(modifier, presses) or "?"))
		end
		-- Measured, and corrected by the player: the frames named StanceBar are not
		-- a bar of their own. They are the in-form page of whichever bar the
		-- GamepadStanceBarOverride setting names (here the R2 bar), which is why they
		-- learn the same chord. Switching forms is the L1+L2 wheel, not a slot.
		local byModifier = {}
		for _, bar in ipairs(GAMEPAD_BARS) do
			local name = barLabel(bar[1] .. "ActionButton1"):gsub(" 1$", "")
			local modifier = barModifier(name)
			if modifier then
				byModifier[modifier] = byModifier[modifier] or {}
				table.insert(byModifier[modifier], name)
			end
		end
		for modifier, names in pairs(byModifier) do
			if #names > 1 then
				line(("-- %s is shared by %s: StanceBar is that bar's page while in a form"
					.. " (cat, bear); out of form it is the other"):format(modifier, table.concat(names, " and ")))
			end
		end
		local form = GetShapeshiftForm and GetShapeshiftForm() or 0
		line(("form at export: %s"):format(form == 0 and "none (caster)" or ("%d"):format(form)))
		line(("GamepadStanceBarOverride: %s (the setting that picks which bar shows form actions)")
			:format(tostring(cvar("GamepadStanceBarOverride"))))
		line("-- changing form is the L1+L2 wheel, not an action slot")
		local stats = WowCompanionDB.chordStats
		if stats then
			line(("-- %d d-pad/face presses watched, %d lit a bar button"):format(stats.presses, stats.lit))
		end
		local misses = WowCompanionDB.chordMisses
		if misses and #misses > 0 then
			line("-- presses that lit none of these bars, newest last:")
			for _, miss in ipairs(misses) do
				line("--   " .. (miss:gsub("PAD%u+", function(name) return PAD_WORDS[name] or name end)))
			end
		end
	else
		line("-- HasAction/GetActionInfo unavailable")
	end

	section("action buttons on screen")
	line("-- every frame bound to an action slot: which of the 120 the UI draws, and where")
	if EnumerateFrames then
		local seen, walked = {}, 0
		local frame = EnumerateFrames()
		while frame and walked < 50000 do
			walked = walked + 1
			local slot
			if type(frame.action) == "number" then
				slot = frame.action
			elseif frame.GetAttribute then
				local ok, value = pcall(frame.GetAttribute, frame, "action")
				if ok and type(value) == "number" then
					slot = value
				end
			end
			if slot then
				local name = frame.GetName and frame:GetName() or nil
				local shown = frame.IsVisible and frame:IsVisible()
				seen[#seen + 1] = ("%3d: %s%s"):format(slot,
					tostring(name or "(anonymous)"), shown and "" or " (hidden)")
			end
			frame = EnumerateFrames(frame)
		end
		table.sort(seen)
		for _, entry in ipairs(seen) do
			line(entry)
		end
		line(("-- %d action-bound frames out of %d walked"):format(#seen, walked))
	else
		line("-- EnumerateFrames unavailable")
	end

	section("bindings")
	line("-- what is already taken. PAD* are the controller's; those are the scarce ones")
	if GetNumBindings and GetBinding then
		local total = GetNumBindings()
		local bound = 0
		for index = 1, total do
			-- GetBinding's return shape differs between builds (some insert a
			-- category before the keys), so take everything after the command and
			-- report it rather than indexing positions we have not verified
			local bits = { GetBinding(index) }
			if index == 1 then
				line(("-- GetBinding returns %d values per binding"):format(#bits))
			end
			local keys = {}
			for at = 2, #bits do
				if type(bits[at]) == "string" and bits[at] ~= "" then
					keys[#keys + 1] = bits[at]
				end
			end
			if #keys > 0 then
				bound = bound + 1
				line(("%s = %s"):format(tostring(bits[1]), table.concat(keys, ", ")))
			end
		end
		line(("-- %d bound of %d bindings"):format(bound, total))
	else
		line("-- GetNumBindings/GetBinding unavailable")
	end

	section("macros")
	if GetNumMacros and GetMacroInfo then
		local global, perChar = GetNumMacros()
		line(("-- %s global, %s character"):format(tostring(global), tostring(perChar)))
		for index = 1, 200 do
			local name, _, body = GetMacroInfo(index)
			if name then
				line(("%d: %s"):format(index, name))
				local shown = (tostring(body or "")):gsub(newline, newline .. "    ")
				line("    " .. shown)
			end
		end
	else
		line("-- GetNumMacros/GetMacroInfo unavailable")
	end

	section("spellbook")
	line("-- also the vocabulary the transcriber needs: these are the words you will say")
	-- the name index says this build has no GetNumSpellTabs, GetSpellBookItemInfo or
	-- GetSpellInfo at all: it is a retail-11.x-era API behind a 1.60.1 version
	-- string. The classic branch stays only so a differently-built client says so
	-- out loud instead of exporting an empty spellbook.
	local walked = pcall(function()
		if GetNumSpellTabs and GetSpellTabInfo and GetSpellBookItemInfo then
			for tab = 1, GetNumSpellTabs() do
				local tabName, _, offset, numSpells = GetSpellTabInfo(tab)
				line(("-- %s"):format(tostring(tabName)))
				for at = (offset or 0) + 1, (offset or 0) + (numSpells or 0) do
					local kind, id = GetSpellBookItemInfo(at, "spell")
					local name = GetSpellBookItemName and GetSpellBookItemName(at, "spell")
					if not name and id then
						name = spellName(id)
					end
					if name then
						line(("%s %s (%s)"):format(tostring(kind), tostring(name), tostring(id)))
					end
				end
			end
		elseif C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
			for tab = 1, C_SpellBook.GetNumSpellBookSkillLines() do
				local info = C_SpellBook.GetSpellBookSkillLineInfo(tab)
				local offset = info and info.itemIndexOffset or 0
				line(("-- %s"):format(tostring(info and info.name)))
				-- GetSpellBookItemInfo's second argument is typed SpellBookSpellBank,
				-- so name it rather than passing the 0 I would otherwise have assumed
				local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
				for at = offset + 1, offset + (info and info.numSpellBookItems or 0) do
					local item = C_SpellBook.GetSpellBookItemInfo(at, bank)
					if item and item.name then
						line(("%s %s (%s)"):format(
							tostring(item.itemType), item.name, tostring(item.spellID)))
					end
				end
			end
		else
			line("-- no spellbook API found under either name")
		end
	end)
	if not walked then
		line("-- the spellbook walk failed partway; the lines above are what it reached")
	end

	section("reach")
	local reached, why = pcall(reachLines, line, actionFrames())
	if not reached then
		line("-- the reach check failed: " .. tostring(why))
	end

	section("modules")
	line("-- Lua the agent stored; each runs at every login")
	local stored = {}
	for name in pairs(WowCompanionDB.modules or {}) do
		stored[#stored + 1] = name
	end
	table.sort(stored)
	for _, name in ipairs(stored) do
		line(name .. ":")
		line("    " .. (tostring(WowCompanionDB.modules[name].code):gsub(newline, newline .. "    ")))
	end
	if #stored == 0 then
		line("none")
	end

	section("code runs")
	line("-- the last runs of agent code this session and before, oldest first")
	local runs = WowCompanionDB.runs or {}
	for at = math.max(1, #runs - 9), #runs do
		local run = runs[at]
		line(("%s %s: %s; taint %s"):format(date("%H:%M:%S", run.at or 0), tostring(run.label),
			tostring(run.outcome), tostring(run.taint or "unchecked")))
		if run.printed and run.printed ~= "" then
			line("    " .. (run.printed:gsub(newline, newline .. "    ")))
		end
	end
	if #runs == 0 then
		line("none")
	end

	section("lua errors")
	line("-- errors from addons that are not Blizzard's (ours, the agent's, the player's),")
	line("-- newest first, with how often each repeated. Read the stack, fix the cause")
	local errors = WowCompanionDB.errors or {}
	for at = #errors, math.max(1, #errors - 9), -1 do
		local err = errors[at]
		line(("%s x%d: %s"):format(date("%m-%d %H:%M:%S", err.at or 0), err.count or 1, tostring(err.message)))
		if err.stack and err.stack ~= "" then
			line("    " .. (err.stack:gsub(newline, newline .. "    ")))
		end
	end
	if #errors == 0 then
		line("none")
	end

	WowCompanionDB.context = table.concat(out, newline) .. newline
	return #out
end

local function probeChat()
	local open = ChatFrame_OpenChat or (ChatFrameUtil and ChatFrameUtil.OpenChat)
	record("chat opener", ChatFrame_OpenChat and "ChatFrame_OpenChat" or open and "ChatFrameUtil.OpenChat" or "none")
	if not open then
		return
	end
	-- the Enter that submits /wc chat closes the edit box once the command returns,
	-- so opening it from here only sticks if we let that finish first
	C_Timer.After(0.1, function()
		open("hello from the companion")
		C_Timer.After(0.1, function()
			local box = activeEditBox()
			record("chat box", box and box:IsVisible() and ("open, holds %q"):format(box:GetText()) or "not open")
		end)
	end)
end

local function probeMacro()
	if InCombatLockdown() then
		say("leave combat first")
		return
	end
	local created, index = pcall(CreateMacro, "WCPROBE", "INV_MISC_QUESTIONMARK", "/say created", false)
	record("CreateMacro", index)
	if not created or not index then
		return
	end
	local edited, err = pcall(EditMacro, index, nil, nil, "/say edited")
	record("EditMacro", edited and GetMacroBody(index) or err)
	local empty
	for action = 1, 120 do
		if not HasAction(action) then
			empty = action
			break
		end
	end
	if empty then
		PickupMacro(index)
		local placed, placeErr = pcall(PlaceAction, empty)
		ClearCursor()
		local kind = GetActionInfo(empty)
		record("PlaceAction", placed and ("action %d now holds %s"):format(empty, tostring(kind)) or placeErr)
		if kind == "macro" then
			PickupAction(empty)
			ClearCursor()
		end
	else
		record("PlaceAction", "no empty action slot to test with")
	end
	DeleteMacro(index)
end

-- PlaceAction, tested one variable at a time.
--
-- The chat taint taught us that "it seemed fine" means nothing: the damage lands
-- later, on an unrelated keypress, and only sometimes. So the A/B check by hand is
-- kept, but it is not the instrument. The instrument is issecurevariable: every
-- global, and every string-keyed field of every global table, is asked who last
-- wrote it, before and after the action. Anything that turns insecure in between,
-- and is not one of our own names, is taint we caused, named by variable.
--
-- That is a claim about the scanner, so it gets a positive control: `chatopen`
-- does the one thing we know broke A and B. If the scan cannot see that, a clean
-- scan for PlaceAction proves nothing.

local function ours(name)
	name = tostring(name)
	return name:find("WowCompanion", 1, true) or name:find("WOWCOMPANION", 1, true)
end

local function taintScan()
	local tainted, checked = {}, 0
	local function check(label, tbl, key)
		checked = checked + 1
		local ok, secure, by
		if tbl then
			ok, secure, by = pcall(issecurevariable, tbl, key)
		else
			ok, secure, by = pcall(issecurevariable, key)
		end
		if ok and not secure then
			tainted[label] = tostring(by)
		end
	end
	for name, value in pairs(_G) do
		if type(name) == "string" and not ours(name) then
			check(name, nil, name)
			-- forbidden frames refuse to be walked; pcall keeps one from ending the scan
			if type(value) == "table" then
				pcall(function()
					for field in pairs(value) do
						if type(field) == "string" and not ours(field) then
							check(name .. "." .. field, value, field)
						end
					end
				end)
			end
		end
	end
	return tainted, checked
end

local PLACE_MACRO = "WCPLACE"

local function placeMacro()
	local index = GetMacroIndexByName(PLACE_MACRO)
	if index and index > 0 then
		return index
	end
	return CreateMacro(PLACE_MACRO, "INV_MISC_QUESTIONMARK", "/wc ping", false)
end

-- chosen fresh each run, so each variant reports exactly where it acted
local function pickSlots()
	local frames = actionFrames()
	local picked = {}
	for slot = 1, LAST_ACTION_SLOT do
		local drawn = frames[slot] and frames[slot].visible
		if not slotHas(slot) then
			if drawn and not picked.emptyVisible then
				picked.emptyVisible = slot
			elseif not frames[slot] and slot <= 120 and not picked.emptyHidden then
				picked.emptyHidden = slot
			end
		elseif drawn and not picked.filledVisible then
			picked.filledVisible = slot
		end
	end
	return picked
end

local placeVariants = {}

placeVariants.none = function()
	return "did nothing: the scan's own noise floor"
end

placeVariants.chatopen = function()
	local open = ChatFrame_OpenChat or (ChatFrameUtil and ChatFrameUtil.OpenChat)
	if not open then
		return "no chat opener on this client"
	end
	-- deferred a tick, as the slash-command path requires, then closed again so the
	-- only thing measured is having opened it
	C_Timer.After(0.1, function()
		open("")
		C_Timer.After(0.1, function()
			local box = activeEditBox()
			if box and ChatEdit_DeactivateChat then
				pcall(ChatEdit_DeactivateChat, box)
			end
		end)
	end)
	return "opened and closed the chat box from addon code (the known-bad control)"
end

placeVariants.pickup = function()
	PickupMacro(placeMacro())
	ClearCursor()
	return "picked up the test macro and cleared the cursor, placing nothing"
end

local function placeInto(slot, how)
	PickupMacro(placeMacro())
	if how == "put" then
		C_ActionBar.PutActionInSlot(slot)
	else
		PlaceAction(slot)
	end
	ClearCursor()
	local kind, id = GetActionInfo(slot)
	return ("slot %d now holds %s %s"):format(slot, tostring(kind), tostring(id))
end

placeVariants.hidden = function(slots)
	if not slots.emptyHidden then
		return "no empty undrawn slot"
	end
	return "PlaceAction into an undrawn slot: " .. placeInto(slots.emptyHidden, "place")
end

placeVariants.visible = function(slots)
	if not slots.emptyVisible then
		return "no empty drawn slot"
	end
	return "PlaceAction into a drawn slot: " .. placeInto(slots.emptyVisible, "place")
end

placeVariants.put = function(slots)
	if not (C_ActionBar and C_ActionBar.PutActionInSlot) then
		return "no C_ActionBar.PutActionInSlot"
	end
	if not slots.emptyVisible then
		return "no empty drawn slot"
	end
	return "PutActionInSlot into a drawn slot: " .. placeInto(slots.emptyVisible, "put")
end

-- A real rearrangement that undoes itself: a filled, drawn slot moves to an empty
-- undrawn one and back. The bars end where they started, but every call a
-- rearrangement needs has run, including holding a live action on the cursor.
placeVariants.move = function(slots)
	local from, to = slots.filledVisible, slots.emptyHidden
	if not (from and to) then
		return "need a filled drawn slot and an empty undrawn one"
	end
	local was, wasId = GetActionInfo(from)
	PickupAction(from)
	PlaceAction(to)
	PickupAction(to)
	PlaceAction(from)
	ClearCursor()
	local now, nowId = GetActionInfo(from)
	return ("moved slot %d to %d and back: holds %s %s, held %s %s"):format(from, to,
		tostring(now), tostring(nowId), tostring(was), tostring(wasId))
end

placeVariants.clean = function()
	local removed = 0
	local index = GetMacroIndexByName(PLACE_MACRO)
	if index and index > 0 then
		for slot = 1, LAST_ACTION_SLOT do
			local ok, kind, id = pcall(GetActionInfo, slot)
			if ok and kind == "macro" and id == index then
				PickupAction(slot)
				ClearCursor()
				removed = removed + 1
			end
		end
		DeleteMacro(index)
	end
	return ("removed the test macro from %d slot(s) and deleted it"):format(removed)
end

local PLACE_ORDER = { "none", "chatopen", "pickup", "hidden", "visible", "put", "move", "clean" }

-- One per UI session. Taint lasts until /reload, so a second test inherits the
-- first one's damage and the hand check cannot tell them apart -- which is how the
-- first full run was spoiled: chatopen's taint was still live for every test after it.
local placeRan
-- the test in flight, so a blocked-action notice can be pinned to it
local placeEntry

-- "Interface action failed because of an AddOn" is shown by this function, and it
-- fires even when ADDON_ACTION_BLOCKED does not reach us. hooksecurefunc runs after
-- the original without tainting it. Every hit is kept with its time, so the hand
-- check stops being the only witness.
if hooksecurefunc and DisplayInterfaceActionBlockedMessage then
	hooksecurefunc("DisplayInterfaceActionBlockedMessage", function()
		WowCompanionDB.blockedNotices = WowCompanionDB.blockedNotices or {}
		local stamp = date("%H:%M:%S")
		table.insert(WowCompanionDB.blockedNotices, stamp)
		if placeEntry then
			placeEntry.notices = (placeEntry.notices or 0) + 1
		end
		remember("probe", "interface action failed notice at " .. stamp
			.. (placeEntry and (" during place " .. placeEntry.variant) or ""))
	end)
end

local function placeTest(variant)
	local act = placeVariants[variant]
	if not act then
		return "variants: " .. table.concat(PLACE_ORDER, ", ")
	end
	if InCombatLockdown() then
		return "refused: in combat"
	end
	if placeRan and variant ~= "clean" then
		return ("refused: %s already ran this session; /reload first"):format(placeRan)
	end
	placeRan = variant
	WowCompanionDB.placeTests = WowCompanionDB.placeTests or {}
	local before, checked = taintScan()
	local ok, result = pcall(act, pickSlots())
	if not ok then
		result = "error: " .. tostring(result)
	end
	local entry = { at = time(), variant = variant, result = result, checked = checked }
	placeEntry = entry
	table.insert(WowCompanionDB.placeTests, entry)
	remember("probe", ("place %s: %s"):format(variant, tostring(result)))
	-- long enough for whatever the action set off to have run: events, OnUpdate,
	-- the deferred chat open
	C_Timer.After(1.5, function()
		local after = taintScan()
		local fresh = {}
		for label, by in pairs(after) do
			if before[label] == nil then
				fresh[#fresh + 1] = ("%s (by %s)"):format(label, by)
			end
		end
		table.sort(fresh)
		entry.tainted = #fresh
		entry.taint = #fresh == 0 and "none" or table.concat(fresh, "; ")
		remember("probe", ("place %s: %d newly tainted of %d checked%s"):format(variant, #fresh,
			checked, #fresh > 0 and (": " .. table.concat(fresh, "; ", 1, math.min(#fresh, 6))) or ""))
		remember("probe", "now A on an NPC, B out of a menu; then /wc verdict ok or /wc verdict broken")
	end)
	return result
end

local function placeVerdict(word)
	local tests = WowCompanionDB.placeTests
	local last = tests and tests[#tests]
	if not last then
		return "no place test to judge"
	end
	last.verdict = word
	remember("probe", ("place %s judged %s"):format(last.variant, word))
	return word
end

-- Put a spell, macro or item on a bar slot, or empty one.
--
-- Cleared by measurement, not assumed: PlaceAction and PutActionInSlot into the
-- slots the gamepad UI draws (189, 202) newly tainted 0 of ~265,000 variables and
-- raised no blocked-action notice. Configuration, out of combat, like a macro.
--
-- Whatever the slot held comes back on the cursor and is dropped. It leaves the bar
-- only: spells stay in the spellbook, macros in the macro list. The reply names it,
-- so "put it back" has something to go on.
local function describeSlot(slot)
	local ok, kind, id = pcall(GetActionInfo, slot)
	if not ok or not kind then
		return "nothing"
	end
	if kind == "spell" then
		return "spell " .. tostring(spellName(id) or id)
	elseif kind == "macro" then
		return "macro " .. tostring(GetMacroInfo(id) or id)
	elseif kind == "item" then
		return "item " .. tostring(itemName(id) or id)
	end
	return tostring(kind) .. " " .. tostring(id)
end

function handlers.bar(inbox)
	if InCombatLockdown() then
		return "refused: in combat"
	end
	local slot = tonumber(inbox.slot)
	if not slot or slot < 1 or slot > LAST_ACTION_SLOT or slot ~= math.floor(slot) then
		return "refused: no valid slot"
	end
	local before = describeSlot(slot)
	local what, name = inbox.what, inbox.name
	ClearCursor()
	if what == "empty" then
		PickupAction(slot)
		ClearCursor()
		remember("claude", ("slot %d emptied (held %s)"):format(slot, before))
		return ("slot %d emptied, held %s"):format(slot, before)
	elseif what == "spell" then
		C_Spell.PickupSpell(tonumber(name) or name)
	elseif what == "macro" then
		local index = GetMacroIndexByName(name or "")
		if not index or index == 0 then
			return ("refused: no macro named %q"):format(tostring(name))
		end
		PickupMacro(index)
	elseif what == "item" then
		C_Item.PickupItem(tonumber(name) or name)
	else
		return "refused: what must be spell, macro, item or empty"
	end
	-- nothing on the cursor means the name did not resolve: do not place nothing,
	-- which would just empty the slot
	if not GetCursorInfo() then
		return ("refused: could not pick up %s %q"):format(tostring(what), tostring(name))
	end
	PlaceAction(slot)
	ClearCursor()
	local after = describeSlot(slot)
	remember("claude", ("slot %d now %s (was %s)"):format(slot, after, before))
	return ("slot %d: %s, was %s"):format(slot, after, before)
end

-- from the helper too, so the bell path is measured and not just the slash command
function handlers.place(inbox)
	return placeTest(inbox.variant or "")
end

-- Code the agent writes, run here.
--
-- This replaces "the model never writes Lua" with something that holds up better
-- than a rule: the client's own security. Insecure addon code cannot cast, target,
-- move or use protected actions at all -- that is what protection is -- so code
-- from the agent can do no more for the player than any addon they install. What
-- is left to guard is what the client does *not* protect, and two failure modes we
-- have actually hit:
--
--  * Things an addon may do that are not ours to do: delete items, send chat as the
--    player, spend gold, leave groups. Those names are refused in the environment
--    the code runs in. This is a guard against mistakes, not an adversary: Lua has
--    ways around an environment, and getfenv/loadstring, the obvious ones, are shut.
--  * Taint and crashes. Every run is followed by the same issecurevariable diff as
--    /wc place, so code that would break A and B says so by name, and nothing runs
--    in combat. A C-level crash cannot be caught; see /wc alive.
--
-- Code arrives two ways: `lua` runs once and reports what it printed and returned;
-- `module` is also stored in SavedVariables and run again at every login, which is
-- as close to the agent writing its own addon as the client allows without a
-- restart (new addon folders are only seen at launch).

local REFUSED = {
	DeleteCursorItem = true, SendChatMessage = true, BNSendWhisper = true,
	BNSendGameData = true, SendMail = true, AcceptTrade = true, InitiateTrade = true,
	BuyMerchantItem = true, BuybackItem = true, RepairAllItems = true,
	PlaceAuctionBid = true, Logout = true, Quit = true, ForceQuit = true,
	LeaveParty = true, GuildLeave = true, GuildDisband = true, GuildUninvite = true,
	AbandonQuest = true, SetAbandonQuest = true,
	RunScript = true, loadstring = true, load = true, getfenv = true, setfenv = true,
	C_AuctionHouse = true, C_TradeInfo = true, C_Mail = true,
}
-- inside namespaces we otherwise allow
local REFUSED_IN = {
	C_ChatInfo = { SendAddonMessage = true, SendChatMessage = true },
	C_Container = { UseContainerItem = true },
	C_PartyInfo = { LeaveParty = true, ConfirmLeaveParty = true },
	C_Macro = { RunMacroText = true },
}

-- globals that modules created, so a module may update its own but never replace
-- one of Blizzard's: overwriting a Blizzard global is a textbook taint source
local moduleGlobals = {}

local function refuse(name)
	return function()
		error(("%s is not available to companion code"):format(name), 2)
	end
end

local function sandbox(output)
	local env = {}
	-- C functions that take or return a vector or a color look its mixin up in
	-- the calling code's environment directly, so the proxy below is not
	-- enough: "unable to find mixin or metatable (Vector2DMixin)". Put the
	-- mixins the API needs into the environment itself.
	for _, name in ipairs({ "Vector2DMixin", "Vector3DMixin", "ColorMixin", "ItemLocationMixin",
		"ItemTransmogInfoMixin", "PlayerLocationMixin", "TransmogLocationMixin" }) do
		if _G[name] ~= nil then rawset(env, name, _G[name]) end
	end
	local wrapped = {}
	setmetatable(env, {
		__index = function(_, key)
			if key == "_G" then
				return env
			elseif key == "print" then
				return function(...)
					local parts = {}
					for i = 1, select("#", ...) do
						parts[#parts + 1] = tostring((select(i, ...)))
					end
					local text = table.concat(parts, " ")
					-- after the run, from a slash command or an event the code set up:
					-- nobody is collecting any more, so straight to the window
					if output.done then
						remember("probe", text)
					else
						output[#output + 1] = text
					end
				end
			end
			if REFUSED[key] then
				return refuse(key)
			end
			local value = _G[key]
			local blocked = REFUSED_IN[key]
			if blocked and type(value) == "table" then
				wrapped[key] = wrapped[key] or setmetatable({}, {
					__index = function(_, name)
						if blocked[name] then
							return refuse(key .. "." .. name)
						end
						return value[name]
					end,
				})
				return wrapped[key]
			end
			return value
		end,
		__newindex = function(_, key, value)
			if rawget(_G, key) ~= nil and not moduleGlobals[key] then
				error(("refusing to replace the global %s"):format(tostring(key)), 2)
			end
			moduleGlobals[key] = true
			rawset(_G, key, value)
		end,
	})
	return env
end

local function results(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[#parts + 1] = tostring((select(i, ...)))
	end
	return table.concat(parts, ", ")
end

-- Run one chunk. Returns the outcome line now and, a moment later, reports any
-- taint it caused. Everything lands in the window and in WowCompanionDB.runs, which
-- reaches disk at the next reload -- the agent's way of seeing what happened.
local function runCode(label, code, quiet)
	if InCombatLockdown() then
		return "refused: in combat"
	end
	local chunk, syntax = loadstring(code, "=" .. label)
	if not chunk then
		remember("probe", ("%s did not compile: %s"):format(label, tostring(syntax)))
		return "syntax error: " .. tostring(syntax)
	end
	local output = {}
	setfenv(chunk, sandbox(output))
	-- the scan costs about a second; a module replayed at login was scanned when it
	-- was first written, so it skips it
	local before = not quiet and taintScan() or nil
	local ok, outcome = (function(okay, ...)
		return okay, okay and results(...) or tostring((...))
	end)(pcall(chunk))
	output.done = true
	local line = ok and ("ran" .. (outcome ~= "" and (", returned " .. outcome) or ""))
		or ("failed: " .. outcome)
	for _, printed in ipairs(output) do
		remember("probe", label .. ": " .. printed)
	end
	if not quiet or not ok then
		remember("probe", ("%s %s"):format(label, line))
	end
	WowCompanionDB.runs = WowCompanionDB.runs or {}
	local run = { at = time(), label = label, outcome = line, printed = table.concat(output, "\n") }
	table.insert(WowCompanionDB.runs, run)
	while #WowCompanionDB.runs > 50 do
		table.remove(WowCompanionDB.runs, 1)
	end
	if not before then
		return line
	end
	C_Timer.After(1.5, function()
		local after = taintScan()
		local fresh = {}
		for name, by in pairs(after) do
			if before[name] == nil and not moduleGlobals[name] then
				fresh[#fresh + 1] = ("%s (by %s)"):format(name, by)
			end
		end
		table.sort(fresh)
		run.taint = #fresh == 0 and "none" or table.concat(fresh, "; ")
		if #fresh > 0 then
			remember("probe", ("%s tainted %d variable(s): %s -- /reload clears it"):format(
				label, #fresh, table.concat(fresh, "; ", 1, math.min(#fresh, 4))))
		end
	end)
	return line
end

function handlers.lua(inbox)
	return runCode("code", inbox.code or "")
end

function handlers.module(inbox)
	local name = tostring(inbox.name or "")
	if not name:match("^[%w_]+$") then
		return "refused: a module name is letters, digits and underscores"
	end
	WowCompanionDB.modules = WowCompanionDB.modules or {}
	if inbox.remove then
		WowCompanionDB.modules[name] = nil
		remember("claude", ("module %s removed; what it already did stays until /reload"):format(name))
		return "removed " .. name
	end
	WowCompanionDB.modules[name] = { code = inbox.code or "", at = time() }
	return runCode("module " .. name, inbox.code or "")
end

-- at login: every stored module, in name order so the order is stable
local function loadModules()
	local names = {}
	for name in pairs(WowCompanionDB.modules or {}) do
		names[#names + 1] = name
	end
	table.sort(names)
	for _, name in ipairs(names) do
		runCode("module " .. name, WowCompanionDB.modules[name].code, true)
	end
end

-- A path we have not measured gets the issecurevariable diff the first time it
-- runs in a session, and says so in the window if it tainted anything. Kept in
-- WowCompanionDB.pathTaint, so the verdict survives into the export.
local measured = {}
local function measureOnce(label, action)
	if measured[label] or InCombatLockdown() then
		return action()
	end
	measured[label] = true
	local before = taintScan()
	action()
	C_Timer.After(1.5, function()
		local after = taintScan()
		local fresh = {}
		for name, by in pairs(after) do
			if before[name] == nil and not moduleGlobals[name] then
				fresh[#fresh + 1] = ("%s (by %s)"):format(name, by)
			end
		end
		table.sort(fresh)
		WowCompanionDB.pathTaint = WowCompanionDB.pathTaint or {}
		WowCompanionDB.pathTaint[label] = #fresh == 0 and "none" or table.concat(fresh, "; ")
		-- the chat frames' fade clock is written by every line any addon prints to
		-- chat, and nothing protected reads it; it stays in pathTaint for the
		-- export, but is not worth a red line in the window every session
		local shown = {}
		for _, entry in ipairs(fresh) do
			if not entry:find("%.oldestFadingLineTimestamp ") then
				shown[#shown + 1] = entry
			end
		end
		if #shown > 0 then
			remember("error", ("%s tainted %d variable(s): %s -- /reload clears it"):format(
				label, #shown, table.concat(shown, "; ", 1, math.min(#shown, 4))))
		end
	end)
end

-- "/g hi" placed by SetText still says Say: the box only reads its slash command
-- when a space is typed (OnSpacePressed -> ParseText(0)) or on send. Run the same
-- parse, so the header shows the channel before the player presses send.
onDictated = function(box)
	local text = box:GetText() or ""
	if text:find("^/%S+ ") and box.ParseText then
		measureOnce("chat channel", function()
			pcall(box.ParseText, box, 0)
		end)
	end
end

-- The controller's cancel takes the box's focus away, and Blizzard closes it then
-- only if it is empty (ShouldDeactivateChatOnEditFocusLost: GetText() == ""), so a
-- draft lingered and came back glued to the next line. Escape clears it, but that
-- is not what cancel does. EventRegistry tells addons the moment focus goes,
-- before that check, so emptying the box there lets Blizzard's own code close it.
-- Not while the gamepad chat menu is open: that takes focus too, and means to
-- come back.
local draftOwner = {}
if EventRegistry and EventRegistry.RegisterCallback then
	EventRegistry:RegisterCallback("ChatFrame.OnEditBoxFocusLost", function(_, box)
		if WowCompanionDB and WowCompanionDB.keepChatDraft then
			return
		end
		if not (box and box.GetText and box.SetText) or (box:GetText() or "") == "" then
			return
		end
		local chat = box.chatFrame
		if chat and chat.IsGamepadMenuOpen and chat:IsGamepadMenuOpen() then
			return
		end
		measureOnce("draft clear", function()
			box:SetText("")
		end)
	end, draftOwner)
end

-- Lua errors, so the agent sees what its code broke instead of writing blind.
-- Blizzard's own hook for this (AddLuaErrorHandler) is secure-only, and replacing
-- the error handler would run Blizzard's error window tainted. A post-hook on the
-- method its handler ends in (ScriptErrors:AddUnhandledError) gets the message,
-- the stack and the locals without touching that path. Only errors whose stack
-- names a non-Blizzard addon are kept: Blizzard's own are not ours to fix.
local ERRORS_KEPT = 25
local function keepError(_, message, stack)
	message = tostring(message or "")
	stack = tostring(stack or "")
	local where = message .. "\n" .. stack
	local foreign = false
	for addon in where:gmatch("AddOns[/\\]([%w_%-]+)") do
		if not addon:find("^Blizzard_") then
			foreign = true
			break
		end
	end
	if not foreign then
		return
	end
	WowCompanionDB.errors = WowCompanionDB.errors or {}
	local errors = WowCompanionDB.errors
	for _, seen in ipairs(errors) do
		if seen.message == message then
			seen.count = (seen.count or 1) + 1
			seen.at = time()
			return
		end
	end
	-- the first lines of a stack say where; the rest is the engine's frames
	local lines, kept = {}, 0
	for text in stack:gmatch("[^\n]+") do
		kept = kept + 1
		if kept > 8 then
			break
		end
		lines[#lines + 1] = text
	end
	errors[#errors + 1] = { at = time(), count = 1, message = message:sub(1, 400), stack = table.concat(lines, "\n") }
	while #errors > ERRORS_KEPT do
		table.remove(errors, 1)
	end
end

local function watchErrors()
	if ScriptErrors and ScriptErrors.AddUnhandledError then
		hooksecurefunc(ScriptErrors, "AddUnhandledError", function(...)
			pcall(keepError, ...)
		end)
		-- hooked once: from here on this does nothing
		watchErrors = function() end
	end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
-- fires on /reload as well as logout, just before SavedVariables is written: the
-- one moment worth exporting at, since nothing reaches disk any other time
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("ADDON_ACTION_BLOCKED")
frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
-- the spellbook shows a form's own spells only while in it
frame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
frame:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		-- Blizzard_ScriptErrors may load before or after us
		pcall(watchErrors)
	end
	if event == "UPDATE_SHAPESHIFT_FORM" then
		-- a moment later, once the book has swapped its entries
		C_Timer.After(0.2, function() pcall(noteForms) end)
		return
	end
	if event == "ADDON_LOADED" and ... == ADDON then
		WowCompanionDB = WowCompanionDB or {}
		-- the game saves before it reloads, so hold on to the session we just read
		-- from disk or a second /reload discards the run we were trying to measure
		WowCompanionDB.previous = WowCompanionDB.probe
		WowCompanionDB.probe = {}
	elseif event == "PLAYER_LOGIN" then
		pcall(bindTap)
		local version, build, _, toc = GetBuildInfo()
		record("client", ("%s.%s, toc %d"):format(version, build, toc))
		-- build the window and refill it before anything can write to it
		logFrame()
		replayLog()
		probeSound()
		-- after login settles: modules may build frames on top of Blizzard's
		C_Timer.After(2, loadModules)
		-- read-only: polls the pad and the buttons' pushed state, hooks nothing
		pcall(learnChords)
		ticker = startPolling()
	elseif event == "PLAYER_LOGOUT" then
		-- a failed export must not cost the rest of the save
		pcall(exportContext)
		-- how many slots this game session can see (folders made after launch
		-- are invisible until a restart): the companion sends no further than this
		pcall(function()
			local seen = 0
			for index = 1, C_AddOns.GetNumAddOns() do
				local name = C_AddOns.GetAddOnInfo(index)
				if name and name:find("^" .. ADDON .. "_S%d+$") then
					seen = seen + 1
				end
			end
			WowCompanionDB.slotCount = seen
		end)
		WowCompanionDB.channel = channel
	elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
		-- taint cascades, and the first block names the real culprit, so number them
		-- rather than letting each one overwrite the last
		local addon, func = ...
		blocked = blocked + 1
		record(("%s %d"):format(event, blocked), ("%s called %s"):format(tostring(addon), tostring(func)))
	end
end)

SLASH_WOWCOMPANION1 = "/wc"
SlashCmdList.WOWCOMPANION = function(command)
	if command == "chat" then
		probeChat()
	elseif command == "macro" then
		probeMacro()
	elseif command == "sound" then
		probeSound()
	elseif command == "gamepad" then
		probeGamepad()
	elseif command == "api" then
		probeApi()
	elseif command == "dump" then
		dumpApi()
	elseif command == "docs" then
		dumpDocs()
	elseif command == "alive" then
		surveyApi()
	elseif command == "context" then
		say(("context: %d lines; /reload to write it to disk"):format(exportContext()))
	elseif command:match("^place") then
		local variant = command:match("^place%s+(%S+)") or ""
		-- deferred a tick, like chat: the Enter that submitted this is still unwinding
		C_Timer.After(0.1, function()
			say(placeTest(variant))
		end)
	elseif command:match("^verdict ") then
		say(placeVerdict(command:match("^verdict (%S+)")))
	elseif command == "taint" then
		local tainted, checked = taintScan()
		local names = {}
		for label, by in pairs(tainted) do
			names[#names + 1] = ("%s (by %s)"):format(label, by)
		end
		table.sort(names)
		WowCompanionDB.taint = table.concat(names, "\n")
		say(("%d tainted of %d checked; /reload to write the list"):format(#names, checked))
	elseif command == "ping" then
		-- the macro test target: no side effects, and unmistakable when it fires.
		-- remember() rather than say(), so the answer survives to SavedVariables --
		-- a probe whose result only reaches the chat frame cannot be read back.
		remember("probe", "pong at " .. date("%H:%M:%S") .. " -- the macro ran")
		record("macrotext runs", "yes, at " .. date("%H:%M:%S"))
	elseif command == "test" then
		-- point the button at our own slash command. If pong appears, macrotext works
		-- and /reload is being refused specifically; if not, macrotext never runs.
		say(offer("Run /wc ping", "/wc ping"))
	elseif command:match("^key ") then
		offerKey = command:match("^key (%S+)")
		say(("offer button will try %s first"):format(tostring(offerKey)))
	elseif command == "button" then
		say(offer("Reload UI", "/reload"))
	-- the bell poll is the only thing this addon does continuously, so silencing it
	-- is how we find out whether it is what taints the gamepad interact target
	elseif command == "quiet" then
		if ticker then
			ticker:Cancel()
			ticker = nil
		end
		say("bell poll stopped; nothing from the helper will arrive until /wc listen")
	elseif command == "listen" then
		if not ticker then
			ticker = startPolling()
		end
		say("bell poll running")
	elseif command == "log" then
		local frame = logFrame()
		if frame:IsShown() then
			-- plain Hide, not HideUIPanel: a programmatic HideUIPanel from a click
			-- handler is the exact path that taints gamepad navigation on this client.
			-- OnHide tells the gamepad manager, which is what Hide alone never did.
			frame:Hide()
		else
			reveal(frame)
		end
	elseif command == "clear" then
		WowCompanionDB.log = {}
		logFrame().messages:Clear()
		say("conversation cleared")
	else
		say("/wc log, /wc clear, /wc button, /wc gamepad, /wc api, /wc dump, /wc test, /wc chat, /wc macro, /wc sound, /wc quiet, /wc listen")
	end
end

-- Agent pins: places the agent talks about ("they're around 72, 69"), drawn on
-- the minimap as a dot, with a shaded disc for an area. The agent sets them from
-- a lua step; they live in WowCompanionDB.pins, so they survive a reload.
--   WCPins.Set({ { map = 1440, x = 72.5, y = 69.5, r = 40, label = "Outrunners" }, ... })
--   WCPins.Add({ ... })    WCPins.Clear()
-- map is a uiMapID, x and y are the 0-100 map coordinates players quote, r is a
-- radius in yards (0 or nil for a dot alone), color an optional { r, g, b }.
-- Drawn only while the player stands on the pin's map, in the open world.
WCPins = WCPins or {}
do
	-- Agent pins: dots and areas on the minimap at coordinates from the
	-- conversation. How it works and what went wrong: docs/api-useful.md, "Minimap pins".
	local layer, pool = nil, {}
	local function makeLayer()
		if layer or not Minimap then return layer end
		layer = CreateFrame("Frame", nil, Minimap)
		layer:SetAllPoints(Minimap)
		layer:SetFrameLevel(Minimap:GetFrameLevel() + 5)
		-- the minimap is round: anything past its edge is masked away
		-- the CircleMask atlas, not the portrait file: a texture or mask made from
		-- that file drew nothing on the minimap, while plain colour did
		-- (measured: a red square showed, every disc did not)
		layer.mask = layer:CreateMaskTexture()
		layer.mask:SetAtlas("CircleMask")
		layer.mask:SetAllPoints(Minimap)
		return layer
	end
	local function piece(i)
		local p = pool[i]
		if p then return p end
		-- solid colour cut to a circle by a mask: the alpha-mask file drawn as a
		-- plain texture may come out invisible, a masked colour cannot
		local function disc(level, sub)
			local t = layer:CreateTexture(nil, level, nil, sub)
			t:SetColorTexture(1, 1, 1, 1)
			local m = layer:CreateMaskTexture()
			m:SetAtlas("CircleMask")
			m:SetAllPoints(t)
			t:AddMaskTexture(m)
			return t
		end
		p = {}
		p.area = disc("ARTWORK", 0)
		p.area:AddMaskTexture(layer.mask)
		p.dot = disc("OVERLAY", 1)
		p.dot:SetSize(9, 9)
		p.edge = disc("OVERLAY", 0)
		p.edge:SetSize(12, 12)
		p.edge:SetVertexColor(0, 0, 0, 0.8)
		pool[i] = p
		return p
	end
	local function hideFrom(n)
		for i = n, #pool do
			local p = pool[i]
			p.area:Hide(); p.dot:Hide(); p.edge:Hide()
		end
	end
	local function draw()
		local pins = WowCompanionDB and WowCompanionDB.pins
		if not (layer and pins and #pins > 0) then hideFrom(1) return end
		local yards = C_Minimap and C_Minimap.GetViewRadius and C_Minimap.GetViewRadius()
		local half = Minimap:GetWidth() / 2
		if not (yards and yards > 0 and half > 0) then hideFrom(1) return end
		local scale = half / yards
		local rotate = GetCVar and GetCVar("rotateMinimap") == "1"
		local facing = rotate and GetPlayerFacing and GetPlayerFacing() or 0
		local sin, cos = math.sin(facing), math.cos(facing)
		local shown = 0
		-- World yards, not map positions: GetPlayerMapPosition errors on this
		-- client. UnitPosition and GetWorldPosFromMapPos both give (north, west),
		-- the order HereBeDragons relies on, so the difference is the offset.
		local pn, pw = UnitPosition("player")
		for _, pin in ipairs(pins) do
			local okPin, cont, world
			if pn and pin.map then
				okPin, cont, world = pcall(C_Map.GetWorldPosFromMapPos, pin.map,
					CreateVector2D((pin.x or 0) / 100, (pin.y or 0) / 100))
			end
			WCPins.probe = { ok = okPin, cont = cont, world = type(world), pn = pn, pw = pw }
			if okPin and world then
				local n, wv = world:GetXY()
				WCPins.probe.n, WCPins.probe.w = n, wv
				local east, north = -(wv - pw), n - pn
				local ox, oy = east * scale, north * scale
				if rotate then ox, oy = ox * cos - oy * sin, ox * sin + oy * cos end
				shown = shown + 1
				local p = piece(shown)
				local c = pin.color or { 1, 0.82, 0 }
				local dist = math.sqrt(ox * ox + oy * oy)
				WCPins.probe.ox, WCPins.probe.oy, WCPins.probe.half = ox, oy, half
				-- a texture keeps only one working mask here, so the minimap's
				-- round edge never clipped the area: keep it inside by size
				-- instead. Off the map there is no area, only the rim dot.
				local r = math.min((pin.r or 0) * scale, half - 2 - dist)
				if r > 2 then
					p.area:ClearAllPoints()
					p.area:SetPoint("CENTER", layer, "CENTER", ox, oy)
					p.area:SetSize(r * 2, r * 2)
					p.area:SetVertexColor(c[1], c[2], c[3], 0.28)
					p.area:Show()
				else
					p.area:Hide()
				end
				-- past the edge the dot sits on the rim, pointing the way
				local limit = half - 6
				local dx, dy = ox, oy
				if dist > limit then dx, dy = ox / dist * limit, oy / dist * limit end
				p.dot:ClearAllPoints(); p.dot:SetPoint("CENTER", layer, "CENTER", dx, dy)
				p.dot:SetVertexColor(c[1], c[2], c[3], 1)
				p.edge:ClearAllPoints(); p.edge:SetPoint("CENTER", p.dot, "CENTER")
				p.dot:Show(); p.edge:Show()
			end
		end
		hideFrom(shown + 1)
	end
	local ticker
	local function start()
		if not makeLayer() then return end
		if ticker then ticker:Cancel() end
		ticker = C_Timer.NewTicker(0.05, function()
			local ok, err = pcall(draw)
			-- kept, not printed: twenty a second would bury the window
			WCPins.lastError = not ok and tostring(err) or nil
			WCPins.drawn = ok
		end)
	end
	function WCPins.Set(list)
		WowCompanionDB.pins = list or {}
		start()
		return #WowCompanionDB.pins
	end
	function WCPins.Add(pin)
		WowCompanionDB.pins = WowCompanionDB.pins or {}
		table.insert(WowCompanionDB.pins, pin)
		start()
		return #WowCompanionDB.pins
	end
	function WCPins.Clear()
		WowCompanionDB.pins = {}
		hideFrom(1)
	end
	local boot = CreateFrame("Frame")
	boot:RegisterEvent("PLAYER_LOGIN")
	boot:SetScript("OnEvent", function()
		if WowCompanionDB and WowCompanionDB.pins and #WowCompanionDB.pins > 0 then start() end
	end)
end

-- The same pins on the world map. Not a data provider: AcquirePin and
-- AddDataProvider reach into Blizzard's map tables, and writing into those from
-- insecure code is the kind of thing that taints. Instead one frame of ours rides
-- on the map's canvas (WorldMapFrame:GetCanvas(), the ScrollContainer child that
-- pans and zooms), and each pin is placed by its position on whatever map is shown.
-- A pin given on a zone map is carried to the shown map through world yards:
-- GetWorldPosFromMapPos, then GetMapPosFromWorldPos(continent, pos, shownMap).
do
	local layer, pool, lastKey = nil, {}, nil
	local function piece(i)
		if pool[i] then return pool[i] end
		local function disc(level, sub)
			local t = layer:CreateTexture(nil, level, nil, sub)
			t:SetColorTexture(1, 1, 1, 1)
			local m = layer:CreateMaskTexture()
			m:SetAtlas("CircleMask")
			m:SetAllPoints(t)
			t:AddMaskTexture(m)
			return t
		end
		local p = { area = disc("ARTWORK", 0), edge = disc("OVERLAY", 0), dot = disc("OVERLAY", 1) }
		p.edge:SetVertexColor(0, 0, 0, 0.8)
		pool[i] = p
		return p
	end
	local function hideFrom(n)
		for i = n, #pool do
			local p = pool[i]
			p.area:Hide(); p.dot:Hide(); p.edge:Hide()
		end
	end
	local function onMap(pin, shown)
		local ok, cont, world = pcall(C_Map.GetWorldPosFromMapPos, pin.map,
			CreateVector2D((pin.x or 0) / 100, (pin.y or 0) / 100))
		if not (ok and cont and world) then return end
		local okPos, mapID, pos = pcall(C_Map.GetMapPosFromWorldPos, cont, world, shown)
		if not (okPos and pos and mapID == shown) then return end
		local x, y = pos:GetXY()
		local rx
		if (pin.r or 0) > 0 then
			-- the radius in map units: a point r yards north, measured on this map
			local n, w = world:GetXY()
			local okR, _, edge = pcall(C_Map.GetMapPosFromWorldPos, cont, CreateVector2D(n + pin.r, w), shown)
			if okR and edge then
				local ex, ey = edge:GetXY()
				rx = math.sqrt((ex - x) ^ 2 + (ey - y) ^ 2)
			end
		end
		return x, y, rx
	end
	local function draw()
		local map = WorldMapFrame
		local pins = WowCompanionDB and WowCompanionDB.pins
		if not (map and map:IsShown() and pins and #pins > 0) then hideFrom(1) return end
		local shown = map:GetMapID()
		local canvas = map:GetCanvas()
		local w, h = canvas:GetWidth(), canvas:GetHeight()
		-- dots keep their size on screen while the canvas zooms
		local scale = map.GetCanvasScale and map:GetCanvasScale() or 1
		if not scale or scale <= 0 then scale = 1 end
		local n = 0
		for _, pin in ipairs(pins) do
			local x, y, rx = onMap(pin, shown)
			if x then
				n = n + 1
				local p = piece(n)
				local c = pin.color or { 1, 0.82, 0 }
				local px, py = x * w, -y * h
				if rx and rx * w > 4 / scale then
					p.area:ClearAllPoints()
					p.area:SetPoint("CENTER", layer, "TOPLEFT", px, py)
					p.area:SetSize(rx * w * 2, rx * w * 2)
					p.area:SetVertexColor(c[1], c[2], c[3], 0.3)
					p.area:Show()
				else
					p.area:Hide()
				end
				p.dot:ClearAllPoints(); p.dot:SetPoint("CENTER", layer, "TOPLEFT", px, py)
				p.dot:SetSize(12 / scale, 12 / scale)
				p.dot:SetVertexColor(c[1], c[2], c[3], 1)
				p.edge:ClearAllPoints(); p.edge:SetPoint("CENTER", p.dot, "CENTER")
				p.edge:SetSize(16 / scale, 16 / scale)
				p.dot:Show(); p.edge:Show()
			end
		end
		hideFrom(n + 1)
	end
	local function attach()
		if layer or not (WorldMapFrame and WorldMapFrame.GetCanvas) then return end
		local canvas = WorldMapFrame:GetCanvas()
		layer = CreateFrame("Frame", nil, canvas)
		layer:SetAllPoints(canvas)
		-- above the map's art, below Blizzard's own pins' tooltips
		layer:SetFrameLevel(canvas:GetFrameLevel() + 20)
		local elapsed = 0
		layer:SetScript("OnUpdate", function(_, dt)
			elapsed = elapsed + dt
			if elapsed < 0.1 then return end
			elapsed = 0
			local ok, err = pcall(draw)
			WCPins.mapError = not ok and tostring(err) or nil
		end)
	end
	local f = CreateFrame("Frame")
	f:RegisterEvent("PLAYER_LOGIN")
	f:RegisterEvent("ADDON_LOADED")
	f:SetScript("OnEvent", function(_, event, name)
		if event == "PLAYER_LOGIN" or name == "Blizzard_WorldMap" then attach() end
	end)
end
