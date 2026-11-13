-- WowCompanion_Agent: the conversation menu. Triangle with the cursor on a
-- conversation in the window's list opens it beside that row (the player,
-- 2026-11-12): Clear chat (its lines out of the window; the agent remembers
-- them) and Start over (the agent forgets the conversation: the companion's
-- `fresh` command, src/requests.rs). Stop has its own keys.
--
-- Jobs.lua binds triangle to WCConvMore while the cursor is on a row and
-- leaves the pad to the menu while it is open (WC.ConvMenu.Open()).

-- Built as the window is, small (the player, 2026-11-12): a body of the
-- frame's dimmed slate inside the wells' border; the options in a well of
-- their own, compact rows (the list's names, no dividers), the one under the
-- cursor on the replies' slate with its name lit; and below the well, in the
-- body's own foot strip as the window keeps its legend, what cross and circle
-- do. It opens beside its row, a little clear of the window.
local W, ROW, FOOT, PAD = 150, 22, 22, 6
local function inset(f)
	local made, frame = pcall(CreateFrame, "Frame", nil, f, "InsetFrameTemplate")
	if not made or not frame then frame = CreateFrame("Frame", nil, f) end
	WC.Window.Inset(frame)
	return frame
end
local menu = CreateFrame("Frame", "WCConvMenu", UIParent)
menu:SetFrameStrata("FULLSCREEN_DIALOG")
menu:Hide()
local body = inset(menu)
body:SetAllPoints()
local bodyStone = body:CreateTexture(nil, "BACKGROUND", nil, 1)
WC.Style.Stone(bodyStone, "you", 0.72)
bodyStone:SetPoint("TOPLEFT", WC.Style.FLOOR, -WC.Style.FLOOR)
bodyStone:SetPoint("BOTTOMRIGHT", -WC.Style.FLOOR, WC.Style.FLOOR)
local well = inset(menu)
well:SetPoint("TOPLEFT", PAD, -PAD)
well:SetPoint("BOTTOMRIGHT", -PAD, PAD + FOOT)
local floor = well:CreateTexture(nil, "BACKGROUND", nil, 1)
WC.Style.Stone(floor, "you")
floor:SetPoint("TOPLEFT", WC.Style.FLOOR, -WC.Style.FLOOR)
floor:SetPoint("BOTTOMRIGHT", -WC.Style.FLOOR, WC.Style.FLOOR)
local lit = well:CreateTexture(nil, "BACKGROUND", nil, 2)
WC.Style.Stone(lit, "claude")
local legend = menu:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
legend:SetPoint("RIGHT", menu, "BOTTOMRIGHT", -PAD - 4, PAD + FOOT / 2)
legend:SetText(WowCompanion_Glyph("PAD1") .. " Select    " .. WowCompanion_Glyph("PAD2") .. " Back")
menu.rows = {}
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
		row:SetTextColor(unpack(i == menu.sel and WC.Style.NAME_LIT or WC.Style.NAME))
	end
	lit:ClearAllPoints()
	lit:SetPoint("TOPLEFT", menu.rows[menu.sel], "TOPLEFT", -10, 0)
	lit:SetPoint("BOTTOMRIGHT", menu.rows[menu.sel], "BOTTOMRIGHT")
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
		local text = well:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		text:SetHeight(ROW)
		text:SetPoint("TOPLEFT", WC.Style.FLOOR + 10, -WC.Style.FLOOR - (i - 1) * ROW)
		text:SetPoint("TOPRIGHT", -WC.Style.FLOOR, -WC.Style.FLOOR - (i - 1) * ROW)
		text:SetJustifyH("LEFT")
		menu.rows[i] = text
	end
	local wide = legend:GetStringWidth() + 2 * PAD + 12
	menu:SetSize(math.max(W, wide), #menu.list * ROW + 2 * WC.Style.FLOOR + 2 * PAD + FOOT)
	menu:SetScale(row:GetEffectiveScale() / UIParent:GetEffectiveScale())
	menu:ClearAllPoints()
	-- beside its row, clear of the window's rim, the first option level with it
	local window = WC.Companion.built()
	menu:SetPoint("LEFT", window, "RIGHT", 8, 0)
	menu:SetPoint("TOP", row, "TOP", 0, PAD + WC.Style.FLOOR)
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
