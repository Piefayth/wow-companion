-- A design sheet, for now: candidate scroll bars side by side, each on a small
-- copy of the chat well (six turns, each on its stone from the transcript's
-- edge to the pane's, the groove carved through them; the dividers meeting
-- the bar), so the player compares them in the Companion window instead of one
-- reload per idea. Shown only; nothing scrolls. Goes when a bar is chosen.

local STONE = WC.Style.STONE
local EDGE = 3

local function stone(tex, which)
	tex:SetTexture(STONE[which], "REPEAT", "REPEAT")
	tex:SetHorizTile(true)
	tex:SetVertTile(true)
end

-- All drawn by tools/make_scrollbar_art.py. The spearhead (round 1) is
-- arrows over the slim grey bar, a rod and joints; the others (round 6) are a
-- groove carved into the stone between two borders of the set's material,
-- the borders closing round its ends under the arrows and the set's own
-- dividers joining the left border (docs/proposals/scrollbar-concepts.md).
local ART = [[Interface\AddOns\WowCompanion_Agent\Art\Scroll-]]
local ROUND6 = 2 -- the generator's VERSION6
local function art(design, piece)
	return ART .. design .. "-" .. piece .. "-" .. (design == "Spear" and 1 or ROUND6)
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
-- y below the column's top, each given the design's joint at the column's edge.
local function spear(c, design, ends)
	local inset = arrows(c, design)
	rule(c, design)
	for _, y in ipairs(ends) do
		local joint = c:CreateTexture(nil, "OVERLAY")
		joint:SetTexture(art(design, "Joint"))
		joint:SetSize(16, 16)
		joint:SetPoint("CENTER", c, "TOPLEFT", 0, y)
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

-- A groove carved into the stone between its borders (Mid, 32 wide over the
-- 20-wide column, the groove its middle 8), the arrow buttons (32x32) over its
-- two ends, the thumb riding in it, and at each divider's y a Joint (32x16, its
-- x 6 the column's left edge) taking the divider into the left border and on
-- past the groove to the pane's edge.
local function groove(c, design, ends)
	local caps = {}
	for _, spec in ipairs({ { "Up", "TOP" }, { "Down", "BOTTOM" } }) do
		local b = CreateFrame("Button", nil, c)
		b:SetSize(32, 32)
		b:SetPoint(spec[2])
		b:SetHitRectInsets(6, 6, 0, 0) -- the column, not the art's spare width
		local base = spec[1] .. "-"
		b:SetNormalTexture(art(design, base .. "Normal"))
		b:SetPushedTexture(art(design, base .. "Pushed"))
		b:SetHighlightTexture(art(design, base .. "Highlight"), "ADD")
		b:SetDisabledTexture(art(design, base .. "Disabled"))
		caps[spec[1]] = b
	end
	local mid = c:CreateTexture(nil, "BACKGROUND")
	mid:SetTexture(art(design, "Mid"))
	mid:SetWidth(32)
	mid:SetPoint("TOP", caps.Up, "BOTTOM")
	mid:SetPoint("BOTTOM", caps.Down, "TOP")
	for _, y in ipairs(ends) do
		local joint = c:CreateTexture(nil, "ARTWORK")
		joint:SetTexture(art(design, "Joint"))
		joint:SetSize(32, 16)
		joint:SetPoint("LEFT", c, "TOPLEFT", -6, y)
	end
	-- the thumb: its ends, its centre (the set's motif) and the shaft stretched between
	local room = (c:GetHeight() > 0 and c:GetHeight() or 300) - 64
	local thumb = CreateFrame("Frame", nil, c)
	thumb:SetFrameLevel(c:GetFrameLevel() + 3)
	thumb:SetSize(32, room / 3)
	thumb:SetPoint("TOP", c, "TOP", 0, -32 - room / 6)
	local function piece(name, height, point)
		local t = thumb:CreateTexture(nil, "ARTWORK")
		t:SetTexture(art(design, name))
		t:SetSize(32, height)
		t:SetPoint(point)
		return t
	end
	local top, centre, bottom = piece("Thumb-Top", 8, "TOP"), piece("Thumb-Centre", 16, "CENTER"), piece("Thumb-Bottom", 8, "BOTTOM")
	for _, span in ipairs({ { top, centre }, { centre, bottom } }) do
		local shaft = thumb:CreateTexture(nil, "ARTWORK")
		shaft:SetTexture(art(design, "Thumb-Mid"))
		shaft:SetPoint("TOPLEFT", span[1], "BOTTOMLEFT")
		shaft:SetPoint("BOTTOMRIGHT", span[2], "TOPRIGHT")
	end
end

-- each: a name, its builder and its art. The spearhead's divider is Blizzard's
-- quest log divider; the grooves' are their own (RuleLeft, RuleMid stretched
-- to the Joint).
local OPTIONS = {
	{ "Bronze spearhead", spear, "Spear" },
	{ "Bronze lance", groove, "Lance" },
	{ "Iron fleur-de-lis", groove, "Fleur" },
	{ "Vine and leaf-bud", groove, "Bud" },
	{ "Inlaid lancet", groove, "Lancet" },
}

