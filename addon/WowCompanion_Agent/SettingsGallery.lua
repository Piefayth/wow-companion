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

-- The section names in the left margin (round 1's pick, for using the
-- width), controls against the right edge, the rows spanning the page between
-- margin and edge.
local MARGIN, ROW, GAP = 170, 36, 24

local function line(parent, atlas, alpha)
	local t = parent:CreateTexture(nil, "ARTWORK")
	t:SetAtlas(atlas)
	t:SetAlpha(alpha or 1)
	return t
end

-- lays the sections out; each(row, spec, first, last) dresses a row,
-- group(head, top, bottom, i) dresses section i's span
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
		if group then group(head, top, y, i) end
		y = y + (i < #SECTIONS and GAP or 0)
	end
end

-- Round 3: the spine (round 2's B, the player's pick), four answers to where
-- the sections divide. group(head, top, bottom, i) also gets the section's
-- index; the gap below a section is GAP.

-- the dark stone down the left from top to bottom (or one piece per section)
local function spine(p, top, bottom)
	local t = p:CreateTexture(nil, "BACKGROUND", nil, 1)
	stone(t, "you")
	t:SetPoint("TOPLEFT", p, "TOPLEFT", -9, top and -top or 7)
	t:SetPoint("BOTTOMRIGHT", p, bottom and "TOPLEFT" or "BOTTOMLEFT", MARGIN - 2, bottom and -bottom or -7)
	local rule = line(p, "spec-columndivider", 1)
	rule:SetWidth(7)
	rule:SetPoint("TOPLEFT", t, "TOPRIGHT", -3, 0)
	rule:SetPoint("BOTTOMLEFT", t, "BOTTOMRIGHT", -3, 0)
end

-- A. No lines at all: the space between sections and the names on the spine
-- do the dividing
CANDIDATES[1] = { "Spine, sections parted by space", function(p)
	spine(p)
	margin(p)
end }

-- B. The spine notched: the light stone's gap between sections cuts through
-- the spine too, so each section has its own piece of it
CANDIDATES[2] = { "Spine in pieces, one per section", function(p)
	margin(p, nil, function(_, top, bottom, i)
		spine(p, i == 1 and -7 or top - GAP / 2 + 4, i == #SECTIONS and nil or bottom + GAP / 2 - 4)
	end)
end }

-- C. Dividers on the right only, each growing out of the spine's edge
CANDIDATES[3] = { "Dividers from the spine's edge, right side only", function(p)
	spine(p)
	margin(p, nil, function(_, _, bottom, i)
		if i == #SECTIONS then return end
		local d = line(p, "QuestLog-frame-devider", 0.8)
		d:SetHeight(15)
		d:SetPoint("LEFT", p, "TOPLEFT", MARGIN, -bottom - GAP / 2)
		d:SetPoint("RIGHT", p, "TOPRIGHT", 9, -bottom - GAP / 2)
	end)
end }

-- D. The ornament on the spine only: a small divider at its own size
-- between the section names, the right side parted by space
CANDIDATES[4] = { "An ornament on the spine between sections", function(p)
	spine(p)
	margin(p, nil, function(_, _, bottom, i)
		if i == #SECTIONS then return end
		local d = line(p, "QuestLog-frame-devider", 0.9)
		d:SetSize(93, 15)
		d:SetPoint("CENTER", p, "TOPLEFT", (MARGIN - 11) / 2, -bottom - GAP / 2)
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
