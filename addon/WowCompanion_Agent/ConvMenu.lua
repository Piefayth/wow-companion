-- WowCompanion_Agent: the window's menu (WC.ConvMenu.Show), opened by
-- triangle: on a chat link (Transcript.lua) and on a conversation in the
-- window's list, beside that row (the player, 2026-11-12): Clear chat (its lines out of the window; the agent remembers
-- them), Compact (a /compact request in that conversation: the companion's
-- `compact` command) and Start over (the agent forgets the conversation: the
-- companion's `fresh` command, src/requests.rs). Stop has its own keys.
--
-- Jobs.lua binds triangle to WCConvMore while the cursor is on a row and
-- leaves the pad to the menu while it is open (WC.ConvMenu.Open()).

-- A drawer of the window (the player, 2026-11-12/13): it slides out of the
-- window's right side, level with its row, and has its own rim on its three
-- outer sides, the window rim's own profile (tools/make_frame_art.py,
-- drawer(), Drawer-*): its top and bottom rims bend up and down into the
-- window's rim (drawer round 9's 6, its volutes taken off), so the
-- joints' pieces reach past the drawer, hold the window's rim beside them
-- and lie over it. Inside, the window's body slate, the options as compact
-- rows of the list's names (no dividers; the one under the cursor on the
-- replies' slate, its name lit), and under a rule of the title rule's make,
-- a band of its own for what cross and circle do.
local W, ROW, FOOT, PAD = 160, 24, 24, 6
local RIM, RULE = 6, 3 -- the window's rim (Window.lua), the rule's width
local JOIN = 18 -- a joint's reach past the window's rim, out and up: RIM + JOIN at the edges' texel density (make_frame_art.py's)
local DRAWER = [[Interface\AddOns\WowCompanion_Agent\Art\Drawer-%s-25]] -- make_frame_art.py's DRAWER_VERSION
local menu = CreateFrame("Frame", "WCConvMenu", UIParent)
menu:Hide()
local function piece(name, layer, sub)
	local t = menu:CreateTexture(nil, layer or "BORDER", nil, sub)
	t:SetTexture(DRAWER:format(name), "CLAMP", "CLAMP")
	return t
end
-- each joint is one picture laid as four quads cut along the rims' lines
-- (the window's rim, the drawer's rim, the elbow beyond), each sharing its
-- edges with the pieces it meets, so the game rounds them to the same pixels
-- and the rims run on without a step
local F = RIM / (RIM + JOIN) -- the rim's share of a joint picture
local function joint(name, v, s, rimRows, farRows)
	local corner, foot, side, bend = piece(name), piece(name), piece(name), piece(name)
	corner:SetTexCoord(0, F, rimRows[1], rimRows[2])
	foot:SetTexCoord(F, 1, rimRows[1], rimRows[2])
	side:SetTexCoord(0, F, farRows[1], farRows[2])
	bend:SetTexCoord(F, 1, farRows[1], farRows[2])
	local other = v == "TOP" and "BOTTOM" or "TOP"
	corner:SetPoint(v .. "LEFT", menu, v .. "LEFT")
	corner:SetPoint(other .. "RIGHT", menu, v .. "LEFT", RIM, -s * RIM)
	foot:SetPoint(v .. "LEFT", corner, v .. "RIGHT")
	foot:SetPoint(other .. "RIGHT", menu, v .. "LEFT", RIM + JOIN, -s * RIM)
	side:SetPoint(other .. "LEFT", corner, v .. "LEFT")
	side:SetPoint(v .. "RIGHT", menu, v .. "LEFT", RIM, s * JOIN)
	bend:SetPoint(other .. "LEFT", corner, v .. "RIGHT")
	bend:SetPoint(v .. "RIGHT", menu, v .. "LEFT", RIM + JOIN, s * JOIN)
	return foot
end
local topFoot = joint("TopJoin", "TOP", 1, { 1 - F, 1 }, { 0, 1 - F })
local bottomFoot = joint("BottomJoin", "BOTTOM", -1, { 0, F }, { F, 1 })
local tr, br = piece("TopRightCorner"), piece("BottomRightCorner")
tr:SetSize(RIM, RIM)
tr:SetPoint("TOPRIGHT")
br:SetSize(RIM, RIM)
br:SetPoint("BOTTOMRIGHT")
local top, bottom = piece("TopEdge"), piece("BottomEdge")
top:SetPoint("TOPLEFT", topFoot, "TOPRIGHT")
top:SetPoint("BOTTOMRIGHT", tr, "BOTTOMLEFT")
bottom:SetPoint("BOTTOMLEFT", bottomFoot, "BOTTOMRIGHT")
bottom:SetPoint("TOPRIGHT", br, "TOPLEFT")
-- the right rim, the rule's end tucked under it, the right rim again
local ruleRight = piece("RightRule")
ruleRight:SetSize(RIM, RULE)
ruleRight:SetPoint("BOTTOMRIGHT", 0, RIM + FOOT - RULE)
local right, rightLow = piece("RightEdge"), piece("RightEdge")
right:SetPoint("TOPLEFT", tr, "BOTTOMLEFT")
right:SetPoint("BOTTOMRIGHT", ruleRight, "TOPRIGHT")
rightLow:SetPoint("TOPLEFT", ruleRight, "BOTTOMLEFT")
rightLow:SetPoint("BOTTOMRIGHT", br, "TOPRIGHT")
local rule, band = piece("Rule"), piece("Band", "BACKGROUND", 1)
rule:SetPoint("BOTTOMLEFT", RIM, RIM + FOOT - RULE)
rule:SetPoint("TOPRIGHT", ruleRight, "TOPLEFT")
band:SetPoint("TOPLEFT", rule, "BOTTOMLEFT")
band:SetPoint("BOTTOMRIGHT", -RIM, RIM)
local body = menu:CreateTexture(nil, "BACKGROUND")
WC.Style.Stone(body, "you", 0.72)
body:SetPoint("TOPLEFT", RIM, -1) -- under the top rim: the elbow's inner edge rises
body:SetPoint("BOTTOMRIGHT", rule, "TOPRIGHT")
local lit = menu:CreateTexture(nil, "BACKGROUND", nil, 2)
WC.Style.Stone(lit, "claude")
local legend = menu:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
legend:SetPoint("RIGHT", menu, "BOTTOMRIGHT", -RIM - PAD - 2, RIM + (FOOT - RULE) / 2)
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
	-- over the window: its joints lie over the window's rim
	menu:SetFrameStrata(window:GetFrameStrata())
	menu:SetFrameLevel(window:GetFrameLevel() + 30)
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
		{ "Compact", function()
			WowCompanion_Strip.Command("compact " .. WC.Conversations.Wire(slot))
			WC.Board.toast(("|cffffd100%s|r  compacts: its answer says the new size"):format(name), 0.8, 0.8, 0.8, 8)
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
	Close = close,
	Show = function(list, row) follow() show(list, row) end,
}
