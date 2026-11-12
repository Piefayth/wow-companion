-- A design sheet, for now: round two of the tab study (the player's verdict on
-- round one is in docs/proposals/companion-tabs.md), each candidate on a
-- full-size copy of the top of the Companion window (its title band, rim,
-- panel and chat well, the real transcript and scroll bar scrolling real
-- turns), so the player compares them live instead of one reload per idea.
-- The copy's tabs are our own plain buttons: a click picks one, the cursor over
-- one shows its hover. Goes when a row is chosen.

local STONE = WC.Style.STONE
-- Window.lua's layout, the copy drawn at the same numbers
local RIM, TOP, BAND, GAP, INSET, FLOOR, FOOT = 6, 28, 22.6, 4, 4, 3, 20
local CLOSE, CLOSE_PAD = 14, 3
local WELL_TOP = 64
local RISEN = 25.5 -- the chat well's top with no tab row above it
local FRAME_ART = [[Interface\AddOns\WowCompanion_Agent\Art\%s-%s-20]]
-- tools/make_tab_options_art.py's pieces, one tab's each
local ART = [[Interface\AddOns\WowCompanion_Agent\Art\TabOpt%s-2]]
local NAME, NAME_HL, NAME_LIT = { 0.78, 0.69, 0.53 }, { 0.91, 0.84, 0.67 }, { 0.98, 0.92, 0.78 }
-- letters cut in the slate: its paler stone where idle, gilt when chosen
local CUT, CUT_HL = { 0.59, 0.61, 0.66 }, { 0.75, 0.76, 0.80 }
local LABELS = { "Chat", "Settings", "Status", "Errands" }

-- a frame's border from our art on its own bounds, as Window.lua's dress
local function nine(owner, art, rim, top)
	local t = {}
	for _, name in ipairs({ "TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner",
		"TopEdge", "BottomEdge", "LeftEdge", "RightEdge" }) do
		t[name] = owner:CreateTexture(nil, "BORDER")
		t[name]:SetTexture(FRAME_ART:format(art, name))
	end
	t.TopLeftCorner:SetPoint("TOPLEFT")
	t.TopRightCorner:SetPoint("TOPRIGHT")
	t.BottomLeftCorner:SetPoint("BOTTOMLEFT")
	t.BottomRightCorner:SetPoint("BOTTOMRIGHT")
	t.TopLeftCorner:SetSize(rim, top)
	t.TopRightCorner:SetSize(rim, top)
	t.BottomLeftCorner:SetSize(rim, rim)
	t.BottomRightCorner:SetSize(rim, rim)
	t.TopEdge:SetPoint("TOPLEFT", t.TopLeftCorner, "TOPRIGHT")
	t.TopEdge:SetPoint("BOTTOMRIGHT", t.TopRightCorner, "BOTTOMLEFT")
	t.BottomEdge:SetPoint("TOPLEFT", t.BottomLeftCorner, "TOPRIGHT")
	t.BottomEdge:SetPoint("BOTTOMRIGHT", t.BottomRightCorner, "BOTTOMLEFT")
	t.LeftEdge:SetPoint("TOPLEFT", t.TopLeftCorner, "BOTTOMLEFT")
	t.LeftEdge:SetPoint("BOTTOMRIGHT", t.BottomLeftCorner, "TOPRIGHT")
	t.RightEdge:SetPoint("TOPLEFT", t.TopRightCorner, "BOTTOMLEFT")
	t.RightEdge:SetPoint("BOTTOMRIGHT", t.BottomRightCorner, "TOPRIGHT")
end

local function stone(tex, which, k)
	tex:SetTexture(STONE[which], "REPEAT", "REPEAT")
	tex:SetHorizTile(true)
	tex:SetVertTile(true)
	if k then tex:SetVertexColor(k, k, k) end
end

