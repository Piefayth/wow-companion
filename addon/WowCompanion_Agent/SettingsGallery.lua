-- A design sheet, for now: the Settings page built from wells like the Chat
-- tab's, four ways, each a full-size mock-up drawn small so the player
-- compares them at once. Shown only; nothing here is a stop or changes a setting.
-- Goes when one is chosen.

local W, H = 700, 420                -- the page in each mock-up
local SPINE, FOOT, ROW, GAP = 170, 58, 36, 24

local function stone(tex, which)
	tex:SetTexture(WC.Style.STONE[which], "REPEAT", "REPEAT")
	tex:SetHorizTile(true)
	tex:SetVertTile(true)
end

local SECTIONS = {
	{ "Companion window", {
		{ "Window size", "dropdown", "Medium" },
		{ "Window scale", "slider", 0.58, "150%", focus = true,
			note = "The Companion window and everything in it, apart from the rest of the interface." },
	} },
	{ "Interface text", {
		{ "Font", "dropdown", "Default" },
		{ "Text size", "slider", 0.2, "100%" },
	} },
	{ "Clean up", {
		{ "Clear map pins", "button", "Clear" },
	} },
}

local function text(parent, font, s, r, g, b)
	local fs = parent:CreateFontString(nil, "OVERLAY", font)
	fs:SetText(s)
	if r then fs:SetTextColor(r, g, b) end
	return fs
end

-- the real controls, as on the page: a dropdown as wide as a slider and its value
local function control(parent, spec)
	if spec[2] == "dropdown" then
		local c = CreateFrame("Frame", nil, parent, "Metal2DropdownWithSteppersAndLabelTemplate")
		c:SetSize(282, 26)
		c.Dropdown:SetWidth(232)
		c.Dropdown:SetupMenu(function(_, root)
			root:CreateRadio(spec[3], function() return true end, function() end, spec[3])
		end)
		c:SetSteppersShown(true)
		c:SetPoint("RIGHT", -8, 0)
		return c
	elseif spec[2] == "slider" then
		local s = CreateFrame("Frame", nil, parent, "MinimalSliderWithSteppersTemplate")
		s:SetWidth(250)
		local label = spec[4]
		s:Init(spec[3], 0, 1, 10, {
			[MinimalSliderWithSteppersMixin.Label.Right] = CreateMinimalSliderFormatter(
				MinimalSliderWithSteppersMixin.Label.Right, function() return label end),
		})
		s:SetPoint("RIGHT", -40, 0)
		return s
	end
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(120, 22)
	b:SetText(spec[3])
	b:SetPoint("RIGHT", -3, 0)
	return b
end

-- Round 2: the page built from the Companion window's own wells. The panel's
-- rock shows in the 2 px between wells, as between the chat and the
-- conversation list; each well is Blizzard's inner bevel with a stone in it.
-- A layout is a list of wells, each { x, y, w, h, stone, role } in the area
-- the Chat tab's two wells take (TW x TH); role says what it holds: names
-- (the section names), rows, note, or names+rows (the spine inside the well).
local TW, TH, SEP = W + 18, H + 14, 2

local function well(mock, w)
	local f = CreateFrame("Frame", nil, mock, "InsetFrameTemplate")
	f:SetPoint("TOPLEFT", w[1], -w[2])
	f:SetSize(w[3], w[4])
	local back = f:CreateTexture(nil, "BACKGROUND", nil, 1)
	stone(back, w[5])
	back:SetPoint("TOPLEFT", 3, -3)
	back:SetPoint("BOTTOMRIGHT", -3, 3)
	return f
end

