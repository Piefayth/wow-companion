-- The conversation list in the Companion window's right well (ConvLooks.lua
-- lays it out). Each row is a button the pad's cursor stops on (its name in the
-- normal font, its chord in the game's own glyphs, its state), the open one
-- the same row lit
-- (Agent.lua: b.Paint, b.selected:SetShown), with a cell for an offered button
-- (Offer.lua: frame.ConvLayout, frame.convOfferSlot).
local C = WC.ConvLooks

-- the names of the buttons that talk to `key` (Main is the talk button), as
-- the companion reported them; none until it has
local function chord(key)
	local settings = WC.Link and WC.Link.Settings and WC.Link.Settings()
	local value = settings and settings[key == "" and "talk" or key]
	local names = {}
	if type(value) == "string" then
		for name in value:gmatch("[^+]+") do names[#names + 1] = name end
	end
	return names
end
local function chordText(key)
	local glyphs = {}
	for i, name in ipairs(chord(key)) do glyphs[i] = WowCompanion_Glyph(name) end
	return table.concat(glyphs, " ")
end

function WC.Companion.ConvList(frame, well)
	local S = WC.Style
	local layer = CreateFrame("Frame", nil, well)
	layer:SetAllPoints()
	layer:SetFrameLevel(well:GetFrameLevel() + 1)
	-- the walls over every vine's ends
	if well.NineSlice then well.NineSlice:SetFrameLevel(layer:GetFrameLevel() + 3) end
	local pool = {} -- the look's textures, reused
	local function draw(i, d)
		local t = pool[i] or layer:CreateTexture()
		pool[i] = t
		t:SetTexCoord(0, 1, 0, 1)
		if d.stone then
			S.Stone(t, d.stone, d.shade)
		elseif d.grad then
			t:SetColorTexture(1, 1, 1, 1)
			local c = d.light and 1 or 0
			t:SetGradient(d.grad, CreateColor(c, c, c, d.from), CreateColor(c, c, c, d.to))
		else
			t:SetTexture(d.tex, "CLAMP", "CLAMP")
			t:SetHorizTile(false)
			t:SetVertTile(false)
			t:SetVertexColor(1, 1, 1)
			t:SetTexCoord(C.Coords(d))
		end
		t:SetDrawLayer(d.layer, d.sub)
		t:SetBlendMode((d.add or d.light) and "ADD" or "BLEND")
		t:SetAlpha(d.alpha or 1)
		t:ClearAllPoints()
		t:SetPoint("TOPLEFT", well, "TOPLEFT", d.x, -d.y)
		t:SetSize(d.w, d.h)
		t:Show()
	end
	local offerSlot = CreateFrame("Frame", nil, well)
	frame.convOfferSlot = offerSlot
	frame.convButtons = {}
	local buttons, open, offered = {}, nil, false
	-- the offer's cell anchors a secure button, so it moves only out of a
	-- fight: one move owed until the fight ends
	local offerAt, owed
	local function placeOffer()
		owed = false
		local o = offerAt
		if not o then return end
		offerSlot:ClearAllPoints()
		offerSlot:SetPoint("TOPLEFT", well, "TOPLEFT", o[1], -o[2])
		offerSlot:SetSize(o[3], o[4])
	end

	local function paintRow(b)
		local word = b.word ~= "" and b.word or nil
		b.name:SetTextColor(unpack(b.open and S.NAME_LIT or b.hover and S.NAME_HL or S.NAME))
		b.state:SetText(word or "")
		b.chord:SetText(chordText(b.key))
		b.chord:SetShown(not word)
		b.chord:SetAlpha(b.open and 1 or C.IDLE_GLYPH)
	end

	local function layout()
		local H = well:GetHeight() or 0
		if H <= 0 then return end
		local lay = C.Lay(H, offered, open or false)
		for i, d in ipairs(lay.pieces) do draw(i, d) end
		for i = #lay.pieces + 1, #pool do pool[i]:Hide() end
		for key, b in pairs(buttons) do
			local r = lay.rows[key]
			b.cell = r
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", well, "TOPLEFT", r.x, -r.y)
			b:SetSize(r.w, r.h)
			b.name:ClearAllPoints()
			b.name:SetPoint("LEFT", b, "LEFT", r.name, 0)
			b.chord:ClearAllPoints()
			b.chord:SetPoint("CENTER", b, "LEFT", r.chord, 0)
			b.state:ClearAllPoints()
			b.state:SetPoint("CENTER", b.chord)
			paintRow(b)
		end
		-- no offer: a point under the rows, for the button's first anchor
		local last = lay.rows[WC.Conversations.list[#WC.Conversations.list]]
		offerAt = lay.offer or { last.x, last.y + last.h, 1, 1 }
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

	for _, key in ipairs(WC.Conversations.list) do
		local b = CreateFrame("Button", nil, well)
		b.key, b.word = key, ""
		b:SetFrameLevel(layer:GetFrameLevel() + 2)
		b.name = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
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
		-- Agent.lua: the name, and the state ("12s", "new", the mic)
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
		-- Main is the one in view after a reload, so its news is being read; the
		-- news is Agent.lua's to paint
		local kept = type(WowCompanionAgentDB) == "table" and WowCompanionAgentDB.unread
		if kept and key == "" then kept[""] = nil end
		b.Paint(WC.Conversations.Label(key))
		b:SetScript("OnClick", function() WowCompanion_SetConversation(key) end)
		WC.MarkFocusable(b)
		buttons[key] = b
		frame.convButtons[key] = b
	end
	well:HookScript("OnSizeChanged", layout)
	frame.convButtons[""].selected:Show()
	layout()
end
