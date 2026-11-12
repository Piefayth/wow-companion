-- A design sheet, for now: candidate layouts of the Settings page side by
-- side, each a full-size mock-up of the same rows drawn small, so the player
-- compares them at once instead of one reload per idea. Shown only; nothing
-- here is a controller stop or changes a setting. Goes when one is chosen.

local W, H = 700, 420 -- each mock-up's own size, drawn scaled into its cell

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
		{ "Clear transcript", "button", "Clear" },
	} },
}

local function text(parent, font, s, r, g, b, a)
	local fs = parent:CreateFontString(nil, "OVERLAY", font)
	fs:SetText(s)
	if r then fs:SetTextColor(r, g, b, a or 1) end
	return fs
end

-- the real controls, showing a value; width as on the page
local function control(parent, spec, width)
	width = width or 250
	if spec[2] == "dropdown" then
		local c = CreateFrame("Frame", nil, parent, "Metal2DropdownWithSteppersAndLabelTemplate")
		c:SetSize(width, 26)
		c.Dropdown:SetWidth(width - 50)
		c.Dropdown:SetupMenu(function(_, root)
			root:CreateRadio(spec[3], function() return true end, function() end, spec[3])
		end)
		c:SetSteppersShown(true)
		return c
	elseif spec[2] == "slider" then
		local s = CreateFrame("Frame", nil, parent, "MinimalSliderWithSteppersTemplate")
		s:SetWidth(width)
		local label = spec[4]
		s:Init(spec[3], 0, 1, 10, {
			[MinimalSliderWithSteppersMixin.Label.Right] = CreateMinimalSliderFormatter(
				MinimalSliderWithSteppersMixin.Label.Right, function() return label end),
		})
		return s
	end
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(120, 22)
	b:SetText(spec[3])
	return b
end

local function value(spec)
	return spec[2] == "slider" and spec[4] or spec[2] == "button" and "" or spec[3]
end

local function hover(row, l, r)
	local t = row:CreateTexture(nil, "BACKGROUND", nil, 1)
	t:SetPoint("TOPLEFT", l or -9, -2)
	t:SetPoint("BOTTOMRIGHT", r or 9, 2)
	t:SetColorTexture(1, 1, 1, 0.1)
end

local CANDIDATES = {}

-- A. What is on the page now
CANDIDATES[1] = { "Now", function(p)
	local y = 0
	for i, section in ipairs(SECTIONS) do
		if i > 1 then
			local d = p:CreateTexture(nil, "ARTWORK")
			d:SetAtlas("QuestLog-frame-devider")
			d:SetAlpha(0.8)
			d:SetHeight(15)
			d:SetPoint("LEFT", p, "TOPLEFT", -9, -y)
			d:SetPoint("RIGHT", p, "TOPRIGHT", 9, -y)
		end
		text(p, "GameFontHighlightLarge", section[1]):SetPoint("TOPLEFT", 7, -y - 16)
		y = y + 36
		for _, spec in ipairs(section[2]) do
			local row = CreateFrame("Frame", nil, p)
			row:SetPoint("TOPLEFT", 0, -y)
			row:SetPoint("RIGHT")
			row:SetHeight(36)
			if spec.focus then hover(row) end
			text(row, "GameFontNormal", spec[1]):SetPoint("LEFT", 24, 0)
			control(row, spec):SetPoint("LEFT", row, "CENTER", -80, 0)
			y = y + 36
		end
	end
	text(p, "GameFontHighlightMed2", SECTIONS[1][2][2].note):SetPoint("BOTTOMLEFT", 24, 14)
end }

-- B. Sentence list, the row you are on lit: every value read as text beside
-- its name; only the focused row shows its control and its note under it
CANDIDATES[2] = { "Values beside names, the focused row lit", function(p)
	local y = 0
	local VALUE_X = 200
	for _, section in ipairs(SECTIONS) do
		text(p, "GameFontHighlightLarge", section[1]):SetPoint("TOPLEFT", 7, -y - 16)
		y = y + 40
		for _, spec in ipairs(section[2]) do
			local h = spec.focus and 56 or 30
			local row = CreateFrame("Frame", nil, p)
			row:SetPoint("TOPLEFT", 0, -y)
			row:SetPoint("RIGHT")
			row:SetHeight(h)
			if spec.focus then
				local glow = row:CreateTexture(nil, "BACKGROUND", nil, 1)
				glow:SetPoint("TOPLEFT", -9, 0)
				glow:SetPoint("BOTTOMRIGHT", 9, 0)
				glow:SetColorTexture(1, 1, 1, 1)
				glow:SetGradient("HORIZONTAL", CreateColor(1, 0.9, 0.6, 0.16), CreateColor(1, 0.9, 0.6, 0))
				text(row, "GameFontNormal", spec[1]):SetPoint("TOPLEFT", 24, -10)
				control(row, spec):SetPoint("TOPLEFT", VALUE_X, -4)
				text(row, "GameFontHighlightSmall", spec.note, 0.75, 0.75, 0.75):SetPoint("TOPLEFT", VALUE_X, -34)
			else
				text(row, "GameFontNormal", spec[1], 1, 0.82, 0, 0.6):SetPoint("LEFT", 24, 0)
				text(row, "GameFontHighlight", value(spec), 0.75, 0.75, 0.75):SetPoint("LEFT", VALUE_X + 30, 0)
			end
			y = y + h
		end
	end
end }

