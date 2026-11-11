-- WowCompanion_Agent: the item viewer.

-- The item viewer: an item someone linked, shown in a
-- window the controller can focus, closed with a button or circle, with
-- Previous / Next through the links remembered from chat
-- (WowCompanionAgentDB.links, filled by LinkCatcher.lua). The tooltip is our own GameTooltip, a
-- child of this window, so nothing of Blizzard's is shown or touched.
local viewer
local function buildViewer()
	local made, frame = pcall(CreateFrame, "Frame", "WowCompanionItemView", UIParent, "BackdropTemplate")
	if not made or not frame then return nil end
	frame:SetSize(340, 200)
	frame:SetPoint("CENTER", UIParent, "CENTER", 220, 60)
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)
	frame:Hide()
	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	local caption = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	caption:SetPoint("TOPLEFT", 20, -18)
	caption:SetPoint("TOPRIGHT", -36, -18)
	caption:SetJustifyH("LEFT")
	frame.caption = caption

	local tip = CreateFrame("GameTooltip", "WowCompanionItemViewTip", frame, "GameTooltipTemplate")
	frame.tip = tip

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)
	close:SetScript("OnClick", function() frame:Hide() end)
	frame.CloseButton = close -- circle clicks this (SmartNavigation:AttemptClose)

	local function button(label, width)
		local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		b:SetSize(width, 24)
		b:SetText(label)
		WC.MarkFocusable(b)
		return b
	end
	frame.closeButton = button("Close", 90)
	frame.closeButton:SetPoint("BOTTOMRIGHT", -20, 16)
	frame.closeButton:SetScript("OnClick", function() frame:Hide() end)
	frame.nextButton = button("Older", 80)
	frame.nextButton:SetPoint("RIGHT", frame.closeButton, "LEFT", -8, 0)
	frame.nextButton:SetScript("OnClick", function() WowCompanion_ShowItem((frame.index or 1) + 1) end)
	frame.prevButton = button("Newer", 80)
	frame.prevButton:SetPoint("RIGHT", frame.nextButton, "LEFT", -8, 0)
	frame.prevButton:SetScript("OnClick", function() WowCompanion_ShowItem((frame.index or 1) - 1) end)

	WC.MarkFocusable(frame)
	if UIPanelWindows then
		UIPanelWindows["WowCompanionItemView"] = { area = "center", pushable = 0, whileDead = 1, allowOtherPanels = 1 }
	end
	frame:SetScript("OnHide", function(self)
		self.tip:Hide()
		WC.FrameHidden(self)
	end)
	return frame
end

-- what: an index into the remembered links (1 = newest) or an item link
function WowCompanion_ShowItem(what)
	local links = WowCompanionAgentDB.links or {}
	local index, entry
	if type(what) == "string" then
		entry = { link = what }
	else
		index = math.max(1, math.min(tonumber(what) or 1, #links))
		entry = links[index]
	end
	if not entry then
		WC.Companion.remember("error", "No item link remembered yet: link one in chat, then ask again.")
		return false
	end
	viewer = viewer or buildViewer()
	if not viewer then return false end
	viewer.index = index
	viewer.caption:SetText(entry.from and ("Linked by %s in %s%s"):format(entry.from, entry.where or "chat",
		index and ("  (%d of %d)"):format(index, #links) or "") or "")
	viewer.prevButton:SetEnabled(index ~= nil and index > 1)
	viewer.nextButton:SetEnabled(index ~= nil and index < #links)
	local tip = viewer.tip
	tip:SetOwner(viewer, "ANCHOR_NONE")
	tip:ClearAllPoints()
	tip:SetPoint("TOPLEFT", viewer, "TOPLEFT", 14, -34)
	tip:SetHyperlink(entry.link)
	tip:Show()
	-- the window wraps the tooltip, with room for the caption and the buttons
	viewer:SetSize(math.max(300, tip:GetWidth() + 28), tip:GetHeight() + 34 + 52)
	WC.ShowPanel(viewer)
	return true
end

WC.Items = {
	Show = function(...) return WowCompanion_ShowItem(...) end,
	ConfirmDestroy = function(...) return WowCompanion_ConfirmDestroy(...) end,
}
