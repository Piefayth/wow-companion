-- Part of WowCompanion; loaded by the .toc in order: Engine, Style, Companion,
-- Pins, Strip, Bags, Status, Modules. A file shares nothing local with another:
-- they talk through globals (WC, WowCompanion_*, WCPins, WCBags).

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

-- The talk button as the game sees it. On this setup the companion's talk button
-- (minus on a Switch pad in DS5 mode) reaches the game as the DualSense Create
-- button, PADSOCIAL; the tap that opens the window is bound to it (bindTap).
WowCompanion_TalkKey = "PADSOCIAL"

-- A controller button drawn as the game draws it for the pad in use: the same
-- glyph set Blizzard's prompts pick (InputDeviceIconSetManager: the active
-- device's labelStyle, Shp shapes, Ltr letters, Rev Nintendo), from the strings
-- SharedConstants.lua defines (KEY_ABBR_PAD1_SHP...). Never a fixed name, so any
-- controller reads right. Falls back to the generic glyph, then the key name.
-- labelStyle reads "Shapes" on this client, not "Shp": unmatched, every glyph
-- falls back to the generic numbered one. Both spellings map.
local GLYPH_SUFFIX = { Shp = "_SHP", Shapes = "_SHP", Ltr = "_LTR", Letters = "_LTR",
	Rev = "_REV", Reverse = "_REV", Reversed = "_REV" }
function WowCompanion_Glyph(key)
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
					WC.Toast("|cffffd100Destroyed|r " .. (f.link or ""), 0.8, 0.8, 0.8, 3)
				else
					ClearCursor()
				end
			else
				WC.Toast("Not destroyed: the item moved", 1, 0.5, 0.5, 3)
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
