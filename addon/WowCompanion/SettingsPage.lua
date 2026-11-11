-- The settings page: one column of rows in Blizzard's look, each row one
-- controller stop (Rows.lua: left and right change it, confirm opens a
-- dropdown's list, up and down move between rows). Owned by Core so it works
-- without the Agent; each addon adds its own rows. Shown in a window of its own
-- (the minimap mark, Blizzard's AddOns settings) or inside another frame (the
-- Companion window's Settings tab), one page moved between them.
--
--   WC.SettingsPage.Add(row)     row: { kind = "dropdown" | "slider" | "button",
--                                label, text (the note beside it), order (lower
--                                first), and by kind: options()/get()/set(name);
--                                min, max, steps, get()/set(value), format(value);
--                                onClick() }
--   WC.SettingsPage.Open()       the page in its own window
--   WC.SettingsPage.ShowIn(f)    the page inside frame f (anchored to fill it)

local Page = {}
WC.SettingsPage = Page

local pending = {} -- rows added and not placed yet
local LABEL_W, CONTROL_W = 130, 190

local page = CreateFrame("Frame", "WowCompanionSettingsPage", UIParent)
page:Hide()
local y = 0

local function note(anchor, text)
	if not text then return end
	local fs = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetPoint("LEFT", anchor, "RIGHT", 12, 0)
	fs:SetPoint("RIGHT", page, "RIGHT", 0, 0)
	fs:SetJustifyH("LEFT")
	fs:SetText(text)
end
-- one setting: its name on the left, the control beside it, a note after
local function label(text, height)
	local fs = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	fs:SetPoint("TOPLEFT", 0, -y - 6)
	fs:SetWidth(LABEL_W)
	fs:SetJustifyH("LEFT")
	fs:SetText(text)
	local top = y
	y = y + (height or 34)
	return top
end

-- A choice from a list, as a dropdown built from parts the controller already
-- reaches: a plain Button in Blizzard's dropdown art showing the current
-- value; confirm opens a list of UIPanelButtons under it, picking one sets it.
local openList
local function dropdown(row)
	local top = label(row.label)
	local d = CreateFrame("Button", nil, page)
	d:SetSize(CONTROL_W, 26)
	d:SetPoint("TOPLEFT", LABEL_W, -top)
	local bg = d:CreateTexture(nil, "BACKGROUND")
	bg:SetAtlas("common-dropdown-textholder")
	bg:SetAllPoints()
	local arrow = d:CreateTexture(nil, "ARTWORK")
	arrow:SetAtlas("common-dropdown-a-button", true)
	arrow:SetPoint("RIGHT", -2, -1)
	local hl = d:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAtlas("common-dropdown-textholder")
	hl:SetAllPoints()
	hl:SetBlendMode("ADD")
	hl:SetAlpha(0.35)
	local value = d:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	value:SetPoint("LEFT", 10, 0)
	value:SetPoint("RIGHT", arrow, "LEFT", -4, 0)
	value:SetJustifyH("LEFT")
	local function show() value:SetText(row.get() or "") end
	show()
	local made, list = pcall(CreateFrame, "Frame", nil, page, "InsetFrameTemplate")
	if not made or not list then list = CreateFrame("Frame", nil, page) end
	list:SetPoint("TOPLEFT", d, "BOTTOMLEFT", 0, -2)
	list:SetFrameStrata("DIALOG")
	list:Hide()
	local back = list:CreateTexture(nil, "BACKGROUND", nil, -1)
	back:SetColorTexture(0, 0, 0, 0.92)
	back:SetAllPoints()
	local items = {}
	local function close()
		list:Hide()
		if openList == list then openList = nil end
	end
	local function choose(name)
		row.set(name)
		show()
	end
	local function fill()
		for _, b in ipairs(items) do b:Hide() end
		local names = row.options()
		for i, name in ipairs(names) do
			local b = items[i]
			if not b then
				local ok, nb = pcall(CreateFrame, "Button", nil, list, "UIPanelButtonTemplate")
				if not ok or not nb then return end
				b = nb
				b:SetSize(CONTROL_W - 12, 24)
				b:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 26)
				WC.MarkFocusable(b)
				items[i] = b
			end
			b:SetText((name == row.get() and "> " or "") .. name)
			b:SetScript("OnClick", function() choose(name) close() end)
			b:Show()
		end
		list:SetSize(CONTROL_W, 12 + #names * 26)
	end
	d:SetScript("OnClick", function()
		if list:IsShown() then return close() end
		if openList then openList:Hide() end
		fill()
		list:Show()
		openList = list
	end)
	d:SetScript("OnShow", show)
	page:HookScript("OnHide", close)
	note(d, row.text)
	-- one row: left and right cycle the choices, confirm opens the list
	WC.RowStop(d, function(dir)
		local names, at = row.options(), 1
		for i, name in ipairs(names) do if name == row.get() then at = i end end
		local name = names[(at - 1 + dir) % #names + 1]
		if name then choose(name) end
	end, "Change")
end

-- a number in a range: Blizzard's slider with steppers either side
local function slider(row)
	local top = label(row.label, 38)
	local made, s = pcall(CreateFrame, "Frame", nil, page, "MinimalSliderWithSteppersTemplate")
	if not made or not s then return end
	s:SetWidth(CONTROL_W)
	s:SetPoint("TOPLEFT", LABEL_W, -top - 2)
	local formatters = MinimalSliderWithSteppersMixin and {
		[MinimalSliderWithSteppersMixin.Label.Right] = CreateMinimalSliderFormatter
			and CreateMinimalSliderFormatter(MinimalSliderWithSteppersMixin.Label.Right, row.format) or row.format,
	}
	s:Init(row.get(), row.min, row.max, row.steps, formatters)
	s:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, value) row.set(value) end, s)
	note(s.RightText or s, row.text)
	WC.SliderStop(s)
end

local function button(row)
	local made, b = pcall(CreateFrame, "Button", nil, page, "UIPanelButtonTemplate")
	if not made or not b then return end
	b:SetSize(LABEL_W + CONTROL_W, 26)
	b:SetPoint("TOPLEFT", 0, -y)
	b:SetText(row.label)
	b:SetScript("OnClick", row.onClick)
	note(b, row.text)
	WC.MarkFocusable(b)
	y = y + 34
end

local KINDS = { dropdown = dropdown, slider = slider, button = button }

-- rows are placed when the page is shown, in order; one added later goes
-- below them
local function build()
	table.sort(pending, function(a, b) return (a.order or 50) < (b.order or 50) end)
	for _, row in ipairs(pending) do
		local ok, err = pcall(KINDS[row.kind] or button, row)
		if not ok then geterrorhandler()(("settings row %s: %s"):format(tostring(row.label), tostring(err))) end
	end
	pending = {}
	page:SetHeight(math.max(y, 1))
end
page:SetScript("OnShow", build)

function Page.Add(row)
	pending[#pending + 1] = row
	if page:IsShown() then build() end
end

function Page.ShowIn(frame)
	page:SetParent(frame)
	page:ClearAllPoints()
	page:SetPoint("TOPLEFT", 12, -10)
	page:SetPoint("BOTTOMRIGHT", -12, 10)
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
	if ButtonFrameTemplate_HidePortrait and f.PortraitContainer then ButtonFrameTemplate_HidePortrait(f) end
	if f.SetTitle then f:SetTitle("WoW Companion settings") end
	if f.CloseButton then f.CloseButton:SetScript("OnClick", function() f:Hide() end) end
	local well = f.Inset or f
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
