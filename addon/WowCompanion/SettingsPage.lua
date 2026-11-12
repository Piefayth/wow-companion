-- The settings page: one column of settings rows in our window, each row one
-- controller stop (Rows.lua: left and right change it, confirm opens a
-- dropdown's menu or presses a button, up and down move between rows). The
-- page holds them on a spine: a strip of the dark stone down the left, edged
-- by a column rule, the section names on it beside their rows; the rows run
-- from the spine to the right edge, name at the spine, control at the edge,
-- a quest log divider between sections growing out of the spine's edge (the
-- player's pick from the Settings looks sheet, 2026-11-11). The focused row's
-- note is read in a band at the foot, where Blizzard shows a tooltip.
-- Owned by Core so it works without the Agent; each addon adds its own rows.
-- Shown in a window of its own (the minimap mark, Blizzard's AddOns settings)
-- or inside another frame (the Companion window's Settings tab).
--
--   WC.SettingsPage.Add(row)     row: { kind = "dropdown" | "slider" | "button",
--                                section (its name on the spine), label, text
--                                (its note), order (lower first; a section goes
--                                where its first row does), and by kind:
--                                options()/get()/set(name);
--                                min, max, steps, get()/set(value), format(value);
--                                button (its text), onClick() }
--   WC.SettingsPage.Open()       the page in its own window
--   WC.SettingsPage.ShowIn(f)    the page inside frame f (anchored to fill it)

local Page = {}
WC.SettingsPage = Page

local rows = {}    -- every row added: { row = the caller's table, frame = once made }
local headers = {} -- section name -> its name on the spine
local ROW_H, GAP, CONTROL_W = 36, 24, 250
-- the spine's width from the page's left; the name's inset from the spine;
-- the control's inset from the right edge (a slider's value text after it)
local SPINE, LABEL_X, EDGE, VALUE_W = 170, 10, 8, 32

local page = CreateFrame("Frame", "WowCompanionSettingsPage", UIParent)
page:Hide()

local function stone(tex, which)
	tex:SetTexture(WC.Style.STONE[which], "REPEAT", "REPEAT")
	tex:SetHorizTile(true)
	tex:SetVertTile(true)
end

-- the spine, to the backing's edges (9 px outside the page left, 7 above and
-- below), fixed while the rows scroll
local spine = page:CreateTexture(nil, "BACKGROUND", nil, 1)
stone(spine, "you")
spine:SetPoint("TOPLEFT", -9, 7)
spine:SetPoint("BOTTOMRIGHT", page, "BOTTOMLEFT", SPINE - 2, -7)
local spineRule = page:CreateTexture(nil, "ARTWORK")
spineRule:SetAtlas("spec-columndivider")
spineRule:SetWidth(7)
spineRule:SetPoint("TOPLEFT", spine, "TOPRIGHT", -3, 0)
spineRule:SetPoint("BOTTOMLEFT", spine, "BOTTOMRIGHT", -3, 0)

-- the band at the foot, right of the spine: the note of the row under the
-- cursor or the mouse
local band = CreateFrame("Frame", nil, page)
band:SetPoint("BOTTOMLEFT", SPINE, 0)
band:SetPoint("BOTTOMRIGHT", 0, 0)
band:SetHeight(48)
local bandText = band:CreateFontString(nil, "OVERLAY", "GameFontHighlightMed2")
bandText:SetPoint("TOPLEFT", LABEL_X, -8)
bandText:SetPoint("BOTTOMRIGHT", -EDGE, 4)
bandText:SetJustifyH("LEFT")
bandText:SetJustifyV("TOP")
-- with no row under the cursor, what the band is for, dimmed
local function describe(row)
	if row and row.text then
		bandText:SetText(row.text)
		bandText:SetTextColor(1, 1, 1)
	else
		bandText:SetText("Move onto a setting to read what it does.")
		bandText:SetTextColor(0.5, 0.5, 0.5)
	end
end

-- the rows and section names above it, in a scroll frame the controller's
-- cursor scrolls as it moves (SmartNavigation's HandleScroll); 9 px wider
-- each side than the page so the dividers reach the backing's edge
local scroll = CreateFrame("ScrollFrame", nil, page)
scroll:SetPoint("TOPLEFT", -9, 0)
scroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 9, 50)
local content = CreateFrame("Frame", nil, scroll)
content:SetSize(1, 1)
scroll:SetScrollChild(content)
scroll:SetScript("OnSizeChanged", function(_, w) content:SetWidth(w) end)
scroll:EnableMouseWheel(true)
scroll:SetScript("OnMouseWheel", function(self, delta)
	local most = math.max(0, content:GetHeight() - self:GetHeight())
	self:SetVerticalScroll(math.min(most, math.max(0, self:GetVerticalScroll() - delta * ROW_H)))
end)

-- One setting: a row from the spine to the right edge, its name at the spine
-- and its control at the edge; the row is the one stop, shaded white at 0.1
-- while the cursor or the mouse is on it (Blizzard's HoverBackgroundTemplate),
-- the cursor just left of its name. The control inside is out of the cycle,
-- as in Blizzard's Settings.
local function settingRow(row, step, prompt)
	local r = CreateFrame("Button", nil, content)
	r:SetPoint("RIGHT", content, "RIGHT", -9, 0)
	r:SetHeight(ROW_H)
	local hover = r:CreateTexture(nil, "HIGHLIGHT")
	hover:SetPoint("TOPLEFT", 2, -3)
	hover:SetPoint("BOTTOMRIGHT", 9, 3)
	hover:SetColorTexture(1, 1, 1, 0.1)
	local fs = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	fs:SetPoint("LEFT", LABEL_X, 0)
	fs:SetPoint("RIGHT", r, "RIGHT", -(CONTROL_W + VALUE_W + EDGE + 12), 0)
	fs:SetJustifyH("LEFT")
	fs:SetWordWrap(false)
	fs:SetText(row.label)
	r:SetScript("OnEnter", function() describe(row) end)
	r.OnRowFocus = function() describe(row) end
	WC.SetCursorAnchor(r, LABEL_X - 4)
	WC.RowStop(r, step, prompt)
	return r
end
-- the control against the right edge; a slider leaves room for its value
local function place(r, control, value)
	control:SetPoint("RIGHT", r, "RIGHT", -(EDGE + (value and VALUE_W or 0)), 0)
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
	-- the steppers either side, inside the control's width
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
	place(r, s, true)
	local formatters = {
		[MinimalSliderWithSteppersMixin.Label.Right] = CreateMinimalSliderFormatter(MinimalSliderWithSteppersMixin.Label.Right, row.format),
	}
	s:Init(row.get(), row.min, row.max, row.steps, formatters)
	s:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, value) row.set(value) end, s)
	if s.RightText then s.RightText:SetFontObject("GameFontHighlight") end
	WC.MarkIgnored(s)
	return r
end

-- An action: their button where the other rows have their control
-- (SettingsButtonControlTemplate), footer-sized (their Defaults button is 96 x 22) so a rarely used action is
-- not the loudest thing on the page; confirm on the row presses it.
local function button(row)
	local r = settingRow(row)
	local b = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
	b:SetSize(120, 22)
	-- level with the dropdowns' outer arrows, which overhang their frame
	b:SetPoint("RIGHT", r, "RIGHT", -(EDGE - 5), 0)
	b:SetText(row.button)
	b:SetScript("OnClick", row.onClick)
	r:SetScript("OnClick", row.onClick)
	WC.MarkIgnored(b)
	return r
end

local KINDS = { dropdown = dropdown, slider = slider, button = button }

-- a section's name on the spine, right-aligned beside its first row, and the
-- divider over the section (shown for every section but the first), from the
-- spine's edge to the backing's right edge
local function header(name)
	if headers[name] then return headers[name] end
	local h = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightMed2")
	h:SetWidth(SPINE - 24)
	h:SetJustifyH("RIGHT")
	h:SetText(name)
	h.divider = content:CreateTexture(nil, "ARTWORK")
	h.divider:SetAtlas("QuestLog-frame-devider")
	h.divider:SetAlpha(0.8)
	h.divider:SetHeight(15)
	headers[name] = h
	return h
end

-- Every row made once; the page laid out again whenever one is added:
-- sections in the order of their first row, rows in order within each, a gap
-- and a divider between sections.
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
	local y, section = 6, nil
	for _, e in ipairs(rows) do
		if e.frame then
			local s = sectionOf(e)
			if s ~= section then
				local h = header(s)
				if section then y = y + GAP end
				h.divider:SetShown(section ~= nil)
				h.divider:ClearAllPoints()
				h.divider:SetPoint("LEFT", content, "TOPLEFT", 9 + SPINE, -y + GAP / 2)
				h.divider:SetPoint("RIGHT", content, "TOPRIGHT", 0, -y + GAP / 2)
				section = s
				h:SetPoint("TOPRIGHT", content, "TOPLEFT", 9 + SPINE - 18, -y - 10)
			end
			e.frame:SetPoint("TOPLEFT", 9 + SPINE, -y)
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
	-- the light stone 3 px inside the inset, the page 12 / 10 inside it, as
	-- in the Companion window's page well
	local inset = f.Inset or f
	local back = inset:CreateTexture(nil, "BACKGROUND", nil, 1)
	stone(back, "claude")
	back:SetPoint("TOPLEFT", 3, -3)
	back:SetPoint("BOTTOMRIGHT", -3, 3)
	local well = CreateFrame("Frame", nil, inset)
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
