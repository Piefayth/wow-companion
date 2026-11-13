-- Control trials, temporary: buttons for the settings page, each a variation on
-- the list's raised slab, at rest and lit (the row under the cursor), beside
-- today's, while the player chooses (art: tools/make_button_art.py). Shown
-- only: nothing here is a stop. Goes when one is chosen.
local S = WC.Style
local ART = [[Interface\AddOns\WowCompanion\Art\Btn-%s-%s-7]] -- make_button_art.py's ROUND
-- make_button_art.py's KINDS, in its order, with what each is
local KINDS = {
	{ "Slab", "1. Slab, as the list's" },
	{ "Rimmed", "2. Slab, rim always" },
	{ "Chamfer", "3. Corners cut" },
	{ "Scrolls", "4. Scrolls at its ends" },
	{ "Block", "5. Thick stone block" },
	{ "Corners", "6. Bronze corners" },
	{ "Pillow", "7. Swelling face" },
	{ "Inlaid", "8. Wire inlaid" },
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
		local function button(kind, lit, x, y)
			local t = box:CreateTexture(nil, "ARTWORK")
			t:SetTexture(ART:format(kind, lit and "Lit" or "Rest"))
			t:SetSize(160, 36)
			t:SetPoint("TOPLEFT", x, y)
			local fs = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			fs:SetPoint("CENTER", t, "CENTER", 0, 1)
			fs:SetTextColor(unpack(lit and S.NAME_LIT or S.BRONZE))
			fs:SetText("Clear")
		end
		local head = box:CreateFontString(nil, "OVERLAY", "GameFontDisable")
		head:SetPoint("TOPLEFT", 220, -8)
		head:SetText("At rest, then lit (under the cursor)")
		label("Now", -28)
		local now = S.Button(box)
		now:SetLabel("Clear")
		now:SetPoint("TOPLEFT", 236, -32)
		for i, k in ipairs(KINDS) do
			local y = -28 - i * 44
			label(k[2], y)
			button(k[1], false, 220, y)
			button(k[1], true, 400, y)
		end
	end)
end)
