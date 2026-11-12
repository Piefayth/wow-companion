-- A design sheet, for now: candidate scroll bars side by side, each on a small
-- copy of the chat well (two turns on the stone, a divider between meeting the
-- bar), so the player compares them in the Companion window instead of one
-- reload per idea. Shown only; nothing scrolls. Goes when a bar is chosen.

local STONE = WC.Transcript.STONE
local EDGE = 3

local function stone(tex, which)
	tex:SetTexture(STONE[which], "REPEAT", "REPEAT")
	tex:SetHorizTile(true)
	tex:SetVertTile(true)
end

-- All drawn by tools/make_scrollbar_art.py. The spearhead (round 1) is
-- arrows over the slim grey bar, a rod and joints; the others (round 2) are
-- one object each: end caps that are the arrows, rails and groove between.
local ART = [[Interface\AddOns\WowCompanion_Agent\Art\Scroll-]]
local function art(design, piece)
	return ART .. design .. "-" .. piece .. "-" .. (design == "Spear" and 1 or 2)
end
local ARROW = 16 -- an arrow's square, its art about 12 of it

local function arrows(c, design)
	for _, spec in ipairs({ { "Up", "TOP", -2 }, { "Down", "BOTTOM", 2 } }) do
		local b = CreateFrame("Button", nil, c)
		b:SetSize(ARROW, ARROW)
		b:SetPoint(spec[2], 0, spec[3])
		local base = spec[1] .. "-"
		b:SetNormalTexture(art(design, base .. "Normal"))
		b:SetPushedTexture(art(design, base .. "Pushed"))
		b:SetHighlightTexture(art(design, base .. "Highlight"), "ADD")
		b:SetDisabledTexture(art(design, base .. "Disabled"))
	end
	return 2 + ARROW + 2
end

-- the rod (8 wide, its art the middle 1.5) centred on the column's left side,
-- from cap to cap
local function rule(c, design)
	local top = c:CreateTexture(nil, "ARTWORK")
	top:SetTexture(art(design, "RuleTop"))
	top:SetSize(8, 8)
	top:SetPoint("TOP", c, "TOPLEFT", 0, 0)
	local bottom = c:CreateTexture(nil, "ARTWORK")
	bottom:SetTexture(art(design, "RuleBottom"))
	bottom:SetSize(8, 8)
	bottom:SetPoint("BOTTOM", c, "BOTTOMLEFT", 0, 0)
	local mid = c:CreateTexture(nil, "ARTWORK")
	mid:SetTexture(art(design, "RuleMid"), nil, "REPEAT")
	mid:SetVertTile(true)
	mid:SetWidth(8)
	mid:SetPoint("TOP", top, "BOTTOM")
	mid:SetPoint("BOTTOM", bottom, "TOP")
end

-- The spearhead: MinimalScrollBar's slim track and thumb, 8 wide, untinted, the
-- thumb a sixth of the way down and a third of the height. ends: the dividers'
-- right ends, each given the design's joint.
local function spear(c, design, ends)
	local inset = arrows(c, design)
	rule(c, design)
	for _, at in ipairs(ends) do
		local joint = c:CreateTexture(nil, "OVERLAY")
		joint:SetTexture(art(design, "Joint"))
		joint:SetSize(16, 16)
		joint:SetPoint("CENTER", at, "TOPRIGHT")
	end
	local width = 8
	local track = CreateFrame("Frame", nil, c)
	track:SetPoint("TOP", 0, -inset)
	track:SetPoint("BOTTOM", 0, inset)
	track:SetWidth(width)
	local function piece(parent, layer, atlas, point)
		local t = parent:CreateTexture(nil, layer)
		t:SetAtlas(atlas)
		t:SetSize(width, 8)
		t:SetPoint(point)
		return t
	end
	local function column3(parent, layer, set, middle)
		local top = piece(parent, layer, set .. "-top", "TOP")
		local bottom = piece(parent, layer, set .. "-bottom", "BOTTOM")
		local mid = parent:CreateTexture(nil, layer)
		mid:SetAtlas(middle)
		mid:SetPoint("TOPLEFT", top, "BOTTOMLEFT")
		mid:SetPoint("BOTTOMRIGHT", bottom, "TOPRIGHT")
	end
	column3(track, "BACKGROUND", "minimal-scrollbar-track", "!minimal-scrollbar-track-middle")
	local thumb = CreateFrame("Frame", nil, track)
	thumb:SetWidth(width)
	local room = (c:GetHeight() > 0 and c:GetHeight() or 300) - 2 * inset
	thumb:SetHeight(room / 3)
	thumb:SetPoint("TOP", track, "TOP", 0, -room / 6)
	column3(thumb, "ARTWORK", "minimal-scrollbar-small-thumb", "minimal-scrollbar-small-thumb-middle")
