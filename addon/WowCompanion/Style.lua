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
-- Mid (repeated, WC.Style.Run), Right, 32 x 16 (Mid 64); Top, VMid (repeated), Bottom,
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
-- A piece of a line drawn in several textures (a vine's ends, its run, a
-- joint), placed where its anchors say, never snapped to the pixel grid: the
-- game snaps each texture's edges on its own, so a 16-unit vine's end and its
-- run landed a pixel apart and every joint showed as a step (measured on the
-- Status spine, 2026-11-12). Blizzard does the same for its nine-slices
-- (NineSliceUtil.DisableSharpening).
function WowCompanion_Style.Unsnapped(t)
	t:SetTexelSnappingBias(0)
	t:SetSnapToPixelGrid(false)
	return t
end
-- the same for a button's state textures (a line's arrow cap)
function WowCompanion_Style.UnsnappedButton(b)
	for _, t in ipairs({ b:GetNormalTexture(), b:GetPushedTexture(), b:GetHighlightTexture(), b:GetDisabledTexture() }) do
		WowCompanion_Style.Unsnapped(t)
	end
	return b
end
-- A run: the middle of a vine, a groove or a slot between its two ends, a
-- texture of `owner`'s to anchor as any other. Never stretched: its art repeats
-- along its length at the ends' own density (`units`, the art's length in UI
-- units), so the game samples every piece of a line alike. A stretched middle
-- was sampled finer than its ends (the long axis barely minified), and each
-- joint showed as a step in the line's shading (the player, 2026-11-12). An
-- empty frame on the texture follows its size.
function WowCompanion_Style.Run(owner, path, vertical, units, layer)
	local t = WowCompanion_Style.Unsnapped(owner:CreateTexture(nil, layer or "ARTWORK"))
	if vertical then t:SetTexture(path, "CLAMP", "REPEAT") else t:SetTexture(path, "REPEAT", "CLAMP") end
	local size = CreateFrame("Frame", nil, owner)
	size:SetAllPoints(t)
	size:SetScript("OnSizeChanged", function(_, w, h)
		local n = (vertical and h or w) / units
		if vertical then t:SetTexCoord(0, 1, 0, n) else t:SetTexCoord(0, n, 0, 1) end
	end)
	return t
