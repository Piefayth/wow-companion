-- A design sheet, for now: the settings page's controls drawn in the chat's
-- language (tools/make_control_art.py), at full size on the settings stone,
-- each as it rests and as it is with the cursor on its row. Shown only:
-- nothing here is a stop or changes a setting. Goes when the controls are built.

local ART = [[Interface\AddOns\WowCompanion\Art\Control-]]
local VERSION = 1
local function art(piece) return ART .. piece .. "-" .. VERSION end
local BRONZE = { 0.78, 0.66, 0.45 } -- washed bronze for values
local FILL = 7.8 / 5.25 -- the thumb widened to the groove's floor, as the chat's

local function tex(parent, piece, w, h, layer, blend)
	local t = parent:CreateTexture(nil, layer or "ARTWORK")
	t:SetTexture(art(piece))
	if blend then t:SetBlendMode(blend) end
	if w then t:SetSize(w, h) end
	return t
end

local function text(parent, font, s, colour)
	local fs = parent:CreateFontString(nil, "OVERLAY", font)
	fs:SetText(s)
	if colour then fs:SetTextColor(unpack(colour)) end
	return fs
end

-- a choice: the fleur arrows either side of a carved plate holding the value
local function choice(row, value, lit)
	local f = CreateFrame("Frame", nil, row)
	f:SetSize(260, 32)
	local left = tex(f, "Step-Left-Normal", 32, 32)
	left:SetPoint("LEFT")
	local right = tex(f, "Step-Right-Normal", 32, 32)
	right:SetPoint("RIGHT")
	local pl = tex(f, "Plate-Left", 16, 24)
	pl:SetPoint("LEFT", left, "RIGHT", -2, 0)
	local pr = tex(f, "Plate-Right", 16, 24)
	pr:SetPoint("RIGHT", right, "LEFT", 2, 0)
	local pm = tex(f, "Plate-Mid", nil, nil)
	pm:SetHeight(24)
	pm:SetPoint("LEFT", pl, "RIGHT")
	pm:SetPoint("RIGHT", pr, "LEFT")
	text(f, "GameFontHighlight", value, BRONZE):SetPoint("CENTER")
	if lit then
		tex(f, "Step-Left-Highlight", 32, 32, "OVERLAY", "ADD"):SetPoint("LEFT")
		tex(f, "Step-Right-Highlight", 32, 32, "OVERLAY", "ADD"):SetPoint("RIGHT")
	end
	return f
end

-- a slider: the scroll bar on its side, the thumb riding its groove
local function slider(row, at, value, lit)
	local f = CreateFrame("Frame", nil, row)
	f:SetSize(260, 32)
	local left = tex(f, "Slide-Left-Normal", 32, 32)
	left:SetPoint("LEFT")
	local right = tex(f, "Slide-Right-Normal", 32, 32)
	right:SetPoint("RIGHT", -40, 0)
	local mid = tex(f, "Slide-Mid", nil, nil)
	mid:SetHeight(32)
	mid:SetPoint("LEFT", left, "RIGHT")
	mid:SetPoint("RIGHT", right, "LEFT")
	local thumb = tex(f, "Slide-Thumb", 34, 32 * FILL, "OVERLAY")
	local span = 260 - 40 - 64 - 34
	thumb:SetPoint("CENTER", f, "LEFT", 32 + 17 + span * at, 0)
	text(f, "GameFontHighlight", value, BRONZE):SetPoint("LEFT", right, "RIGHT", 4, 0)
	if lit then
		tex(f, "Slide-Left-Highlight", 32, 32, "OVERLAY", "ADD"):SetPoint("LEFT")
		tex(f, "Slide-Right-Highlight", 32, 32, "OVERLAY", "ADD"):SetPoint("RIGHT", -40, 0)
	end
	return f
end

-- a button: raised slate in a bark border, its word in bronze
local function button(row, word, lit)
	local f = CreateFrame("Frame", nil, row)
	f:SetSize(128, 24)
	tex(f, "Button-Normal"):SetAllPoints()
	if lit then tex(f, "Button-Highlight", nil, nil, "OVERLAY", "ADD"):SetAllPoints() end
	text(f, "GameFontHighlight", word, BRONZE):SetPoint("CENTER")
	return f
end

local ROWS = {
	{ "Window size", function(r, lit) return choice(r, "Medium", lit) end },
	{ "Text size", function(r, lit) return slider(r, 0.2, "100%", lit) end },
	{ "Clear transcript", function(r, lit) return button(r, "Clear", lit) end },
}

WC.Companion.AddTab("Controls", function(page)
	WC.MarkIgnored(page)
	local back = page:CreateTexture(nil, "BACKGROUND")
	back:SetTexture(WC.Style.STONE.claude, "REPEAT", "REPEAT")
	back:SetHorizTile(true)
	back:SetVertTile(true)
	back:SetAllPoints()
	local y = 16
	for _, lit in ipairs({ false, true }) do
		text(page, "GameFontHighlightMed2", lit and "With the cursor on its row" or "At rest")
			:SetPoint("TOPLEFT", 16, -y)
		y = y + 30
		for _, spec in ipairs(ROWS) do
			local row = CreateFrame("Frame", nil, page)
			row:SetPoint("TOPLEFT", 8, -y)
			row:SetPoint("RIGHT", -8, 0)
			row:SetHeight(40)
			if lit then
				local hover = row:CreateTexture(nil, "BACKGROUND", nil, 1)
				hover:SetAllPoints()
				hover:SetColorTexture(1, 1, 1, 0.1)
			end
			text(row, "GameFontNormal", spec[1]):SetPoint("LEFT", 12, 0)
			spec[2](row, lit):SetPoint("RIGHT", -12, 0)
			y = y + 44
		end
		y = y + 16
	end
end)
