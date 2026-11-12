-- A design sheet, for now: the chat's slim grey bar with candidate ornate
-- arrows and divider edges side by side, each on a small copy of the chat well (two turns on the
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

-- The arrows and the dividers' edge, drawn by tools/make_scrollbar_art.py
-- (ornate, not Blizzard's): each candidate's up and down arrow as real buttons
-- with all four states, and where the dividers end, its edge: a rod down the
-- column's left side with caps, and a joint on each divider's end.
local ART_VERSION = 1
local ART = [[Interface\AddOns\WowCompanion_Agent\Art\Scroll-]]
local function art(design, piece) return ART .. design .. "-" .. piece .. "-" .. ART_VERSION end
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

-- The slim bar: MinimalScrollBar's track and thumb, 8 wide, untinted, the
-- thumb a sixth of the way down and a third of the height. ends: the dividers'
-- right ends, each given the design's joint.
local function marker(c, design, hasRule, ends)
	local inset = arrows(c, design)
	if hasRule then rule(c, design) end
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

-- each: a name, the column's width, the design's art, and whether it has a rod
local OPTIONS = {
	{ "Gilded chevron, ruby", 20, "Gilded", true },
	{ "Bronze spearhead", 20, "Spear", true },
	{ "Fleur, sapphire, no rod", 20, "Fleur", false },
	{ "Iron and gold, amber", 20, "Ember", true },
}

local SAMPLE = {
	{ "you", "|cffffd100You|r 20:47\nArrows worthy of the bar, please." },
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
		if last then
			local divider = text:CreateTexture(nil, "ARTWORK")
			divider:SetAtlas("QuestLog-frame-devider")
			divider:SetAlpha(0.8)
			divider:SetHeight(15)
			divider:SetPoint("LEFT", band, "TOPLEFT")
			divider:SetPoint("RIGHT", band, "TOPRIGHT")
			ends[#ends + 1] = band
		end
		last = band
		y = y - 64
	end
	local ok, err = pcall(marker, column, option[3], option[4], ends)
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
