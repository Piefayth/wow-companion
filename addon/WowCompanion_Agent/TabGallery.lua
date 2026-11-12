-- A design sheet, for now: the seven tab rows of the study
-- (target/tab-options), each on a full-size copy of the top of the Companion
-- window (its title band, rim, panel and chat well, the real transcript and
-- scroll bar scrolling real turns), so the player compares them live instead of
-- one reload per idea. The copy's tabs are our own plain buttons: a click picks
-- one, the cursor over one shows its hover. Goes when a row is chosen.

local STONE = WC.Style.STONE
-- Window.lua's layout, the copy drawn at the same numbers
local RIM, TOP, BAND, GAP, INSET, FLOOR, FOOT = 6, 28, 22.6, 4, 4, 3, 20
local CLOSE, CLOSE_PAD = 14, 3
local WELL_TOP = 64
local FRAME_ART = [[Interface\AddOns\WowCompanion_Agent\Art\%s-%s-20]]
local ART = [[Interface\AddOns\WowCompanion_Agent\Art\TabOpt%s-1]]
local NAME, NAME_HL, NAME_LIT = { 0.78, 0.69, 0.53 }, { 0.91, 0.84, 0.67 }, { 0.98, 0.92, 0.78 }
local LABELS = { "Chat", "Settings", "Status", "Errands" }

-- Rows painted by the study's own painters, one picture per chosen tab
-- (tools/make_tab_options_art.py prints this): the picture's rect, each tab's
-- hit rect, its label's centre unchosen then chosen; UI units from the
-- window's top left, y down. wellTop: where the chat well starts once the row
-- above it is gone.
local BAKED = {
	[2] = { box = { 13.8, 33.8, 291.2, 59.0 }, wellTop = 64.0,
		hits = { { 22.0, 36.0, 77.5, 56.0 }, { 77.5, 36.0, 150.4, 56.0 }, { 150.4, 36.0, 213.6, 56.0 }, { 213.6, 36.0, 282.4, 56.0 } },
		labels = { { 49.7, 46.0, 49.7, 46.0 }, { 113.9, 46.0, 113.9, 46.0 }, { 182.0, 46.0, 182.0, 46.0 }, { 248.0, 46.0, 248.0, 46.0 } } },
	[3] = { box = { 16.4, 21.2, 277.9, 63.8 }, wellTop = 64.0,
		hits = { { 20.0, 24.6, 67.5, 50.0 }, { 75.5, 24.6, 140.4, 50.0 }, { 148.4, 24.6, 203.6, 50.0 }, { 211.6, 24.6, 272.4, 50.0 } },
		labels = { { 43.7, 37.1, 43.7, 37.1 }, { 107.9, 37.1, 107.9, 37.1 }, { 176.0, 37.1, 176.0, 37.1 }, { 242.0, 37.1, 242.0, 37.1 } } },
	[4] = { box = { -78.1, 41.9, 8.2, 160.8 }, wellTop = 25.5,
		hits = { { -76.0, 44.0, 0.0, 68.0 }, { -76.0, 73.0, 0.0, 97.0 }, { -76.0, 102.0, 0.0, 126.0 }, { -76.0, 131.0, 0.0, 155.0 } },
		labels = { { -33.0, 56.0, -38.0, 56.0 }, { -33.0, 85.0, -38.0, 85.0 }, { -33.0, 114.0, -38.0, 114.0 }, { -33.0, 143.0, -38.0, 143.0 } } },
	[5] = { box = { 11.9, 5.6, 266.7, 22.7 }, wellTop = 25.5,
		hits = { { 14.0, 6.4, 65.5, 21.9 }, { 67.5, 6.4, 136.4, 21.9 }, { 138.4, 6.4, 197.6, 21.9 }, { 199.6, 6.4, 264.4, 21.9 } },
		labels = { { 39.7, 14.4, 39.7, 14.4 }, { 101.9, 14.4, 101.9, 14.4 }, { 168.0, 14.4, 168.0, 14.4 }, { 232.0, 14.4, 232.0, 14.4 } } },
	[7] = { box = { 18.2, 28.2, 282.7, 71.6 }, wellTop = 64.0,
		hits = { { 20.0, 30.0, 69.5, 64.0 }, { 76.5, 30.0, 143.4, 64.0 }, { 150.4, 30.0, 207.6, 64.0 }, { 214.6, 30.0, 277.4, 64.0 } },
		labels = { { 44.7, 52.5, 44.7, 44.5 }, { 109.9, 52.5, 109.9, 44.5 }, { 179.0, 52.5, 179.0, 44.5 }, { 246.0, 52.5, 246.0, 44.5 } } },
}

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
	{ "claude", "The plaques stand out from the window's left rim, and the title band row lifts the chat well into the freed space." },
	{ "you", "Good. Which one sits best?" },
	{ "claude", "Pick each on the right and compare: the chat's stone stays shaded and apart from the row in all of them." },
	{ "you", "Show me the end." },
	{ "claude", "This is the last turn." },
}

