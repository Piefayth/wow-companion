-- Part of WowCompanion; loaded by the .toc in order: Engine, Style, Companion,
-- Pins, Strip, Bags, Status, Modules. A file shares nothing local with another:
-- they talk through globals (WC, WowCompanion_*).

-- Destroying an item. Agent
-- code cannot delete (DeleteCursorItem is refused in its sandbox), but it may
-- open this confirmation; the deletion happens only in the Destroy button's own
-- click, which is the player's press (DeleteCursorItem needs a hardware event).
-- Cross destroys, circle cancels, while it is shown and out of combat. The item
-- is checked again at the press, so a sort in between cannot destroy the wrong one.
-- Blizzard's own look for our windows. Only virtual templates are inherited, into frames of
-- ours: the dark dialog border StaticPopups use (DialogTemplates.xml), the
-- controller button prompt with the pad's real glyph (InputPrompts.xml), and the
-- context menu's art (MenuStyle2Mixin, MenuTemplates.lua). Each falls back to
-- plain art if a template is missing.
WowCompanion_Style = WowCompanion_Style or {}

-- A controller button drawn as the game draws it for the pad in use: the
-- textured prompt icons Blizzard's own legends use for the active controller
-- (InputIconTextureSetUtility, InputIconTexture.lua: the PlayStation and Xbox
-- sets), at text size. A pad with no textured set (Nintendo layout) gets the
-- flat glyph strings (KEY_ABBR_<key>_SHP...) for its label style, then the
-- generic glyph, then the key name.
-- labelStyle reads "Shapes" on this client, not "Shp": both spellings map.
local GLYPH_SUFFIX = { Shp = "_SHP", Shapes = "_SHP", Ltr = "_LTR", Letters = "_LTR",
	Rev = "_REV", Reverse = "_REV", Reversed = "_REV" }
local GLYPH_SIZE = 20
-- the newer prompt art sits on a 76 x 75 canvas with padding round it; Blizzard
-- draws those 5 px past their bounds each side (InputIconTextureMixin
-- ApplyTextureLayout), so inline they are drawn that much larger
local PADDED = { width = 76, height = 75, scale = 76 / 66 }
-- the stick-press icons (L3, R3) carry a press arrow over the stick that takes a
-- third of the canvas: inline they are cut to the stick and its label (pixels
-- of the 76 x 75 canvas, measured from a screenshot), so the label can be read
local PRESS_CROP = { x0 = 10, x1 = 66, y0 = 27, y1 = 64 }
local function pressIcon(info)
	local w = info.width / (info.rightTexCoord - info.leftTexCoord)
	local h = info.height / (info.bottomTexCoord - info.topTexCoord)
	local left, top = info.leftTexCoord * w, info.topTexCoord * h
	local c = PRESS_CROP
	local width = math.floor(GLYPH_SIZE * (c.x1 - c.x0) / (c.y1 - c.y0) + 0.5)
	return ("|T%d:%d:%d:0:0:%d:%d:%d:%d:%d:%d|t"):format(info.file, GLYPH_SIZE, width, w, h,
		left + c.x0, left + c.x1, top + c.y0, top + c.y1)
end
-- the face buttons keep the flat glyphs: theirs are in the controller's own
-- colours, which the textured set draws in bronze
local FLAT = { PAD1 = true, PAD2 = true, PAD3 = true, PAD4 = true }
function WowCompanion_Glyph(key)
	local icons = not FLAT[key] and InputIconTextureSetUtility or nil
	local ok, atlas = icons ~= nil, nil
	if ok then ok, atlas = pcall(icons.GetNormalActiveInputIconButtonTexture, key) end
	local info = ok and type(atlas) == "string" and C_Texture.GetAtlasInfo(atlas)
	if info and info.width == PADDED.width and info.height == PADDED.height
		and (key == "PADLSTICK" or key == "PADRSTICK") and type(info.file) == "number" then
		return pressIcon(info)
	end
	if info then
		local size = GLYPH_SIZE
		if info.width == PADDED.width and info.height == PADDED.height then
			size = math.floor(GLYPH_SIZE * PADDED.scale + 0.5)
		end
		return ("|A:%s:%d:%d|a"):format(atlas, size, size)
	end
	local style
	pcall(function()
		local state = C_GamePad.GetDeviceMappedState(C_GamePad.GetActiveDeviceID())
		style = state and state.labelStyle
	end)
	return _G["KEY_ABBR_" .. key .. (GLYPH_SUFFIX[style or ""] or "")] or _G["KEY_ABBR_" .. key] or key
end

function WowCompanion_Style.Dialog(frame)
	local ok, border = pcall(CreateFrame, "Frame", nil, frame, "DialogBorderDarkTemplate")
	if ok and border then
		border:SetAllPoints()
		return border
	end
	if frame.SetBackdrop then
		frame:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 },
		})
	end
