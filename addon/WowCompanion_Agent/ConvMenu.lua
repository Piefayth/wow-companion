-- WowCompanion_Agent: the window's menu (WC.ConvMenu.Show), opened by
-- triangle: on a chat link (Transcript.lua) and on a conversation in the
-- window's list, beside that row (the player, 2026-11-12): Clear chat (its lines out of the window; the agent remembers
-- them) and Start over (the agent forgets the conversation: the companion's
-- `fresh` command, src/requests.rs). Stop has its own keys.
--
-- Jobs.lua binds triangle to WCConvMore while the cursor is on a row and
-- leaves the pad to the menu while it is open (WC.ConvMenu.Open()).

-- A drawer of the window (the player, 2026-11-12): it slides out of the
-- window's right side, level with its row, its left edge under the window's
-- rim, and the window's own bronze rim round its three outer sides
-- (tools/make_frame_art.py, Drawer-*). Inside, the window's body slate, the
-- options as compact rows of the list's names (no dividers; the one under
-- the cursor on the replies' slate, its name lit), and a foot strip of its
-- own for what cross and circle do, in the window legend's style.
local W, ROW, FOOT, PAD = 160, 24, 24, 6
local RIM = 6 -- the window's rim (Window.lua)
local DRAWER = [[Interface\AddOns\WowCompanion_Agent\Art\Drawer-%s-21]]
local menu = CreateFrame("Frame", "WCConvMenu", UIParent)
menu:Hide()
local function piece(name, layer)
	local t = menu:CreateTexture(nil, layer or "BORDER")
	t:SetTexture(DRAWER:format(name), "CLAMP", "CLAMP")
	return t
end
local tr, br = piece("TopRightCorner"), piece("BottomRightCorner")
tr:SetSize(RIM, RIM)
tr:SetPoint("TOPRIGHT")
br:SetSize(RIM, RIM)
br:SetPoint("BOTTOMRIGHT")
local top, bottom, right = piece("TopEdge"), piece("BottomEdge"), piece("RightEdge")
top:SetPoint("TOPLEFT")
top:SetPoint("BOTTOMRIGHT", tr, "BOTTOMLEFT")
bottom:SetPoint("BOTTOMLEFT")
bottom:SetPoint("TOPRIGHT", br, "TOPLEFT")
right:SetPoint("TOPLEFT", tr, "BOTTOMLEFT")
right:SetPoint("BOTTOMRIGHT", br, "TOPRIGHT")
local body = menu:CreateTexture(nil, "BACKGROUND")
WC.Style.Stone(body, "you", 0.72)
body:SetPoint("TOPLEFT", 0, -RIM)
body:SetPoint("BOTTOMRIGHT", -RIM, RIM)
local lit = menu:CreateTexture(nil, "BACKGROUND", nil, 2)
WC.Style.Stone(lit, "claude")
local legend = menu:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
legend:SetPoint("RIGHT", menu, "BOTTOMRIGHT", -RIM - PAD - 2, RIM + FOOT / 2)
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
	lit:SetPoint("TOPLEFT", menu.rows[menu.sel], "TOPLEFT", -10 - PAD, 0)
	lit:SetPoint("BOTTOMRIGHT", menu.rows[menu.sel], "BOTTOMRIGHT", PAD, 0)
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

-- list: { { name, fn }, ... }; the drawer level with `row`, the pad its own
-- until a pick or back
local function show(list, row)
	if InCombatLockdown() then return end
	menu.list = list
	menu.sel = 1
	for i = #menu.rows + 1, #menu.list do
		local text = menu:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		text:SetHeight(ROW)
		text:SetPoint("TOPLEFT", RIM + PAD + 10, -RIM - PAD - (i - 1) * ROW)
		text:SetPoint("TOPRIGHT", -RIM - PAD, -RIM - PAD - (i - 1) * ROW)
		text:SetJustifyH("LEFT")
		menu.rows[i] = text
	end
	local window = WC.Companion.built()
	local wide = legend:GetStringWidth() + 2 * (RIM + PAD) + 16
	menu:SetSize(math.max(W, wide), RIM + PAD + #menu.list * ROW + PAD + FOOT + RIM)
	menu:SetScale(window:GetEffectiveScale() / UIParent:GetEffectiveScale())
	-- under the window, so its left edge tucks beneath the window's rim
	menu:SetFrameStrata(window:GetFrameStrata())
	menu:SetFrameLevel(math.max(1, window:GetFrameLevel() - 1))
	menu:ClearAllPoints()
	menu:SetPoint("LEFT", window, "RIGHT", -RIM, 0)
	menu:SetPoint("TOP", row, "TOP", 0, RIM + PAD)
	paint()
	menu:Show()
	SetOverrideBindingClick(keys, true, "PADDUP", "WCConvMenuUp")
	SetOverrideBindingClick(keys, true, "PADDDOWN", "WCConvMenuDown")
	SetOverrideBindingClick(keys, true, "PAD1", "WCConvMenuPick")
	for _, key in ipairs({ "PAD2", "PAD3", "PAD4", "PADDLEFT", "PADDRIGHT" }) do
		SetOverrideBindingClick(keys, true, key, "WCConvMenuBack")
	end
end

plainButton("WCConvMore", function()
	local slot, row = rowUnderCursor()
	if not slot then return end
	local name = WC.Conversations.Label(slot)
	show({
		{ "Clear chat", function()
			WC.Companion.clear(slot)
			WC.Board.toast(("|cffffd100%s|r  chat cleared"):format(name), 0.8, 0.8, 0.8, 5)
		end },
		{ "Start over", function()
			WowCompanion_Strip.Command("fresh " .. WC.Conversations.Wire(slot))
			WC.Board.toast(("|cffffd100%s|r  starts over: it forgets this conversation"):format(name), 0.8, 0.8, 0.8, 8)
		end },
	}, row)
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
	Show = function(list, row) follow() show(list, row) end,
}