-- The options. Each build(r) draws its row into r.layer and places r.buttons
-- (r.rect), and returns show(chosen) and label(i, lit) -> centre.
local function baked(n)
	return function(r)
		local spec = BAKED[n]
		local pics = {}
		local b = spec.box
		for i = 1, #LABELS do
			local t = r.layer:CreateTexture(nil, "ARTWORK")
			t:SetTexture(ART:format(n .. "-Chosen" .. i))
			t:SetPoint("TOPLEFT", r.win, "TOPLEFT", b[1], -b[2])
			t:SetSize(b[3] - b[1], b[4] - b[2])
			pics[i] = t
		end
		for i, h in ipairs(spec.hits) do r.rect(r.buttons[i], h[1], h[2], h[3], h[4]) end
		return function(chosen)
			for i, t in ipairs(pics) do t:SetShown(i == chosen) end
		end, function(i, lit)
			local l = spec.labels[i]
			if lit then return l[3], l[4] end
			return l[1], l[2]
		end
	end
end

-- the labels' widths as the game draws them, laid out from x0
local function widths(buttons, pad, gap, x0, least)
	local spans, x = {}, x0
	for i, b in ipairs(buttons) do
		local w = math.max(b.label:GetStringWidth() + 2 * pad, least or 0)
		spans[i] = { x, x + w }
		x = x + w + gap
	end
	return spans
end

-- 1: one vine (the chat's medium) along the well's top, the names over it, a
-- bronze fleur hung from the vine under the chosen name
local function fleur(r)
	local VINE_Y, FS = 57, 0.95
	local vine = CreateFrame("Frame", nil, r.layer)
	vine:SetHeight(16)
	vine:SetPoint("LEFT", r.win, "TOPLEFT", 14.5, -VINE_Y)
	vine:SetPoint("RIGHT", r.well, "TOPRIGHT", -4.5, WELL_TOP - VINE_Y)
	WC.Style.VineLine(vine, "", false, true, true)
	local spans = widths(r.buttons, 16, 6, 18)
	for i, s in ipairs(spans) do r.rect(r.buttons[i], s[1], 31, s[2], 55) end
	local f = r.layer:CreateTexture(nil, "OVERLAY")
	f:SetTexture(ART:format("1-Fleur"))
	f:SetSize(32 * FS, 32 * FS)
	return function(chosen)
		local s = spans[chosen]
		f:ClearAllPoints()
		f:SetPoint("TOPLEFT", r.win, "TOPLEFT", (s[1] + s[2]) / 2 - 16 * FS, -(VINE_Y - 13.25 * FS - 0.6))
	end, function(i)
		return (spans[i][1] + spans[i][2]) / 2, 43
	end
end

-- 6: PanelTopTabButtonTemplate's own atlases, set up as its OnLoad does (the
-- top three quarters, flipped), desaturated and tinted to the window's bronze
local function blizzard(r)
	local FOOT_Y = 65.3 -- over the well's top border
	local TINT = { 0.99, 0.88, 0.72 }
	local function art(owner, layer, atlas)
		local t = owner:CreateTexture(nil, layer)
		local info = C_Texture.GetAtlasInfo(atlas)
		if not info then return t end
		t:SetTexture(info.file)
		local top, bottom = info.topTexCoord, info.bottomTexCoord
		t:SetTexCoord(info.leftTexCoord, info.rightTexCoord, bottom, top + (bottom - top) * 0.25)
		t:SetSize(info.width, info.height * 0.75)
		t:SetDesaturated(true)
		t:SetVertexColor(TINT[1], TINT[2], TINT[3])
		return t
	end
	local function set(b, layer, kind, left, right)
		local l = art(b, layer, "uiframe-" .. kind .. "-left")
		l:SetPoint("BOTTOMLEFT", left, 0)
		local rt = art(b, layer, "uiframe-" .. kind .. "-right")
		rt:SetPoint("BOTTOMRIGHT", right, 0)
		local m = art(b, layer, "_uiframe-" .. kind .. "-center")
		m:SetPoint("TOPLEFT", l, "TOPRIGHT")
		m:SetPoint("TOPRIGHT", rt, "TOPLEFT")
		return { l, m, rt }
	end
	local spans = widths(r.buttons, 15, 1, 14, 69)
	local idle, active = {}, {}
	for i, b in ipairs(r.buttons) do
		r.rect(b, spans[i][1], FOOT_Y - 32, spans[i][2], FOOT_Y)
		idle[i] = set(b, "BACKGROUND", "tab", -3, 7)
		active[i] = set(b, "BACKGROUND", "activetab", -1, 8)
		for _, t in ipairs(set(b, "HIGHLIGHT", "tab", -3, 7)) do
			t:SetBlendMode("ADD")
			t:SetAlpha(0.4)
		end
	end
	return function(chosen)
		for i = 1, #r.buttons do
			for _, t in ipairs(idle[i]) do t:SetShown(i ~= chosen) end
			for _, t in ipairs(active[i]) do t:SetShown(i == chosen) end
		end
	end, function(i, lit)
		return (spans[i][1] + spans[i][2]) / 2, FOOT_Y - (lit and 12 or 9)
	end
end

