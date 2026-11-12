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

-- A slim marker, no arrows: a gutter and a thumb exactly its width (never
-- wider), a sixth of the way down, a third of the height. g: the gutter
-- (track atlases tinted, or a stone), t: the thumb (atlases, tint, desaturate)
local function marker(c, width, g, t)
	local track = CreateFrame("Frame", nil, c)
	track:SetPoint("TOP", 0, -6)
	track:SetPoint("BOTTOM", 0, 6)
	track:SetWidth(width)
	if g.stone then
		local s = track:CreateTexture(nil, "BACKGROUND")
		stone(s, g.stone)
		s:SetAllPoints()
		if g.rim then
			-- a recessed groove: Blizzard's inset border around the stone
			local rim = CreateFrame("Frame", nil, track, "InsetFrameTemplate")
			rim:SetPoint("TOPLEFT", -3, 3)
			rim:SetPoint("BOTTOMRIGHT", 3, -3)
			if rim.Bg then rim.Bg:Hide() end
		end
	else
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
		for _, x in ipairs({ top, bottom, mid }) do
			if g.color then x:SetVertexColor(unpack(g.color)) end
		end
	end
	local thumb = CreateFrame("Frame", nil, track)
	thumb:SetWidth(width)
	local room = (c:GetHeight() > 0 and c:GetHeight() or 300) - 12
	thumb:SetHeight(room / 3)
	thumb:SetPoint("TOP", track, "TOP", 0, -room / 6)
	if t.knob then
		-- Blizzard's classic knob art (gold, bevelled), its centre tiled
		local top = thumb:CreateTexture(nil, "ARTWORK")
		top:SetAtlas("UI-ScrollBar-Knob-EndCap-Top")
		top:SetSize(width, 21 * width / 18)
		top:SetPoint("TOP")
		local bottom = thumb:CreateTexture(nil, "ARTWORK")
		bottom:SetAtlas("UI-ScrollBar-Knob-EndCap-Bottom")
		bottom:SetSize(width, 21 * width / 18)
		bottom:SetPoint("BOTTOM")
		local mid = thumb:CreateTexture(nil, "BACKGROUND", nil, 1)
		mid:SetAtlas("UI-ScrollBar-Knob-Center")
		mid:SetPoint("TOPLEFT", 0, -5)
		mid:SetPoint("BOTTOMRIGHT", 0, 5)
		-- tiled, never squashed: the art is 1022 tall (as Window.lua's thumb)
		mid:SetTexCoord(0, 1, 0, (room / 3 - 10) / 1022)
		return
	end
	local set = t.set or "minimal-scrollbar-small-thumb"
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
local OPTIONS = {
	{ "Was 7, fitted", 14, function(c) marker(c, 8, {}, {}) end },
	{ "Gold", 14, function(c) marker(c, 8, {}, { desaturate = true, color = { 1, 0.82, 0.25 } }) end },
	{ "Bronze", 14, function(c) marker(c, 8, {}, { desaturate = true, color = { 0.78, 0.6, 0.38 } }) end },
	{ "Parchment", 14, function(c) marker(c, 8, {}, { desaturate = true, color = { 0.86, 0.83, 0.76 } }) end },
	{ "Stone groove, gold", 18, function(c)
		marker(c, 8, { stone = "you", rim = true }, { desaturate = true, color = { 1, 0.82, 0.25 } })
	end },
	{ "Stone groove, knob", 22, function(c) marker(c, 12, { stone = "you", rim = true }, { knob = true }) end },
	{ "Trough gutter, knob", 31, function(c)
		local g = c:CreateTexture(nil, "BACKGROUND")
		stone(g, "you")
		g:SetPoint("TOPLEFT", 5, 0)
		g:SetPoint("BOTTOMRIGHT", -5, 0)
		trough(c)
		-- the knob exactly the gutter's width (columns 6..24 of the 31)
		local knob = CreateFrame("Frame", nil, c)
		knob:SetPoint("TOPLEFT", 6, -40)
		knob:SetSize(19, 90)
		knob:SetFrameLevel(c:GetFrameLevel() + 1)
		local top = knob:CreateTexture(nil, "ARTWORK")
		top:SetAtlas("UI-ScrollBar-Knob-EndCap-Top")
		top:SetSize(19, 22)
		top:SetPoint("TOP")
		local bottom = knob:CreateTexture(nil, "ARTWORK")
		bottom:SetAtlas("UI-ScrollBar-Knob-EndCap-Bottom")
		bottom:SetSize(19, 22)
		bottom:SetPoint("BOTTOM")
		local mid = knob:CreateTexture(nil, "BACKGROUND", nil, 1)
		mid:SetAtlas("UI-ScrollBar-Knob-Center")
		mid:SetPoint("TOPLEFT", 0, -5)
		mid:SetPoint("BOTTOMRIGHT", 0, 5)
		mid:SetTexCoord(0, 1, 0, 80 / 1022)
	end },
}

local SAMPLE = {
	{ "you", "|cffffd100You|r 20:47\nThe scroll bar again, what else have you got?" },
	{ "claude", "|cffffd100Claude|r 20:48\nSlim markers, no arrows, each thumb its gutter's width. Each pane is a small chat well with your stone and mine, and its bar on the right." },
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
