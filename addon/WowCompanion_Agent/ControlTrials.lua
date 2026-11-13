-- Control trials, temporary: the settings page's button (round 8's pick,
-- Facets) lit six ways under the cursor, beside it at rest and pressed, while
-- the player chooses (art: tools/make_button_art.py). Shown only: nothing here
-- is a stop. Goes when one is chosen.
local S = WC.Style
local ART = [[Interface\AddOns\WowCompanion\Art\Btn-Facets-%s-9]] -- make_button_art.py's ROUND
-- make_button_art.py's STATES, with what each is
local STATES = {
	{ "Rest", "At rest" },
	{ "Pushed", "Pressed" },
	{ "LitHalo", "1. Glow round it" },
	{ "LitRim", "2. Bright rim" },
	{ "LitHaloRim", "3. Glow and bright rim" },
	{ "LitInner", "4. Glow inside the rim" },
	{ "LitLamp", "5. Lamplight from below" },
	{ "LitGilt", "6. Gilded bevel" },
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
		local head = box:CreateFontString(nil, "OVERLAY", "GameFontDisable")
		head:SetPoint("TOPLEFT", 14, -8)
		head:SetText("Button 5, and six ways to light it under the cursor")
		for i, st in ipairs(STATES) do
			local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
			local x, y = 14 + col * 360, -34 - row * 50
			local label = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			label:SetPoint("TOPLEFT", x, y - 10)
			label:SetText(st[2])
			local t = box:CreateTexture(nil, "ARTWORK")
			t:SetTexture(ART:format(st[1]))
			t:SetSize(160, 36)
			t:SetPoint("TOPLEFT", x + 170, y)
			local lit = st[1]:find("^Lit") ~= nil
			local fs = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			fs:SetPoint("CENTER", t, "CENTER", 0, st[1] == "Pushed" and -1 or 1)
			fs:SetTextColor(unpack(lit and S.NAME_LIT or S.BRONZE))
			fs:SetText("Clear")
		end
	end)
end)
