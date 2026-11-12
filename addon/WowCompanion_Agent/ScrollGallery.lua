-- A design sheet, for now: the candidate scroll bars, one at a time on a
-- full-size copy of the chat well that scrolls as the chat does (the turns,
-- their dividers and the dividers' joints move together; the bar stays, its
-- arrows scroll, its thumb follows), so the player compares them in the
-- Companion window instead of one reload per idea. Goes when a bar is chosen.

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
local ROUND6 = 5 -- the generator's VERSION6
local function art(design, piece)
	return ART .. design .. "-" .. piece .. "-" .. (design == "Spear" and 1 or ROUND6)
end
local ARROW = 16 -- an arrow's square, its art about 12 of it

local function arrows(c, design)
	local made = {}
	for _, spec in ipairs({ { "Up", "TOP", -2 }, { "Down", "BOTTOM", 2 } }) do
		local b = CreateFrame("Button", nil, c)
		b:SetSize(ARROW, ARROW)
		b:SetPoint(spec[2], 0, spec[3])
		local base = spec[1] .. "-"
		b:SetNormalTexture(art(design, base .. "Normal"))
		b:SetPushedTexture(art(design, base .. "Pushed"))
		b:SetHighlightTexture(art(design, base .. "Highlight"), "ADD")
		b:SetDisabledTexture(art(design, base .. "Disabled"))
		made[spec[1]] = b
	end
	return 2 + ARROW + 2, made.Up, made.Down
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

-- Each builder draws its bar in the column c, puts each divider's joint in
-- the lane (the strip over the column that scrolls with the turns) at the
-- divider's y (ends), and returns its arrows, its thumb and the thumb's inset
-- at each end of the column.

-- The spearhead: MinimalScrollBar's slim track and thumb, 8 wide, untinted.
local function spear(c, design, lane, ends)
	local inset, up, down = arrows(c, design)
	rule(c, design)
	for _, e in ipairs(ends) do
		local joint = lane:CreateTexture(nil, "OVERLAY")
		joint:SetTexture(art(design, "Joint"))
		joint:SetSize(16, 16)
		joint:SetPoint("CENTER", lane, "TOPLEFT", 0, e.y)
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
	column3(thumb, "ARTWORK", "minimal-scrollbar-small-thumb", "minimal-scrollbar-small-thumb-middle")
	return up, down, thumb, inset
end

-- A groove carved into the stone between its borders (Mid, 32 wide over the
-- 20-wide column, the groove its middle 8), the arrow buttons (32x32) over its
-- two ends, the thumb riding in it, and at each divider's y a Joint (32x16, its
-- x 6 the column's left edge) taking the divider into the left border and on
-- past the groove to the pane's edge.
-- the thumb art's opaque width, in the art's 32 (alpha over half, measured
-- off the TGAs), to the groove floor's 7.8
local FILL = { Lance = 7.8 / 5.75, Fleur = 7.8 / 5.5, Bud = 7.8 / 5.25, Lancet = 7.8 / 6.25 }
local function groove(c, design, lane, ends)
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
	for _, e in ipairs(ends) do
		local joint = lane:CreateTexture(nil, "ARTWORK")
		joint:SetTexture(art(design, "Joint" .. (e.thick and "Thick" or "")))
		joint:SetSize(32, 16)
		joint:SetPoint("LEFT", lane, "TOPLEFT", -6, e.y)
	end
	-- the thumb: its ends, its centre (the set's motif) and the shaft stretched between
	local thumb = CreateFrame("Frame", nil, c)
	thumb:SetFrameLevel(c:GetFrameLevel() + 3)
	-- as wide as the groove's floor (8 of the art's 32): the drawn thumb is
	-- narrower (measured, its opaque width per set), so its art is widened to
	-- fill the floor with no gap down either side
	thumb:SetWidth(32 * FILL[design])
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
	-- the thumb travels to the groove's own rounded ends, which lie inside the
	-- caps (the round end's centre 24 of each cap's 32, radius 4), so it meets
	-- them flush; it draws above the caps there, or their art hid its end
	return caps.Up, caps.Down, thumb, 20
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
-- owner (its stone), header, text in the chat's fonts, and band height
local SAMPLE = {
	{ "you", "You 20:47", "The scroll bar again. Show me the real thing this time, at full size.", 64 },
	{ "claude", "Claude 20:48", "This is the chat at its real size, with the design you picked on its right. The arrows sit at the groove's ends and each divider meets the groove's edge.", 104 },
	{ "you", "You 20:49", "And the dividers between turns?", 64 },
	{ "claude", "Claude 20:50", "Each one runs the full width and joins the gutter's border, never the thumb, since the thumb moves.", 86 },
	{ "you", "You 20:51", "What about the stone behind the bar?", 64 },
	{ "claude", "Claude 20:52", "Each turn's stone runs on behind the groove to the panel's edge, so the bands never stop short.", 86 },
	{ "you", "You 20:53", "Good. Pick one on the right to compare.", 64 },
	{ "claude", "Claude 20:54", "Each button shows its design here, in the same place.", 64 },
	{ "you", "You 20:55", "Does it scroll?", 64 },
	{ "claude", "Claude 20:56", "It does: the arrows move the turns, the dividers and their joints together, and the thumb follows.", 86 },
	{ "you", "You 20:57", "And the dividers stay lined up with the bar?", 64 },
	{ "claude", "Claude 20:58", "Each joint scrolls with its divider, so they meet the groove at every position.", 86 },
	{ "you", "You 20:59", "Show me the end.", 64 },
	{ "claude", "Claude 21:00", "This is the last turn; the thumb sits at the bottom of its groove.", 70 },
}

