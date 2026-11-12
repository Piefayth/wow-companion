-- A design sheet, for now: the Settings page as built (wells like the Chat
-- tab's), four ways to ground the section names, each a full-size mock-up drawn small so the player
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

-- The page built from wells like the Companion window's own: the panel's rock
-- shows between them, as between the chat and the conversation list; each
-- well a stone, edged by style (below).
-- A layout is a list of wells, each { x, y, w, h, stone, role } in the area
-- the Chat tab's two wells take (TW x TH); role says what it holds: names
-- (the section names), rows, note, or names+rows (the spine inside the well).
local TW, TH, SEP = W + 18, H + 14, 2

-- style: "bevel" Blizzard's inner bevel round the stone; "plain" the stone
-- alone, the rock between wells its only edge; "shade" the stone with a soft
-- shadow inside its top and left edges, sunk without a rim
local function well(mock, w, style)
	local f = CreateFrame("Frame", nil, mock, style == "bevel" and "InsetFrameTemplate" or nil)
	f:SetPoint("TOPLEFT", w[1], -w[2])
	f:SetSize(w[3], w[4])
	local back = f:CreateTexture(nil, "BACKGROUND", nil, 1)
	stone(back, w[5])
	local inset = style == "bevel" and 3 or 0
	back:SetPoint("TOPLEFT", inset, -inset)
	back:SetPoint("BOTTOMRIGHT", -inset, inset)
	if style == "shade" then
		for _, spec in ipairs({ { "Top", "TOPLEFT", "TOPRIGHT", true }, { "Left", "TOPLEFT", "BOTTOMLEFT" } }) do
			local t = f:CreateTexture(nil, "BACKGROUND", nil, 2)
			t:SetTexture([[Interface\Common\ShadowOverlay-]] .. spec[1])
			t:SetAlpha(0.7)
			t:SetPoint(spec[2])
			t:SetPoint(spec[3])
			if spec[4] then t:SetHeight(12) else t:SetWidth(12) end
		end
	end
	return f
end

local function layout(mock, wells, style, dress)
	local rock = mock:CreateTexture(nil, "BACKGROUND", nil, -8)
	rock:SetTexture([[Interface\FrameGeneral\UI-Background-Rock]], "REPEAT", "REPEAT")
	rock:SetHorizTile(true)
	rock:SetVertTile(true)
	rock:SetAllPoints()
	local at = {}
	for _, w in ipairs(wells) do
		local f = well(mock, w, style or "bevel")
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
		local top = y
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
		if dress then dress(mock, names, rows, top, y, head, i) end
	end
end

local FW = FOOT + 6 -- a note well's height

-- Round 4: the page as built (the names down the left, the settings over
-- the note, each well sunk by a soft shadow), four ways to ground each
-- section's name to its section. dress(mock, names, rows, top, bottom, head,
-- i) gets each section's span, in the wells' own y from their tops.
local function threeWells(mock, dress)
	layout(mock, {
		{ 0, 0, SPINE + 6, TH, "you", "names" },
		{ SPINE + 6 + 3, 0, TW - SPINE - 9, TH - FW - 3, "claude", "rows" },
		{ SPINE + 6 + 3, TH - FW, TW - SPINE - 9, FW, "you", "note" },
	}, "shade", dress)
end

local function shade(parent, tex)
	for _, spec in ipairs({ { "Top", "TOPRIGHT" }, { "Left", "BOTTOMLEFT" } }) do
		local t = parent:CreateTexture(nil, "ARTWORK", nil, -1)
		t:SetTexture([[Interface\Common\ShadowOverlay-]] .. spec[1])
		t:SetAlpha(0.7)
		t:SetPoint("TOPLEFT", tex)
		t:SetPoint(spec[2], tex)
		if spec[1] == "Top" then t:SetHeight(12) else t:SetWidth(12) end
	end
end

-- a layer over the names well for a candidate's shapes, under the names
local function over(mock, names)
	local f = CreateFrame("Frame", nil, mock)
	f:SetAllPoints(names)
	f:SetFrameLevel(names:GetFrameLevel() + 1)
	return f
end

local CANDIDATES = {
	-- A. each name on a tab of the light stone that joins its section: the
	-- seam closes beside it, so name and rows are one shape
	{ "Tab: the name joined to its rows", function(mock)
		threeWells(mock, function(m, names, _, top, bottom, head)
			local f = over(m, names)
			local tab = f:CreateTexture(nil, "BACKGROUND")
			stone(tab, "claude")
			tab:SetPoint("TOPLEFT", names, "TOPLEFT", 10, -top + 2)
			tab:SetPoint("BOTTOMRIGHT", names, "TOPRIGHT", 3, -bottom - 2)
			shade(f, tab)
			head:SetParent(f)
			head:SetTextColor(1, 0.82, 0)
		end)
	end },
	-- B. the names column split into a sunk well per section, rock between
	{ "A small well per section in the names column", function(mock)
		threeWells(mock, function(m, names, _, top, bottom, head)
			local f = over(m, names)
			if not names.rocked then
				names.rocked = true
				local rock = f:CreateTexture(nil, "BACKGROUND", nil, -2)
				rock:SetTexture([[Interface\FrameGeneral\UI-Background-Rock]], "REPEAT", "REPEAT")
				rock:SetHorizTile(true)
				rock:SetVertTile(true)
				rock:SetAllPoints(names)
			end
			local w = f:CreateTexture(nil, "BACKGROUND")
			stone(w, "you")
			w:SetPoint("TOPLEFT", names, "TOPLEFT", 0, -top + 4)
			w:SetPoint("BOTTOMRIGHT", names, "TOPRIGHT", 0, -bottom - 4)
			shade(f, w)
			head:SetParent(f)
		end)
	end },
	-- C. a faint band of light behind each section's span in the names column,
	-- the name at its top
	{ "A faint band behind each section's name", function(mock)
		threeWells(mock, function(m, names, _, top, bottom, head)
			local f = over(m, names)
			local band = f:CreateTexture(nil, "BACKGROUND")
			band:SetColorTexture(1, 1, 1, 0.05)
			band:SetPoint("TOPLEFT", names, "TOPLEFT", 8, -top + 2)
			band:SetPoint("BOTTOMRIGHT", names, "TOPRIGHT", 0, -bottom - 2)
			head:SetParent(f)
		end)
	end },
	-- D. the name centred on its section's span, a slim upright rule from
	-- the first row to the last beside it
	{ "Centred on its rows, a slim rule beside", function(mock)
		threeWells(mock, function(m, names, _, top, bottom, head)
			local f = over(m, names)
			local rule = f:CreateTexture(nil, "ARTWORK")
			rule:SetAtlas("Talents-divider-vertical-c60")
			rule:SetWidth(2)
			rule:SetPoint("TOPRIGHT", names, "TOPRIGHT", -8, -top - 6)
			rule:SetPoint("BOTTOMRIGHT", names, "TOPRIGHT", -8, -bottom + 6)
			head:SetParent(f)
			head:ClearAllPoints()
			head:SetPoint("RIGHT", rule, "LEFT", -10, 0)
		end)
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