end
-- key: "PAD1" (cross), "PAD2" (circle), "PAD3" (square), "PAD4" (triangle)...
function WowCompanion_Style.Prompt(parent, key, text)
	local ok, p = pcall(CreateFrame, "Frame", nil, parent, "InputPromptOneIconWithTextTemplate")
	if ok and p and p.SetPromptInputIconKey then
		local fine = pcall(function()
			p:SetPromptInputIconKey(1, key)
			p:SetPromptText(text)
			if p.RefreshInputPromptSize then p:RefreshInputPromptSize() end
		end)
		if fine then return p end
		p:Hide()
	end
	local f = CreateFrame("Frame", nil, parent)
	f:SetSize(120, 24)
	local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	fs:SetPoint("LEFT")
	fs:SetText(("%s %s"):format(WowCompanion_Glyph(key), text))
	f:SetWidth(fs:GetStringWidth() + 4)
	f.SetPromptText = function(_, t) fs:SetText(("%s %s"):format(WowCompanion_Glyph(key), t)) end
	return f
end
-- the context menu's background (common-dropdown-c-bg, as MenuStyle2 draws it)
function WowCompanion_Style.Menu(frame)
	local bg = frame:CreateTexture(nil, "BACKGROUND")
	if pcall(bg.SetAtlas, bg, "common-dropdown-c-bg") then
		bg:SetPoint("TOPLEFT", -17, 12)
		bg:SetPoint("BOTTOMRIGHT", 17, -14) -- the atlas reads as more padding below than above at -22
	else
		bg:SetAllPoints()
		bg:SetColorTexture(0, 0, 0, 0.9)
	end
	return bg
end
-- the row highlight Blizzard's dropdowns use
function WowCompanion_Style.Highlight(parent)
	local t = parent:CreateTexture(nil, "ARTWORK")
	t:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
	t:SetBlendMode("ADD")
	t:Hide()
	return t
end

local destroyFrame
function WowCompanion_ConfirmDestroy(bag, slot, onClose)
	if InCombatLockdown() then return false end
	local info = C_Container.GetContainerItemInfo(bag, slot)
	if not info or not info.itemID then return false end
	local link = C_Container.GetContainerItemLink(bag, slot) or info.itemName or "?"
	if not destroyFrame then
		-- laid out as a StaticPopup: dark dialog border, centred text, the warning
		-- icon, two buttons, and the controller prompts under them
		local f = CreateFrame("Frame", "WowCompanionDestroy", UIParent, "BackdropTemplate")
		f:SetSize(320, 150)
		f:SetPoint("TOP", 0, -135)
		f:SetFrameStrata("FULLSCREEN_DIALOG")
		WowCompanion_Style.Dialog(f)
		local alert = f:CreateTexture(nil, "ARTWORK")
		alert:SetTexture("Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew")
		alert:SetSize(36, 36)
		alert:SetPoint("TOPLEFT", 18, -16)
		f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		f.text:SetPoint("TOPLEFT", 60, -20)
		f.text:SetPoint("TOPRIGHT", -20, -20)
		f.text:SetJustifyH("CENTER")
		local yes = CreateFrame("Button", "WowCompanionDestroyYes", f, "UIPanelButtonTemplate")
		yes:SetSize(128, 22)
		yes:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -6, 44)
		yes:SetText(YES or "Yes")
		yes:RegisterForClicks("AnyDown")
		yes:SetScript("OnClick", function()
			local now = C_Container.GetContainerItemInfo(f.bag, f.slot)
			if not InCombatLockdown() and now and now.itemID == f.itemID then
				ClearCursor()
				C_Container.PickupContainerItem(f.bag, f.slot)
				local kind, id = GetCursorInfo()
				if kind == "item" and id == f.itemID then
					DeleteCursorItem()
					WC.Board.toast("|cffffd100Destroyed|r " .. (f.link or ""), 0.8, 0.8, 0.8, 3)
				else
					ClearCursor()
				end
			else
				WC.Board.toast("Not destroyed: the item moved", 1, 0.5, 0.5, 3)
			end
			f:Hide()
		end)
		local no = CreateFrame("Button", "WowCompanionDestroyNo", f, "UIPanelButtonTemplate")
		no:SetSize(128, 22)
		no:SetPoint("BOTTOMLEFT", f, "BOTTOM", 6, 44)
		no:SetText(NO or "No")
		no:RegisterForClicks("AnyDown")
		no:SetScript("OnClick", function() f:Hide() end)
		local pYes = WowCompanion_Style.Prompt(f, "PAD1", DELETE or "Destroy")
		pYes:SetPoint("TOP", yes, "BOTTOM", 0, -6)
		local pNo = WowCompanion_Style.Prompt(f, "PAD2", CANCEL or "Cancel")
		pNo:SetPoint("TOP", no, "BOTTOM", 0, -6)
		f:SetScript("OnHide", function(self)
			if not InCombatLockdown() then ClearOverrideBindings(self) end
			local done = self.onClose
			self.onClose = nil
			if done then pcall(done) end
		end)
		f:RegisterEvent("PLAYER_REGEN_DISABLED")
		f:SetScript("OnEvent", function(self) self:Hide() end)
		f:Hide()
		destroyFrame = f
	end
	local f = destroyFrame
	f.bag, f.slot, f.itemID, f.link, f.onClose = bag, slot, info.itemID, link, onClose
	-- Blizzard's own wording (DELETE_ITEM: "Do you want to destroy %s?")
	local name = link .. ((info.stackCount or 1) > 1 and (" x" .. info.stackCount) or "")
	f.text:SetText(DELETE_ITEM and DELETE_ITEM:format(name) or ("Do you want to destroy %s?"):format(name))
	f:SetHeight(math.max(150, f.text:GetStringHeight() + 110))
	f:Show()
	ClearOverrideBindings(f)
	SetOverrideBindingClick(f, true, "PAD1", "WowCompanionDestroyYes")
	SetOverrideBindingClick(f, true, "PAD2", "WowCompanionDestroyNo")
	return true