-- a divider at y across the turns, as the bands run: Blizzard's to the
-- spearhead's lane, its plain middle on under the lane to the edge; a groove's
-- own to its Joint
local function divider(text, lane, y, design, thick)
	if design == "Spear" then
		local line = text:CreateTexture(nil, "ARTWORK")
		line:SetAtlas("QuestLog-frame-devider")
		line:SetAlpha(thick and 1 or 0.8)
		line:SetHeight(thick and 22 or 15)
		line:SetPoint("LEFT", text, "TOPLEFT", 0, y)
		line:SetPoint("RIGHT", lane, "TOPLEFT", 0, y)
		local info = C_Texture.GetAtlasInfo("QuestLog-frame-devider")
		if info then
			local on = text:CreateTexture(nil, "ARTWORK")
			on:SetTexture(info.file)
			local l, r = info.leftTexCoord, info.rightTexCoord
			on:SetTexCoord(l + (r - l) * 0.45, l + (r - l) * 0.55, info.topTexCoord, info.bottomTexCoord)
			on:SetAlpha(thick and 1 or 0.8)
			on:SetHeight(thick and 22 or 15)
			on:SetPoint("LEFT", lane, "TOPLEFT", 0, y)
			on:SetPoint("RIGHT", lane, "TOPRIGHT", 0, y)
		end
		return
	end
	local left = text:CreateTexture(nil, "ARTWORK")
	local weight = thick and "Thick" or ""
	left:SetTexture(art(design, "RuleLeft" .. weight))
	left:SetSize(32, 16)
	left:SetPoint("LEFT", text, "TOPLEFT", 0, y)
	local line = text:CreateTexture(nil, "ARTWORK")
	line:SetTexture(art(design, "RuleMid" .. weight))
	line:SetHeight(16)
	line:SetPoint("LEFT", left, "RIGHT")
	line:SetPoint("RIGHT", lane, "TOPLEFT", -6, y) -- where the Joint takes it on
end

