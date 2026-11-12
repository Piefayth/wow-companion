-- The settings page: one column of rows in Blizzard's look, each row one
-- controller stop (Rows.lua: left and right change it, confirm opens a
-- dropdown's menu, up and down move between rows). Owned by Core so it works
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

-- A choice from a list, as Blizzard's Settings show one: their dropdown with
-- steppers (SettingsDropdownWithButtonsTemplate's own), its menu the game's.
-- The row is one stop laid over it, as their settings row is (the control
-- itself out of the cycle): left and right are the steppers, confirm opens the
-- menu the way their gamepad footer does (MouseDown, MouseUp). A pick does not
-- refresh the steppers by itself (Settings re-inits on every change), so each
-- pick signals the dropdown again, or an end's disabled arrow stays disabled.
local function dropdown(row)
	local top = label(row.label)
	local control = CreateFrame("Frame", nil, page, "Metal2DropdownWithSteppersAndLabelTemplate")
	local dd = control.Dropdown
	dd:SetWidth(CONTROL_W - 50)
	control:SetSize(CONTROL_W, 26)
	control:SetPoint("TOPLEFT", LABEL_W, -top + 1)
	dd:SetupMenu(function(_, root)
		for _, name in ipairs(row.options()) do
			root:CreateRadio(name, function(n) return n == row.get() end, function(n) row.set(n) dd:SignalUpdate() end, name)
		end
	end)
	control:SetSteppersShown(true)
	WC.MarkIgnored(control)
	local stop = CreateFrame("Button", nil, page)
	stop:SetPoint("TOPLEFT", control.DecrementButton, "TOPLEFT", -4, 4)
	stop:SetPoint("BOTTOMRIGHT", control.IncrementButton, "BOTTOMRIGHT", 4, -4)
	stop:SetFrameLevel(control:GetFrameLevel() + 5)
	stop:SetHighlightAtlas("Options_List_Hover", "ADD")
	stop:SetScript("OnClick", function() dd:MouseDown() dd:MouseUp() end)
	note(control.IncrementButton, row.text)
	WC.RowStop(stop, function(dir)
		if dir < 0 then control.DecrementButton:Click() else control.IncrementButton:Click() end
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
