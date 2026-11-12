-- A design sheet, for now: the Settings page's edge between the dark stone
-- (the spine and the note's footer, one L) and the light stone the rows sit
-- on, four ways, each a full-size mock-up drawn small so the player compares
-- them at once. Shown only; nothing here is a stop or changes a setting.
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

-- The page as built: dark stone over the whole backing (the L shows where
-- the light does not), the light stone's rectangle given by inset (from the
-- backing's top and right; 0 runs it to the edge), the section names on the
-- spine, the rows on the light, the focused row's note on the footer.
-- edge(mock, light) dresses the edge between them.
local function page(mock, inset, edge)
	local dark = mock:CreateTexture(nil, "BACKGROUND", nil, 0)
	stone(dark, "you")
	dark:SetAllPoints()
	local light = CreateFrame("Frame", nil, mock)
	light:SetPoint("TOPLEFT", 9 + SPINE, -inset)
	light:SetPoint("BOTTOMRIGHT", -inset, 7 + FOOT)
	local back = light:CreateTexture(nil, "BACKGROUND", nil, 1)
	stone(back, "claude")
	back:SetAllPoints()
	edge(mock, light)
	local p = CreateFrame("Frame", nil, mock)
	p:SetPoint("TOPLEFT", 9, -7)
	p:SetSize(W, H)
	p:SetFrameLevel(light:GetFrameLevel() + 10)
	local y = 6 + inset
	for i, section in ipairs(SECTIONS) do
		if i > 1 then
			y = y + GAP
			local d = p:CreateTexture(nil, "ARTWORK")
			d:SetAtlas("QuestLog-frame-devider")
			d:SetAlpha(0.8)
			d:SetHeight(15)
			d:SetPoint("LEFT", p, "TOPLEFT", SPINE + 2, -y + GAP / 2)
			d:SetPoint("RIGHT", p, "TOPRIGHT", 9 - inset - 2, -y + GAP / 2)
		end
		local head = text(p, "GameFontHighlightMed2", section[1])
		head:SetPoint("TOPRIGHT", p, "TOPLEFT", SPINE - 18, -y - 10)
		for _, spec in ipairs(section[2]) do
			local row = CreateFrame("Frame", nil, p)
			row:SetPoint("TOPLEFT", SPINE, -y)
			row:SetPoint("RIGHT", -inset, 0)
			row:SetHeight(ROW)
			if spec.focus then
				local hover = row:CreateTexture(nil, "BACKGROUND")
				hover:SetPoint("TOPLEFT", 2, -3)
				hover:SetPoint("BOTTOMRIGHT", 9, 3)
				hover:SetColorTexture(1, 1, 1, 0.1)
				local name = text(p, "GameFontNormal", spec[1])
				name:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 14, FOOT - 22)
				text(p, "GameFontHighlightMed2", spec.note):SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -4)
			end
			text(row, "GameFontNormal", spec[1]):SetPoint("LEFT", 10, 0)
			control(row, spec)
			y = y + ROW
		end
	end
end

local function nineSlice(light, layout, out)
	local f = CreateFrame("Frame", nil, light)
	f:SetPoint("TOPLEFT", -out, out)
	f:SetPoint("BOTTOMRIGHT", out, -out)
	f:SetFrameLevel(light:GetFrameLevel() + 5)
	NineSliceUtil.ApplyLayoutByName(f, layout)
	return f
end

local CANDIDATES = {
	-- A. the light page sunk into the dark stone: Blizzard's inner bevel
	-- (the window's own wells) around it, a margin of dark all round
	{ "Sunk: the light page set into the dark", function(mock)
		page(mock, 8, function(_, light) nineSlice(light, "InsetFrameTemplate", 0) end)
	end },
	-- B. the light page raised over the dark: it casts a shadow onto the
	-- spine and the footer, running to the backing's edge
	{ "Raised: the light page casts a shadow", function(mock)
		page(mock, 0, function(m, light)
			local left = m:CreateTexture(nil, "BORDER")
			left:SetTexture([[Interface\Common\ShadowOverlay-Right]])
			left:SetWidth(18)
			left:SetPoint("TOPRIGHT", light, "TOPLEFT")
			left:SetPoint("BOTTOMRIGHT", light, "BOTTOMLEFT")
			local below = m:CreateTexture(nil, "BORDER")
			below:SetTexture([[Interface\Common\ShadowOverlay-Top]])
			below:SetHeight(18)
			below:SetPoint("TOPLEFT", light, "BOTTOMLEFT", -18, 0)
			below:SetPoint("TOPRIGHT", light, "BOTTOMRIGHT")
		end)
	end },
	-- C. a thin band of Blizzard's dark metal frames the light page
	{ "Framed: dark metal round the light page", function(mock)
		page(mock, 12, function(_, light) nineSlice(light, "Dialog", 6) end)
	end },
	-- D. the heavy metal frame Blizzard uses on its big panels
	{ "Framed: heavy metal round the light page", function(mock)
		page(mock, 14, function(_, light) nineSlice(light, "GenericMetal", 0) end)
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