-- name, what it is, its builder, and where its row sits: "over" the chat
-- well, "behind" it (its feet under the well's wall) or "under" the window
-- (out from under its rim)
local OPTIONS = {
	{ "Fleur on the vine", "Names on the panel over one vine along the chat's top; a bronze fleur hangs from the vine under the chosen name.", fleur, "over" },
	{ "The scroll groove, laid flat", "A carved groove with bronze rails, as the scroll bar's; the chosen tab is its heartwood thumb.", baked(2), "over" },
	{ "Banners from the title rule", "Slate banners hung from the bronze rule under the title; the chosen one hangs longest, lit.", baked(3), "over" },
	{ "Plaques from under the rim", "Slate plaques sliding out from under the window's left rim; the chosen one out furthest. No tab row: the chat well rises.", baked(4), "under" },
	{ "Tabs in the title band", "No tab row: the names are the window's title, the chosen one in a carved, lit cartouche. The chat well rises.", baked(5), "over" },
	{ "Blizzard's own tab art, washed", "PanelTopTabButtonTemplate's own art, desaturated and tinted to our bronze, as Blizzard joins it to the well.", blizzard, "over" },
	{ "Bookmarks behind the wall", "Ribbons rising from behind the chat well's top wall, the wall over their feet; the chosen one tallest.", baked(7), "behind" },
}
local OUT = 84 -- room on the left for option 4's plaques

-- one option on its own copy of the window's top, filling `box`
local function replica(box, n)
	local option = OPTIONS[n]
	local L = box:GetFrameLevel()
	local spec = BAKED[n]
	local win = CreateFrame("Frame", nil, box)
	win:SetFrameLevel(L + 2)
	win:SetPoint("TOPLEFT", option[4] == "under" and OUT or 0, 0)
	win:SetPoint("BOTTOMRIGHT")
	nine(win, "Frame", RIM, TOP)
	local bg = win:CreateTexture(nil, "BACKGROUND")
	stone(bg, "you", 0.72)
	bg:SetPoint("TOPLEFT", RIM, -RIM)
	bg:SetPoint("BOTTOMRIGHT", -RIM, RIM)
	if n ~= 5 then
		local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		title:SetPoint("TOPLEFT", RIM + CLOSE_PAD + CLOSE, -RIM)
		title:SetPoint("BOTTOMRIGHT", win, "TOPRIGHT", -(RIM + CLOSE_PAD + CLOSE), -BAND)
		title:SetTextColor(0.90, 0.79, 0.55)
		title:SetText("Companion")
	end
	local close = win:CreateTexture(nil, "OVERLAY")
	close:SetTexture(FRAME_ART:format("Close", "Normal"))
	close:SetSize(CLOSE, CLOSE)
	close:SetPoint("TOPRIGHT", -(RIM + CLOSE_PAD), -(RIM + BAND - CLOSE) / 2)

	-- the chat well, as Window.lua builds it: the real transcript and scroll bar
	local well = CreateFrame("Frame", nil, win)
	well:SetFrameLevel(L + 4)
	well:SetPoint("TOPLEFT", RIM + GAP, -(spec and spec.wellTop or WELL_TOP))
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

	-- the row, at its place among the window's levels, and its tabs
	local layer = CreateFrame("Frame", nil, box)
	layer:SetAllPoints(win)
	layer:SetFrameLevel(L + ({ under = 1, behind = 3, over = 20 })[option[4]])
	local r = { win = win, well = well, layer = layer, buttons = {} }
	function r.rect(b, x0, y0, x1, y1)
		b:SetPoint("TOPLEFT", win, "TOPLEFT", x0, -y0)
		b:SetSize(x1 - x0, y1 - y0)
	end
	local chosen, hover = 1, nil
	local show, label
	local function paint()
		show(chosen)
		for i, b in ipairs(r.buttons) do
			local x, y = label(i, i == chosen)
			b.label:ClearAllPoints()
			b.label:SetPoint("CENTER", win, "TOPLEFT", x, -y)
			b.label:SetTextColor(unpack(i == chosen and NAME_LIT or i == hover and NAME_HL or NAME))
		end
	end
	for i, name in ipairs(LABELS) do
		local b = CreateFrame("Button", nil, layer)
		b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		b.label:SetText(name)
		b:SetScript("OnClick", function() chosen = i paint() end)
		b:SetScript("OnEnter", function() hover = i paint() end)
		b:SetScript("OnLeave", function() hover = nil paint() end)
		WC.MarkFocusable(b)
		r.buttons[i] = b
	end
	show, label = option[3](r)
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
					buttons[n].label:SetText(n .. ". " .. OPTIONS[n][1] .. " |cffff6060(failed)|r")
				end
				boxes[n] = b
			end
			for i, b in pairs(boxes) do b:SetShown(i == n) end
			for i, b in ipairs(buttons) do b.selected:SetShown(i == n) end
			about:SetText(failed[n] or OPTIONS[n][2])
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
			b.label:SetText(n .. ". " .. option[1])
			b:SetScript("OnClick", function() pick(n) end)
			WC.MarkFocusable(b)
			buttons[n] = b
		end
		pick(1)
	end)
end)
