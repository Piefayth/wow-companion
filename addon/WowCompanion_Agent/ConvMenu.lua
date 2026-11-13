-- WowCompanion_Agent: the conversation menu. Triangle with the cursor on a
-- conversation in the window's list opens it beside that row (the player,
-- 2026-11-12): Clear chat (its lines out of the window; the agent remembers
-- them) and Start over (the agent forgets the conversation: the companion's
-- `fresh` command, src/requests.rs). Stop has its own keys.
--
-- Jobs.lua binds triangle to WCConvMore while the cursor is on a row and
-- leaves the pad to the menu while it is open (WC.ConvMenu.Open()).

-- Drawn as the list it opens from (the player, 2026-11-12): a well of the
-- window's own border and dark slate, its options the list's rows, the one
-- under the cursor lit as the conversation in view is. It stands against
-- the window's right edge, level with its row, a drawer of the window rather
-- than a box in the air; what cross and circle do is its own foot strip, in
-- the window legend's style (glyphs inline, white).
local W, FOOT = 150, 24 -- its rows as tall as the list's
local made, menu = pcall(CreateFrame, "Frame", "WCConvMenu", UIParent, "InsetFrameTemplate")
if not made or not menu then menu = CreateFrame("Frame", "WCConvMenu", UIParent) end
menu:SetFrameStrata("FULLSCREEN_DIALOG")
menu:Hide()
local inset = WC.Window.INSET
WC.Window.Inset(menu)
local floor = menu:CreateTexture(nil, "BACKGROUND", nil, 1)
WC.Style.Stone(floor, "you")
floor:SetPoint("TOPLEFT", WC.Style.FLOOR, -WC.Style.FLOOR)
floor:SetPoint("BOTTOMRIGHT", -WC.Style.FLOOR, WC.Style.FLOOR)
menu.rows = {}
local legend = menu:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
legend:SetPoint("BOTTOMRIGHT", -inset - 8, inset + 5)
legend:SetJustifyH("RIGHT")
legend:SetText(WowCompanion_Glyph("PAD1") .. " Select     " .. WowCompanion_Glyph("PAD2") .. " Back")
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
		row:SetChosen(i == menu.sel)
	end
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
		-- rows edge to edge across the well, as the list's
		local r = WC.Style.ChoiceRow(menu)
		r:SetPoint("LEFT", inset, 0)
		r:SetPoint("RIGHT", -inset, 0)
		r:EnableMouse(false)
		menu.rows[i] = r
	end
	local ROW = row:GetHeight()
	for i, r in ipairs(menu.rows) do
		r:SetHeight(ROW)
		r:SetPoint("TOP", 0, -inset - (i - 1) * ROW)
	end
	menu:SetSize(W, #menu.list * ROW + FOOT + 2 * inset)
	menu:SetScale(row:GetEffectiveScale() / UIParent:GetEffectiveScale())
	menu:ClearAllPoints()
	-- against the window's right edge, its first option level with the row
	local window = WC.Companion.built()
	menu:SetPoint("LEFT", window, "RIGHT", 0, 0)
	menu:SetPoint("TOP", row, "TOP", 0, inset)
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
