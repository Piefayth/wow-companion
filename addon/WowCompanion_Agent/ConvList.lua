-- The conversation list in the Companion window's right well
-- (tools/make_convlist_art.py draws each look and says its idea). A trial
-- while the player picks one at true size: WC.Companion.ConvLook(key), or the
-- settings page's "Conversation list" row, switches it live, and
-- WowCompanionAgentDB.convLook keeps it; the looks not picked then go, with
-- their art and this switch.
-- Every look has a row a conversation (a button the pad's cursor stops on: its
-- name, its chord in the game's own glyphs, its state), the open one the same
-- row lit (Agent.lua: b.Paint, b.selected:SetShown), the player's crests
-- holding the list (Crest-*, never redrawn), and a cell for an offered button
-- above the foot (Offer.lua: frame.ConvLayout, frame.convOfferSlot).
local ART = [[Interface\AddOns\WowCompanion_Agent\Art\]]
local VERSION = 3 -- make_convlist_art.py's VERSION
local function art(look, piece, lit)
	return ("%sConv-%s-%s%s-%d"):format(ART, look, piece, lit and "-Lit" or "", VERSION)
end
-- in units, as make_convlist_art.py has them
local W, INSET = 130, 4
local RW = W - 2 * INSET
local HEAD_H, HEAD_RULE, FOOT_H, FOOT_RULE = 37, 32, 28, 4
local OFFER, GAP_MIN, HALF_W, BAND_H, STEM_W = 36, 10, 62, 10, 24
local GROUPS = { { "" }, { "l1", "l2" }, { "r1", "r2" }, { "quick" } } -- talk alone, left, right, both triggers
local PAD_BANDS = { { "" }, { "l1", "r1" }, { "l2", "r2" }, { "quick" } } -- as the shoulders sit

-- row: its height; grouped: the pad's groups apart; spread: down the whole
-- well; seam: between rows (negative: overlapping wires); pad: between the
-- crests' rules and the rows; rules: what lies between rows; name: its left
-- (or centred over the chord's cell, centred); chord: where its glyphs sit
-- (side, from that side, down from the middle); slot: the state shows there
-- instead, else at the right, state units in; ink: the open row's name dark
local LOOKS = {
	heartwood = { label = "Heartwood plaques", row = 40, grouped = true, spread = true, rules = "vine",
		name = 10, chord = { "RIGHT", 33, 0 }, slot = true },
	brass = { label = "Bronze nameplates", row = 34, pad = 1, name = 12, chord = { "RIGHT", 31, 0 }, slot = true,
		ink = true },
	spine = { label = "Leather spine", row = 38, pad = BAND_H / 2, rules = "band", name = 13,
		chord = { "RIGHT", 28, 0 }, slot = true },
	cloisonne = { label = "Enamel, as the pad", row = 54, grid = true, seam = -2, pad = 1, centred = { 15, 38.5 },
		slot = true },
	lantern = { label = "Lantern rails", row = 36, name = 57, nameDown = 1.5, chord = { "LEFT", 27, 2 }, state = 8 },
	stem = { label = "Lacquer signs on a stem", row = 32, grouped = true, spread = true, seam = 4, stem = true,
		name = 30, chord = { "RIGHT", 24, 0 }, slot = true },
}
local ORDER = { "heartwood", "brass", "spine", "cloisonne", "lantern", "stem" }
local INK = { 0.17, 0.12, 0.06 } -- a name on polished bronze
-- the same place, reached by different sums
local function near(a, b) return math.abs(a - b) < 0.01 end
local function picked()
	local key = type(WowCompanionAgentDB) == "table" and WowCompanionAgentDB.convLook
	return LOOKS[key] and key or ORDER[1]
end

local function bandsOf(look)
	if look.grid then return { PAD_BANDS } end
	local groups, all = {}, {}
	for _, g in ipairs(GROUPS) do
		local bands = {}
		for _, key in ipairs(g) do
			bands[#bands + 1] = { key }
			all[#all + 1] = { key }
		end
		groups[#groups + 1] = bands
	end
	return look.grouped and groups or { all }
end

-- Where everything goes in a well H tall, in units from its top left: each
-- row's { x, y, w, h } by key, the rules' ys, the head and foot crests' rule
-- ys (ornate: the crests fit), the offer's cell and the last row's foot.
local function place(look, H, offered)
	local groups = bandsOf(look)
	local row, seam, pad = look.row, look.seam or 0, look.pad or 0
	local nb, ng = 0, #groups
	for _, g in ipairs(groups) do nb = nb + #g end
	local off = offered and OFFER or 0
	local top, gap, ornate = HEAD_RULE + pad, 0, true
	if look.spread then
		local bottom = H - (FOOT_H - FOOT_RULE) - pad - off
		gap = (bottom - top - nb * row - (nb - ng) * seam) / math.max(ng - 1, 1)
		ornate = gap >= GAP_MIN
	else
		ornate = top + nb * row + (nb - 1) * seam + off + pad + FOOT_H - FOOT_RULE <= H
	end
	if not ornate then
		-- too short for the crests: the rows from wall to wall, shrunk only
		-- when even that is too little
		top = 6 + pad
		local fin = H - 6 - pad - off
		local least = look.spread and GAP_MIN or 0
		row = math.min(row, (fin - top - (ng - 1) * least - (nb - ng) * seam) / nb)
		if look.spread then gap = (fin - top - nb * row - (nb - ng) * seam) / math.max(ng - 1, 1) end
	end
	local rows, rules, y = {}, {}, top
	local function rule(at) if rules[#rules] ~= at then rules[#rules + 1] = at end end
	for gi, g in ipairs(groups) do
		if gi > 1 then y = y + gap end
		for bi, band in ipairs(g) do
			if bi > 1 then y = y + seam end
			rule(y)
			local w = #band == 1 and RW or HALF_W
			for j, key in ipairs(band) do rows[key] = { x = (j - 1) * (RW - w), y = y, w = w, h = row } end
			y = y + row
			rule(y)
		end
	end
	local foot = look.spread and ornate and H - (FOOT_H - FOOT_RULE) or y + off + pad
	return { rows = rows, rules = rules, ornate = ornate, head = ornate and HEAD_RULE or top - pad,
		foot = foot, last = y, offer = offered and { y + 6, y + off - 6 } or nil }
end

-- the glyphs of the buttons that talk to `key` (Main is the talk button), as
-- the companion reported them; "" until it has
local function chordText(key)
	local settings = WC.Link and WC.Link.Settings and WC.Link.Settings()
	local value = settings and settings[key == "" and "talk" or key]
	if type(value) ~= "string" then return "" end
	local glyphs = {}
	for name in value:gmatch("[^+]+") do glyphs[#glyphs + 1] = WowCompanion_Glyph(name) end
	return table.concat(glyphs, " ")
end

function WC.Companion.ConvList(frame, well)
	local S = WC.Style
	local layer = CreateFrame("Frame", nil, well)
	layer:SetAllPoints()
	layer:SetFrameLevel(well:GetFrameLevel() + 1)
	-- the walls over every rule's ends
	if well.NineSlice then well.NineSlice:SetFrameLevel(layer:GetFrameLevel() + 3) end
	local function texture(sub)
		local t = layer:CreateTexture(nil, "ARTWORK", nil, sub or 0)
		return t
	end
	local CREST = ART .. "Crest-%s"
	local head, foot = texture(3), texture(3)
	head:SetSize(W, HEAD_H)
	foot:SetSize(W, FOOT_H)
	local stem = layer:CreateTexture(nil, "BORDER")
	stem:SetTexture(art("stem", "Stem"), "CLAMP", "CLAMP")
	stem:SetWidth(STEM_W)
	local rules = {} -- a pool, each a texture across the well
	local offerSlot = CreateFrame("Frame", nil, well)
	frame.convOfferSlot = offerSlot
	frame.convButtons = {}
	local buttons, open, offered = {}, nil, false
	-- the offer's cell anchors a secure button, so it moves only out of a
	-- fight: one move owed until the fight ends
	local offerAt, owed
	local function placeOffer()
		owed = false
		local p = offerAt
		if not p then return end
		offerSlot:ClearAllPoints()
		if p.offer then
			offerSlot:SetPoint("TOPLEFT", well, "TOPLEFT", INSET + p.left, -p.offer[1])
			offerSlot:SetPoint("BOTTOMRIGHT", well, "TOPRIGHT", -INSET - 6, -p.offer[2])
		else
			offerSlot:SetPoint("TOPLEFT", well, "TOPLEFT", INSET, -p.last)
			offerSlot:SetSize(1, 1)
		end
	end

	local function paintRow(b)
		local look = LOOKS[picked()]
		local lit = b.open
		b.face:SetTexture(art(picked(), look.grid and (b.cell.w < RW and "Half" or "Wide") or "Row", lit))
		-- the open one over its neighbours' wire where they overlap
		b.face:SetDrawLayer("BORDER", lit and 2 or 1)
		b.name:SetTextColor(unpack(lit and (look.ink and INK or S.NAME_LIT) or b.hover and S.NAME_HL or S.NAME))
		local word = b.word ~= "" and b.word or nil
		b.state:SetText(word or "")
		b.chord:SetText(chordText(b.key))
		b.chord:SetShown(not (look.slot and word))
		b.chord:SetAlpha(lit and 1 or 0.6)
	end

	local function anchorRow(b, look)
		b.name:ClearAllPoints()
		b.chord:ClearAllPoints()
		b.state:ClearAllPoints()
		if look.centred then
			b.name:SetPoint("CENTER", b, "TOP", 0, -look.centred[1])
			b.chord:SetPoint("CENTER", b, "TOP", 0, -look.centred[2])
			b.state:SetPoint("CENTER", b.chord)
			return
		end
		b.name:SetPoint("LEFT", look.name, -(look.nameDown or 0))
		local side, from, down = unpack(look.chord)
		b.chord:SetPoint("CENTER", b, side, side == "RIGHT" and -from or from, -down)
		if look.slot then
			b.state:SetPoint("CENTER", b.chord)
		else
			b.state:SetPoint("RIGHT", -look.state, -(look.nameDown or 0))
		end
	end

	local function layout()
		local H = well:GetHeight() or 0
		if H <= 0 then return end
		local key = picked()
		local look = LOOKS[key]
		local p = place(look, H, offered)
		local openCell = open and p.rows[open]
		local function at(t, x, y) t:SetPoint("TOPLEFT", well, "TOPLEFT", x, -y) end
		for k, b in pairs(buttons) do
			local c = p.rows[k]
			b.cell = c
			b:ClearAllPoints()
			at(b, INSET + c.x, c.y)
			b:SetSize(c.w, c.h)
			anchorRow(b, look)
			paintRow(b)
		end
		-- the crests, lit with a vine look's open row beside them
		local litHead = look.rules == "vine" and openCell and near(openCell.y, p.head)
		local litFoot = look.rules == "vine" and openCell and near(openCell.y + openCell.h, p.foot)
		head:SetTexture(CREST:format(litHead and "Head-Lit" or "Head"), "CLAMP", "CLAMP")
		foot:SetTexture(CREST:format(litFoot and "Foot-Lit" or "Foot"), "CLAMP", "CLAMP")
		head:ClearAllPoints()
		at(head, 0, p.head - HEAD_RULE)
		foot:ClearAllPoints()
		at(foot, 0, p.foot - FOOT_RULE)
		head:SetShown(p.ornate)
		foot:SetShown(p.ornate)
		stem:SetShown(look.stem and true or false)
		stem:ClearAllPoints()
		at(stem, INSET, p.head)
		stem:SetHeight(p.foot - p.head)
		-- the rules: a vine look's vines (thick at the ends of a well too short
		-- for the crests), the spine's bands
		local n = 0
		local function rule(path, y, h, w)
			n = n + 1
			local t = rules[n] or texture(look.rules == "band" and 4 or 2)
			rules[n] = t
			t:SetTexture(path, "CLAMP", "CLAMP")
			t:SetDrawLayer("ARTWORK", look.rules == "band" and 4 or 2)
			t:ClearAllPoints()
			at(t, w and INSET or 0, y - h / 2)
			t:SetSize(w or W, h)
			t:Show()
		end
		if look.rules == "band" then
			for _, y in ipairs(p.rules) do rule(art("spine", "Band"), y, BAND_H, RW) end
		elseif look.rules == "vine" then
			local ys = {}
			for _, y in ipairs(p.rules) do ys[#ys + 1] = y end
			if not p.ornate and offered then ys[#ys + 1] = p.foot end
			for _, y in ipairs(ys) do
				local ends = near(y, p.head) or near(y, p.foot)
				local lit = openCell and (near(y, openCell.y) or near(y, openCell.y + openCell.h))
				if not (ends and p.ornate) then
					local piece = lit and (ART .. "ConvVine-Rule" .. (ends and "Thick" or "") .. "-Lit")
						or S.Vine(ends and "ThickMid" or "Mid")
					rule(piece, y, 16)
				end
			end
		end
		for i = n + 1, #rules do rules[i]:Hide() end
		p.left = look.stem and STEM_W or 6
		offerAt = p
		if not InCombatLockdown() then
			placeOffer()
		elseif not owed then
			owed = true
			WC.AfterCombat(placeOffer)
		end
	end
	-- Offer.lua: the offered button shown or gone; the list makes room for it
	function frame.ConvLayout(shown)
		offered = shown and true or false
		layout()
	end
	function WC.Companion.ConvLook(key)
		if not LOOKS[key] then return false end
		WowCompanionAgentDB.convLook = key
		layout()
		return true
	end

	for _, key in ipairs(WC.Conversations.list) do
		local b = CreateFrame("Button", nil, well)
		b.key, b.word = key, ""
		b:SetFrameLevel(layer:GetFrameLevel() + 2)
		b.face = layer:CreateTexture(nil, "BORDER", nil, 1)
		b.face:SetAllPoints(b)
		b.name = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
		b.name:SetJustifyH("LEFT")
		b.chord = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		b.state = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		local function hover(on)
			b.hover = on
			if b.cell then paintRow(b) end
		end
		b:SetScript("OnEnter", function() hover(true) end)
		b:SetScript("OnLeave", function() hover(false) end)
		-- the controller's pointer locks the highlight of the row it is on
		hooksecurefunc(b, "LockHighlight", function() hover(true) end)
		hooksecurefunc(b, "UnlockHighlight", function() hover(false) end)
		-- Agent.lua: the name, and the state word ("12s", "new")
		function b.Paint(label, word)
			b.name:SetText(label)
			b.word = word or ""
			if b.cell then paintRow(b) end
		end
		-- the one in view is the open row (Agent.lua shows it with SetShown)
		local selected = {}
		function selected:SetShown(on)
			on = on and true or false
			if b.open == on then return end
			b.open = on
			if on then open = key elseif open == key then open = nil end
			layout()
		end
		function selected:Show() self:SetShown(true) end
		b.selected = selected
		-- news kept across a reload shows from the start
		local kept = type(WowCompanionAgentDB) == "table" and WowCompanionAgentDB.unread
		-- Main is the one in view after a reload, so its news is being read
		if kept and key == "" then kept[""] = nil end
		b.Paint(WC.Conversations.Label(key), kept and kept[key] and S.GOOD .. "new|r")
		b:SetScript("OnClick", function() WowCompanion_SetConversation(key) end)
		WC.MarkFocusable(b)
		buttons[key] = b
		frame.convButtons[key] = b
	end
	well:HookScript("OnSizeChanged", layout)
	frame.convButtons[""].selected:Show()
	layout()

	WC.SettingsPage.Add({ kind = "dropdown", section = "Companion window", order = 12, label = "Conversation list",
		text = "A trial: the conversation list's looks, to pick one at true size. Each shows on the Chat tab at once.",
		options = function()
			local names = {}
			for i, key in ipairs(ORDER) do names[i] = LOOKS[key].label end
			return names
		end,
		get = function() return LOOKS[picked()].label end,
		set = function(label)
			for _, key in ipairs(ORDER) do
				if LOOKS[key].label == label then WC.Companion.ConvLook(key) end
			end
		end })
end