-- a conversation as the chat shows it, long enough to scroll: each turn's
-- band height, its owner's stone, the header and the text in the chat's fonts
local SAMPLE = {
	{ "you", "You 20:47", "The scroll bar again. Show me the real thing this time, at full size.", 64 },
	{ "claude", "Claude 20:48", "This is the chat at its real size, with the design you picked on its right. The arrows sit at the groove's ends and each divider meets the groove's edge.", 104 },
	{ "you", "You 20:49", "And the dividers between turns?", 64 },
	{ "claude", "Claude 20:50", "Each one runs the full width and joins the gutter's border, never the thumb, since the thumb moves.", 86 },
	{ "you", "You 20:51", "What about the stone behind the bar?", 64 },
	{ "claude", "Claude 20:52", "Each turn's stone runs on behind the groove to the panel's edge, so the bands never stop short.", 86 },
	{ "you", "You 20:53", "Good. Pick one on the right to compare.", 64 },
	{ "claude", "Claude 20:54", "Each button shows its design here, in the same place.", 0 },
}

-- a divider at y across the pane, as the bands run: Blizzard's to the
-- spearhead's column, its plain middle on under the column to the edge; a
-- groove's own to its Joint
local function divider(text, column, y, design)
	if design == "Spear" then
		local line = text:CreateTexture(nil, "ARTWORK")
		line:SetAtlas("QuestLog-frame-devider")
		line:SetAlpha(0.8)
		line:SetHeight(15)
		line:SetPoint("LEFT", text, "TOPLEFT", 0, y)
		line:SetPoint("RIGHT", column, "TOPLEFT", 0, y)
		local info = C_Texture.GetAtlasInfo("QuestLog-frame-devider")
		if info then
			local on = text:CreateTexture(nil, "ARTWORK")
			on:SetTexture(info.file)
			local l, r = info.leftTexCoord, info.rightTexCoord
			on:SetTexCoord(l + (r - l) * 0.45, l + (r - l) * 0.55, info.topTexCoord, info.bottomTexCoord)
			on:SetAlpha(0.8)
			on:SetHeight(15)
			on:SetPoint("LEFT", column, "TOPLEFT", 0, y)
			on:SetPoint("RIGHT", column, "TOPRIGHT", 0, y)
		end
		return
	end
	local left = text:CreateTexture(nil, "ARTWORK")
	left:SetTexture(art(design, "RuleLeft"))
	left:SetSize(32, 16)
	left:SetPoint("LEFT", text, "TOPLEFT", 0, y)
	local line = text:CreateTexture(nil, "ARTWORK")
	line:SetTexture(art(design, "RuleMid"))
	line:SetHeight(16)
	line:SetPoint("LEFT", left, "RIGHT")
	line:SetPoint("RIGHT", column, "TOPLEFT", -6, y) -- where the Joint takes it on
end

