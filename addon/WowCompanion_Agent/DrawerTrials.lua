-- Drawer trials, temporary: ways the conversation menu's drawer
-- (ConvMenu.lua) could hook into the window's rim, side by side at true
-- size. Round 6: each cell is drawn as the drawer would be, a base picture
-- (a slice of the window's right side and the drawer butted against its rim,
-- the legend's panel) with a joint piece over each place the drawer's rims
-- meet the window's: the crossing is the settings joint's, a four-filleted
-- star of one metal, its ornament springing from the star
-- (tools/make_drawer_trials.py). Its words drawn here. Shown only: nothing
-- here is a stop. Goes when one is chosen.
local S = WC.Style
local ART = [[Interface\AddOns\WowCompanion_Agent\Art\DrawerTrial-%s-6]] -- the generator's VERSION
-- the generator's cell and joint boxes, in units, at 2.7 texels a unit
local TEXEL = 2.7
local CW, CH, BASE_TEX = 172, 180, 512
local JW, JH, JOINT_TEX = 60, 70, 256
local X0, RIM, XR, DT = 16, 6, 170, 46
local ROWS, ROW = DT + 12, 24
local LEGEND_Y = DT + 75.5 -- the middle of the legend's panel
local OPTIONS = {
	{ "Band", "The star alone: the crossing forged, no ornament" },
	{ "Band", "Sprig: one stem from the star into a big volute" },
	{ "Band", "Cascade from the star, two satellites" },
	{ "Band", "Fork: up the rim and along the drawer" },
	{ "Band", "Lyre: a volute and a long S over the drawer" },
	{ "Band", "Pair: a stem into a volute, a second budding off" },
}

local function picture(f, file, x, y, w, h, tex, layer)
	local t = f:CreateTexture(nil, "ARTWORK", nil, layer)
	t:SetTexture(ART:format(file), "CLAMP", "CLAMP")
	t:SetPoint("TOPLEFT", x, -y)
	t:SetSize(w, h)
	t:SetTexCoord(0, w * TEXEL / tex, 0, h * TEXEL / tex)
end

local function cell(box, i, x, y)
	local legend, title = OPTIONS[i][1], OPTIONS[i][2]
	local f = CreateFrame("Frame", nil, box)
	f:SetSize(CW, CH)
	f:SetPoint("TOPLEFT", x, y)
	picture(f, legend, 0, 0, CW, CH, BASE_TEX, 0)
	picture(f, ("Joint-%d-Top"):format(i), 0, 0, JW, JH, JOINT_TEX, 1)
	picture(f, ("Joint-%d-Bottom"):format(i), 0, CH - JH, JW, JH, JOINT_TEX, 1)
	local top = CreateFrame("Frame", nil, f)
	top:SetAllPoints()
	top:SetFrameLevel(f:GetFrameLevel() + 4)
	for n, name in ipairs({ "Clear chat", "Start over" }) do
		local fs = top:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		fs:SetHeight(ROW)
		fs:SetPoint("TOPLEFT", X0 + 16, -(ROWS + (n - 1) * ROW))
		fs:SetTextColor(unpack(n == 1 and S.NAME_LIT or S.NAME))
		fs:SetText(name)
	end
	local keys = top:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	keys:SetPoint("RIGHT", top, "TOPLEFT", XR - RIM - 8, -LEGEND_Y)
	keys:SetText(WowCompanion_Glyph("PAD1") .. " Select    " .. WowCompanion_Glyph("PAD2") .. " Back")
	local label = top:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	label:SetPoint("TOPLEFT", JW, -4)
	label:SetWidth(CW - JW)
	label:SetJustifyH("LEFT")
	label:SetTextColor(unpack(S.LABEL))
	label:SetText(i .. ". " .. title)
end

WC.Companion.AddTab("Drawers", function(page)
	local built
	page:HookScript("OnShow", function()
		if built then return end
		built = true
		-- above the page well's own top shadow (Window.lua's pageLip, its level + 20)
		local box = CreateFrame("Frame", nil, page)
		box:SetFrameLevel(page:GetParent():GetFrameLevel() + 25)
		box:SetAllPoints()
		for i = 1, #OPTIONS do
			cell(box, i, 4 + ((i - 1) % 4) * 178, i > 4 and -224 or -4)
		end
	end)
end)
