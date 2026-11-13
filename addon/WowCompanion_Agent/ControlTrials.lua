-- Control trials, temporary: buttons for the settings page, the cut-cornered
-- slab made more of a button, each at rest, lit (the row under the cursor) and
-- pressed, beside today's, while the player chooses (art:
-- tools/make_button_art.py). Shown only: nothing here is a stop. Goes when one
-- is chosen.
local S = WC.Style
local ART = [[Interface\AddOns\WowCompanion\Art\Btn-%s-%s-8]] -- make_button_art.py's ROUND
-- make_button_art.py's KINDS, in its order, with what each is
local KINDS = {
	{ "CutBlock", "1. Cut, thick block" },
	{ "CutBlockRim", "2. Cut, block, rim" },
	{ "CutPillow", "3. Cut, swelling, rim" },
	{ "CutBlockPillow", "4. Cut, block + swell" },
	{ "Facets", "5. Cut, faceted bevel" },
	{ "Plinth", "6. Cut, on a bronze step" },
	{ "CutCorners", "7. Bronze on the cuts" },
	{ "CornerScrolls", "8. Scrolls on the cuts" },
}

WC.Companion.AddTab("Trials", function(page)
	local built
	page:HookScript("OnShow", function()
		if built then return end
		built = true
		-- above the page well's own top shadow (Window.lua's pageLip, its level + 20)
		local box = CreateFrame("Frame", nil, page)
		box:SetFrameLevel(page:GetParent():GetFrameLevel() + 25)
		box:SetAllPoints()
		local function label(text, y)
			local fs = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			fs:SetPoint("TOPLEFT", 14, y - 10)
			fs:SetText(text)
		end
		local function button(kind, state, x, y)
			local lit = state == "Lit"
			local t = box:CreateTexture(nil, "ARTWORK")
			t:SetTexture(ART:format(kind, state))
			t:SetSize(160, 36)
			t:SetPoint("TOPLEFT", x, y)
			local fs = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			fs:SetPoint("CENTER", t, "CENTER", 0, state == "Pushed" and -1 or 1)
			fs:SetTextColor(unpack(lit and S.NAME_LIT or S.BRONZE))
			fs:SetText("Clear")
		end
		local head = box:CreateFontString(nil, "OVERLAY", "GameFontDisable")
		head:SetPoint("TOPLEFT", 220, -8)
		head:SetText("At rest, lit (under the cursor), pressed")
		label("Now", -28)
		local now = S.Button(box)
		now:SetLabel("Clear")
		now:SetPoint("TOPLEFT", 236, -32)
		for i, k in ipairs(KINDS) do
			local y = -28 - i * 44
			label(k[2], y)
			for i, state in ipairs({ "Rest", "Lit", "Pushed" }) do
				button(k[1], state, 220 + (i - 1) * 172, y)
			end
		end
	end)
end)