-- C. Book page: one centred column, name and control close, the section
-- titles centred with the divider's ornament at its own size under them
CANDIDATES[3] = { "A centred column, like a book page", function(p)
	local y = 4
	for _, section in ipairs(SECTIONS) do
		local title = text(p, "GameFontHighlightLarge", section[1])
		title:SetPoint("TOP", 0, -y - 8)
		local d = p:CreateTexture(nil, "ARTWORK")
		d:SetAtlas("QuestLog-frame-devider", true)
		d:SetPoint("TOP", title, "BOTTOM", 0, -2)
		y = y + 44
		for _, spec in ipairs(section[2]) do
			local row = CreateFrame("Frame", nil, p)
			row:SetPoint("TOP", 0, -y)
			row:SetSize(440, 34)
			if spec.focus then hover(row, -12, 12) end
			local name = text(row, "GameFontNormal", spec[1])
			name:SetPoint("RIGHT", row, "LEFT", 160, 0)
			control(row, spec, 230):SetPoint("LEFT", 176, 0)
			y = y + 34
		end
	end
end }

-- D. Hanging headings: each section's name in the left margin beside its
-- rows, no rules
CANDIDATES[4] = { "Section names in the margin", function(p)
	local y = 6
	local MARGIN = 170
	for i, section in ipairs(SECTIONS) do
		local head = text(p, "GameFontHighlightMed2", section[1])
		head:SetPoint("TOPRIGHT", p, "TOPLEFT", MARGIN - 16, -y - 10)
		for _, spec in ipairs(section[2]) do
			local row = CreateFrame("Frame", nil, p)
			row:SetPoint("TOPLEFT", MARGIN, -y)
			row:SetPoint("RIGHT")
			row:SetHeight(36)
			if spec.focus then hover(row, -8, 9) end
			text(row, "GameFontNormal", spec[1]):SetPoint("LEFT", 0, 0)
			control(row, spec):SetPoint("LEFT", 150, 0)
			y = y + 36
		end
		y = y + (i < #SECTIONS and 18 or 0)
	end
end }

local function cell(page, i, candidate)
	local box = CreateFrame("Frame", nil, page)
	local label = text(box, "GameFontNormalLarge", ("%s. %s"):format(string.char(64 + i), candidate[1]))
	label:SetPoint("BOTTOMLEFT", box, "TOPLEFT", 2, 4)
	-- the mock-up at full size on the light stone, scaled into the cell
	local mock = CreateFrame("Frame", nil, box)
	mock:SetSize(W + 18, H + 14)
	mock:SetPoint("TOPLEFT")
	local back = mock:CreateTexture(nil, "BACKGROUND")
	stone(back, "claude")
	back:SetAllPoints()
	local p = CreateFrame("Frame", nil, mock)
	p:SetPoint("TOPLEFT", 9, -7)
	p:SetSize(W, H)
	local ok, err = pcall(candidate[2], p)
	if not ok then label:SetText(label:GetText() .. " |cffff6060" .. tostring(err) .. "|r") end
	box.mock = mock
	return box
end

WC.Companion.AddTab("Settings looks", function(page)
	WC.MarkIgnored(page)
	local boxes = {}
	for i, candidate in ipairs(CANDIDATES) do boxes[i] = cell(page, i, candidate) end
	local function layout()
		local w, h = page:GetWidth(), page:GetHeight()
		if w <= 0 then return end
		local gap, top = 10, 26
		local cw = (w - gap) / 2
		local ch = (h - top * 2 - gap) / 2
		local scale = math.min(cw / (W + 18), ch / (H + 14))
		for i, box in ipairs(boxes) do
			local col, line = (i - 1) % 2, math.floor((i - 1) / 2)
			box:ClearAllPoints()
			box:SetPoint("TOPLEFT", page, "TOPLEFT", col * (cw + gap), -top - line * (ch + top + gap))
			box:SetSize(cw, ch)
			box.mock:SetScale(scale)
		end
	end
	page:HookScript("OnSizeChanged", layout)
	page:HookScript("OnShow", layout)
end)
