-- Junction trials, temporary: three directions for where the vine dividers
-- meet, side by side at real size on the window's slate, while the player
-- chooses (art: tools/make_junction_trials.py; the first is the settings
-- page's). Goes with its art when one is chosen.
local TRIALS = {
	{ "Fleur", "on the settings page: the arm runs through and opens into a fleur-de-lis; a branch's root splits into two S volutes" },
	{ "Whiplash", "the arm forks and its branches run into the trunk; two trunks add a long lyre on the left" },
	{ "Interlace", "the arm parts into two wires that pass behind the trunk and cross on its far side" },
}
local SIZE = { Big = 112, Small = 80 }
local ART = [[Interface\AddOns\WowCompanion_Agent\Art\Try-%s-%s-2]]
local CELL, GAP = 150, 16
local AT = -25 -- the trunk, left of the cell's centre so a big one's left side stays inside it

WC.Companion.AddTab("Junctions", function(page)
	local built
	page:HookScript("OnShow", function()
		if built then return end
		built = true
		-- above the page well's own top shadow (Window.lua's pageLip, its level + 20)
		local above = page:GetParent():GetFrameLevel() + 25
		local box = CreateFrame("Frame", nil, page)
		box:SetFrameLevel(above)
		box:SetAllPoints()
		for i, trial in ipairs(TRIALS) do
			local x = (i - 1) * (CELL + GAP)
			local title = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			title:SetPoint("TOPLEFT", x, -4)
			title:SetText(i .. ". " .. trial[1])
			local about = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			about:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
			about:SetWidth(CELL)
			about:SetJustifyH("LEFT")
			about:SetText(trial[2])
			for row, size in ipairs({ "Big", "Small" }) do
				local cell = CreateFrame("Frame", nil, box)
				cell:SetFrameLevel(above + 1)
				cell:SetSize(CELL, CELL)
				cell:SetPoint("TOPLEFT", x, -58 - (row - 1) * (CELL + GAP + 14))
				local run = CreateFrame("Frame", nil, cell)
				run:SetPoint("TOP", cell, "TOP", AT, 0)
				run:SetPoint("BOTTOM", cell, "BOTTOM", AT, 0)
				run:SetWidth(16)
				WC.Style.VineLine(run, "Thick", true, true, true)
				local arm = CreateFrame("Frame", nil, cell)
				arm:SetPoint("LEFT", cell, "CENTER", AT, 0)
				arm:SetPoint("RIGHT")
				arm:SetHeight(16)
				WC.Style.VineLine(arm, size == "Big" and "Thick" or "", false, false, true)
				local join = CreateFrame("Frame", nil, cell)
				join:SetFrameLevel(above + 3)
				join:SetAllPoints()
				local t = join:CreateTexture(nil, "OVERLAY")
				t:SetTexture(ART:format(trial[1], size))
				t:SetSize(SIZE[size], SIZE[size])
				t:SetPoint("CENTER", cell, "CENTER", AT, 0)
				local tag = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
				tag:SetPoint("TOPLEFT", cell, "BOTTOMLEFT", 0, -2)
				tag:SetText(size == "Big" and "thick into thick" or "medium into thick")
			end
		end
	end)
end)
