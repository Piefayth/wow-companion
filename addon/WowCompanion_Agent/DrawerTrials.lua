-- Drawer trials, temporary: six ways the conversation menu's drawer
-- (ConvMenu.lua) could hook into the window's rim, each with its own panel
-- for the legend, side by side at true size. Each cell is one picture
-- (tools/make_drawer_trials.py: a slice of the window's right side and the
-- drawer coming out of it), its words drawn here. Shown only: nothing here is
-- a stop. Goes when one is chosen.
local S = WC.Style
local ART = [[Interface\AddOns\WowCompanion_Agent\Art\DrawerTrial-%d-1]] -- the generator's VERSION
-- the generator's cell, in units; its picture 2.7 texels a unit in a 512 texture
local CW, CH, TEXELS = 186, 188, 2.7 / 512
local X0, RIM, XR, DT, DB = 16, 6, 170, 46, 150
local ROWS, ROW = DT + 12, 24
local LEG = { DT + 64, DB - RIM }
local TITLES = {
	"One rim: the window's steps out round it; the rows in a well",
	"The rims sweep out of the window's; a carved strip",
	"Scroll brackets; a rule over the title band's leather",
	"The rim swells into a sleeve; a sunk bronze plate",
	"A rounded tongue; the page's vine, deeper stone",
	"Knee braces, plain; a sill of grey stone",
}

local function cell(box, i, x, y)
	local f = CreateFrame("Frame", nil, box)
	f:SetSize(CW, CH)
	f:SetPoint("TOPLEFT", x, y)
	local t = f:CreateTexture(nil, "ARTWORK")
	t:SetTexture(ART:format(i), "CLAMP", "CLAMP")
	t:SetAllPoints()
	t:SetTexCoord(0, CW * TEXELS, 0, CH * TEXELS)
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
	local legend = top:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	legend:SetPoint("RIGHT", top, "TOPLEFT", XR - RIM - 8, -(LEG[1] + LEG[2]) / 2)
	legend:SetText(WowCompanion_Glyph("PAD1") .. " Select    " .. WowCompanion_Glyph("PAD2") .. " Back")
	if i == 5 then
		local v = CreateFrame("Frame", nil, f)
		v:SetHeight(16)
		v:SetPoint("LEFT", f, "TOPLEFT", X0 + 4, -LEG[1])
		v:SetPoint("RIGHT", f, "TOPLEFT", XR - RIM - 4, -LEG[1])
		S.VineLine(v, "", false, true, true)
	end
	local label = top:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	label:SetPoint("TOPLEFT", 56, -4)
	label:SetWidth(CW - 58)
	label:SetJustifyH("LEFT")
	label:SetTextColor(unpack(S.LABEL))
	label:SetText(i .. ". " .. TITLES[i])
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
		for i = 1, #TITLES do
			cell(box, i, 18 + ((i - 1) % 3) * 240, i > 3 and -222 or -4)
		end
	end)
end)