-- one design on a full-size copy of the chat well, in the chat well's place
local function pane(page, option)
	local box = CreateFrame("Frame", nil, page, "InsetFrameTemplate")
	if box.Bg then box.Bg:Hide() end
	-- the turns past the well's bottom are cut off there, as the chat's scroll does
	box:SetClipsChildren(true)
	local column = CreateFrame("Frame", nil, box)
	column:SetPoint("TOPRIGHT", -EDGE, -EDGE)
	column:SetPoint("BOTTOMRIGHT", -EDGE, EDGE)
	column:SetWidth(20)
	column:SetFrameLevel(box:GetFrameLevel() + 2)
	local text = CreateFrame("Frame", nil, box)
	text:SetPoint("TOPLEFT", EDGE, -EDGE)
	text:SetPoint("BOTTOMRIGHT", column, "BOTTOMLEFT")
	text:SetFrameLevel(box:GetFrameLevel() + 1)
	local y, ends = 0, {}
	for n, turn in ipairs(SAMPLE) do
		local band = text:CreateTexture(nil, "BACKGROUND")
		stone(band, turn[1])
		local head = text:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		head:SetPoint("TOPLEFT", 10, y - 8)
		head:SetText(turn[2])
		local fs = text:CreateFontString(nil, "OVERLAY", ChatFontNormal and "ChatFontNormal" or "GameFontHighlight")
		fs:SetJustifyH("LEFT")
		fs:SetTextColor(0.86, 0.83, 0.76)
		fs:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -4)
		fs:SetPoint("RIGHT", -10, 0)
		fs:SetText(turn[3])
		band:SetPoint("TOPLEFT", 0, y)
		band:SetPoint("RIGHT", column) -- on behind the groove, to the pane's edge
		if n == #SAMPLE then band:SetPoint("BOTTOM") else band:SetHeight(turn[4]) end
		if n > 1 then
			divider(text, column, y, option[3])
			ends[#ends + 1] = y
		end
		y = y - turn[4]
	end
	local ok, err = pcall(option[2], column, option[3], ends)
	return box, not ok and tostring(err) or nil
end

-- The tab: the preview where the chat sits, the designs as buttons where the
-- conversation list sits, in its buttons' art; the one picked shows.
WC.Companion.AddTab("Scroll bars", function(page)
	local log = WowCompanionLog
	local chatWell = log and log.chatWell
	local boxes, buttons = {}, {}
	local function pick(i)
		for n, box in ipairs(boxes) do box:SetShown(n == i) end
		for n, b in ipairs(buttons) do b.selected:SetShown(n == i) end
	end
	for i, option in ipairs(OPTIONS) do
		local box, err = pane(page, option)
		box:SetFrameLevel(page:GetFrameLevel() + 5)
		if chatWell then
			box:SetPoint("TOPLEFT", chatWell, "TOPLEFT")
			box:SetPoint("BOTTOMRIGHT", chatWell, "BOTTOMRIGHT")
		else
			box:SetAllPoints(page)
		end
		boxes[i] = box
		local b = CreateFrame("Button", nil, page)
		-- in the conversation list's own places, Main's button the first
		local first = log and log.convButtons and log.convButtons[""]
		if first then
			b:SetPoint("TOPLEFT", first, "TOPLEFT", 0, -(i - 1) * 24)
			b:SetPoint("TOPRIGHT", first, "TOPRIGHT", 0, -(i - 1) * 24)
			b:SetHeight(first:GetHeight())
		else
			b:SetSize(150, 21)
			b:SetPoint("TOPRIGHT", page, "TOPRIGHT", -6, -(i - 1) * 24)
		end
		b:SetFrameLevel(box:GetFrameLevel() + 10)
		local function art(layer, atlas)
			local t = b:CreateTexture(nil, layer)
			t:SetAtlas(atlas)
			t:SetPoint("TOPLEFT", -2, 0)
			t:SetPoint("BOTTOMRIGHT", 2, 0)
			return t
		end
		art("BACKGROUND", "auctionhouse-nav-button")
		b.selected = art("ARTWORK", "auctionhouse-nav-button-select")
		b.selected:SetBlendMode("ADD")
		art("HIGHLIGHT", "auctionhouse-nav-button-highlight"):SetBlendMode("ADD")
		local label = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		label:SetPoint("LEFT", 10, 0)
		label:SetPoint("RIGHT", -6, 0)
		label:SetJustifyH("LEFT")
		label:SetWordWrap(false)
		label:SetText(i .. ". " .. option[1] .. (err and " |cffff6060(failed)|r" or ""))
		b:SetScript("OnClick", function() pick(i) end)
		WC.MarkFocusable(b)
		buttons[i] = b
	end
	pick(1)
end)
