-- The settings page: one column of settings rows in our window, each row one
-- controller stop (Rows.lua: left and right change it, confirm opens a
-- dropdown's menu or presses a button, up and down move between rows). The
-- page is three sunk wells (below): the section names down the left beside
-- their rows; the rows from there to the right edge, name at the left,
-- control at the edge, the chat's vine between sections; the focused
-- row's note in the well under them, its name in gold, where Blizzard shows
-- a tooltip.
-- Owned by Core so it works without the Agent; each addon adds its own rows.
-- Shown in a window of its own (the minimap mark, Blizzard's AddOns settings)
-- or inside another frame (the Companion window's Settings tab).
--
--   WC.SettingsPage.Add(row)     row: { kind = "dropdown" | "slider" | "button" | "key",
--                                section (its name in the names well), label, text
--                                (its note, or a function giving it), order (lower
--                                first; a section goes where its first row does),
--                                and by kind:
--                                options()/get()/set(name);
--                                min, max, steps, get()/set(value), format(value);
--                                button (its text, or a function giving it), onClick();
--                                key: as button, drawn as Blizzard's key-binding button }
--   WC.SettingsPage.Refresh()    the rows' values and notes drawn again, for rows
--                                whose values change by themselves
--   WC.SettingsPage.Open()       the page in its own window
--   WC.SettingsPage.ShowIn(f)    the page inside frame f (anchored to fill it)

local Page = {}
WC.SettingsPage = Page

local rows = {}    -- every row added: { row = the caller's table, frame = once made }
local refreshers = {} -- one per made row whose shown value can change
local headers = {} -- section name -> its name in the names well
-- the controls 200 wide: Blizzard's 250 is for a 920-wide Settings window;
-- in ours it took half of each row and dwarfed the names
local ROW_H, GAP, CONTROL_W = 36, 24, 200
-- the names well's width from the page's left; a row's name inset from it;
-- the control's inset from the right edge (a slider's value text after it)
local SPINE, LABEL_X, EDGE, VALUE_W = 170, 10, 8, 32

local page = CreateFrame("Frame", "WowCompanionSettingsPage", UIParent)
page:Hide()

local function stone(tex, which)
	tex:SetTexture(WC.Style.STONE[which], "REPEAT", "REPEAT")
	tex:SetHorizTile(true)
	tex:SetVertTile(true)
end

-- Three wells, as the Chat tab is made of wells: the section names down the
-- left on the dark stone, the settings on the light stone, the focused row's
-- note under them on the dark (its name in gold), so the note has a place of
-- its own. The window's rock shows in a seam between them; each well is sunk
-- by a soft shadow inside its top and left edges, light falling from the top
-- left, no rim (the player's pick from the Settings looks sheet, 2026-11-12).
-- To the backing's edges (9 px outside the page each side, 7 above and
-- below); fixed while the rows scroll.
local FOOT, SEAM, SHADE = 58, 3, 12
local band = CreateFrame("Frame", nil, page)
band:SetPoint("BOTTOMLEFT", SPINE, 0)
band:SetPoint("BOTTOMRIGHT", 0, 0)
band:SetHeight(FOOT)
local rock = page:CreateTexture(nil, "BACKGROUND", nil, 0)
rock:SetTexture([[Interface\FrameGeneral\UI-Background-Rock]], "REPEAT", "REPEAT")
rock:SetHorizTile(true)
rock:SetVertTile(true)
rock:SetPoint("TOPLEFT", -9, 7)
rock:SetPoint("BOTTOMRIGHT", 9, -7)
local function well(which, left, top, right, bottom)
	local t = page:CreateTexture(nil, "BACKGROUND", nil, 1)
	stone(t, which)
	t:SetPoint("TOPLEFT", left[1], left[2], left[3], top)
	t:SetPoint("BOTTOMRIGHT", right[1], right[2], right[3], bottom)
	for _, side in ipairs({ "Top", "Left" }) do
		local shade = page:CreateTexture(nil, "BACKGROUND", nil, 2)
		shade:SetTexture([[Interface\Common\ShadowOverlay-]] .. side)
		shade:SetAlpha(0.7)
		shade:SetPoint("TOPLEFT", t)
		shade:SetPoint(side == "Top" and "TOPRIGHT" or "BOTTOMLEFT", t)
		if side == "Top" then shade:SetHeight(SHADE) else shade:SetWidth(SHADE) end
	end
end
-- names: the left edge to the seam; settings: the seam to the right edge,
-- down to the note's seam; the note: under the settings
well("you", { page, "TOPLEFT", -9 }, 7, { page, "BOTTOMLEFT", SPINE - 2 - SEAM }, -7)
well("claude", { page, "TOPLEFT", SPINE - 2 }, 7, { band, "TOPRIGHT", 9 }, SEAM)
well("you", { band, "TOPLEFT", -2 }, 0, { band, "BOTTOMRIGHT", 9 }, -7)
local bandName = band:CreateFontString(nil, "OVERLAY", "GameFontNormal")
bandName:SetPoint("TOPLEFT", 14, -10)
bandName:SetPoint("RIGHT", -EDGE, 0)
bandName:SetJustifyH("LEFT")
local bandText = band:CreateFontString(nil, "OVERLAY", "GameFontHighlightMed2")
bandText:SetPoint("TOPLEFT", bandName, "BOTTOMLEFT", 0, -4)
bandText:SetPoint("BOTTOMRIGHT", -EDGE, 2)
bandText:SetJustifyH("LEFT")
bandText:SetJustifyV("TOP")
-- a row's note: a string, or a function for one that changes
local function textOf(v)
	if type(v) == "function" then return v() end
	return v
end
-- with no row under the cursor, what the band is for, dimmed
local described
local function describe(row)
	described = row
	if row and row.text then
		bandName:SetText(row.label)
		bandText:SetText(textOf(row.text))
		bandText:SetTextColor(1, 1, 1)
	else
		bandName:SetText("")
		bandText:SetText("Move onto a setting to read what it does.")
		bandText:SetTextColor(0.5, 0.5, 0.5)
	end
end

-- the rows and section names above it, in a scroll frame the controller's
-- cursor scrolls as it moves (SmartNavigation's HandleScroll), 9 px wider
-- each side than the page so the names and dividers reach the edges; the
-- scroll bar down the settings well's right edge, as the chat's (WC.Style)
local column = CreateFrame("Frame", nil, page)
column:SetPoint("TOPRIGHT", 9, 7)
column:SetPoint("BOTTOMRIGHT", band, "TOPRIGHT", 9, SEAM)
column:SetWidth(WC.Style.BAR)
local scroll = CreateFrame("ScrollFrame", nil, page)
scroll:SetPoint("TOPLEFT", -9, 0)
scroll:SetPoint("BOTTOMRIGHT", column, "BOTTOMLEFT", 9, 3)
local content = CreateFrame("Frame", nil, scroll)
content:SetSize(1, 1)
scroll:SetScrollChild(content)
scroll:SetScript("OnSizeChanged", function(_, w) content:SetWidth(w) end)
scroll:EnableMouseWheel(true)
scroll:SetScript("OnMouseWheel", function(self, delta)
	local most = math.max(0, content:GetHeight() - self:GetHeight())
	self:SetVerticalScroll(math.min(most, math.max(0, self:GetVerticalScroll() - delta * ROW_H)))
end)
-- over the rows' 9 px under it, as the dividers run to the backing's edge
WC.Style.ScrollBar(scroll, column, ROW_H)

-- The seams between the wells are the thick vine (WC.Style.VineLine): down
-- between the names and the settings, across between the settings and the
-- note, a T where they meet; over the scrolling rows, under the scroll bar
local seams = CreateFrame("Frame", nil, page)
seams:SetAllPoints()
local down = CreateFrame("Frame", nil, seams)
down:SetWidth(16)
down:SetPoint("TOP", page, "TOPLEFT", SPINE - 2 - SEAM / 2, 7)
down:SetPoint("BOTTOM", page, "BOTTOMLEFT", SPINE - 2 - SEAM / 2, -7)
WC.Style.VineLine(down, "Thick", true, true, true)
local across = CreateFrame("Frame", nil, seams)
across:SetHeight(16)
across:SetPoint("LEFT", band, "TOPLEFT", -2 - SEAM / 2, SEAM / 2)
across:SetPoint("RIGHT", band, "TOPRIGHT", 9, SEAM / 2)
WC.Style.VineLine(across, "Thick", false, false, true)
WC.Style.VineJoin(across, "Thick", "TRightBig", "LEFT")

-- One setting: a row from the names well to the right edge, its name at the left
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
	-- as wide as a slider and its value together, so the left arrows of both
	-- start at one line and both end at the edge
	dd:SetWidth(CONTROL_W + VALUE_W - 50)
	control:SetSize(CONTROL_W + VALUE_W, 26)
	place(r, control)
	dd:SetupMenu(function(_, root)
		for _, name in ipairs(row.options()) do
			root:CreateRadio(name, function(n) return n == row.get() end, function(n) row.set(n) dd:SignalUpdate() end, name)
		end
	end)
	refreshers[#refreshers + 1] = function() dd:GenerateMenu() end
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
	b:SetText(textOf(row.button))
	refreshers[#refreshers + 1] = function() b:SetText(textOf(row.button)) end
	b:SetScript("OnClick", row.onClick)
	r:SetScript("OnClick", row.onClick)
	WC.MarkIgnored(b)
	return r
end

-- A key binding: Blizzard's key-binding button (KeyBindingFrameBindingButtonTemplate
-- is UIMenuButtonStretchTemplate), as wide as the other controls, showing the key
-- as the game does, by its icon.
local function key(row)
	local r = settingRow(row)
	local b = CreateFrame("Button", nil, r, "UIMenuButtonStretchTemplate")
	b:SetSize(CONTROL_W, 24)
	b:SetPoint("RIGHT", r, "RIGHT", -(EDGE - 5), 0)
	b:SetNormalFontObject("GameFontHighlight")
	b:SetHighlightFontObject("GameFontHighlight")
	b:SetText(textOf(row.button))
	refreshers[#refreshers + 1] = function() b:SetText(textOf(row.button)) end
	b:SetScript("OnClick", row.onClick)
	r:SetScript("OnClick", row.onClick)
	WC.MarkIgnored(b)
	return r
end

local KINDS = { dropdown = dropdown, slider = slider, button = button, key = key }

-- a section's name in the names well, right-aligned beside its first row, and the
-- divider over the section (shown for every section but the first), from the
-- spine between the wells to the backing's right edge
local function header(name)
	if headers[name] then return headers[name] end
	local h = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightMed2")
	h:SetWidth(SPINE - 24)
	h:SetJustifyH("RIGHT")
	h:SetText(name)
	-- grown out of the thick spine between the wells, forged into it
	-- (WC.Style.VineJoin): the joint draws its own stretch of the spine, over
	-- the spine as it scrolls past
	h.divider = CreateFrame("Frame", nil, content)
	h.divider:SetHeight(16)
	WC.Style.VineLine(h.divider, "", false, false, true)
	WC.Style.VineJoin(h.divider, "Thick", "TRightFromMediumPlain", "LEFT")
	headers[name] = h
	return h
end

-- Every row made once; the page laid out again whenever one is added:
-- sections in the order of their first row, rows in order within each, a gap
-- and a divider between sections.
local function sectionOf(e) return e.row.section or "General" end
local function orderOf(e) return e.row.order or 50 end
-- The vines and the scroll bar above the drop shadow of whatever window shows
-- the page (the Companion's page well casts one from its top, its level + 20),
-- so the vines' joints read as joined; set on each show, as the page is moved
-- into another frame, which resets levels set before
local LIFT = 25
local function lift()
	local base = page:GetFrameLevel() + LIFT
	-- the joints over the spine: each draws its stretch of the spine
	seams:SetFrameLevel(base)
	down:SetFrameLevel(base)
	across:SetFrameLevel(base + 1)
	for _, h in pairs(headers) do h.divider:SetFrameLevel(base + 1) end
	column:SetFrameLevel(base + 2)
end
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
				h.divider:SetPoint("LEFT", content, "TOPLEFT", 9 + SPINE - 2 - SEAM / 2, -y + GAP / 2)
				h.divider:SetPoint("RIGHT", content, "TOPRIGHT", 0, -y + GAP / 2)
				section = s
				h:SetPoint("TOPRIGHT", content, "TOPLEFT", 9 + SPINE - 18, -y - 10)
			end
			e.frame:SetPoint("TOPLEFT", 9 + SPINE, -y)
			y = y + ROW_H
		end
	end
	content:SetHeight(math.max(y, 1))
	lift()
end
page:SetScript("OnShow", function()
	layout()
	describe(nil)
end)

function Page.Add(row)
	rows[#rows + 1] = { row = row }
	if page:IsShown() then layout() end
end

function Page.Refresh()
	for _, refresh in ipairs(refreshers) do pcall(refresh) end
	if described then describe(described) end
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
