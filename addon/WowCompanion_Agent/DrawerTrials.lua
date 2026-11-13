-- Drawer trials, temporary: ways the conversation menu's drawer
-- (ConvMenu.lua) could hook into the window's rim, side by side at true
-- size, each cell one picture (tools/make_drawer_trials.py; round 9: the drawer's
-- own rim meeting the window's, elbows and bearing scrolls) and its words drawn
-- here. Shown only: nothing here is a stop. Goes when one is chosen.
local S = WC.Style
local ART = [[Interface\AddOns\WowCompanion_Agent\Art\DrawerTrial-%s-9]] -- the generator's VERSION
-- the generator's cell and joint boxes, in units, at 2.7 texels a unit
local TEXEL = 2.7
local CW, CH, BASE_TEX = 172, 180, 512
local JW = 60 -- the label's left
local X0, RIM, XR, DT = 16, 6, 170, 46
local ROWS, ROW = DT + 12, 24
local LEGEND_Y = DT + 76 -- the middle of the legend's panel
local OPTIONS = {
	"Elbow: the rims bend into the window's",
	"Wide elbow",
	"Butt: the window's rim lies over, its shadow",
	"Bearing scroll: a volute against both rims",
	"Stacked scrolls: big on the drawer, small on the window",
	"Wide elbow, a volute hugging it",
}

local function picture(f, file, x, y, w, h, tex, layer)
	local t = f:CreateTexture(nil, "ARTWORK", nil, layer)
	t:SetTexture(ART:format(file), "CLAMP", "CLAMP")
	t:SetPoint("TOPLEFT", x, -y)
	t:SetSize(w, h)
	t:SetTexCoord(0, w * TEXEL / tex, 0, h * TEXEL / tex)
end

local function cell(box, i, x, y)
	local title = OPTIONS[i]
	local f = CreateFrame("Frame", nil, box)
	f:SetSize(CW, CH)
	f:SetPoint("TOPLEFT", x, y)
	picture(f, ("Cell-%d"):format(i), 0, 0, CW, CH, BASE_TEX, 0)
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
