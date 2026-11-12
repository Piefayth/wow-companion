-- The settings page: Blizzard's Settings list in our window. Rows grouped
-- under section headers (their SettingsListSectionHeaderTemplate), a quest log
-- divider between sections as on the Status tab, each row one controller stop
-- (Rows.lua: left and right change it, confirm opens a dropdown's menu or
-- presses a button, up and down move between rows). The focused row's note is
-- read in one band at the foot of the page, where Blizzard shows a tooltip.
-- Owned by Core so it works without the Agent; each addon adds its own rows.
-- Shown in a window of its own (the minimap mark, Blizzard's AddOns settings)
-- or inside another frame (the Companion window's Settings tab).
--
--   WC.SettingsPage.Add(row)     row: { kind = "dropdown" | "slider" | "button",
--                                section (its header), label, text (its note),
--                                order (lower first; a section goes where its
--                                first row does), and by kind:
--                                options()/get()/set(name);
--                                min, max, steps, get()/set(value), format(value);
--                                button (its text), onClick() }
--   WC.SettingsPage.Open()       the page in its own window
--   WC.SettingsPage.ShowIn(f)    the page inside frame f (anchored to fill it)

local Page = {}
WC.SettingsPage = Page

local rows = {}    -- every row added: { row = the caller's table, frame = once made }
local headers = {} -- section name -> header frame
local ROW_H, HEADER_H, CONTROL_W = 36, 36, 250
-- Blizzard's columns: the label from the left to the middle, the control from
-- just left of the middle (SettingsListElementMixin, SettingsSliderControlMixin)
local LABEL_X, CONTROL_X = 24, -80

local page = CreateFrame("Frame", "WowCompanionSettingsPage", UIParent)
page:Hide()

local function divider(parent)
	local d = parent:CreateTexture(nil, "ARTWORK")
	d:SetAtlas("QuestLog-frame-devider")
	d:SetAlpha(0.8)
	d:SetHeight(15)
	-- edge to edge of the well's backing (the page sits 9 px inside it)
	d:SetPoint("LEFT", parent, "TOPLEFT", -9, 0)
	d:SetPoint("RIGHT", parent, "TOPRIGHT", 9, 0)
	return d
end

-- the band at the foot: the note of the row under the cursor or the mouse
local band = CreateFrame("Frame", nil, page)
band:SetPoint("BOTTOMLEFT", 0, 0)
band:SetPoint("BOTTOMRIGHT", 0, 0)
band:SetHeight(48)

-- the rows above it, in a scroll frame the controller's cursor scrolls as it
-- moves (SmartNavigation's HandleScroll); 9 px wider each side than the page
-- so the dividers reach the backing's edge without being clipped
local scroll = CreateFrame("ScrollFrame", nil, page)
scroll:SetPoint("TOPLEFT", -9, 0)
scroll:SetPoint("BOTTOMRIGHT", band, "TOPRIGHT", 9, 2)
local content = CreateFrame("Frame", nil, scroll)
content:SetSize(1, 1)
scroll:SetScrollChild(content)
scroll:SetScript("OnSizeChanged", function(_, w) content:SetWidth(w) end)
scroll:EnableMouseWheel(true)
scroll:SetScript("OnMouseWheel", function(self, delta)
	local most = math.max(0, content:GetHeight() - self:GetHeight())
	self:SetVerticalScroll(math.min(most, math.max(0, self:GetVerticalScroll() - delta * ROW_H)))
end)
local bandLine = divider(band)
local bandText = band:CreateFontString(nil, "OVERLAY", "GameFontHighlightMed2")
bandText:SetPoint("TOPLEFT", LABEL_X, -14)
bandText:SetPoint("BOTTOMRIGHT", -LABEL_X, 4)
bandText:SetJustifyH("LEFT")
bandText:SetJustifyV("TOP")
-- nothing focused, nothing shown: no line over an empty band
local function describe(row)
	local text = row and row.text
	bandText:SetText(text or "")
	bandLine:SetShown(text ~= nil)
end

-- One setting as Blizzard's Settings lay one out (SettingsListElementTemplate):
-- a row the width of the page holding its name and its control; the row is the
-- one stop, shaded white at 0.1 while the cursor or the mouse is on it (their
-- HoverBackgroundTemplate), the cursor just left of its name. The control
-- inside is out of the cycle, as theirs is.
local function settingRow(row, step, prompt)
	local r = CreateFrame("Button", nil, content)
	r:SetPoint("RIGHT", content, "RIGHT", -9, 0)
	r:SetHeight(ROW_H)
	local hover = r:CreateTexture(nil, "HIGHLIGHT")
	hover:SetPoint("TOPLEFT", -9, -3)
	hover:SetPoint("BOTTOMRIGHT", 9, 3)
	hover:SetColorTexture(1, 1, 1, 0.1)
	local fs = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	fs:SetPoint("LEFT", LABEL_X, 0)
	fs:SetPoint("RIGHT", r, "CENTER", CONTROL_X - 5, 0)
	fs:SetJustifyH("LEFT")
	fs:SetWordWrap(false)
	fs:SetText(row.label)
	r:SetScript("OnEnter", function() describe(row) end)
	r.OnRowFocus = function() describe(row) end
	WC.SetCursorAnchor(r, LABEL_X - 6)
	WC.RowStop(r, step, prompt)
	return r
end
local function place(r, control)
	control:SetPoint("LEFT", r, "CENTER", CONTROL_X, 0)
end

-- A choice from a list: their dropdown with steppers
-- (SettingsDropdownWithButtonsTemplate's own), its menu the game's. Left and
-- right are the steppers, confirm opens the menu the way their gamepad footer
-- does (MouseDown, MouseUp). A pick does not refresh the steppers by itself
-- (Settings re-inits on every change), so each pick signals the dropdown
-- again, or an end's disabled arrow stays disabled.
local function dropdown(row)
	local control
	local r = settingRow(row, function(dir)
		if dir < 0 then control.DecrementButton:Click() else control.IncrementButton:Click() end
	end, "Change")
	control = CreateFrame("Frame", nil, r, "Metal2DropdownWithSteppersAndLabelTemplate")
	local dd = control.Dropdown
	-- the steppers either side, inside the column's width
	dd:SetWidth(CONTROL_W - 50)
	control:SetSize(CONTROL_W, 26)
	place(r, control)
	dd:SetupMenu(function(_, root)
		for _, name in ipairs(row.options()) do
			root:CreateRadio(name, function(n) return n == row.get() end, function(n) row.set(n) dd:SignalUpdate() end, name)
		end
	end)
	control:SetSteppersShown(true)
	WC.MarkIgnored(control)
	r:SetScript("OnClick", function() dd:MouseDown() dd:MouseUp() end)
	return r
end

-- A number in a range: their slider with steppers, its value after it; left
-- and right step it as their footer does (OnStepperClicked).
local function slider(row)
	local s
	local r = settingRow(row, function(dir) s:OnStepperClicked(dir > 0) end, "Adjust")
	s = CreateFrame("Frame", nil, r, "MinimalSliderWithSteppersTemplate")
	s:SetWidth(CONTROL_W)
	place(r, s)
	local formatters = {
		[MinimalSliderWithSteppersMixin.Label.Right] = CreateMinimalSliderFormatter(MinimalSliderWithSteppersMixin.Label.Right, row.format),
	}
	s:Init(row.get(), row.min, row.max, row.steps, formatters)
	s:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, value) row.set(value) end, s)
	if s.RightText then s.RightText:SetFontObject("GameFontHighlight") end
	WC.MarkIgnored(s)
	return r
end

-- An action: their button in the control column (SettingsButtonControlTemplate),
-- footer-sized (their Defaults button is 96 x 22) so a rarely used action is
-- not the loudest thing on the page; confirm on the row presses it.
local function button(row)
	local r = settingRow(row)
	local b = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
	b:SetSize(120, 22)
	place(r, b)
	b:SetText(row.button)
	b:SetScript("OnClick", row.onClick)
	r:SetScript("OnClick", row.onClick)
	WC.MarkIgnored(b)
	return r
end

local KINDS = { dropdown = dropdown, slider = slider, button = button }

local function header(name)
	if headers[name] then return headers[name] end
	local h = CreateFrame("Frame", nil, content, "SettingsListSectionHeaderTemplate")
	h:SetPoint("RIGHT", content, "RIGHT", -9, 0)
	h.Title:SetText(name)
	h.divider = divider(h)
	headers[name] = h
	return h
end

-- Every row made once; the page laid out again whenever one is added:
-- sections in the order of their first row, rows in order within each, a
-- divider between sections (over every header but the first).
local function sectionOf(e) return e.row.section or "General" end
local function orderOf(e) return e.row.order or 50 end
local function layout()
	for _, e in ipairs(rows) do
		if not e.frame then
			local ok, made = pcall(KINDS[e.row.kind] or button, e.row)
			if ok then e.frame = made
			else geterrorhandler()(("settings row %s: %s"):format(tostring(e.row.label), tostring(made))) end
		end
	end
	local first = {}
	for _, e in ipairs(rows) do
		local s = sectionOf(e)
		first[s] = math.min(first[s] or math.huge, orderOf(e))
	end
	table.sort(rows, function(a, b)
		local sa, sb = sectionOf(a), sectionOf(b)
		if sa ~= sb then
			if first[sa] ~= first[sb] then return first[sa] < first[sb] end
			return sa < sb
		end
		return orderOf(a) < orderOf(b)
	end)
	local y, section = 0, nil
	for _, e in ipairs(rows) do
		if e.frame then
			local s = sectionOf(e)
			if s ~= section then
				local h = header(s)
				h.divider:SetShown(section ~= nil)
				section = s
				h:SetPoint("TOPLEFT", 9, -y)
				y = y + HEADER_H
			end
			e.frame:SetPoint("TOPLEFT", 9, -y)
			y = y + ROW_H
		end
	end
	content:SetHeight(math.max(y, 1))
end
page:SetScript("OnShow", function()
	layout()
	describe(nil)
end)

function Page.Add(row)
	rows[#rows + 1] = { row = row }
	if page:IsShown() then layout() end
end

-- frame is the page's area: its holder decides the margin (the Companion
-- window's pages already sit 12 px inside their well)
function Page.ShowIn(frame)
	page:SetParent(frame)
	page:ClearAllPoints()
	page:SetAllPoints()
	page:Show()
end

-- Its own window, a UI panel the controller's focus cycle reaches, in
-- Blizzard's panel art.
local window
local function buildWindow()
	local made, f = pcall(CreateFrame, "Frame", "WowCompanionSettings", UIParent, "ButtonFrameTemplate")
	if not made or not f then f = CreateFrame("Frame", "WowCompanionSettings", UIParent) end
	f:SetSize(560, 360)
	f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -116)
	f:SetFrameStrata("DIALOG")
	f:SetClampedToScreen(true)
	f:Hide()
	WC.Style.NoPortrait(f)
	if f.SetTitle then f:SetTitle("WoW Companion settings") end
	if f.CloseButton then f.CloseButton:SetScript("OnClick", function() f:Hide() end) end
	local well = CreateFrame("Frame", nil, f.Inset or f)
	well:SetPoint("TOPLEFT", 12, -10)
	well:SetPoint("BOTTOMRIGHT", -12, 10)
	WC.MarkFocusable(f)
	if UIPanelWindows then
		UIPanelWindows["WowCompanionSettings"] = { area = "left", pushable = 1, whileDead = 1, allowOtherPanels = 1 }
	end
	f:SetScript("OnHide", function(self) WC.FrameHidden(self) end)
	f.well = well
	return f
end

function Page.Open()
	window = window or buildWindow()
	Page.ShowIn(window.well)
	WC.ShowPanel(window)
end

-- Blizzard's Settings, AddOns: one category with one button that opens the
-- page. Registered through Blizzard's addon API; nothing of theirs is opened
-- or changed by our code.
local login = CreateFrame("Frame")
login:RegisterEvent("PLAYER_LOGIN")
login:SetScript("OnEvent", function()
	if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
	local canvas = CreateFrame("Frame")
	local made, open = pcall(CreateFrame, "Button", nil, canvas, "UIPanelButtonTemplate")
	if not made or not open then return end
	open:SetSize(260, 26)
	open:SetPoint("TOPLEFT", 16, -16)
	open:SetText("Open WoW Companion settings")
	open:SetScript("OnClick", Page.Open)
	WC.MarkFocusable(open)
	pcall(function()
		Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(canvas, "WoW Companion"))
	end)
end)
