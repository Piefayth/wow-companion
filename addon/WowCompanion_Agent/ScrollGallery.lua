-- A design sheet, for now: the chat's scroll bar in several of Blizzard's own
-- looks side by side, each on a small copy of the chat well (two turns on the
-- stone, the quest log divider between), so the player compares them in the
-- Companion window instead of one reload per idea. Shown only; nothing scrolls.
-- Goes when a bar is chosen.

local STONE = WC.Transcript.STONE
local EDGE = 3

local function stone(tex, which)
	tex:SetTexture(STONE[which], "REPEAT", "REPEAT")
	tex:SetHorizTile(true)
	tex:SetVertTile(true)
end

-- Blizzard's classic arrows and knob (UIPanelScrollBarTemplate's pieces)
local function classicArrows(column, inset, top)
	local up = CreateFrame("Button", nil, column, "UIPanelScrollUpButtonTemplate")
	up:SetPoint("TOP", column, "TOP", inset or 0, -(top or 4))
	local down = CreateFrame("Button", nil, column, "UIPanelScrollDownButtonTemplate")
	down:SetPoint("BOTTOM", column, "BOTTOM", inset or 0, top or 4)
	local knob = column:CreateTexture(nil, "OVERLAY")
	knob:SetTexture([[Interface\Buttons\UI-ScrollBar-Knob]])
	knob:SetTexCoord(0.20, 0.80, 0.125, 0.875)
	knob:SetSize(18, 24)
	knob:SetPoint("TOP", up, "BOTTOM", 0, -40)
	return up, down
end

-- the classic trough: its end caps, and the top cap's rails-only rows
-- stretched between them (the centre atlas is not in this client)
local function trough(column)
	local top = column:CreateTexture(nil, "BORDER")
	top:SetAtlas("UI-ClassicScrollBar-EndCap-Top", true)
	top:SetPoint("TOPLEFT")
	local bottom = column:CreateTexture(nil, "BORDER")
	bottom:SetAtlas("UI-ClassicScrollBar-EndCap-Bottom", true)
	bottom:SetPoint("BOTTOMLEFT")
	local cap = C_Texture.GetAtlasInfo("UI-ClassicScrollBar-EndCap-Top")
	if cap then
		local rails = column:CreateTexture(nil, "BORDER")
		rails:SetTexture(cap.file)
		rails:SetTexCoord(cap.leftTexCoord, cap.rightTexCoord, 9 / 64, 14 / 64)
		rails:SetPoint("TOPLEFT", top, "BOTTOMLEFT")
		rails:SetPoint("BOTTOMRIGHT", bottom, "TOPRIGHT")
	end
end

-- a Blizzard ScrollBar template, shown at a quarter of the way down
local function templateBar(column, template)
	local made, bar = pcall(CreateFrame, "EventFrame", nil, column, template)
	if not made or not bar then return false end
	bar:SetPoint("TOPLEFT")
	bar:SetPoint("BOTTOMLEFT")
	pcall(bar.Init, bar, 0.3, 0.1)
	pcall(bar.SetScrollPercentage, bar, 0.25, true)
	return bar
end

-- each: a name, the column's width, and what draws in it
local OPTIONS = {
	{ "Trough, dark stone", 31, function(c)
		local g = c:CreateTexture(nil, "BACKGROUND")
		stone(g, "you")
		g:SetPoint("TOPLEFT", 5, 0)
		g:SetPoint("BOTTOMRIGHT", -5, 0)
		trough(c)
		-- centred on the gap between the rails (columns 6..24 of 31)
		classicArrows(c, -0.5, 5)
	end },
	{ "Trough, black", 31, function(c)
		local g = c:CreateTexture(nil, "BACKGROUND")
		g:SetColorTexture(0, 0, 0, 0.75)
		g:SetPoint("TOPLEFT", 5, 0)
		g:SetPoint("BOTTOMRIGHT", -5, 0)
		trough(c)
		classicArrows(c, -0.5, 5)
	end },
	{ "List trough", 27, function(c)
		local top = c:CreateTexture(nil, "BORDER")
		top:SetAtlas("macropopup-scrollbar-top", true)
		top:SetPoint("TOPLEFT")
		local bottom = c:CreateTexture(nil, "BORDER")
		bottom:SetAtlas("macropopup-scrollbar-bottom", true)
		bottom:SetPoint("BOTTOMLEFT")
		local mid = c:CreateTexture(nil, "BORDER")
		mid:SetAtlas("!macropopup-scrollbar-middle", true)
		mid:SetVertTile(true)
		mid:SetPoint("TOPLEFT", top, "BOTTOMLEFT")
		mid:SetPoint("BOTTOMLEFT", bottom, "TOPLEFT")
		classicArrows(c, 0, 4)
	end },
	{ "Trim (modern)", 18, function(c) templateBar(c, "WowTrimScrollBar") end },
	{ "Minimal", 10, function(c) templateBar(c, "MinimalScrollBar") end },
	{ "Arrows only", 24, function(c) classicArrows(c, 0, 2) end },
	{ "Marker only", 10, function(c)
		local bar = templateBar(c, "MinimalScrollBar")
		if bar then
			if bar.Back then bar.Back:Hide() end
			if bar.Forward then bar.Forward:Hide() end
			if bar.Track then
				bar.Track:ClearAllPoints()
				bar.Track:SetPoint("TOPLEFT", 0, -4)
				bar.Track:SetPoint("BOTTOMRIGHT", 0, 4)
			end
		end
	end },
}

