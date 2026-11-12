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
-- "hold a conversation's chord": both shoulder buttons with no letters, inline
-- in text (tools/make_chord_glyph.py draws it on a 64 x 64 canvas, the version
-- in its name), cut to the rows the bumpers fill so it stands as tall as the
-- other prompt icons and about as wide as the trimmed R3
local CHORD_ROWS = { 14, 52 }
WowCompanion_Style.CHORD = ("|T%sChord-6:%d:%d:0:0:64:64:0:64:%d:%d|t"):format(ART, GLYPH_SIZE,
	math.floor(GLYPH_SIZE * 64 / (CHORD_ROWS[2] - CHORD_ROWS[1]) + 0.5), CHORD_ROWS[1], CHORD_ROWS[2])

-- A scroll bar for a ScrollFrame of ours, as the Companion's chat draws its
-- own (Window.lua): Blizzard's classic scroll trough in column (its end caps,
-- the top cap's rails-only rows 9..14 stretched between them, the dark stone
-- in the gutter), Blizzard's up and down arrows inside the caps scrolling by
-- step, and Blizzard's thumb between them, sized to the share in view, shown
-- only. column is a frame BAR wide where the bar goes. Out of the cursor's
-- path: the controller scrolls by moving through what is scrolled.
WowCompanion_Style.BAR = 31
function WowCompanion_Style.ScrollBar(scroll, column, step)
	local gutter = column:CreateTexture(nil, "BACKGROUND")
	gutter:SetTexture(WowCompanion_Style.STONE.you, "REPEAT", "REPEAT")
	gutter:SetHorizTile(true)
	gutter:SetVertTile(true)
	gutter:SetPoint("TOPLEFT", 5, 0)
	gutter:SetPoint("BOTTOMRIGHT", -5, 0)
	local capTop = column:CreateTexture(nil, "BORDER")
	capTop:SetAtlas("UI-ClassicScrollBar-EndCap-Top", true)
	capTop:SetPoint("TOPLEFT")
	local capBottom = column:CreateTexture(nil, "BORDER")
	capBottom:SetAtlas("UI-ClassicScrollBar-EndCap-Bottom", true)
	capBottom:SetPoint("BOTTOMLEFT")
	local cap = C_Texture.GetAtlasInfo("UI-ClassicScrollBar-EndCap-Top")
	if cap then
		local rails = column:CreateTexture(nil, "BORDER")
		rails:SetTexture(cap.file)
		rails:SetTexCoord(cap.leftTexCoord, cap.rightTexCoord, 9 / 64, 14 / 64)
		rails:SetPoint("TOPLEFT", capTop, "BOTTOMLEFT")
		rails:SetPoint("BOTTOMRIGHT", capBottom, "TOPRIGHT")
	end
	local function scrollBy(dir)
		local most = scroll:GetVerticalScrollRange() or 0
		scroll:SetVerticalScroll(math.min(most, math.max(0, scroll:GetVerticalScroll() + dir * step)))
	end
	local up = CreateFrame("Button", nil, column, "UIPanelScrollUpButtonTemplate")
	up:SetPoint("TOP", 0, -4)
	up:SetScript("OnClick", function() scrollBy(-1) end)
	local down = CreateFrame("Button", nil, column, "UIPanelScrollDownButtonTemplate")
	down:SetPoint("BOTTOM", 0, 4)
	down:SetScript("OnClick", function() scrollBy(1) end)
	local track = CreateFrame("Frame", nil, column)
	track:SetPoint("TOP", up, "BOTTOM", 0, -2)
	track:SetPoint("BOTTOM", down, "TOP", 0, 2)
	track:SetWidth(18)
	-- Blizzard's WowTrimScrollBar thumb: round caps at their size, the centre
	-- tiled (its coordinate runs past 1), never stretched
	local thumb = CreateFrame("Frame", nil, track)
	local top = thumb:CreateTexture(nil, "OVERLAY")
	top:SetAtlas("UI-ScrollBar-Knob-EndCap-Top", true)
	top:SetPoint("TOPLEFT")
	local bottom = thumb:CreateTexture(nil, "OVERLAY")
	bottom:SetAtlas("UI-ScrollBar-Knob-EndCap-Bottom", true)
	bottom:SetPoint("BOTTOMLEFT")
	local middle = thumb:CreateTexture(nil, "ARTWORK")
	middle:SetAtlas("UI-ScrollBar-Knob-Center", true)
	middle:SetPoint("TOPLEFT", 0, -5)
	middle:SetPoint("TOPRIGHT", 0, -5)
	local centre = C_Texture.GetAtlasInfo("UI-ScrollBar-Knob-Center")
	thumb:SetWidth(math.max(top:GetWidth(), middle:GetWidth()))
	local function paint()
		local range = scroll:GetVerticalScrollRange() or 0
		local view, room = scroll:GetHeight() or 0, track:GetHeight() or 0
		up:SetEnabled(range > 1 and scroll:GetVerticalScroll() > 0)
		down:SetEnabled(range > 1 and scroll:GetVerticalScroll() < range)
		if range <= 1 or view <= 0 or room <= 0 then thumb:Hide() return end
		local size = math.max(23, room * view / (view + range))
		thumb:ClearAllPoints()
		thumb:SetPoint("TOP", track, "TOP", 0, -(room - size) * math.min(1, scroll:GetVerticalScroll() / range))
		thumb:SetHeight(size)
		local h = math.max(1, size - 10)
		middle:SetHeight(h)
		if centre and centre.height > 0 then middle:SetTexCoord(0, 1, 0, h / centre.height) end
		thumb:Show()
	end
	scroll:HookScript("OnVerticalScroll", paint)
	scroll:HookScript("OnScrollRangeChanged", paint)
	scroll:HookScript("OnSizeChanged", paint)
	track:SetScript("OnShow", paint)
	WC.MarkIgnored(column)
end
