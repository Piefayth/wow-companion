-- The settings page: one column of settings rows in our window, each row one
-- controller stop (Rows.lua: left and right change it, confirm opens a
-- dropdown's menu or presses a button, up and down move between rows). The
-- page is three sunk wells (below): the section names down the left beside
-- their rows; the rows from there to the right edge, name at the left,
-- control at the edge, the chat's vine between sections; the focused
-- row's note in the well under them, its name in gold, where Blizzard shows
-- a tooltip.
-- Owned by Core so it works without the Agent; each addon adds its own rows.
-- Shown in a window of its own (the minimap mark, Blizzard's AddOns settings)
-- or inside another frame (the Companion window's Settings tab).
--
--   WC.SettingsPage.Add(row)     row: { kind = "dropdown" | "slider" | "button" | "key",
--                                section (its name in the names well), label, text
--                                (its note, or a function giving it), order (lower
--                                first; a section goes where its first row does),
--                                and by kind:
--                                options()/get()/set(name);
--                                min, max, steps, get()/set(value), format(value);
--                                button (its text, or a function giving it), onClick();
--                                key: as button, drawn as Blizzard's key-binding button }
--   WC.SettingsPage.Refresh()    the rows' values and notes drawn again, for rows
--                                whose values change by themselves
--   WC.SettingsPage.Open()       the page in its own window
--   WC.SettingsPage.ShowIn(f)    the page inside frame f (anchored to fill it)

local Page = {}
WC.SettingsPage = Page

local rows = {}    -- every row added: { row = the caller's table, frame = once made }
local refreshers = {} -- one per made row whose shown value can change
local headers = {} -- section name -> its name in the names well
-- the controls 200 wide: Blizzard's 250 is for a 920-wide Settings window;
-- in ours it took half of each row and dwarfed the names
local ROW_H, GAP, CONTROL_W = 36, 24, 200
-- the names well's width from the page's left; a row's name inset from it;
-- the control's inset from the right edge (a slider's value text after it)
local SPINE, LABEL_X, EDGE, VALUE_W = 170, 10, 8, 32

local page = CreateFrame("Frame", "WowCompanionSettingsPage", UIParent)
page:Hide()

-- Three wells (WC.Style.Well), as the Chat tab is made of wells: the section
-- names down the left on the dark stone, the settings on the light stone, the
-- focused row's note under them on the dark (its name in gold), so the note
-- has a place of its own (the player's pick from the Settings looks sheet,
-- 2026-11-12). Out to the page well's floor; fixed while the rows scroll.
local FOOT, SEAM = 58, WC.Style.SEAM
local BX, BY = WC.Style.BLEED_X, WC.Style.BLEED_Y
local band = CreateFrame("Frame", nil, page)
band:SetPoint("BOTTOMLEFT", SPINE, 0)
band:SetPoint("BOTTOMRIGHT", 0, 0)
band:SetHeight(FOOT)
WC.Style.PageRock(page)
local function well(which, left, top, right, bottom, shade, raised, sunk)
	local t = WC.Style.Well(page, which, shade, raised, sunk)
	t:SetPoint("TOPLEFT", left[1], left[2], left[3], top)
	t:SetPoint("BOTTOMRIGHT", right[1], right[2], right[3], bottom)
	return t
end
-- names: the left edge to the seam; settings: the seam to the right edge,
-- down to the note's seam; the note: under the settings
-- The dark wells raised, on trial (the player, 2026-11-12; Style.lua's
-- Well): the settings well lies lower, between them, and takes the names
-- well's shadow down its left edge in place of its own
local names = well("you", { page, "TOPLEFT", -BX }, BY, { page, "BOTTOMLEFT", SPINE - 2 - SEAM }, -BY, WC.Style.DEEPER, true)
local settings = well("claude", { page, "TOPLEFT", SPINE - 2 }, BY, { band, "TOPRIGHT", BX }, SEAM, nil, false, { "Top" })
well("you", { band, "TOPLEFT", -2 }, 0, { band, "BOTTOMRIGHT", BX }, -BY, WC.Style.DEEPER, true)
-- a setting's name and the note's title in LABEL; the section names stay white
local LABEL = WC.Style.LABEL
local bandName = band:CreateFontString(nil, "OVERLAY", "GameFontNormal")
bandName:SetPoint("TOPLEFT", 14, -10)
bandName:SetPoint("RIGHT", -EDGE, 0)
bandName:SetJustifyH("LEFT")
bandName:SetTextColor(unpack(LABEL))
local bandText = band:CreateFontString(nil, "OVERLAY", "GameFontHighlightMed2")
bandText:SetPoint("TOPLEFT", bandName, "BOTTOMLEFT", 0, -4)
bandText:SetPoint("BOTTOMRIGHT", -EDGE, 2)
bandText:SetJustifyH("LEFT")
bandText:SetJustifyV("TOP")
-- a row's note: a string, or a function for one that changes
local function textOf(v)
	if type(v) == "function" then return v() end
	return v
end
-- with no row under the cursor, what the band is for, dimmed
local described
local function describe(row)
	described = row
	if row and row.text then
		bandName:SetText(row.label)
		bandText:SetText(textOf(row.text))
		bandText:SetTextColor(1, 1, 1)
	else
		bandName:SetText("")
		bandText:SetText("Move onto a setting to read what it does.")
		bandText:SetTextColor(0.5, 0.5, 0.5)
	end
end

-- the rows and section names above it, in a scroll frame the controller's
-- cursor scrolls as it moves (SmartNavigation's HandleScroll), as wide
-- on the left as the wells, so the names reach the edge, and out to the
-- well's right edge so the section bands run under the chat's scroll bar
-- (WC.ScrollBar), the rows keeping clear of it as the turns do
local barWell = CreateFrame("Frame", nil, page)
barWell:SetPoint("TOPRIGHT", BX, BY)
barWell:SetPoint("BOTTOMRIGHT", band, "TOPRIGHT", BX, SEAM)
barWell:SetWidth(40)
local scroll = CreateFrame("ScrollFrame", nil, page)
scroll:SetPoint("TOPLEFT", -BX, 0)
scroll:SetPoint("BOTTOMRIGHT", band, "TOPRIGHT", BX, SEAM + 3)
local content = CreateFrame("Frame", nil, scroll)
content:SetSize(1, 1)
scroll:SetScrollChild(content)
scroll:SetScript("OnSizeChanged", function(_, w) content:SetWidth(w) end)
scroll:EnableMouseWheel(true)
scroll:SetScript("OnMouseWheel", function(self, delta)
	local most = math.max(0, content:GetHeight() - self:GetHeight())
	self:SetVerticalScroll(math.min(most, math.max(0, self:GetVerticalScroll() - delta * ROW_H)))
end)
local column = WC.ScrollBar.Build(barWell, scroll, 3, page:GetFrameLevel())
WC.MarkIgnored(column)
-- each of the bar's frames' level over its column's, kept as built: the bar is
-- lifted whole (lift, below)
local barLevels = {}
local function collect(f)
	for _, child in ipairs({ f:GetChildren() }) do
		barLevels[child] = child:GetFrameLevel() - column:GetFrameLevel()
		collect(child)
	end
end
collect(column)

-- The seams between the wells are the thick vine (WC.Style.VineLine): down
-- between the names and the settings, across between the settings and the
-- note, a T where they meet; over the scrolling rows, under the scroll bar
local seams = CreateFrame("Frame", nil, page)
seams:SetAllPoints()
local down = WC.Style.Spine(seams, page, SPINE - 2 - SEAM / 2)
local across = CreateFrame("Frame", nil, seams)
across:SetHeight(16)
across:SetPoint("LEFT", band, "TOPLEFT", -2 - SEAM / 2, SEAM / 2)
across:SetPoint("RIGHT", band, "TOPRIGHT", BX, SEAM / 2)
WC.Style.VineLine(across, "Thick", false, false, true)
WC.Style.VineJoin(across, "Thick", "TRightBig", "LEFT")
-- the section joints' frame: each joint carries its own stretch of the spine,
-- which near the page's top or foot reached past the spine's end, up through
-- the floor to the title rule (seen on screen, 2026-11-13); cut to the spine,
-- short of its ends (the trial's cut: how far each end's art reaches down)
local joins = CreateFrame("Frame", nil, seams)
joins:SetClipsChildren(true)
joins:SetPoint("LEFT", page, -BX, 0)
joins:SetPoint("RIGHT", page, BX, 0)
-- the names well's shadow on the settings, over their rows and dividers, under
-- the vines (or over the joints, as the trial's meeting says)
local cast = CreateFrame("Frame", nil, seams)
cast:SetAllPoints()
WC.Style.CastOn(cast, settings, "LEFT")

-- Trial, temporary (the player, 2026-11-13): the spine's ends where it meets
-- the raised panel's edges, round 3 corner fittings (tools/make_spine_trials.py), and how the dividers,
-- lying lower, meet the spine on the panel's edge. Kept in WowCompanionDB.spineEnd
-- and .dividerMeet; what is not picked goes with this switch.
local ENDS = {
	{ key = "Round", name = "Round, as now", wide = 16, cut = 3 },
	{ key = "Square", name = "Square corner", wide = 48, cut = 9 },
	{ key = "Point", name = "Square, pointed arm", wide = 48, cut = 9 },
	{ key = "Scroll", name = "Square, scroll arm", wide = 48, cut = 9 },
	{ key = "Heavier", name = "Square, a little heavier", wide = 48, cut = 9 },
	{ key = "Deeper", name = "Square, further inside", wide = 48, cut = 11 },
	{ key = "Brace", name = "Square, braced", wide = 48, cut = 13 },
}
local END_OFF = 2 -- the fittings' art starts this far past the panel's edge (make_spine_trials.py's OFF)
local MEETS = {
	{ key = "joined", name = "Joined, as now" },
	{ key = "shadow", name = "Joined, in the shadow" },
	{ key = "under", name = "Under the spine" },
	{ key = "apart", name = "Apart, short of it" },
}
local function trialPick(list, field)
	local want = WowCompanionDB and WowCompanionDB[field]
	for _, t in ipairs(list) do if t.key == want then return t end end
	return list[1]
end
local function endLook() return trialPick(ENDS, "spineEnd") end
local function meet() return trialPick(MEETS, "dividerMeet").key end
local function paintEnds()
	local e = endLook()
	for i, t in ipairs(down.ends) do
		local which = i == 1 and "Top" or "Bottom"
		local round = e.key == "Round"
		t:SetTexture(round and WC.Style.Vine("Thick" .. which)
			or ([[Interface\AddOns\WowCompanion\Art\Vine-ThickEnd%s%s-T3]]):format(e.key, which), "CLAMP", "CLAMP")
		t:SetWidth(e.wide)
		t:ClearAllPoints()
		t:SetPoint(which:upper(), down, which:upper(), 0, (round and 0 or END_OFF) * (i == 1 and 1 or -1))
	end
	joins:SetPoint("TOP", down, 0, -e.cut)
	joins:SetPoint("BOTTOM", down, 0, e.cut)
end
paintEnds()
page:HookScript("OnShow", paintEnds) -- the saved pick arrives after this file runs
page:HookScript("OnShow", function() WC.Style.PaintRaised() end)

-- One setting: a row from the names well to the right edge, its name at the left
-- and its control at the edge; the row is the one stop, the cursor just left
-- of its name. While the cursor or the mouse is on it, its control lights
-- (r.OnRowLit, set by each kind; Rows.lua): no shade of its own. The control
-- inside is out of the cycle, as in Blizzard's Settings.
local function settingRow(row, step, prompt)
	local r = CreateFrame("Button", nil, content)
	r:SetPoint("RIGHT", content, "RIGHT", -(12 + WC.ScrollBar.ROOM), 0)
	r:SetHeight(ROW_H)
	local fs = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	fs:SetPoint("LEFT", LABEL_X, 0)
	fs:SetPoint("RIGHT", r, "RIGHT", -(CONTROL_W + VALUE_W + EDGE + 12), 0)
	fs:SetJustifyH("LEFT")
	fs:SetWordWrap(false)
	fs:SetTextColor(unpack(LABEL))
	fs:SetText(row.label)
	r:SetScript("OnEnter", function() describe(row) end)
	r.OnRowFocus = function() describe(row) end
	WC.SetCursorAnchor(r, LABEL_X - 4)
	WC.RowStop(r, step, prompt)
	return r
end
-- the control against the right edge; a slider leaves room for its value
local function place(r, control, value)
	control:SetPoint("RIGHT", r, "RIGHT", -(EDGE + (value and VALUE_W or 0)), 0)
end

-- The controls in the chat's language (WC.Style.Control), values in washed
-- bronze. Each draws over the Blizzard control it stands in for, which stays
-- (invisible) for its logic and its menu.
local controlArt = WC.Style.Control
local FILL = 7.8 / 5.25 -- the thumb widened to the groove's floor, as the chat's

-- an arrow cap (Choice- or Slide-), a button of ours with the art's states
local function cap(parent, kind, side, w, onClick)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w, 32)
	local base = kind .. "-" .. side .. "-"
	b:SetNormalTexture(controlArt(base .. "Normal"))
	b:SetPushedTexture(controlArt(base .. "Pushed"))
	b:SetHighlightTexture(controlArt(base .. "Highlight"), "ADD")
	b:SetDisabledTexture(controlArt(base .. "Disabled"))
	WC.Style.UnsnappedButton(b)
	b:SetScript("OnClick", onClick)
	return b
end
-- both arrows lit as under the mouse, for the row holding the cursor (an
-- arrow greyed at its end stays grey)
local function lightCaps(r, less, more)
	r.OnRowLit = function(on)
		for _, b in ipairs({ less, more }) do
			if on then b:LockHighlight() else b:UnlockHighlight() end
		end
	end
end
-- the run between two caps (WC.Style.Run: its art, 8 units long, repeated)
local function between(parent, piece, left, right)
	local t = WC.Style.Run(parent, controlArt(piece), false, 8)
	t:SetHeight(32)
	t:SetPoint("LEFT", left, "RIGHT")
	t:SetPoint("RIGHT", right, "LEFT")
	return t
end
local function bronze(parent)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	fs:SetTextColor(unpack(WC.Style.BRONZE))
	return fs
end

-- A choice from a list: the fleur arrows joined to a carved slot holding the
-- value. Under it, invisible, Blizzard's dropdown with steppers
-- (SettingsDropdownWithButtonsTemplate's own): its menu is the game's, opened
-- the way their gamepad footer does (MouseDown, MouseUp), and anchored to it.
-- A pick does not refresh their steppers by itself (Settings re-inits on every
-- change), so each pick signals the dropdown again.
local function dropdown(row)
	local control
	local r = settingRow(row, function(dir)
		if dir < 0 then control.DecrementButton:Click() else control.IncrementButton:Click() end
	end, "Change")
	control = CreateFrame("Frame", nil, r, "Metal2DropdownWithSteppersAndLabelTemplate")
	local dd = control.Dropdown
	-- as wide as a slider and its value together, so both start at one line
	-- and end at the edge
	dd:SetWidth(CONTROL_W + VALUE_W - 50)
	control:SetSize(CONTROL_W + VALUE_W, 26)
	place(r, control)
	control:SetAlpha(0)
	local face = CreateFrame("Frame", nil, r)
	face:SetSize(CONTROL_W + VALUE_W, 32)
	face:SetAllPoints(control)
	face:SetFrameLevel(control:GetFrameLevel() + 5)
	local less = cap(face, "Choice", "Left", 40, function() control.DecrementButton:Click() end)
	less:SetPoint("LEFT")
	local more = cap(face, "Choice", "Right", 40, function() control.IncrementButton:Click() end)
	more:SetPoint("RIGHT")
	between(face, "Choice-Mid", less, more)
	local value = bronze(face)
	value:SetPoint("LEFT", less, "RIGHT", 2, 0)
	value:SetPoint("RIGHT", more, "LEFT", -2, 0)
	-- one line, cut with "..." when a value (a long mic name) is wider than the box
	value:SetWordWrap(false)
	value:SetMaxLines(1)
	-- the value and the arrows from the row itself: an arrow greys at its end
	local function paint()
		local names, at = row.options(), 0
		for i, name in ipairs(names) do if name == row.get() then at = i end end
		value:SetText(textOf(row.get()) or "")
		less:SetEnabled(at > 1)
		more:SetEnabled(at > 0 and at < #names)
	end
	dd:SetupMenu(function(_, root)
		for _, name in ipairs(row.options()) do
			root:CreateRadio(name, function(n) return n == row.get() end, function(n) row.set(n) dd:SignalUpdate() end, name)
		end
	end)
	dd:RegisterCallback(DropdownButtonMixin.Event.OnUpdate, paint, face)
	refreshers[#refreshers + 1] = function() dd:GenerateMenu() paint() end
	control:SetSteppersShown(true)
	WC.MarkIgnored(control)
	WC.MarkIgnored(face)
	face:SetScript("OnShow", paint)
	paint()
	lightCaps(r, less, more)
	r:SetScript("OnClick", function() dd:MouseDown() dd:MouseUp() end)
	return r
end

-- A number in a range: the scroll bar on its side, the heartwood thumb riding
-- its groove, the value after it in bronze. Under it, invisible, Blizzard's
-- slider with steppers keeps the value; left and right step it as their
-- footer does (OnStepperClicked).
local function slider(row)
	local s
	local r = settingRow(row, function(dir) s:OnStepperClicked(dir > 0) end, "Adjust")
	s = CreateFrame("Frame", nil, r, "MinimalSliderWithSteppersTemplate")
	s:SetWidth(CONTROL_W)
	place(r, s, true)
	s:Init(row.get(), row.min, row.max, row.steps, {})
	s:SetAlpha(0)
	local face = CreateFrame("Frame", nil, r)
	face:SetSize(CONTROL_W, 32)
	face:SetPoint("RIGHT", r, "RIGHT", -(EDGE + VALUE_W), 0)
	face:SetFrameLevel(s:GetFrameLevel() + 5)
	local less = cap(face, "Slide", "Left", 32, function() s:OnStepperClicked(false) end)
	less:SetPoint("LEFT")
	local more = cap(face, "Slide", "Right", 32, function() s:OnStepperClicked(true) end)
	more:SetPoint("RIGHT")
	between(face, "Slide-Mid", less, more)
	local thumb = face:CreateTexture(nil, "OVERLAY")
	thumb:SetTexture(controlArt("Slide-Thumb"))
	thumb:SetSize(36, 32 * FILL)
	local value = bronze(face)
	value:SetPoint("LEFT", face, "RIGHT", 4, 0)
	-- the thumb's travel: between the groove's round ends (8 into each cap),
	-- as the chat's stops a pixel short of them
	local INSET = 24
	local function paint(v)
		v = v or row.get()
		local span = math.max(1, row.max - row.min)
		local frac = math.min(1, math.max(0, (v - row.min) / span))
		local room = CONTROL_W - 2 * INSET - 36
		thumb:ClearAllPoints()
		thumb:SetPoint("CENTER", face, "LEFT", INSET + 18 + room * frac, 0)
		value:SetText(row.format and row.format(v) or tostring(v))
		less:SetEnabled(v > row.min)
		more:SetEnabled(v < row.max)
	end
	s:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, v)
		row.set(v)
		paint(v)
	end, s)
	WC.MarkIgnored(s)
	WC.MarkIgnored(face)
	face:SetScript("OnShow", function() paint() end)
	paint()
	lightCaps(r, less, more)
	return r
end

-- An action: our button (WC.Style.Button) where the other rows have their
-- control (as Blizzard's SettingsButtonControlTemplate places theirs), its
-- right end on the other controls' line; confirm on the row presses it.
local function button(row)
	local r = settingRow(row)
	local b = WC.Style.Button(r)
	b:SetPoint("RIGHT", r, "RIGHT", -EDGE, 0)
	local function fill() b:SetLabel(textOf(row.button)) end
	fill()
	refreshers[#refreshers + 1] = fill
	b:SetScript("OnClick", row.onClick)
	r:SetScript("OnClick", row.onClick)
	r.OnRowLit = function(on) b:SetLit(on) end
	WC.MarkIgnored(b)
	return r
end

-- A key binding: the choice's carved slot closed at both ends, no arrows (it is
-- set by pressing), holding the key as the game shows it, by its icon.
local function key(row)
	local r = settingRow(row)
	local b = CreateFrame("Button", nil, r)
	b:SetHeight(32)
	place(r, b)
	local left = WC.Style.Unsnapped(b:CreateTexture(nil, "ARTWORK"))
	left:SetTexture(controlArt("Choice-Left-Closed"))
	left:SetSize(16, 32)
	left:SetPoint("LEFT")
	local right = WC.Style.Unsnapped(b:CreateTexture(nil, "ARTWORK"))
	right:SetTexture(controlArt("Choice-Right-Closed"))
	right:SetSize(16, 32)
	right:SetPoint("RIGHT")
	local mid = between(b, "Choice-Mid", left, right)
	-- lit: the focus glow round the slot, as the arrows' (make_control_art.py),
	-- and its word in the lit bronze
	local glow = {}
	-- (the ends' glow 4 wider than the ends, reaching past the slot)
	for i, piece in ipairs({ { left, "Choice-Left-Closed", "RIGHT" }, { mid, "Choice-Mid" }, { right, "Choice-Right-Closed", "LEFT" } }) do
		local g = b:CreateTexture(nil, "OVERLAY")
		g:SetTexture(controlArt(piece[2] .. "-Highlight"))
		if piece[3] then
			g:SetSize(20, 32)
			g:SetPoint(piece[3], piece[1])
		else
			g:SetAllPoints(piece[1])
		end
		g:SetBlendMode("ADD")
		g:Hide()
		glow[i] = g
	end
	local word = bronze(b)
	b:SetFontString(word)
	word:SetPoint("CENTER")
	-- as wide as what it holds, its right end on the other controls' line
	local function fill()
		b:SetText(textOf(row.button))
		b:SetWidth(word:GetStringWidth() + 2 * 16 + 16)
	end
	fill()
	refreshers[#refreshers + 1] = fill
	b:SetScript("OnClick", row.onClick)
	r:SetScript("OnClick", row.onClick)
	r.OnRowLit = function(on)
		for _, g in ipairs(glow) do g:SetShown(on) end
		word:SetTextColor(unpack(on and WC.Style.BRONZE_LIT or WC.Style.BRONZE))
	end
	WC.MarkIgnored(b)
	return r
end
local KINDS = { dropdown = dropdown, slider = slider, button = button, key = key }

-- a section's name in the names well, right-aligned beside its first row, and the
-- divider over the section (shown for every section but the first), from the
-- spine between the wells to the backing's right edge
local function header(name)
	if headers[name] then return headers[name] end
	local h = WC.Style.Heading(content)
	h:SetWidth(SPINE - 24)
	h:SetJustifyH("RIGHT")
	h:SetText(name)
	-- grown out of the thick spine between the wells, forged into it
	-- (WC.Style.VineJoin). The joint is the seams' (joins: over the spine, following
	-- the divider), never the scroll child's: what a scroll frame holds draws
	-- at the scroll frame's level, under the spine whatever its own level, and
	-- the spine then cut across every joint (seen on screen, 2026-11-12)
	-- every other section on the dark stone, as Status's rows alternate
	h.band = content:CreateTexture(nil, "BACKGROUND")
	WC.Style.Stone(h.band, "you")
	h.divider = CreateFrame("Frame", nil, content)
	h.divider:SetHeight(16)
	WC.Style.VineLine(h.divider, "", false, false, true)
	-- the trial's "apart": the divider from clear of the panel's shadow, a round end
	h.apart = CreateFrame("Frame", nil, content)
	h.apart:SetHeight(16)
	WC.Style.VineLine(h.apart, "", false, true, true)
	h.join = CreateFrame("Frame", nil, joins)
	h.join:SetSize(1, 1)
	h.join:SetPoint("CENTER", h.divider, "LEFT")
	WC.Style.VineJoin(h.join, "Thick", "TRightFromMediumPlain", "CENTER")
	headers[name] = h
	return h
end

-- Every row made once; the page laid out again whenever one is added:
-- sections in the order of their first row, rows in order within each, a gap
-- and a divider between sections.
local function sectionOf(e) return e.row.section or "General" end
local function orderOf(e) return e.row.order or 50 end
-- The vines and the scroll bar above the drop shadow of whatever window shows
-- the page (the Companion's page well casts one from its top, its level + 20),
-- so the vines' joints read as joined; set on each show, as the page is moved
-- into another frame, which resets levels set before
local LIFT = 25
local function lift()
	local base = page:GetFrameLevel() + LIFT
	-- joined, the joints over the spine (each draws its stretch of the
	-- spine) and the shadow under both; else the shadow over the joints, and
	-- the spine over them
	local joined = meet() == "joined"
	seams:SetFrameLevel(base)
	cast:SetFrameLevel(joined and base or base + 1)
	down:SetFrameLevel(joined and base + 1 or base + 2)
	joins:SetFrameLevel(joined and base + 2 or base)
	for _, h in pairs(headers) do h.join:SetFrameLevel(joins:GetFrameLevel()) end
	across:SetFrameLevel(base + 3)
	column:SetFrameLevel(base + 4)
	for f, over in pairs(barLevels) do f:SetFrameLevel(base + 4 + over) end
end
-- the joints, outside the scroll frame, shown only while their divider is
-- shown and inside it
local function joints()
	local top, bottom = scroll:GetTop(), scroll:GetBottom()
	for _, h in pairs(headers) do
		local y = h.divider:IsShown() and top and select(2, h.divider:GetCenter())
		h.join:SetShown(y and y <= top and y >= bottom and (meet() == "joined" or meet() == "shadow") or false)
	end
end
scroll:HookScript("OnVerticalScroll", joints)
local function layout()
	for _, e in ipairs(rows) do
		if not e.frame then
			local ok, made = pcall(KINDS[e.row.kind] or button, e.row)
			if ok then e.frame = made
			else geterrorhandler()(("settings row %s: %s"):format(tostring(e.row.label), tostring(made))) end
		end
	end
	local first = {}
	for _, e in ipairs(rows) do
		local s = sectionOf(e)
		first[s] = math.min(first[s] or math.huge, orderOf(e))
	end
	table.sort(rows, function(a, b)
		local sa, sb = sectionOf(a), sectionOf(b)
		if sa ~= sb then
			if first[sa] ~= first[sb] then return first[sa] < first[sb] end
			return sa < sb
		end
		return orderOf(a) < orderOf(b)
	end)
	local y, section, open, count = 6, nil, nil, 0
	-- a section's band from the divider over it to the one under it
	local function close(bottom)
		if not open then return end
		open.band:ClearAllPoints()
		open.band:SetPoint("TOPLEFT", content, "TOPLEFT", BX + SPINE - 2, -open.top)
		open.band:SetPoint("BOTTOMRIGHT", content, "TOPRIGHT", 0, -bottom)
		open.band:SetShown(count % 2 == 0)
	end
	for _, e in ipairs(rows) do
		if e.frame then
			local s = sectionOf(e)
			if s ~= section then
				local h = header(s)
				close(y + GAP / 2)
				if section then y = y + GAP end
				count = count + 1
				h.top = section and (y - GAP / 2) or -7
				open = h
				h.divider:SetShown(section ~= nil and meet() ~= "apart")
				h.divider:ClearAllPoints()
				h.divider:SetPoint("LEFT", content, "TOPLEFT", BX + SPINE - 2 - SEAM / 2, -y + GAP / 2)
				h.divider:SetPoint("RIGHT", content, "TOPRIGHT", 0, -y + GAP / 2)
				h.apart:SetShown(section ~= nil and meet() == "apart")
				h.apart:ClearAllPoints()
				h.apart:SetPoint("LEFT", content, "TOPLEFT", BX + SPINE - 2 + 10, -y + GAP / 2)
				h.apart:SetPoint("RIGHT", content, "TOPRIGHT", 0, -y + GAP / 2)
				section = s
				h:SetPoint("TOPRIGHT", content, "TOPLEFT", BX + SPINE - 18, -y - 10)
			end
			e.frame:SetPoint("TOPLEFT", BX + SPINE, -y)
			y = y + ROW_H
		end
	end
	close(math.max(y + GAP / 2, scroll:GetHeight() or 0))
	content:SetHeight(math.max(y, 1))
	lift()
	joints()
	C_Timer.After(0, joints) -- once the new layout's positions are resolved
end
page:SetScript("OnShow", function()
	layout()
	describe(nil)
end)

function Page.Add(row)
	rows[#rows + 1] = { row = row }
	if page:IsShown() then layout() end
end

function Page.Refresh()
	for _, refresh in ipairs(refreshers) do pcall(refresh) end
	if described then describe(described) end
end

-- frame is the page's area: its holder decides the margin (the Companion
-- window's pages already sit 12 px inside their well)
function Page.ShowIn(frame)
	frame.raised = names
	page:SetParent(frame)
	page:ClearAllPoints()
	page:SetAllPoints()
	page:Show()
end

-- Its own window, a UI panel the controller's focus cycle reaches, in
-- Blizzard's panel art.
local window
local function buildWindow()
	local made, f = pcall(CreateFrame, "Frame", "WowCompanionSettings", UIParent, "ButtonFrameTemplate")
	if not made or not f then f = CreateFrame("Frame", "WowCompanionSettings", UIParent) end
	f:SetSize(560, 360)
	f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -116)
	f:SetFrameStrata("DIALOG")
	f:SetClampedToScreen(true)
	f:Hide()
	WC.Style.NoPortrait(f)
	if f.SetTitle then f:SetTitle("WoW Companion settings") end
	if f.CloseButton then f.CloseButton:SetScript("OnClick", function() f:Hide() end) end
	-- the light stone on the inset's floor, the page inside it, as in the
	-- Companion window's page well
	local inset = f.Inset or f
	local S = WC.Style
	local back = inset:CreateTexture(nil, "BACKGROUND", nil, 1)
	S.Stone(back, "claude")
	back:SetPoint("TOPLEFT", S.FLOOR, -S.FLOOR)
	back:SetPoint("BOTTOMRIGHT", -S.FLOOR, S.FLOOR)
	local well = CreateFrame("Frame", nil, inset)
	well:SetPoint("TOPLEFT", S.PAGE_X, -S.PAGE_Y)
	well:SetPoint("BOTTOMRIGHT", -S.PAGE_X, S.PAGE_Y)
	WC.MarkFocusable(f)
	if UIPanelWindows then
		UIPanelWindows["WowCompanionSettings"] = { area = "left", pushable = 1, whileDead = 1, allowOtherPanels = 1 }
	end
	f:SetScript("OnHide", function(self) WC.FrameHidden(self) end)
	f.well = well
	return f
end

function Page.Open()
	window = window or buildWindow()
	Page.ShowIn(window.well)
	WC.ShowPanel(window)
end

-- Blizzard's Settings, AddOns: one category with one button that opens the
-- page. Registered through Blizzard's addon API; nothing of theirs is opened
-- or changed by our code.
local login = CreateFrame("Frame")
login:RegisterEvent("PLAYER_LOGIN")
login:SetScript("OnEvent", function()
	if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
	local canvas = CreateFrame("Frame")
	local made, open = pcall(CreateFrame, "Button", nil, canvas, "UIPanelButtonTemplate")
	if not made or not open then return end
	open:SetSize(260, 26)
	open:SetPoint("TOPLEFT", 16, -16)
	open:SetText("Open WoW Companion settings")
	open:SetScript("OnClick", Page.Open)
	WC.MarkFocusable(open)
	pcall(function()
		Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(canvas, "WoW Companion"))
	end)
end)

-- Trial, temporary: the raised wells' look, picked live (Style.lua's RAISE_LOOKS)
Page.Add({ kind = "dropdown", section = "Trial", order = 1, label = "Raised panels",
	text = "On trial: how the dark panels stand above the settings. Left and right switch it live.",
	options = function()
		local names = {}
		for i, look in ipairs(WC.Style.RAISE_LOOKS) do names[i] = look.name end
		return names
	end,
	get = function() return WC.Style.RaisedLook().name end,
	set = function(name) WC.Style.PaintRaised(name) end })
Page.Add({ kind = "dropdown", section = "Trial", order = 2, label = "Spine ends",
	text = "On trial: the thick vine's ends where it meets the dark panel's top and bottom.",
	options = function()
		local names = {}
		for i, e in ipairs(ENDS) do names[i] = e.name end
		return names
	end,
	get = function() return endLook().name end,
	set = function(name)
		for _, e in ipairs(ENDS) do if e.name == name then WowCompanionDB.spineEnd = e.key end end
		paintEnds()
	end })
Page.Add({ kind = "dropdown", section = "Trial", order = 3, label = "Dividers meet",
	text = "On trial: how the dividers, lying lower, meet the thick vine on the dark panel's edge.",
	options = function()
		local names = {}
		for i, m in ipairs(MEETS) do names[i] = m.name end
		return names
	end,
	get = function() return trialPick(MEETS, "dividerMeet").name end,
	set = function(name)
		for _, m in ipairs(MEETS) do if m.name == name then WowCompanionDB.dividerMeet = m.key end end
		layout()
	end })