-- one design on a full-size copy of the chat well, in the chat well's place
local function pane(page, option)
	-- a plain frame holding the inset's border: InsetFrameTemplate is
	-- useParentLevel, so a box made of it ignores SetFrameLevel and stayed
	-- under the page well's top shadow (measured, level 2)
	local box = CreateFrame("Frame", nil, page)
	local border = CreateFrame("Frame", nil, box, "InsetFrameTemplate")
	border:SetAllPoints()
	if border.Bg then border.Bg:Hide() end
	local column = CreateFrame("Frame", nil, box)
	-- Shorter than the well, with the same clear stone past each tip, measured
	-- at 4K: the inset's top border reads thicker than its bottom one, and the
	-- down arrow's art carries its cast shadow below the tip; with 3 and 3 the
	-- top tip touched the border and the bottom one stood 15 px off.
	column:SetPoint("TOPRIGHT", -EDGE, -9)
	column:SetPoint("BOTTOMRIGHT", -EDGE, 4)
	column:SetWidth(20)
	column:SetFrameLevel(box:GetFrameLevel() + 3) -- above the top shadow (the lip, below)
	-- The turns scroll in a frame over the whole well, behind the bar: each
	-- turn's stone runs on behind the groove to the edge; the lane is the strip
	-- under the column, where each divider ends.
	local scroll = CreateFrame("ScrollFrame", nil, box)
	scroll:SetPoint("TOPLEFT", EDGE, -EDGE)
	scroll:SetPoint("BOTTOMRIGHT", -EDGE, EDGE)
	scroll:SetFrameLevel(box:GetFrameLevel() + 1)
	local text = CreateFrame("Frame", nil, scroll)
	scroll:SetScrollChild(text)
	local lane = CreateFrame("Frame", nil, text)
	lane:SetPoint("TOPRIGHT")
	lane:SetPoint("BOTTOMRIGHT")
	lane:SetWidth(20)
	-- The joints sit over the groove's border, so they scroll in a second,
	-- transparent frame above the column, kept at the same offset.
	local over = CreateFrame("ScrollFrame", nil, box)
	over:SetAllPoints(scroll)
	over:SetFrameLevel(box:GetFrameLevel() + 4)
	local overText = CreateFrame("Frame", nil, over)
	over:SetScrollChild(overText)
	local joints = CreateFrame("Frame", nil, overText)
	joints:SetPoint("TOPRIGHT")
	joints:SetPoint("BOTTOMRIGHT")
	joints:SetWidth(20)
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
		fs:SetPoint("RIGHT", lane, "LEFT", -10, 0)
		fs:SetText(turn[3])
		band:SetPoint("TOPLEFT", 0, y)
		band:SetPoint("RIGHT") -- on behind the groove, to the pane's edge
		band:SetHeight(turn[4])
		if n > 1 then
			-- the upper dividers thin, the lower ones thick: both weights in view
			local thick = n > #SAMPLE / 2 + 1
			divider(text, lane, y, option[3], thick)
			ends[#ends + 1] = { y = y, thick = thick }
		end
		y = y - turn[4]
	end
	local total = -y
	text:SetSize(1, total)
	overText:SetSize(1, total)

	local ok, built = pcall(function() return { option[2](column, option[3], joints, ends) } end)
	local up, down, thumb, inset
	if ok then
		up, down, thumb, inset = unpack(built)
		-- the arrows and thumb over the scrolling joints
		up:SetFrameLevel(box:GetFrameLevel() + 6)
		down:SetFrameLevel(box:GetFrameLevel() + 6)
		thumb:SetFrameLevel(box:GetFrameLevel() + 7)
	end
	-- The thumb's share of its room is the share of the conversation in view,
	-- its place the scroll's; an arrow moves most of a view, as the chat's do.
	local function paint()
		local view = scroll:GetHeight()
		text:SetWidth(scroll:GetWidth())
		overText:SetWidth(scroll:GetWidth())
		if not thumb or view <= 0 then return end
		local range = math.max(0, total - view)
		local room = column:GetHeight() - 2 * inset
		local size = math.max(24, room * math.min(1, view / total))
		local at = range > 0 and scroll:GetVerticalScroll() / range or 0
		thumb:SetHeight(size)
		thumb:ClearAllPoints()
		thumb:SetPoint("TOP", column, "TOP", 0, -(inset + (room - size) * at))
	end
	local function by(pages)
		local view = scroll:GetHeight()
		local range = math.max(0, total - view)
		scroll:SetVerticalScroll(math.max(0, math.min(range, scroll:GetVerticalScroll() + pages * view * 0.75)))
	end
	-- Whatever moves the turns (the arrows, a wheel, the stick, any offset at
	-- all), the joints and the thumb follow from here, the one place.
	scroll:SetScript("OnVerticalScroll", function(self, offset)
		over:SetVerticalScroll(offset)
		paint()
	end)
	if up then up:SetScript("OnClick", function() by(-1) end) end
	if down then down:SetScript("OnClick", function() by(1) end) end
	scroll:SetScript("OnSizeChanged", paint)
	box:SetScript("OnShow", paint)

	-- The chat's top shadow (Blizzard's ShadowOverlay-Top, as Window.lua's lip)
	-- over the turns, fading out sideways as it nears the bar, so the stone
	-- round the top arrow is as clean as round the bottom one, with no edge
	-- where the shadow stops.
	local FADE = 48
	local lip = CreateFrame("Frame", nil, box)
	lip:SetPoint("TOPLEFT", EDGE, -EDGE)
	lip:SetPoint("TOPRIGHT", column, "TOPLEFT", -6, 0)
	lip:SetHeight(24)
	lip:SetFrameLevel(box:GetFrameLevel() + 2)
	local shade = lip:CreateTexture(nil, "OVERLAY")
	shade:SetTexture([[Interface\Common\ShadowOverlay-Top]])
	shade:SetPoint("TOPLEFT")
	shade:SetPoint("BOTTOMRIGHT", -FADE, 0)
	local fade = lip:CreateTexture(nil, "OVERLAY")
	fade:SetTexture([[Interface\Common\ShadowOverlay-Top]])
	fade:SetPoint("TOPLEFT", shade, "TOPRIGHT")
	fade:SetPoint("BOTTOMRIGHT")
	fade:SetGradient("HORIZONTAL", CreateColor(1, 1, 1, 1), CreateColor(1, 1, 1, 0))
	return box, not ok and tostring(built) or nil
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
	-- Above the page well's own top shadow (Window.lua's pageLip, the well's
	-- level + 20), which shaded the whole preview's top, bar included. Set on
	-- each show: the page is re-parented after it is filled, which resets the
	-- levels set while filling.
	page:HookScript("OnShow", function()
		local above = page:GetParent():GetFrameLevel() + 25
		for n, box in ipairs(boxes) do
			box:SetFrameLevel(above)
			buttons[n]:SetFrameLevel(above + 10)
		end
	end)
end)
