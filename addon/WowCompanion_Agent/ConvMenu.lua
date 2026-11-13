-- WowCompanion_Agent: the conversation menu. Triangle with the cursor on a
-- conversation in the window's list opens it beside that row (the player,
-- 2026-11-12): Clear chat (its lines out of the window; the agent remembers
-- them) and Start over (the agent forgets the conversation: the companion's
-- `fresh` command, src/requests.rs). Stop has its own keys.
--
-- Jobs.lua binds triangle to WCConvMore while the cursor is on a row and
-- leaves the pad to the menu while it is open (WC.ConvMenu.Open()).

local menu = CreateFrame("Frame", "WCConvMenu", UIParent)
menu:SetFrameStrata("FULLSCREEN_DIALOG")
menu:Hide()
WC.Style.Menu(menu)
menu.hl = WC.Style.Highlight(menu)
menu.rows = {}
local pick = WC.Style.Prompt(menu, "PAD1", ACCEPT or "Select")
pick:SetPoint("TOPLEFT", menu, "BOTTOMLEFT", 2, -10)
local back = WC.Style.Prompt(menu, "PAD2", BACK or "Back")
back:SetPoint("LEFT", pick, "RIGHT", 14, 0)
local keys = CreateFrame("Frame", "WCConvMenuKeys", UIParent)

-- the conversation whose row has the cursor now, or nil
local function rowUnderCursor()
	local frame = WC.Companion.built()
	for key, b in pairs(frame and frame.convButtons or {}) do
		if b:IsVisible() and b:IsHighlightLocked() then return key, b end
	end
end

local function close()
	menu:Hide()
	if not InCombatLockdown() then ClearOverrideBindings(keys) end
end
menu:RegisterEvent("PLAYER_REGEN_DISABLED")
menu:SetScript("OnEvent", close)

local function paint()
	for i, row in ipairs(menu.rows) do
		local entry = menu.list[i]
		row:SetText(entry and entry[1] or "")
		row:SetShown(entry ~= nil)
	end
	menu.hl:ClearAllPoints()
	menu.hl:SetPoint("LEFT", menu, "LEFT", 2, 0)
	menu.hl:SetPoint("RIGHT", menu, "RIGHT", -2, 0)
	menu.hl:SetPoint("TOP", menu, "TOP", 0, -(6 + (menu.sel - 1) * 20))
	menu.hl:SetHeight(20)
	menu.hl:Show()
end

local function plainButton(name, fn)
	local b = CreateFrame("Button", name, UIParent)
	b:RegisterForClicks("AnyDown")
	b:SetScript("OnClick", fn)
end
plainButton("WCConvMenuUp", function() menu.sel = menu.sel > 1 and menu.sel - 1 or #menu.list paint() end)
plainButton("WCConvMenuDown", function() menu.sel = menu.sel < #menu.list and menu.sel + 1 or 1 paint() end)
plainButton("WCConvMenuPick", function()
	local entry = menu.list[menu.sel]
	close()
	if entry then entry[2]() end
end)
plainButton("WCConvMenuBack", close)

plainButton("WCConvMore", function()
	if InCombatLockdown() then return end
	local slot, row = rowUnderCursor()
	if not slot then return end
	local name = WC.Conversations.Label(slot)
	menu.list = {
		{ "Clear chat", function()
			WC.Companion.clear(slot)
			WC.Board.toast(("|cffffd100%s|r  chat cleared"):format(name), 0.8, 0.8, 0.8, 5)
		end },
		{ "Start over", function()
			WowCompanion_Strip.Command("fresh " .. WC.Conversations.Wire(slot))
			WC.Board.toast(("|cffffd100%s|r  starts over: it forgets this conversation"):format(name), 0.8, 0.8, 0.8, 8)
		end },
	}
	menu.sel = 1
	for i = #menu.rows + 1, #menu.list do
		-- MenuStyle2's insets: 6 above, 7 below; each row a 20 px cell, text centred in it
		local text = menu:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		text:SetPoint("LEFT", menu, "TOPLEFT", 12, -(6 + (i - 0.5) * 20))
		text:SetJustifyH("LEFT")
		menu.rows[i] = text
	end
	menu:SetSize(150, 6 + #menu.list * 20 + 7)
	menu:ClearAllPoints()
	menu:SetPoint("TOPRIGHT", row, "TOPLEFT", -6, 4)
	paint()
	menu:Show()
	SetOverrideBindingClick(keys, true, "PADDUP", "WCConvMenuUp")
	SetOverrideBindingClick(keys, true, "PADDDOWN", "WCConvMenuDown")
	SetOverrideBindingClick(keys, true, "PAD1", "WCConvMenuPick")
	for _, key in ipairs({ "PAD2", "PAD3", "PAD4", "PADDLEFT", "PADDRIGHT" }) do
		SetOverrideBindingClick(keys, true, key, "WCConvMenuBack")
	end
end)

-- the window closing takes the menu with it
local function follow()
	local frame = WC.Companion.built()
	if frame and not frame.convMenuFollows then
		frame.convMenuFollows = true
		frame:HookScript("OnHide", close)
	end
end

WC.ConvMenu = {
	BUTTON = "WCConvMore",
	Row = function() follow() return (rowUnderCursor()) end,
	Open = function() return menu:IsShown() end,
}