local SAMPLE = {
	{ "you", "|cffffd100You|r 20:47\nThe scroll bar again, what else have you got?" },
	{ "claude", "|cffffd100Claude|r 20:48\nSeven of Blizzard's own looks, side by side. Each pane is a small chat well with your stone and mine, and its bar on the right." },
}

local function pane(page, i, option)
	local box = CreateFrame("Frame", nil, page, "InsetFrameTemplate")
	if box.Bg then box.Bg:Hide() end
	local label = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	label:SetPoint("BOTTOM", box, "TOP", 0, 4)
	label:SetText(i .. ". " .. option[1])
	local column = CreateFrame("Frame", nil, box)
	column:SetPoint("TOPRIGHT", -EDGE, -EDGE)
	column:SetPoint("BOTTOMRIGHT", -EDGE, EDGE)
	column:SetWidth(option[2])
	column:SetFrameLevel(box:GetFrameLevel() + 2)
	local text = CreateFrame("Frame", nil, box)
	text:SetPoint("TOPLEFT", EDGE, -EDGE)
	text:SetPoint("BOTTOMRIGHT", column, "BOTTOMLEFT")
	text:SetFrameLevel(box:GetFrameLevel() + 1)
	-- the transcript's stone behind the column too, as in the chat well
	local under = box:CreateTexture(nil, "BACKGROUND", nil, -2)
	stone(under, "claude")
	under:SetPoint("TOPLEFT", EDGE, -EDGE)
	under:SetPoint("BOTTOMRIGHT", -EDGE, EDGE)
	local y, last = 0, nil
	for n, turn in ipairs(SAMPLE) do
		local band = text:CreateTexture(nil, "BACKGROUND")
		stone(band, turn[1])
		local fs = text:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetJustifyH("LEFT")
		fs:SetTextColor(0.86, 0.83, 0.76)
		fs:SetPoint("TOPLEFT", 8, y - 6)
		fs:SetPoint("RIGHT", -8, 0)
		fs:SetText(turn[2])
		band:SetPoint("TOPLEFT", 0, y)
		band:SetPoint("RIGHT")
		if n == #SAMPLE then band:SetPoint("BOTTOM") else band:SetHeight(64) end
		if last then
			local divider = text:CreateTexture(nil, "ARTWORK")
			divider:SetAtlas("QuestLog-frame-devider")
			divider:SetAlpha(0.8)
			divider:SetHeight(15)
			divider:SetPoint("LEFT", band, "TOPLEFT")
			divider:SetPoint("RIGHT", band, "TOPRIGHT")
		end
		last = band
		y = y - 64
	end
	local ok, err = pcall(option[3], column)
	if not ok then
		label:SetText(i .. ". " .. option[1] .. " |cffff6060" .. tostring(err) .. "|r")
	end
	return box
end

WC.Companion.AddTab("Scroll bars", function(page)
	local boxes = {}
	for i, option in ipairs(OPTIONS) do boxes[i] = pane(page, i, option) end
	local function layout()
		local w, h = page:GetWidth(), page:GetHeight()
		if w <= 0 then return end
		local gap = 8
		local each = (w - 16 - gap * (#boxes - 1)) / #boxes
		for i, box in ipairs(boxes) do
			box:ClearAllPoints()
			box:SetPoint("TOPLEFT", page, "TOPLEFT", 8 + (i - 1) * (each + gap), -24)
			box:SetSize(each, math.max(120, h - 32))
		end
	end
	page:HookScript("OnSizeChanged", layout)
	page:HookScript("OnShow", layout)
end)