end
-- A vine run through `owner`: across its middle (vertical false, owner 16
-- tall) or down it (owner 16 wide), with a round end at its start and end when
-- asked (none where it runs into a junction). Returns its textures.
function WowCompanion_Style.VineLine(owner, weight, vertical, capStart, capEnd)
	weight = weight or ""
	local made = {}
	local function piece(name, w, h)
		local t = WowCompanion_Style.Unsnapped(owner:CreateTexture(nil, "ARTWORK"))
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
		mid = WowCompanion_Style.Run(owner, WowCompanion_Style.Vine(weight .. "VMid"), true, 64)
		mid:SetWidth(16)
		made[#made + 1] = mid
		if first then first:SetPoint("TOP") end
		if last then last:SetPoint("BOTTOM") end
		mid:SetPoint("TOP", first or owner, first and "BOTTOM" or "TOP")
		mid:SetPoint("BOTTOM", last or owner, last and "TOP" or "BOTTOM")
	else
		first = capStart and piece("Left", 32, 16)
		last = capEnd and piece("Right", 32, 16)
		mid = WowCompanion_Style.Run(owner, WowCompanion_Style.Vine(weight .. "Mid"), false, 64)
		mid:SetHeight(16)
		made[#made + 1] = mid
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
	local t = WowCompanion_Style.Unsnapped(owner:CreateTexture(nil, "OVERLAY"))
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
-- a fact (LABEL), a control's value (BRONZE, BRONZE_LIT lit), what is not
-- there yet (DIM).
-- In text, a short word for good or bad, colour-blind safe, and grey detail.
WowCompanion_Style.NAME = { 0.78, 0.69, 0.53 }
WowCompanion_Style.NAME_HL = { 0.91, 0.84, 0.67 }
WowCompanion_Style.NAME_LIT = { 0.98, 0.92, 0.78 }
WowCompanion_Style.LABEL = { 0.86, 0.76, 0.56 }
WowCompanion_Style.HEAD = { 0.93, 0.85, 0.68 } -- a heading: pale bronze, lighter than LABEL, short of white
WowCompanion_Style.BRONZE = { 0.78, 0.66, 0.45 }
WowCompanion_Style.BRONZE_LIT = { 0.95, 0.80, 0.53 } -- bronze brightened, never toward white (a button under the cursor)
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
-- edges (sunk: the sides that have one, by default both), light falling from
-- the top left, no rim. Returns its stone, for the caller to anchor, and its
-- shadows; what lies
-- on the stone under the shadow goes at sublevel 0.
--
-- Raised, it stands up out of the page instead. Nothing is painted on it: its
-- height is told by what is round it, as light from the top left would. The
-- page's lower well beside it takes its shadow over whatever lies
-- there (WC.Style.CastOn, drawn in a frame of the caller's over the lower
-- well's contents and under the vines); the window's top shadow is cut over
-- it (Window.lua, page.raised); its own stone lighter, nearer
-- the light, a faint lit line along its top and left edges. The look is the
-- player's pick of the trial (2026-11-13, "All fade, wide"): the stone's shade;
-- the shadow a 1-wide solid line fading over 12 at half dark.
local RAISED = { shade = 0.8, cast = 1, soft = 12, alpha = 0.5, rim = 0.08 }
-- the shadow along side of stone ("LEFT" or "TOP"): a solid band, then its edge fading
local function paintCast(c)
	local across = c.side == "TOP"
	local solid, fade = c.tex[1], c.tex[2]
	solid:SetPoint("TOPLEFT", c.stone)
	solid:SetPoint(across and "TOPRIGHT" or "BOTTOMLEFT", c.stone)
	solid:SetColorTexture(0, 0, 0, RAISED.alpha)
	fade:SetPoint("TOPLEFT", solid, across and "BOTTOMLEFT" or "TOPRIGHT")
	fade:SetPoint(across and "TOPRIGHT" or "BOTTOMLEFT", solid, across and "BOTTOMRIGHT" or "BOTTOMRIGHT")
	fade:SetColorTexture(1, 1, 1, 1)
	local dark, clear = CreateColor(0, 0, 0, RAISED.alpha), CreateColor(0, 0, 0, 0)
	if across then
		solid:SetHeight(RAISED.cast)
		fade:SetHeight(RAISED.soft)
		fade:SetGradient("VERTICAL", clear, dark)
	else
		solid:SetWidth(RAISED.cast)
		fade:SetWidth(RAISED.soft)
		fade:SetGradient("HORIZONTAL", dark, clear)
	end
end
-- a raised well's shadow along side of the lower well's stone, drawn in over
function WowCompanion_Style.CastOn(over, stone, side)
	paintCast({ stone = stone, side = side, tex = { over:CreateTexture(nil, "BACKGROUND"), over:CreateTexture(nil, "BACKGROUND") } })
end
function WowCompanion_Style.Well(page, which, shade, raised, sunk)
	local t = page:CreateTexture(nil, "BACKGROUND", nil, -1)
	WowCompanion_Style.Stone(t, which, shade)
	if raised then
		t:SetVertexColor(RAISED.shade, RAISED.shade, RAISED.shade)
		for i, edge in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "TOPLEFT", "BOTTOMLEFT" } }) do
			local line = page:CreateTexture(nil, "BACKGROUND", nil, 2)
			line:SetBlendMode("ADD")
			line:SetPoint(edge[1], t)
			line:SetPoint(edge[2], t)
			if i == 1 then line:SetHeight(1) else line:SetWidth(1) end
			line:SetColorTexture(1, 1, 1, RAISED.rim)
		end
		return t
	end
	local shades = {}
	for _, side in ipairs(sunk or { "Top", "Left" }) do
		local s = page:CreateTexture(nil, "BACKGROUND", nil, 2)
		s:SetTexture([[Interface\Common\ShadowOverlay-]] .. side)
		s:SetAlpha(0.7)
		s:SetPoint("TOPLEFT", t)
		s:SetPoint(side == "Top" and "TOPRIGHT" or "BOTTOMLEFT", t)
		if side == "Top" then s:SetHeight(SHADE) else s:SetWidth(SHADE) end
		shades[#shades + 1] = s
	end
	return t, shades
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
-- A page's rules, casts, spine and covers stand over the window's top shadow
-- (Window.lua's page lip, 20 levels over its page well), so the shadow falls
-- on the stone and the rows, never across the vines: frames, lowest first,
-- set from OVER_SHADE over the page each time it shows, as a page shown in
-- another frame has its levels reset.
WowCompanion_Style.OVER_SHADE = 25
function WowCompanion_Style.OverShade(page, frames)
	local function lift()
		local base = page:GetFrameLevel() + WowCompanion_Style.OVER_SHADE
		for i, f in ipairs(frames) do f:SetFrameLevel(base + i - 1) end
	end
	page:HookScript("OnShow", lift)
	lift()
end
-- The covers over a spine's ends where it meets a raised well's top and
-- bottom (tools/make_cover_art.py), in a frame of owner's over the spine;
-- returns it, for the caller to set its level. What else draws a stretch of
-- the spine (a section's joint) stays COVER_CUT short of its ends.
WowCompanion_Style.COVER_CUT = 17
function WowCompanion_Style.SpineCovers(owner, spine)
	local f = CreateFrame("Frame", nil, owner)
	f:SetAllPoints(spine)
	for _, which in ipairs({ "Top", "Bottom" }) do
		local c = WowCompanion_Style.Unsnapped(f:CreateTexture(nil, "OVERLAY"))
		c:SetSize(48, 16)
		c:SetPoint(which:upper(), f, which:upper())
		c:SetTexture(ART .. "Vine-CornerCover" .. which, "CLAMP", "CLAMP")
	end
	return f
end

-- A heading over what follows it, as the Settings page names its sections:
-- in HEAD on the raised dark stone
function WowCompanion_Style.Heading(parent)
	local h = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightMed2")
	h:SetTextColor(unpack(WowCompanion_Style.HEAD))
	return h
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
-- line of detail (row.detail), each the dark stone raised as a raised well is
-- (RAISED): a faint lit line along its top and left, a shadow cast down onto
-- what it lies on; chosen, the light stone, the same. edge (on trial) closes
-- its far sides: line, a dark line along its right and bottom; bevel, a
-- shaded band there; both, that and a lit band along its top and left; deep,
-- a wider, darker band.
-- WC.Style.List(content): list:Row(i) the i-th row, made once
-- (row:SetLines(name, detail), row:SetChosen(on), row.face for the caller's
-- own marks); list:Lay(n, y, how) stacks rows 1..n from y down content,
-- hides the rest and returns the y under them. how: gap between rows, left
-- and right in from content's sides, edge.
local LIST_ITEM_VERSION = 1 -- make_listitem_art.py's VERSION
local function listArt(piece) return ART .. "ListItem-" .. piece .. "-" .. LIST_ITEM_VERSION end
local PAD, GAP, INSET = 8, 2, 14 -- the words' inset top and bottom, between the lines, from the left
local function listStone(row, which)
	local tex = row:CreateTexture(nil, "BACKGROUND")
	WowCompanion_Style.Stone(tex, which)
	tex:SetAllPoints()
	return tex
end
-- a nine-slice of make_listitem_art's (corners 8), set out 4 round the box l, t, r, b in from frame
local function nine(frame, piece, l, t, r, b)
	local made = {}
	local cut = { 0, 0.25, 0.75, 1 }
	local xs = { { "LEFT", l - 4 }, { "LEFT", l + 4 }, { "RIGHT", -r - 4 }, { "RIGHT", -r + 4 } }
	local ys = { { "TOP", -t + 4 }, { "TOP", -t - 4 }, { "BOTTOM", b + 4 }, { "BOTTOM", b - 4 } }
	for i = 1, 3 do
		for j = 1, 3 do
			local tex = frame:CreateTexture(nil, "BORDER")
			tex:SetTexture(listArt(piece))
			tex:SetTexCoord(cut[j], cut[j + 1], cut[i], cut[i + 1])
			tex:SetPoint("TOPLEFT", frame, ys[i][1] .. xs[j][1], xs[j][2], ys[i][2])
			tex:SetPoint("BOTTOMRIGHT", frame, ys[i + 1][1] .. xs[j + 1][1], xs[j + 1][2], ys[i + 1][2])
			made[#made + 1] = tex
		end
	end
	return made
end
-- the bark rim round the box l, t, r, b in from frame's sides
function WowCompanion_Style.BarkRim(frame, l, t, r, b) return nine(frame, "Slab-Rim", l, t, r, b) end
local function shown(parts, on) for _, p in ipairs(parts) do p:SetShown(on) end end
local ROW_CAST = 6
-- a band along side ("TOP", "LEFT", "BOTTOM", "RIGHT") of row, w wide,
-- strongest at the edge: dark, or lit (added)
local function band(row, side, w, alpha, lit)
	local t = row:CreateTexture(nil, "BORDER")
	t:SetColorTexture(1, 1, 1, 1)
	if lit then t:SetBlendMode("ADD") end
	local across = side == "TOP" or side == "BOTTOM"
	local first = (side == "TOP" or side == "BOTTOM") and side .. "LEFT" or "TOP" .. side
	local second = (side == "TOP" or side == "BOTTOM") and side .. "RIGHT" or "BOTTOM" .. side
	t:SetPoint(first)
	t:SetPoint(second)
	if across then t:SetHeight(w) else t:SetWidth(w) end
	local c = lit and 1 or 0
	local strong, none = CreateColor(c, c, c, alpha), CreateColor(c, c, c, 0)
	-- VERTICAL runs bottom to top, HORIZONTAL left to right
	if side == "TOP" then t:SetGradient("VERTICAL", none, strong)
	elseif side == "BOTTOM" then t:SetGradient("VERTICAL", strong, none)
	elseif side == "LEFT" then t:SetGradient("HORIZONTAL", strong, none)
	else t:SetGradient("HORIZONTAL", none, strong) end
	return t
end
local EDGES = {
	line = function(row) return { band(row, "RIGHT", 1, 0.6), band(row, "BOTTOM", 1, 0.6) } end,
	bevel = function(row) return { band(row, "RIGHT", 3, 0.5), band(row, "BOTTOM", 3, 0.5) } end,
	both = function(row)
		return { band(row, "RIGHT", 3, 0.5), band(row, "BOTTOM", 3, 0.5), band(row, "TOP", 2, 0.12, true), band(row, "LEFT", 2, 0.12, true) }
	end,
	deep = function(row) return { band(row, "RIGHT", 5, 0.65), band(row, "BOTTOM", 5, 0.65) } end,
}
local function makeRow(row)
	local p = { idle = { listStone(row, "you") }, chosen = { listStone(row, "claude") }, rim = {}, edges = {} }
	for i, edge in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "TOPLEFT", "BOTTOMLEFT" } }) do
		local line = row:CreateTexture(nil, "BORDER")
		line:SetBlendMode("ADD")
		line:SetPoint(edge[1])
		line:SetPoint(edge[2])
		if i == 1 then line:SetHeight(1) else line:SetWidth(1) end
		line:SetColorTexture(1, 1, 1, RAISED.rim)
		p.rim[i] = line
	end
	-- the shadow on the content under every row, so the row below lies over it
	local dark, clear = CreateColor(0, 0, 0, RAISED.alpha), CreateColor(0, 0, 0, 0)
	local down = row:GetParent():CreateTexture(nil, "BACKGROUND")
	down:SetColorTexture(1, 1, 1, 1)
	down:SetPoint("TOPLEFT", row, "BOTTOMLEFT")
	down:SetPoint("TOPRIGHT", row, "BOTTOMRIGHT")
	down:SetHeight(ROW_CAST)
	down:SetGradient("VERTICAL", clear, dark)
	p.cast = { down }
	return p
end
function WowCompanion_Style.List(content)
	local list = { rows = {} }
	function list:Row(i)
		local row = self.rows[i]
		if row then return row end
		row = CreateFrame("Button", nil, content)
		row.parts = makeRow(row)
		-- the words over the row's art
		row.face = CreateFrame("Frame", nil, row)
		row.face:SetAllPoints()
		row.face:SetFrameLevel(row:GetFrameLevel() + 3)
		row.text = row.face:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		row.text:SetJustifyH("LEFT")
		row.text:SetMaxLines(2)
		row.text:SetPoint("TOPLEFT", INSET, -PAD)
		row.text:SetPoint("TOPRIGHT", -8, -PAD)
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
	function list:Lay(n, y, how)
		for i, row in ipairs(self.rows) do
			local p = row.parts
			if i > n then
				row:Hide()
				shown(p.cast, false)
			else
				row:ClearAllPoints()
				row:SetPoint("TOPLEFT", content, "TOPLEFT", how.left, y)
				row:SetPoint("TOPRIGHT", content, "TOPRIGHT", -how.right, y)
				local h = 2 * PAD + row.text:GetStringHeight()
				if (row.detail:GetText() or "") ~= "" then h = h + GAP + row.detail:GetStringHeight() end
				row:SetHeight(math.floor(h + 0.5))
				shown(p.idle, not row.chosen)
				shown(p.chosen, row.chosen)
				shown(p.cast, true)
				for k, parts in pairs(p.edges) do shown(parts, k == how.edge) end
				if how.edge and not p.edges[how.edge] then p.edges[how.edge] = EDGES[how.edge](row) end
				row:Show()
				y = y - row:GetHeight() - (i < n and how.gap or 0)
			end
		end
		return y
	end
	return list
end

-- The controls' art (tools/make_control_art.py): the scroll bar's fleur
-- arrows, carved groove, bark borders and heartwood thumb, for the settings
-- page's controls. Each version its own names, as the stone's.
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
-- A button of ours (tools/make_button_art.py, the player's pick, 2026-11-12):
-- a slab of the dark stone with cut corners and a faceted bevel in a bark rim,
-- its word in bronze, as wide as its word (button:SetLabel(text)). Under the
-- cursor it stays dark and lights round it: the focus glow outside, the rim
-- and the word a brighter bronze (button:SetLit(on) for a row that holds the
-- cursor for it); pressed, its face sinks; unavailable, greyed. The art is
-- 160 x 36 with the 128 x 28 body in its middle, cut in three so the ends keep
-- their cuts and the middle stretches.
local BUTTON_VERSION = 1 -- make_button_art.py's VERSION
local BUTTON_SLICES = { { 0, 28 }, { 28, 132 }, { 132, 160 } }
function WowCompanion_Style.Button(parent)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(128, 28)
	local parts = {}
	for i, cut in ipairs(BUTTON_SLICES) do
		local t = b:CreateTexture(nil, "BACKGROUND")
		t:SetTexCoord(cut[1] / 160, cut[2] / 160, 0, 1)
		t:SetPoint("TOP", 0, 4)
		t:SetPoint("BOTTOM", 0, -4)
		parts[i] = t
	end
	parts[1]:SetWidth(28)
	parts[1]:SetPoint("LEFT", -16, 0)
	parts[3]:SetWidth(28)
	parts[3]:SetPoint("RIGHT", 16, 0)
	parts[2]:SetPoint("LEFT", parts[1], "RIGHT")
	parts[2]:SetPoint("RIGHT", parts[3], "LEFT")
	local word = b:CreateFontString(nil, "OVERLAY")
	b:SetFontString(word)
	b:SetNormalFontObject(BUTTON_FONT)
	b:SetDisabledFontObject(BUTTON_FONT_OFF)
	word:SetPoint("CENTER", 0, 1)
	b:SetPushedTextOffset(0, -1)
	local over, held, lit = false, false, false
	local function paint()
		local on = b:IsEnabled()
		local state = on and (held and "Pushed" or (over or lit) and "Lit") or "Rest"
		for _, t in ipairs(parts) do
			t:SetTexture(ART .. "Button-" .. state .. "-" .. BUTTON_VERSION)
			t:SetDesaturated(not on)
		end
		if on then word:SetTextColor(unpack((over or lit) and WowCompanion_Style.BRONZE_LIT or WowCompanion_Style.BRONZE)) end
	end
	b:HookScript("OnEnter", function() over = true paint() end)
	b:HookScript("OnLeave", function() over, held = false, false paint() end)
	b:HookScript("OnMouseDown", function() held = true paint() end)
	b:HookScript("OnMouseUp", function() held = false paint() end)
	b:HookScript("OnEnable", paint)
	b:HookScript("OnDisable", paint)
	function b:SetLit(on)
		lit = on
		paint()
	end
	function b:SetLabel(text)
		self:SetText(text)
		self:SetWidth(word:GetStringWidth() + 2 * 16 + 16)
	end
	paint()
	return b
end