-- a conversation long enough to scroll, in the real transcript
local SAMPLE = {
	{ "you", "The tabs again. Show me each one on the real window this time." },
	{ "claude", "This is the top of the Companion window at its true size: the title band, the panel and the chat well, with each tab row in its own place above the chat." },
	{ "you", "Can I scroll it?" },
	{ "claude", "Yes: the wheel and the arrows move the turns under the tabs, as the chat does, so you see each row against a moving chat." },
	{ "you", "And the chosen tab?" },
	{ "claude", "Click a tab in the copy to choose it; the cursor over one shows its hover." },
	{ "you", "What about the ones that move things?" },
	{ "claude", "The plaques come out from under the window's top or bottom rim, and the chat well rises into the row they free." },
	{ "you", "Good. Which one sits best?" },
	{ "claude", "Pick each on the right and compare: the chat's stone stays shaded and apart from the row in all of them." },
	{ "you", "Show me the end." },
	{ "claude", "This is the last turn." },
}

-- The options. Each build(r) draws its row into r.layer and places r.buttons
-- (r.rect), and returns show(chosen) and label(i, lit) -> x, y (from the
-- window's top left, or its bottom left for a row under the window).

-- 1a, 1b: the chat's vine along the well's top, the names over it, a bronze
-- fleur hung in front of the vine under the chosen name; 1b sets each name
-- on a slate lens
local VINE_Y, FS, NAME_Y = 55, 1.3, 41
local function fleur(backed)
	return function(r)
		local vine = CreateFrame("Frame", nil, r.layer)
		vine:SetHeight(16)
		vine:SetPoint("LEFT", r.win, "TOPLEFT", 14.5, -VINE_Y)
		vine:SetPoint("RIGHT", r.well, "TOPRIGHT", -4.5, WELL_TOP - VINE_Y)
		WC.Style.VineLine(vine, "", false, true, true)
		local spans, backs = {}, {}
		local x = backed and 14 or 18
		for i, b in ipairs(r.buttons) do
			local w = backed and 96 or b.label:GetStringWidth() + 32
			spans[i] = { x, x + w }
			x = x + w + (backed and 2 or 6)
			r.rect(b, spans[i][1], NAME_Y - 10, spans[i][2], NAME_Y + 10)
			if backed then
				backs[i] = {}
				for _, piece in ipairs({ "Idle", "Chosen" }) do
					local t = r.layer:CreateTexture(nil, "ARTWORK")
					t:SetTexture(ART:format("1b-" .. piece))
					t:SetPoint("TOPLEFT", r.win, "TOPLEFT", spans[i][1], -(NAME_Y - 10))
					t:SetSize(96, 20)
					backs[i][piece] = t
				end
			end
		end
		-- its own frame above the vine's, so it hangs in front of it
		local front = CreateFrame("Frame", nil, r.layer)
		front:SetAllPoints(r.layer)
		front:SetFrameLevel(vine:GetFrameLevel() + 2)
		local f = front:CreateTexture(nil, "ARTWORK")
		f:SetTexture(ART:format("1-Fleur"))
		f:SetSize(32 * FS, 36 * FS)
		return function(chosen)
			local s = spans[chosen]
			f:ClearAllPoints()
			f:SetPoint("TOPLEFT", r.win, "TOPLEFT", (s[1] + s[2]) / 2 - 16 * FS, -(VINE_Y - 13.2 * FS))
			for i, t in ipairs(backs) do
				t.Idle:SetShown(i ~= chosen)
				t.Chosen:SetShown(i == chosen)
			end
		end, function(i)
			return (spans[i][1] + spans[i][2]) / 2, NAME_Y
		end
	end
end

-- 3a..4b: a piece per tab, Idle or Chosen, w x h, the first at x0 and each
-- `step` on, its top `top` below the anchor's edge; hit: the tab's rect in
-- the piece; ys: the name's centre in the piece, idle then chosen
local function plaques(id, s)
	return function(r)
		local idle, lit = {}, {}
		for i, b in ipairs(r.buttons) do
			local x = s.x0 + (i - 1) * s.step
			local function art(piece)
				local t = r.layer:CreateTexture(nil, "ARTWORK")
				t:SetTexture(ART:format(id .. "-" .. piece))
				t:SetPoint("TOPLEFT", r.win, r.anchor, x, -s.top)
				t:SetSize(s.w, s.h)
				return t
			end
			idle[i], lit[i] = art("Idle"), art("Chosen")
			local h = s.hit
			r.rect(b, x + h[1], s.top + h[2], x + h[3], s.top + h[4])
		end
		return function(chosen)
			for i = 1, #idle do
				idle[i]:SetShown(i ~= chosen)
				lit[i]:SetShown(i == chosen)
			end
		end, function(i, isLit)
			return s.x0 + (i - 1) * s.step + s.w / 2, s.top + s.ys[isLit and 2 or 1]
		end
	end
end

-- id, name, what it is, its builder, and where its row sits: "over" the
-- panel, or under the window's rim "above" or "below" it (the chat well
-- risen into the freed row); its names' font, and "cut" for engraved names
local OPTIONS = {
	{ "1a", "Fleur, heavier names", "The vine along the chat's top, the names over it in the larger type, lit when chosen; the fleur hangs in front of the vine under the chosen name.",
		fleur(false), "over", "GameFontNormalMed3" },
	{ "1b", "Fleur, names on lenses", "As 1a, each name on a slate lens rimmed in wire, curled at its points; the chosen lens on the lighter slate, its wire lit.",
		fleur(true), "over", "GameFontNormalMed3" },
	{ "3a", "Escutcheon on hooks", "Notched slate plaques on two wire hooks caught over the title rule; the chosen one hangs lower, on the lighter slate, its bronze lit.",
		plaques("3a", { w = 84, h = 40, x0 = 14, step = 82, top = 20, hit = { 7, 9, 77, 34 }, ys = { 21, 24 } }), "over" },
	{ "3b", "Cartouche", "Slate cartouches framed in wire scrolled back at both ends, each on one stem crowned on the title rule; the chosen one hangs lower and lit.",
		plaques("3b", { w = 92, h = 40, x0 = 10, step = 90, top = 20, hit = { 14, 10, 78, 32 }, ys = { 21, 24 } }), "over" },
	{ "3c", "Framed, engraved", "Slate plaques in a broad bevelled bronze frame, hung as pictures are from the title rule; names cut in the slate, gilt in the chosen one.",
		plaques("3c", { w = 84, h = 42, x0 = 14, step = 82, top = 20, hit = { 8, 11, 76, 37 }, ys = { 24, 27 } }), "over", nil, "cut" },
	{ "4a", "Plaques over the top rim", "Round one's plaques, moved from the window's side to rise from under its top rim, so the conversation list stays the one column. The chosen one stands tallest.",
		plaques("4a", { w = 80, h = 32, x0 = 18, step = 80, top = -28, hit = { 3, 8, 77, 28 }, ys = { 18, 15 } }), "above" },
	{ "4b", "Plaques under the bottom rim", "The same plaques hanging from under the window's bottom rim, below the legend; the chosen one hangs lowest.",
		plaques("4b", { w = 80, h = 32, x0 = 18, step = 80, top = -4, hit = { 3, 4, 77, 24 }, ys = { 14, 17 } }), "below" },
}
local ROOM = 32 -- the copy's room above or below the window for 4a and 4b

