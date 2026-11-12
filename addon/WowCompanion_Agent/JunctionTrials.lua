-- Junction trials, temporary: the vine dividers' meetings side by side at real
-- size on the window's slate, while the player chooses (art:
-- tools/make_crest.py, tools/make_junction_trials.py). Goes with its art when
-- one is chosen.
local TRIALS = {
	{ "Crest", "the fleur arrow's language: pincers clasp the trunk; two trunks add long sweeps and the arm through", 96 },
	{ "Current", "the S-scroll on the settings page now", 64 },
	{ "Graft", "the branch flares into the trunk, a long tendril off it", 64 },
	{ "Tendril", "one long slow loop out along both vines", 64 },
}
local ART = [[Interface\AddOns\WowCompanion_Agent\Art\Try-%s-%s-1]]
local CELL, GAP = 150, 16
local AT = -25 -- the trunk, left of the cell's centre so a crest stays inside it

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
				t:SetSize(trial[3], trial[3])
				t:SetPoint("CENTER", cell, "CENTER", AT, 0)
				local tag = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
				tag:SetPoint("TOPLEFT", cell, "BOTTOMLEFT", 0, -2)
				tag:SetText(size == "Big" and "thick into thick" or "medium into thick")
			end
		end
	end)
end)