local function layout(mock, wells)
	local rock = mock:CreateTexture(nil, "BACKGROUND", nil, -8)
	rock:SetTexture([[Interface\FrameGeneral\UI-Background-Rock]], "REPEAT", "REPEAT")
	rock:SetHorizTile(true)
	rock:SetVertTile(true)
	rock:SetAllPoints()
	local at = {}
	for _, w in ipairs(wells) do
		local f = well(mock, w)
		for role in w[6]:gmatch("[^+]+") do at[role] = f end
		if w[6] == "names+rows" then
			-- the spine inside the well, its dark stone to a column rule
			local spine = f:CreateTexture(nil, "BACKGROUND", nil, 2)
			stone(spine, "you")
			spine:SetPoint("TOPLEFT", 3, -3)
			spine:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT", SPINE, 3)
			local rule = f:CreateTexture(nil, "ARTWORK")
			rule:SetAtlas("spec-columndivider")
			rule:SetWidth(7)
			rule:SetPoint("TOPLEFT", spine, "TOPRIGHT", -3, 0)
			rule:SetPoint("BOTTOMLEFT", spine, "BOTTOMRIGHT", -3, 0)
		end
	end
	local names, rows, note = at.names, at.rows, at.note
	local nameRight = names == rows and SPINE - 16 or names:GetWidth() - 16
	local rowLeft = names == rows and SPINE + 4 or 6
	local y = 10
	for i, section in ipairs(SECTIONS) do
		if i > 1 then
			y = y + GAP
			local d = rows:CreateTexture(nil, "ARTWORK")
			d:SetAtlas("QuestLog-frame-devider")
			d:SetAlpha(0.8)
			d:SetHeight(15)
			d:SetPoint("LEFT", rows, "TOPLEFT", rowLeft - 2, -y + GAP / 2)
			d:SetPoint("RIGHT", rows, "TOPRIGHT", -3, -y + GAP / 2)
		end
		local head = text(names, "GameFontHighlightMed2", section[1])
		head:SetPoint("TOPRIGHT", names, "TOPLEFT", nameRight, -y - 10)
		for _, spec in ipairs(section[2]) do
			local row = CreateFrame("Frame", nil, rows)
			row:SetPoint("TOPLEFT", rowLeft, -y)
			row:SetPoint("RIGHT", -6, 0)
			row:SetHeight(ROW)
			if spec.focus then
				local hover = row:CreateTexture(nil, "BACKGROUND", nil, 3)
				hover:SetPoint("TOPLEFT", 0, -3)
				hover:SetPoint("BOTTOMRIGHT", 3, 3)
				hover:SetColorTexture(1, 1, 1, 0.1)
				local name = text(note, "GameFontNormal", spec[1])
				name:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 14, FOOT - 6)
				local body = text(note, "GameFontHighlightMed2", spec.note)
				body:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -4)
				body:SetPoint("RIGHT", note, "RIGHT", -10, 0)
				body:SetJustifyH("LEFT")
			end
			text(row, "GameFontNormal", spec[1]):SetPoint("LEFT", 10, 0)
			control(row, spec)
			y = y + ROW
		end
	end
end

local FW = FOOT + 6 -- a note well's height

local CANDIDATES = {
	-- A. two wells as on the Chat tab, mirrored: the spine its own well on the
	-- left, the rows in the big one, the note at the foot of the spine's well
	{ "Two wells: names and note | settings", function(mock)
		layout(mock, {
			{ 0, 0, SPINE + 6, TH, "you", "names+note" },
			{ SPINE + 6 + SEP, 0, TW - SPINE - 6 - SEP, TH, "claude", "rows" },
		})
	end },
	-- B. three wells: the spine down the left, the rows above the note's well
	{ "Three wells: names | settings over the note", function(mock)
		layout(mock, {
			{ 0, 0, SPINE + 6, TH, "you", "names" },
			{ SPINE + 6 + SEP, 0, TW - SPINE - 6 - SEP, TH - FW - SEP, "claude", "rows" },
			{ SPINE + 6 + SEP, TH - FW, TW - SPINE - 6 - SEP, FW, "you", "note" },
		})
	end },
	-- C. three wells: the spine and the rows side by side, the note's well
	-- the full width under both
	{ "Three wells: names | settings, the note under both", function(mock)
		layout(mock, {
			{ 0, 0, SPINE + 6, TH - FW - SEP, "you", "names" },
			{ SPINE + 6 + SEP, 0, TW - SPINE - 6 - SEP, TH - FW - SEP, "claude", "rows" },
			{ 0, TH - FW, TW, FW, "you", "note" },
		})
	end },
	-- D. two wells: the spine inside the settings' well as now, the note in a
	-- well of its own under it
	{ "Two wells: names and settings over the note", function(mock)
		layout(mock, {
			{ 0, 0, TW, TH - FW - SEP, "claude", "names+rows" },
			{ 0, TH - FW, TW, FW, "you", "note" },
		})
	end },
}

local function cell(parent, i, candidate)
	local box = CreateFrame("Frame", nil, parent)
	local label = text(box, "GameFontNormalLarge", ("%s. %s"):format(string.char(64 + i), candidate[1]))
	label:SetPoint("BOTTOMLEFT", box, "TOPLEFT", 2, 4)
	local mock = CreateFrame("Frame", nil, box)
	mock:SetSize(W + 18, H + 14)
	mock:SetPoint("TOPLEFT")
	local ok, err = pcall(candidate[2], mock)
	if not ok then label:SetText(label:GetText() .. " |cffff6060" .. tostring(err) .. "|r") end
	box.mock = mock
	return box
end

WC.Companion.AddTab("Settings looks", function(tab)
	WC.MarkIgnored(tab)
	local boxes = {}
	for i, candidate in ipairs(CANDIDATES) do boxes[i] = cell(tab, i, candidate) end
	local function layout()
		local w, h = tab:GetWidth(), tab:GetHeight()
		if w <= 0 then return end
		local gap, top = 10, 26
		local cw = (w - gap) / 2
		local ch = (h - top * 2 - gap) / 2
		local scale = math.min(cw / (W + 18), ch / (H + 14))
		for i, box in ipairs(boxes) do
			local col, line = (i - 1) % 2, math.floor((i - 1) / 2)
			box:ClearAllPoints()
			box:SetPoint("TOPLEFT", tab, "TOPLEFT", col * (cw + gap), -top - line * (ch + top + gap))
			box:SetSize(cw, ch)
			box.mock:SetScale(scale)
		end
	end
	tab:HookScript("OnSizeChanged", layout)
	tab:HookScript("OnShow", layout)
end)