-- one option on its own copy of the window's top, filling `box`
local function replica(box, n)
	local option = OPTIONS[n]
	local place = option[5]
	local L = box:GetFrameLevel()
	local win = CreateFrame("Frame", nil, box)
	win:SetFrameLevel(L + 2)
	win:SetPoint("TOPLEFT", 0, place == "above" and -ROOM or 0)
	win:SetPoint("BOTTOMRIGHT", 0, place == "below" and ROOM or 0)
	nine(win, "Frame", RIM, TOP)
	local bg = win:CreateTexture(nil, "BACKGROUND")
	stone(bg, "you", 0.72)
	bg:SetPoint("TOPLEFT", RIM, -RIM)
	bg:SetPoint("BOTTOMRIGHT", -RIM, RIM)
	local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", RIM + CLOSE_PAD + CLOSE, -RIM)
	title:SetPoint("BOTTOMRIGHT", win, "TOPRIGHT", -(RIM + CLOSE_PAD + CLOSE), -BAND)
	title:SetTextColor(0.90, 0.79, 0.55)
	title:SetText("Companion")
	local close = win:CreateTexture(nil, "OVERLAY")
	close:SetTexture(FRAME_ART:format("Close", "Normal"))
	close:SetSize(CLOSE, CLOSE)
	close:SetPoint("TOPRIGHT", -(RIM + CLOSE_PAD), -(RIM + BAND - CLOSE) / 2)

	-- the chat well, as Window.lua builds it: the real transcript and scroll bar
	local well = CreateFrame("Frame", nil, win)
	well:SetFrameLevel(L + 4)
	well:SetPoint("TOPLEFT", RIM + GAP, -(place == "over" and WELL_TOP or RISEN))
	well:SetPoint("BOTTOMRIGHT", -(RIM + GAP), RIM + FOOT)
	nine(well, "Inset", INSET, INSET)
	local floor = well:CreateTexture(nil, "BACKGROUND", nil, 1)
	stone(floor, "you")
	floor:SetPoint("TOPLEFT", FLOOR, -FLOOR)
	floor:SetPoint("BOTTOMRIGHT", -FLOOR, FLOOR)
	local level = well:GetFrameLevel()
	local chat = WC.Transcript.newTranscript(well)
	chat.scroll:SetPoint("TOPLEFT", INSET, -INSET)
	chat.scroll:SetPoint("BOTTOMRIGHT", -INSET, INSET)
	chat.scroll:SetFrameLevel(level + 1)
	chat.content:SetFrameLevel(level + 2)
	local column = WC.ChatBar.Build(well, chat.scroll, INSET, level)
	WC.MarkTextScroll(chat.scroll)
	chat:Hold(true)
	local at = time() - #SAMPLE * 60
	for i, turn in ipairs(SAMPLE) do chat:Add(turn[1], turn[2], false, at + i * 60) end
	chat:Hold(false)
	-- the chat's top shadow, as Window.lua's lip
	local FADE = 48
	local lip = CreateFrame("Frame", nil, well)
	lip:SetPoint("TOPLEFT", chat.scroll, "TOPLEFT")
	lip:SetPoint("TOPRIGHT", column, "TOPLEFT", -6, 0)
	lip:SetHeight(24)
	lip:SetFrameLevel(level + 5)
	local shade = lip:CreateTexture(nil, "OVERLAY")
	shade:SetTexture([[Interface\Common\ShadowOverlay-Top]])
	shade:SetPoint("TOPLEFT")
	shade:SetPoint("BOTTOMRIGHT", -FADE, 0)
	local fade = lip:CreateTexture(nil, "OVERLAY")
	fade:SetTexture([[Interface\Common\ShadowOverlay-Top]])
	fade:SetPoint("TOPLEFT", shade, "TOPRIGHT")
	fade:SetPoint("BOTTOMRIGHT")
	fade:SetGradient("HORIZONTAL", CreateColor(1, 1, 1, 1), CreateColor(1, 1, 1, 0))

	-- the row, over the window or under its rim, and its tabs
	local layer = CreateFrame("Frame", nil, box)
	layer:SetAllPoints(win)
	layer:SetFrameLevel(L + (place == "over" and 20 or 1))
	local r = { win = win, well = well, layer = layer, buttons = {}, anchor = place == "below" and "BOTTOMLEFT" or "TOPLEFT" }
	function r.rect(b, x0, y0, x1, y1)
		b:SetPoint("TOPLEFT", win, r.anchor, x0, -y0)
		b:SetSize(x1 - x0, y1 - y0)
	end
	local cut = option[7] == "cut"
	local chosen, hover = 1, nil
	local show, label
	local function paint()
		show(chosen)
		for i, b in ipairs(r.buttons) do
			local x, y = label(i, i == chosen)
			b.label:ClearAllPoints()
			b.label:SetPoint("CENTER", win, r.anchor, x, -y)
			local idle, hl = NAME, NAME_HL
			if cut then idle, hl = CUT, CUT_HL end
			b.label:SetTextColor(unpack(i == chosen and NAME_LIT or i == hover and hl or idle))
		end
	end
	for i, name in ipairs(LABELS) do
		local b = CreateFrame("Button", nil, layer)
		b.label = b:CreateFontString(nil, "OVERLAY", option[6] or "GameFontNormal")
		b.label:SetText(name)
		if cut then
			-- sunk: the shade on the cut's top left wall
			b.label:SetShadowOffset(-1, 1)
		elseif option[6] then
			b.label:SetShadowOffset(1.5, -1.5)
			b.label:SetShadowColor(0, 0, 0, 1)
		end
		b:SetScript("OnClick", function() chosen = i paint() end)
		b:SetScript("OnEnter", function() hover = i paint() end)
		b:SetScript("OnLeave", function() hover = nil paint() end)
		WC.MarkFocusable(b)
		r.buttons[i] = b
	end
	show, label = option[4](r)
	paint()