end

-- A ButtonFrameTemplate window of ours without its portrait. Blizzard's
-- HidePortrait swaps the border, but the controller's focus glow (FrameGlow,
-- FocusEffects.lua) took its shape from the portrait layout when the frame was
-- made: a portrait's corner at the top left, set out past the frame. Its own
-- OnLoad, run again under the portrait-less layout, fits it to the frame.
function WowCompanion_Style.NoPortrait(frame)
	if not (ButtonFrameTemplate_HidePortrait and frame.PortraitContainer) then return end
	ButtonFrameTemplate_HidePortrait(frame)
	frame.layoutType = "ButtonFrameTemplateNoPortrait"
	if frame.FrameGlow and frame.FrameGlow.OnLoad then frame.FrameGlow:OnLoad() end
end

WC.Style = WowCompanion_Style

-- Our own stone (Art/, made by tools/make_slate.py): a dark, fine-grained
-- slate in two values, the backing of our windows' text; the lighter one under
-- what is read, the darker under what the player does (his turns, the scroll
-- gutter). The game keeps a texture it has loaded for
-- the session under its path, so a changed file needs a new name to show
-- without a restart: each version gets its own names (make_slate.py reads
-- this number).
local STONE_VERSION = 6
local ART = [[Interface\AddOns\WowCompanion\Art\]]
WowCompanion_Style.STONE = {
	you = ART .. "Slate-" .. STONE_VERSION,
	claude = ART .. "SlateLight-" .. STONE_VERSION,
}
-- The vine dividers, every window's (tools/make_scrollbar_art.py, rule_pieces):
-- three weights, "Thin", "" (medium, the chat's) and "Thick"; pieces Left,
-- Mid (stretched), Right, 32 x 16 (Mid 64); Top, VMid (stretched), Bottom,
-- 16 x 32. The line runs down each piece's middle; a round end sits 1.2 + its
-- half-width in from a cap's outer edge. Where the thick vine is met at a
-- right angle, a junction (make_scrollbar_art.py, junction) forged as one
-- piece with both vines: ThickTRightBig (two thick vines, a heart of scrolls
-- on the run's far side), ThickTRightFromMedium (a medium vine growing out of
-- the thick, scrolls beside it) and ThickTRightFromMediumPlain (no scrolls),
-- each for a run going down and an arm leaving right.
local VINE_VERSION = 9 -- the generator's VINE_VERSION
function WowCompanion_Style.Vine(piece)
	return ART .. "Vine-" .. piece .. "-" .. VINE_VERSION
end
-- A vine run through `owner`: across its middle (vertical false, owner 16
-- tall) or down it (owner 16 wide), with a round end at its start and end when
-- asked (none where it runs into a junction). Returns its textures.
function WowCompanion_Style.VineLine(owner, weight, vertical, capStart, capEnd)
	weight = weight or ""
	local made = {}
	local function piece(name, w, h)
		local t = owner:CreateTexture(nil, "ARTWORK")
		-- clamped: a wrapped edge samples the far edge, and a cap's far edge is
		-- the vine, a grey nub past its round end
		t:SetTexture(WowCompanion_Style.Vine(weight .. name), "CLAMP", "CLAMP")
		if w then t:SetWidth(w) end
		if h then t:SetHeight(h) end
		made[#made + 1] = t
		return t
	end
	local first, last, mid
	if vertical then
		first = capStart and piece("Top", 16, 32)
		last = capEnd and piece("Bottom", 16, 32)
		mid = piece("VMid", 16)
		if first then first:SetPoint("TOP") end
		if last then last:SetPoint("BOTTOM") end
		mid:SetPoint("TOP", first or owner, first and "BOTTOM" or "TOP")
		mid:SetPoint("BOTTOM", last or owner, last and "TOP" or "BOTTOM")
	else
		first = capStart and piece("Left", 32, 16)
		last = capEnd and piece("Right", 32, 16)
		mid = piece("Mid", nil, 16)
		if first then first:SetPoint("LEFT") end
		if last then last:SetPoint("RIGHT") end
		mid:SetPoint("LEFT", first or owner, first and "RIGHT" or "LEFT")
		mid:SetPoint("RIGHT", last or owner, last and "LEFT" or "RIGHT")
	end
	return made
end
-- A junction centred on a point of `owner`, square at the size it was drawn
-- for (the art's units), its own stretch of both vines inside it; each kind
-- ornamental, and plain (…Plain) where there is no room for scrollwork
local JOIN_SIZE = { TRightBig = 112, TRightBigPlain = 112, TRightFromMedium = 80, TRightFromMediumPlain = 80 }
function WowCompanion_Style.VineJoin(owner, weight, kind, point)
	local t = owner:CreateTexture(nil, "OVERLAY")
	t:SetTexture(WowCompanion_Style.Vine(weight .. kind), "CLAMP", "CLAMP")
	t:SetSize(JOIN_SIZE[kind], JOIN_SIZE[kind])
	t:SetPoint("CENTER", owner, point)
	return t
end

-- "hold a conversation's chord": both shoulder buttons with no letters, inline
-- in text (tools/make_chord_glyph.py draws it on a 64 x 64 canvas, the version
-- in its name), cut to the rows the bumpers fill so it stands as tall as the
-- other prompt icons and about as wide as the trimmed R3
local CHORD_ROWS = { 14, 52 }
WowCompanion_Style.CHORD = ("|T%sChord-6:%d:%d:0:0:64:64:0:64:%d:%d|t"):format(ART, GLYPH_SIZE,
	math.floor(GLYPH_SIZE * 64 / (CHORD_ROWS[2] - CHORD_ROWS[1]) + 0.5), CHORD_ROWS[1], CHORD_ROWS[2])

-- The words of our windows, in washed bronze: a name in a list of choices
-- (NAME, NAME_HL under the cursor, NAME_LIT chosen), what names a setting or
-- a fact (LABEL), a control's value (BRONZE), what is not there yet (DIM).
-- In text, a short word for good or bad, colour-blind safe, and grey detail.
WowCompanion_Style.NAME = { 0.78, 0.69, 0.53 }
WowCompanion_Style.NAME_HL = { 0.91, 0.84, 0.67 }
WowCompanion_Style.NAME_LIT = { 0.98, 0.92, 0.78 }
WowCompanion_Style.LABEL = { 0.86, 0.76, 0.56 }
WowCompanion_Style.BRONZE = { 0.78, 0.66, 0.45 }
WowCompanion_Style.DIM = { 0.5, 0.5, 0.5 }
WowCompanion_Style.GREY, WowCompanion_Style.GOOD, WowCompanion_Style.BAD = "|cff8c8c8c", "|cff7fd07f", "|cffe0786a"

-- A texture tiled with one of the stones; shade darkens it
function WowCompanion_Style.Stone(tex, which, shade)
	tex:SetTexture(WowCompanion_Style.STONE[which], "REPEAT", "REPEAT")
	tex:SetHorizTile(true)
	tex:SetVertTile(true)
	shade = shade or 1
	tex:SetVertexColor(shade, shade, shade)
end

-- A page of ours (the Companion window's tabs, the settings window) stands
-- PAGE_X, PAGE_Y inside its well, whose floor starts FLOOR in, under the
-- border's inner edge, which fades out over it: a page's wells reach BLEED_X,
-- BLEED_Y past the page, to that floor.
WowCompanion_Style.FLOOR = 3
WowCompanion_Style.PAGE_X, WowCompanion_Style.PAGE_Y = 12, 10
WowCompanion_Style.BLEED_X = WowCompanion_Style.PAGE_X - WowCompanion_Style.FLOOR
WowCompanion_Style.BLEED_Y = WowCompanion_Style.PAGE_Y - WowCompanion_Style.FLOOR
-- A page is sunk wells of stone on the window's rock, the rock showing in a
-- SEAM between them, the thick vine down it (Spine). The darker side's stone
-- darker still (DEEPER), as Status's names and Settings' sections are.
WowCompanion_Style.SEAM, WowCompanion_Style.DEEPER = 3, 0.6
local SHADE = 12
-- the rock under a page's wells, out to its well's floor
function WowCompanion_Style.PageRock(page)
	local rock = page:CreateTexture(nil, "BACKGROUND", nil, -2)
	rock:SetTexture([[Interface\FrameGeneral\UI-Background-Rock]], "REPEAT", "REPEAT")
	rock:SetHorizTile(true)
	rock:SetVertTile(true)
	rock:SetPoint("TOPLEFT", -WowCompanion_Style.BLEED_X, WowCompanion_Style.BLEED_Y)
	rock:SetPoint("BOTTOMRIGHT", WowCompanion_Style.BLEED_X, -WowCompanion_Style.BLEED_Y)
	return rock
end
-- A well of stone on page, sunk by a soft shadow inside its top and left
-- edges, light falling from the top left, no rim. Returns its stone, for the
-- caller to anchor; what lies on the stone under the shadow goes at sublevel 0.
function WowCompanion_Style.Well(page, which, shade)
	local t = page:CreateTexture(nil, "BACKGROUND", nil, -1)
	WowCompanion_Style.Stone(t, which, shade)
	for _, side in ipairs({ "Top", "Left" }) do
		local s = page:CreateTexture(nil, "BACKGROUND", nil, 2)
		s:SetTexture([[Interface\Common\ShadowOverlay-]] .. side)
		s:SetAlpha(0.7)
		s:SetPoint("TOPLEFT", t)
		s:SetPoint(side == "Top" and "TOPRIGHT" or "BOTTOMLEFT", t)
		if side == "Top" then s:SetHeight(SHADE) else s:SetWidth(SHADE) end
	end
	return t
end
-- The thick vine down page's whole height, centred x from its left, in a frame
-- of owner's (which decides what it is drawn over)
function WowCompanion_Style.Spine(owner, page, x)
	local spine = CreateFrame("Frame", nil, owner)
	spine:SetWidth(16)
	spine:SetPoint("TOP", page, "TOPLEFT", x, WowCompanion_Style.BLEED_Y)
	spine:SetPoint("BOTTOM", page, "BOTTOMLEFT", x, -WowCompanion_Style.BLEED_Y)
	WowCompanion_Style.VineLine(spine, "Thick", true, true, true)
	return spine
end

-- A heading over what follows it, as the Settings page names its sections
function WowCompanion_Style.Heading(parent)
	return parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightMed2")
end

-- A row of a list of choices, as the conversation picker's: its name in NAME
-- on the well's stone; the chosen one a plate of the replies' slate between
-- two of the chat's vines, its name lit. row:SetChosen(on); row.text its name.
function WowCompanion_Style.ChoiceRow(parent)
	local b = CreateFrame("Button", nil, parent)
	local plate = b:CreateTexture(nil, "BACKGROUND")
	WowCompanion_Style.Stone(plate, "claude")
	plate:SetAllPoints()
	local parts = { plate }
	for _, edge in ipairs({ "TOP", "BOTTOM" }) do
		local f = CreateFrame("Frame", nil, b)
		f:SetHeight(16)
		f:SetPoint("LEFT", b, edge .. "LEFT")
		f:SetPoint("RIGHT", b, edge .. "RIGHT")
		WowCompanion_Style.VineLine(f, "", false, true, true)
		parts[#parts + 1] = f
	end
	-- the words over the vines, which reach 8 into the row
	local face = CreateFrame("Frame", nil, b)
	face:SetAllPoints()
	face:SetFrameLevel(b:GetFrameLevel() + 2)
	b.face = face
	local text = face:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	text:SetPoint("LEFT", 12, 0)
	text:SetPoint("RIGHT", -8, 0)
	text:SetJustifyH("LEFT")
	text:SetWordWrap(false)
	b:SetFontString(text)
	b.text = text
	function b:SetChosen(on)
		for _, t in ipairs(parts) do t:SetShown(on) end
		text:SetTextColor(unpack(on and WowCompanion_Style.NAME_LIT or WowCompanion_Style.NAME))
		self.chosen = on
	end
	b:SetChosen(false)
	return b
end

-- A scrolling list's items, each its name (row.text, up to two lines) over a
-- line of detail (row.detail), in the look on trial (the player's pick,
-- 2026-11-12): a letter in WowCompanionDB.listItem, switched live by
-- WC.Style.ListItemStyle. The pieces are tools/make_listitem_art.py's
-- (ListItem-*), the stones' and the vines'.
--   A Slab   each item a raised slab of the dark stone; chosen, the light stone in a bark rim
--   B Inlay  thin vines between items; chosen, sunk light stone between vines ending in scrolls
--   C Branch a vine down the list, a tendril for each item; chosen, a plate grown from it on T joints
--   D Bands  the stones in turn, as Status's rows, thin vines between; chosen, medium vines round it
-- WC.Style.List(content, relayout, left, right): rows from left to right in
-- from content's sides. list:Row(i) the i-th row, made once
-- (row:SetLines(name, detail), row:SetChosen(on), row.face for the caller's
-- own marks); list:Lay(n, y) stacks rows 1..n flush from y down content,
-- hides the rest and returns the y under them. relayout() is called when
-- the look changes, as the rows' heights may.
local LIST_ITEM_VERSION = 1 -- make_listitem_art.py's VERSION
local function listArt(piece) return ART .. "ListItem-" .. piece .. "-" .. LIST_ITEM_VERSION end
local PAD, GAP, STEM = 8, 2, 10 -- the words' inset top and bottom, between the lines; Branch's stem
WowCompanion_Style.LIST_MARGIN = 8 -- clear above the first row and under the last (Branch's stem runs on past them)
local function listStone(row, which, l, t, r, b)
	local tex = row:CreateTexture(nil, "BACKGROUND")
	WowCompanion_Style.Stone(tex, which)
	tex:SetPoint("TOPLEFT", l, -t)
	tex:SetPoint("BOTTOMRIGHT", -r, b)
	return tex
end
-- a vine along the row's top or bottom edge, from l in to r in
local function edgeVine(row, edge, weight, l, r, capStart, capEnd)
	local f = CreateFrame("Frame", nil, row.vines)
	f:SetHeight(16)
	f:SetPoint("LEFT", row, edge .. "LEFT", l, 0)
	f:SetPoint("RIGHT", row, edge .. "RIGHT", -r, 0)
	WowCompanion_Style.VineLine(f, weight, false, capStart, capEnd)
	return f
end
-- a medium vine along an edge whose ends curl into the row
local function curledVine(row, edge)
	local f = CreateFrame("Frame", nil, row.vines)
	f:SetHeight(16)
	f:SetPoint("LEFT", row, edge .. "LEFT")
	f:SetPoint("RIGHT", row, edge .. "RIGHT")
	local side = edge == "TOP" and "T" or "B"
	local l, r = f:CreateTexture(nil, "ARTWORK"), f:CreateTexture(nil, "ARTWORK")
	l:SetTexture(listArt("Curl-" .. side .. "L"), "CLAMP", "CLAMP")
	r:SetTexture(listArt("Curl-" .. side .. "R"), "CLAMP", "CLAMP")
	l:SetSize(32, 32)
	r:SetSize(32, 32)
	l:SetPoint("LEFT")
	r:SetPoint("RIGHT")
	local mid = f:CreateTexture(nil, "ARTWORK")
	mid:SetTexture(WowCompanion_Style.Vine("Mid"), "CLAMP", "CLAMP")
	mid:SetHeight(16)
	mid:SetPoint("LEFT", l, "RIGHT")
	mid:SetPoint("RIGHT", r, "LEFT")
	return f
end
-- a nine-slice of make_listitem_art's (corners 8), set out 4 round the box l, t, r, b in from the row
local function nine(row, piece, l, t, r, b)
	local made = {}
	local cut = { 0, 0.25, 0.75, 1 }
	local xs = { { "LEFT", l - 4 }, { "LEFT", l + 4 }, { "RIGHT", -r - 4 }, { "RIGHT", -r + 4 } }
	local ys = { { "TOP", -t + 4 }, { "TOP", -t - 4 }, { "BOTTOM", b + 4 }, { "BOTTOM", b - 4 } }
	for i = 1, 3 do
		for j = 1, 3 do
			local tex = row:CreateTexture(nil, "BORDER")
			tex:SetTexture(listArt(piece))
			tex:SetTexCoord(cut[j], cut[j + 1], cut[i], cut[i + 1])
			tex:SetPoint("TOPLEFT", row, ys[i][1] .. xs[j][1], xs[j][2], ys[i][2])
			tex:SetPoint("BOTTOMRIGHT", row, ys[i + 1][1] .. xs[j + 1][1], xs[j + 1][2], ys[i + 1][2])
			made[#made + 1] = tex
		end
	end
	return made
end
local function shown(parts, on) for _, p in ipairs(parts) do p:SetShown(on) end end
-- each look: the words' left inset; make(row) its pieces, once; paint(row,
-- parts, i, n, after) shows them for the row's place (after: the row above is chosen)
local LOOKS = {
	A = {
		inset = 14,
		make = function(row)
			local idle = { listStone(row, "you", 3, 3, 3, 3) }
			for _, t in ipairs(nine(row, "Slab-Edge", 3, 3, 3, 3)) do idle[#idle + 1] = t end
			local chosen = { listStone(row, "claude", 3, 3, 3, 3) }
			for _, t in ipairs(nine(row, "Slab-Rim", 3, 3, 3, 3)) do chosen[#chosen + 1] = t end
			return { idle = idle, chosen = chosen }
		end,
		paint = function(row, p)
			shown(p.idle, not row.chosen)
			shown(p.chosen, row.chosen)
		end,
	},
	B = {
		inset = 14,
		make = function(row)
			local chosen = { listStone(row, "claude", 0, 0, 0, 0) }
			for _, side in ipairs({ "Top", "Left" }) do
				local s = row:CreateTexture(nil, "BORDER")
				s:SetTexture([[Interface\Common\ShadowOverlay-]] .. side)
				s:SetAlpha(0.7)
				s:SetPoint("TOPLEFT")
				s:SetPoint(side == "Top" and "TOPRIGHT" or "BOTTOMLEFT")
				if side == "Top" then s:SetHeight(SHADE) else s:SetWidth(SHADE) end
				chosen[#chosen + 1] = s
			end
			chosen[#chosen + 1] = curledVine(row, "TOP")
			chosen[#chosen + 1] = curledVine(row, "BOTTOM")
			return { rule = edgeVine(row, "TOP", "Thin", 6, 6, true, true), chosen = chosen }
		end,
		paint = function(row, p, i, _, after)
			shown(p.chosen, row.chosen)
			p.rule:SetShown(i > 1 and not row.chosen and not after)
		end,
	},
	C = {
		inset = 26,
		make = function(row)
			local stem = CreateFrame("Frame", nil, row.vines)
			stem:SetWidth(16)
			local function piece(name)
				local t = stem:CreateTexture(nil, "ARTWORK")
				t:SetTexture(WowCompanion_Style.Vine(name), "CLAMP", "CLAMP")
				return t
			end
			local top, mid, bottom = piece("Top"), piece("VMid"), piece("Bottom")
			top:SetSize(16, 32)
			bottom:SetSize(16, 32)
			top:SetPoint("TOP")
			bottom:SetPoint("BOTTOM")
			mid:SetWidth(16)
			local function joint(name)
				local t = row.vines:CreateTexture(nil, "OVERLAY")
				t:SetTexture(listArt(name), "CLAMP", "CLAMP")
				t:SetSize(32, 32)
				return t
			end
			local tendril = joint("Stem-Tendril")
			tendril:SetPoint("CENTER", row, "TOPLEFT", STEM, -(PAD + 7))
			local chosen = { listStone(row, "claude", STEM, 0, 0, 0) }
			for _, edge in ipairs({ "TOP", "BOTTOM" }) do
				chosen[#chosen + 1] = edgeVine(row, edge, "", STEM, 0, false, true)
				local t = joint("Stem-T")
				t:SetPoint("CENTER", row, edge .. "LEFT", STEM, 0)
				chosen[#chosen + 1] = t
			end
			return { stem = stem, top = top, mid = mid, bottom = bottom, tendril = tendril, chosen = chosen }
		end,
		paint = function(row, p, i, n)
			local M = WowCompanion_Style.LIST_MARGIN
			p.stem:Show()
			p.stem:ClearAllPoints()
			p.stem:SetPoint("TOP", row, "TOPLEFT", STEM, i == 1 and M - 2 or 0)
			p.stem:SetPoint("BOTTOM", row, "BOTTOMLEFT", STEM, i == n and 2 - M or 0)
			p.top:SetShown(i == 1)
			p.bottom:SetShown(i == n)
			p.mid:SetShown(not (i == 1 and i == n)) -- one row: its two caps meet
			p.mid:ClearAllPoints()
			p.mid:SetPoint("TOP", i == 1 and p.top or p.stem, i == 1 and "BOTTOM" or "TOP")
			p.mid:SetPoint("BOTTOM", i == n and p.bottom or p.stem, i == n and "TOP" or "BOTTOM")
			p.tendril:SetShown(not row.chosen)
			shown(p.chosen, row.chosen)
		end,
	},
	D = {
		inset = 14,
		make = function(row)
			return { light = listStone(row, "claude", 0, 0, 0, 0), dark = listStone(row, "you", 0, 0, 0, 0),
				rule = edgeVine(row, "TOP", "Thin", 6, 6, true, true),
				chosen = { edgeVine(row, "TOP", "", 0, 0, true, true), edgeVine(row, "BOTTOM", "", 0, 0, true, true) } }
		end,
		paint = function(row, p, i, _, after)
			local light = row.chosen or i % 2 == 1
			p.light:SetShown(light)
			p.dark:SetShown(not light)
			p.rule:SetShown(i > 1 and not row.chosen and not after)
			shown(p.chosen, row.chosen)
		end,
	},
}
local function pickedLook()
	local pick = type(WowCompanionDB) == "table" and WowCompanionDB.listItem
	return LOOKS[pick] and pick or "A"
end
local lists = {}
local function hideParts(parts)
	for _, p in pairs(parts) do
		if type(p) == "table" and p.SetShown then p:Hide() elseif type(p) == "table" then shown(p, false) end
	end
end
function WowCompanion_Style.List(content, relayout, left, right)
	local list = { rows = {}, relayout = relayout }
	lists[#lists + 1] = list
	function list:Row(i)
		local row = self.rows[i]
		if row then return row end
		row = CreateFrame("Button", nil, content)
		row.looks = {}
		row.vines = CreateFrame("Frame", nil, row)
		row.vines:SetAllPoints()
		row.vines:SetFrameLevel(row:GetFrameLevel() + 1)
		-- the words over the vines, which reach 8 into the row
		row.face = CreateFrame("Frame", nil, row)
		row.face:SetAllPoints()
		row.face:SetFrameLevel(row:GetFrameLevel() + 3)
		row.text = row.face:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		row.text:SetJustifyH("LEFT")
		row.text:SetMaxLines(2)
		row.detail = row.face:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.detail:SetJustifyH("LEFT")
		row.detail:SetWordWrap(false)
		row.detail:SetPoint("TOPLEFT", row.text, "BOTTOMLEFT", 0, -GAP)
		row.detail:SetPoint("RIGHT", -8, 0)
		function row:SetLines(name, detail)
			self.text:SetText(name)
			self.detail:SetText(detail or "")
		end
		function row:SetChosen(on)
			self.chosen = on
			self.text:SetTextColor(unpack(on and WowCompanion_Style.NAME_LIT or WowCompanion_Style.NAME))
		end
		row:SetChosen(false)
		self.rows[i] = row
		return row
	end
	function list:Lay(n, y)
		local key = pickedLook()
		local look = LOOKS[key]
		for i, row in ipairs(self.rows) do
			if i > n then
				row:Hide()
			else
				for k, parts in pairs(row.looks) do if k ~= key then hideParts(parts) end end
				row.looks[key] = row.looks[key] or look.make(row)
				row:ClearAllPoints()
				row:SetPoint("TOPLEFT", content, "TOPLEFT", left or 0, y)
				row:SetPoint("TOPRIGHT", content, "TOPRIGHT", -(right or 0), y)
				row.text:ClearAllPoints()
				row.text:SetPoint("TOPLEFT", look.inset, -PAD)
				row.text:SetPoint("TOPRIGHT", -8, -PAD)
				local h = 2 * PAD + row.text:GetStringHeight()
				if (row.detail:GetText() or "") ~= "" then h = h + GAP + row.detail:GetStringHeight() end
				row:SetHeight(math.floor(h + 0.5))
				look.paint(row, row.looks[key], i, n, i > 1 and self.rows[i - 1].chosen)
				row:Show()
				y = y - row:GetHeight()
			end
		end
		return y
	end
	return list
end
-- "A".."D": every list's rows change at once
function WowCompanion_Style.ListItemStyle(pick)
	if not LOOKS[pick] then return false end
	WowCompanionDB = WowCompanionDB or {}
	WowCompanionDB.listItem = pick
	for _, list in ipairs(lists) do pcall(list.relayout) end
	return true
end

-- The controls' art (tools/make_control_art.py): the scroll bar's fleur
-- arrows, carved groove, bark borders and heartwood thumb, for the settings
-- page's controls and our buttons. Each version its own names, as the stone's.
local CONTROL_VERSION = 2 -- make_control_art.py's VERSION
function WowCompanion_Style.Control(piece)
	return ART .. "Control-" .. piece .. "-" .. CONTROL_VERSION
end
local function controlFont(name, colour)
	local f = CreateFont(name)
	f:CopyFontObject(GameFontHighlight)
	f:SetTextColor(unpack(colour))
	return f
end
local BUTTON_FONT = controlFont("WowCompanionButtonFont", WowCompanion_Style.BRONZE)
local BUTTON_FONT_OFF = controlFont("WowCompanionButtonFontOff", WowCompanion_Style.DIM)
-- A button of ours: a slate slab standing out of the stone, its word in
-- bronze, as wide as its word (button:SetLabel(text)). Footer-sized, as
-- Blizzard's Defaults button is, so an action is not the loudest thing on a page.
function WowCompanion_Style.Button(parent)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(128, 28)
	b:SetNormalTexture(WowCompanion_Style.Control("Button-Normal"))
	b:SetPushedTexture(WowCompanion_Style.Control("Button-Pushed"))
	b:SetHighlightTexture(WowCompanion_Style.Control("Button-Highlight"), "ADD")
	b:SetDisabledTexture(WowCompanion_Style.Control("Button-Disabled"))
	local word = b:CreateFontString(nil, "OVERLAY")
	b:SetFontString(word)
	b:SetNormalFontObject(BUTTON_FONT)
	b:SetDisabledFontObject(BUTTON_FONT_OFF)
	word:SetPoint("CENTER", 0, 1)
	b:SetPushedTextOffset(0, -1)
	function b:SetLabel(text)
		self:SetText(text)
		self:SetWidth(word:GetStringWidth() + 2 * 16 + 16)
	end
	return b
end
