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

local function hover(row, l, r)
	local t = row:CreateTexture(nil, "BACKGROUND", nil, 1)
	t:SetPoint("TOPLEFT", l or -9, -2)
	t:SetPoint("BOTTOMRIGHT", r or 9, 2)
	t:SetColorTexture(1, 1, 1, 0.1)
end

local CANDIDATES = {}

-- Round 2: the section names in the left margin (round 1's D, the player's
-- pick for using the width), each candidate grounding the rows differently
-- so they stop floating. Controls against the right edge, the rows spanning
-- the page between margin and edge.
local MARGIN, ROW, GAP = 170, 36, 18

local function line(parent, atlas, alpha)
	local t = parent:CreateTexture(nil, "ARTWORK")
	t:SetAtlas(atlas)
	t:SetAlpha(alpha or 1)
	return t
end

-- lays the sections out; each(row, spec, first, last) dresses a row,
-- group(head, top, bottom) dresses a section's span
local function margin(p, each, group)
	local y = 6
	for i, section in ipairs(SECTIONS) do
		local top = y
		local head = text(p, "GameFontHighlightMed2", section[1])
		head:SetPoint("TOPRIGHT", p, "TOPLEFT", MARGIN - 18, -y - 10)
		head:SetJustifyH("RIGHT")
		for n, spec in ipairs(section[2]) do
			local row = CreateFrame("Frame", nil, p)
			row:SetPoint("TOPLEFT", MARGIN, -y)
			row:SetPoint("RIGHT", -4, 0)
			row:SetHeight(ROW)
			if spec.focus then hover(row, -6, 6) end
			text(row, "GameFontNormal", spec[1]):SetPoint("LEFT", 10, 0)
			control(row, spec):SetPoint("RIGHT", spec[2] == "slider" and -40 or -8, 0)
			if each then each(row, spec, n == 1, n == #section[2]) end
			y = y + ROW
		end
		if group then group(head, top, y) end
		y = y + (i < #SECTIONS and GAP or 0)
	end
end

-- A. Ledger: every row on a fine rule, a column rule between the margin and
-- the rows; the words sit on lines as in a ledger
CANDIDATES[1] = { "Ledger: rows on ruled lines", function(p)
	local rule = line(p, "spec-columndivider", 0.8)
	rule:SetWidth(7)
	rule:SetPoint("TOPLEFT", MARGIN - 4, 0)
	rule:SetPoint("BOTTOMLEFT", MARGIN - 4, 0)
	margin(p, function(row)
		local l = line(row, "Options_HorizontalDivider", 0.5)
		l:SetHeight(1)
		l:SetPoint("BOTTOMLEFT", 4, 0)
		l:SetPoint("BOTTOMRIGHT", 0, 0)
	end)
end }

-- B. Spine: the margin is a strip of the dark stone down the page's left,
-- the section names on it, its edge a column rule; the rows hang off it
CANDIDATES[2] = { "Spine: the margin on dark stone", function(p)
	local spine = p:CreateTexture(nil, "BACKGROUND", nil, 1)
	stone(spine, "you")
	spine:SetPoint("TOPLEFT", -9, 7)
	spine:SetPoint("BOTTOMRIGHT", p, "BOTTOMLEFT", MARGIN - 2, -7)
	local rule = line(p, "spec-columndivider", 1)
	rule:SetWidth(7)
	rule:SetPoint("TOPLEFT", MARGIN - 5, 7)
	rule:SetPoint("BOTTOMLEFT", MARGIN - 5, -7)
	margin(p)
end }

-- C. Inlaid rows: each row a shallow band of the dark stone between two
-- fine rules, from the margin to the edge
CANDIDATES[3] = { "Inlaid: each row a band of dark stone", function(p)
	margin(p, function(row)
		local band = row:CreateTexture(nil, "BACKGROUND")
		stone(band, "you")
		band:SetPoint("TOPLEFT", 2, -2)
		band:SetPoint("BOTTOMRIGHT", 9, 2)
		for _, edge in ipairs({ "TOP", "BOTTOM" }) do
			local l = line(row, "Options_HorizontalDivider", 0.6)
			l:SetHeight(1)
			l:SetPoint(edge .. "LEFT", 2, edge == "TOP" and -2 or 2)
			l:SetPoint(edge .. "RIGHT", 9, edge == "TOP" and -2 or 2)
		end
	end)
end }

-- D. Bracketed: a vertical rule runs beside each section's rows only,
-- joining its name to them; nothing across the page
CANDIDATES[4] = { "Bracket: a rule binds each section", function(p)
	margin(p, function(row, _, _, last)
		if last then return end
		local l = line(row, "Options_HorizontalDivider", 0.35)
		l:SetHeight(1)
		l:SetPoint("BOTTOMLEFT", 10, 0)
		l:SetPoint("BOTTOMRIGHT", 0, 0)
	end, function(head, top, bottom)
		local bracket = line(head:GetParent(), "Talents-divider-vertical-c60", 1)
		bracket:SetWidth(2)
		bracket:SetPoint("TOPLEFT", head:GetParent(), "TOPLEFT", MARGIN - 6, -top - 4)
		bracket:SetPoint("BOTTOMLEFT", head:GetParent(), "TOPLEFT", MARGIN - 6, -bottom + 4)
	end)
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
