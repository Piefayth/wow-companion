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

-- An arrow button at each end, for the controller cursor (the right stick
-- stays the camera). "minimal": MinimalScrollBar's own steppers (17x11,
-- with their over and down art); "classic": UIPanelScrollUp/DownButton.
-- Returns the height they take at each end.
local function arrows(c, a)
	if a.kind == "classic" then
		local up = CreateFrame("Button", nil, c, "UIPanelScrollUpButtonTemplate")
		up:SetPoint("TOP", 0, -4)
		local down = CreateFrame("Button", nil, c, "UIPanelScrollDownButtonTemplate")
		down:SetPoint("BOTTOM", 0, 4)
		return 4 + up:GetHeight() + 4
	end
	for _, spec in ipairs({ { "top", "TOP", -4 }, { "bottom", "BOTTOM", 4 } }) do
		local b = CreateFrame("Button", nil, c)
		b:SetSize(17, 11)
		b:SetPoint(spec[2], 0, spec[3])
		local base = "minimal-scrollbar-arrow-" .. spec[1]
		b:SetNormalAtlas(base)
		b:SetHighlightAtlas(base .. "-over")
		b:SetPushedAtlas(base .. "-down")
		for _, t in ipairs({ b:GetNormalTexture(), b:GetPushedTexture() }) do
			if a.color then
				t:SetDesaturated(true)
				t:SetVertexColor(unpack(a.color))
			end
		end
	end
	return 4 + 11 + 4
end

-- A slim bar: a gutter and a thumb exactly its width (never wider), a sixth
-- of the way down, a third of the height, on MinimalScrollBar's track. t: the
-- thumb's tint, a: the arrows
local function marker(c, width, t, a)
	local ends = arrows(c, a)
	local track = CreateFrame("Frame", nil, c)
	track:SetPoint("TOP", 0, -ends)
	track:SetPoint("BOTTOM", 0, ends)
	track:SetWidth(width)
	local top = track:CreateTexture(nil, "BACKGROUND")
	top:SetAtlas("minimal-scrollbar-track-top")
	top:SetSize(width, 8)
	top:SetPoint("TOP")
	local bottom = track:CreateTexture(nil, "BACKGROUND")
	bottom:SetAtlas("minimal-scrollbar-track-bottom")
	bottom:SetSize(width, 8)
	bottom:SetPoint("BOTTOM")
	local mid = track:CreateTexture(nil, "BACKGROUND")
	mid:SetAtlas("!minimal-scrollbar-track-middle")
	mid:SetPoint("TOPLEFT", top, "BOTTOMLEFT")
	mid:SetPoint("BOTTOMRIGHT", bottom, "TOPRIGHT")
	local thumb = CreateFrame("Frame", nil, track)
	thumb:SetWidth(width)
	local room = (c:GetHeight() > 0 and c:GetHeight() or 300) - 12
	thumb:SetHeight(room / 3)
	thumb:SetPoint("TOP", track, "TOP", 0, -room / 6)
	local set = "minimal-scrollbar-small-thumb"
	local top = thumb:CreateTexture(nil, "ARTWORK")
	top:SetAtlas(set .. "-top")
	top:SetSize(width, 8)
	top:SetPoint("TOP")
	local bottom = thumb:CreateTexture(nil, "ARTWORK")
	bottom:SetAtlas(set .. "-bottom")
	bottom:SetSize(width, 8)
	bottom:SetPoint("BOTTOM")
	local mid = thumb:CreateTexture(nil, "ARTWORK")
	mid:SetAtlas(set .. "-middle")
	mid:SetPoint("TOPLEFT", top, "BOTTOMLEFT")
	mid:SetPoint("BOTTOMRIGHT", bottom, "TOPRIGHT")
	for _, x in ipairs({ top, bottom, mid }) do
		if t.desaturate then x:SetDesaturated(true) end
		if t.color then x:SetVertexColor(unpack(t.color)) end
	end
end

-- each: a name, the column's width, and what draws in it
local GOLD, BRONZE, PARCHMENT = { 1, 0.82, 0.25 }, { 0.78, 0.6, 0.38 }, { 0.86, 0.83, 0.76 }
local function tinted(color) return { desaturate = true, color = color } end
local OPTIONS = {
	{ "Minimal", 18, function(c) marker(c, 8, {}, { kind = "minimal" }) end },
	{ "Minimal, gold", 18, function(c)
		marker(c, 8, tinted(GOLD), { kind = "minimal", color = GOLD })
	end },
	{ "Minimal, bronze", 18, function(c)
		marker(c, 8, tinted(BRONZE), { kind = "minimal", color = BRONZE })
	end },
	{ "Minimal, parchment", 18, function(c)
		marker(c, 8, tinted(PARCHMENT), { kind = "minimal", color = PARCHMENT })
	end },
	{ "Grey bar, gold arrows", 18, function(c)
		marker(c, 8, {}, { kind = "minimal", color = GOLD })
	end },
	{ "Classic arrows, grey", 24, function(c) marker(c, 8, {}, { kind = "classic" }) end },
	{ "Classic arrows, gold", 24, function(c) marker(c, 8, tinted(GOLD), { kind = "classic" }) end },
}

local SAMPLE = {
	{ "you", "|cffffd100You|r 20:47\nThe scroll bar again, what else have you got?" },
	{ "claude", "|cffffd100Claude|r 20:48\nThe thin rounded bar with arrows, in a few colours. Each pane is a small chat well with your stone and mine, and its bar on the right." },
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