end

-- The tab: the picker on the right, the copy of the window filling the rest;
-- made the first time it is looked at, each copy the first time it is picked.
WC.Companion.AddTab("Tab styles", function(page)
	local built
	page:HookScript("OnShow", function()
		if built then return end
		built = true
		-- above the page well's own top shadow (Window.lua's pageLip, its level + 20)
		local above = page:GetParent():GetFrameLevel() + 25
		local PICK = 170
		local box = CreateFrame("Frame", nil, page)
		box:SetFrameLevel(above)
		box:SetPoint("TOPLEFT")
		box:SetPoint("BOTTOMRIGHT", -(PICK + 10), 0)
		box:SetClipsChildren(true)
		local about = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		about:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, -(#OPTIONS * 24 + 10))
		about:SetWidth(PICK)
		about:SetJustifyH("LEFT")
		local boxes, buttons, failed = {}, {}, {}
		local function pick(n)
			if not boxes[n] then
				local b = CreateFrame("Frame", nil, box)
				b:SetAllPoints()
				b:SetFrameLevel(above + 1)
				local ok, err = pcall(replica, b, n)
				if not ok then
					failed[n] = "|cffff6060" .. tostring(err) .. "|r"
					buttons[n].label:SetText(OPTIONS[n][1] .. ". " .. OPTIONS[n][2] .. " |cffff6060(failed)|r")
				end
				boxes[n] = b
			end
			for i, b in pairs(boxes) do b:SetShown(i == n) end
			for i, b in ipairs(buttons) do b.selected:SetShown(i == n) end
			about:SetText(failed[n] or OPTIONS[n][3])
		end
		for n, option in ipairs(OPTIONS) do
			local b = CreateFrame("Button", nil, page)
			b:SetFrameLevel(above + 30)
			b:SetSize(PICK, 21)
			b:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, -(n - 1) * 24)
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
			b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			b.label:SetPoint("LEFT", 10, 0)
			b.label:SetPoint("RIGHT", -6, 0)
			b.label:SetJustifyH("LEFT")
			b.label:SetWordWrap(false)
			b.label:SetText(option[1] .. ". " .. option[2])
			b:SetScript("OnClick", function() pick(n) end)
			WC.MarkFocusable(b)
			buttons[n] = b
		end
		pick(1)
	end)
end)