end

-- One object, 16 wide in the 20-wide column: the caps (16x16) are the
-- arrow buttons, the rails and groove (Mid) stretch between them, the thumb
-- (8 wide) rides in the groove. Each divider's end gets the design's Joint,
-- 16x16, its right 2.5 the left rail (column x 3 to 5.5).
local function onePiece(c, design, ends)
	local caps = {}
	for _, spec in ipairs({ { "Up", "TOP" }, { "Down", "BOTTOM" } }) do
		local b = CreateFrame("Button", nil, c)
		b:SetSize(16, 16)
		b:SetPoint(spec[2])
		local base = "Cap-" .. spec[1] .. "-"
		b:SetNormalTexture(art(design, base .. "Normal"))
		b:SetPushedTexture(art(design, base .. "Pushed"))
		b:SetHighlightTexture(art(design, base .. "Highlight"), "ADD")
		b:SetDisabledTexture(art(design, base .. "Disabled"))
		caps[spec[1]] = b
	end
	local mid = c:CreateTexture(nil, "BACKGROUND")
	mid:SetTexture(art(design, "Mid"))
	mid:SetPoint("TOP", caps.Up, "BOTTOM")
	mid:SetPoint("BOTTOM", caps.Down, "TOP")
	mid:SetWidth(16)
	local room = (c:GetHeight() > 0 and c:GetHeight() or 300) - 32
	local function thumb(piece, h, y)
		local t = c:CreateTexture(nil, "ARTWORK")
		t:SetTexture(art(design, "Thumb-" .. piece))
		t:SetSize(8, h)
		t:SetPoint("TOP", mid, "TOP", 0, y)
		return t
	end
	thumb("Top", 4, -room / 6)
	thumb("Mid", room / 3 - 8, -room / 6 - 4)
	thumb("Bottom", 4, -room / 6 - room / 3 + 4)
	for _, at in ipairs(ends) do
		local joint = c:CreateTexture(nil, "OVERLAY")
		joint:SetTexture(art(design, "Joint"))
		joint:SetSize(16, 16)
		joint:SetPoint("CENTER", at, "TOPRIGHT", -2.5, 0)
	end
end

-- each: a name, its builder, its art, and its divider: Blizzard's quest log
-- divider, or the design's own (RuleLeft, RuleMid stretched, into the Joint)
local OPTIONS = {
	{ "Bronze spearhead", spear, "Spear", "blizzard" },
	{ "Gold sceptre, ruby", onePiece, "Sceptre", "own" },
	{ "Blackiron arrowhead", onePiece, "Blackiron", "blizzard" },
	{ "Iron onion, sapphire", onePiece, "Onion", "own" },
}

local SAMPLE = {
	{ "you", "|cffffd100You|r 20:47\nOne bar, one piece, please." },
	{ "claude", "|cffffd100Claude|r 20:48\nThe slim grey bar with new ornate arrows, and an edge where each divider ends. Each pane is a small chat well with your stone and mine." },
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
	column:SetWidth(20)
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
	local y, last, ends = 0, nil, {}
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
		if last and option[4] == "blizzard" then
			local divider = text:CreateTexture(nil, "ARTWORK")
			divider:SetAtlas("QuestLog-frame-devider")
			divider:SetAlpha(0.8)
			divider:SetHeight(15)
			divider:SetPoint("LEFT", band, "TOPLEFT")
			divider:SetPoint("RIGHT", band, "TOPRIGHT")
			ends[#ends + 1] = band
		elseif last then
			local left = text:CreateTexture(nil, "ARTWORK")
			left:SetTexture(art(option[3], "RuleLeft"))
			left:SetSize(16, 8)
			left:SetPoint("LEFT", band, "TOPLEFT")
			local line = text:CreateTexture(nil, "ARTWORK")
			line:SetTexture(art(option[3], "RuleMid"))
			line:SetHeight(8)
			line:SetPoint("LEFT", left, "RIGHT")
			line:SetPoint("RIGHT", band, "TOPRIGHT", -9, 0)
			ends[#ends + 1] = band
		end
		last = band
		y = y - 64
	end
	local ok, err = pcall(option[2], column, option[3], ends)
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
