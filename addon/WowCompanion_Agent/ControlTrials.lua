-- Control trials, temporary: slot floors and button faces for the settings
-- page, at real size on the window's slate, while the player chooses (art:
-- tools/make_demo_art.py). Shown only: nothing here is a stop. Goes with its
-- art when one is chosen.
local BRONZE = { 0.78, 0.66, 0.45 }
local CREAM = { 0.94, 0.89, 0.77 }
local INK = { 0.16, 0.11, 0.07 }
local FLOORS = {
	{ "Slate", "A. Slate in shadow" },
	{ "Ink", "B. Near-black, cool" },
	{ "Lamplit", "C. Warm light at its foot" },
}
local BUTTONS = {
	{ "Bronze", "1. Dark bronze", CREAM },
	{ "Wood", "2. Polished heartwood", BRONZE },
	{ "Lacquer", "3. Black lacquer", BRONZE },
	{ "Brass", "4. Old brass", INK },
}
local ART = [[Interface\AddOns\WowCompanion\Art\Demo-R2-]] -- make_demo_art.py's ROUND

WC.Companion.AddTab("Trials", function(page)
	local built
	page:HookScript("OnShow", function()
		if built then return end
		built = true
		-- above the page well's own top shadow (Window.lua's pageLip, its level + 20)
		local box = CreateFrame("Frame", nil, page)
		box:SetFrameLevel(page:GetParent():GetFrameLevel() + 25)
		box:SetAllPoints()
		local function label(text, x, y)
			local fs = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			fs:SetPoint("TOPLEFT", x, y)
			fs:SetText(text)
			return fs
		end
		local function piece(name, w, h, x, y, word, colour, dy)
			local t = box:CreateTexture(nil, "ARTWORK")
			t:SetTexture(ART .. name)
			t:SetSize(w, h)
			t:SetPoint("TOPLEFT", x, y)
			local fs = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			fs:SetPoint("CENTER", t, "CENTER", 0, dy or 1)
			fs:SetTextColor(unpack(colour))
			fs:SetText(word)
		end
		label("Slot floors (dropdowns, key slots)", 12, -10)
		for i, f in ipairs(FLOORS) do
			local y = -36 - (i - 1) * 56
			label(f[2], 12, y)
			piece("Floor-" .. f[1], 240, 32, 12, y - 18, "Default", BRONZE)
		end
		label("Buttons (and pressed)", 320, -10)
		for i, b in ipairs(BUTTONS) do
			local y = -36 - (i - 1) * 56
			label(b[2], 320, y)
			piece("Button-" .. b[1], 128, 28, 320, y - 18, "Clear", b[3])
			piece("Button-" .. b[1] .. "-Pushed", 128, 28, 456, y - 18, "Clear", b[3], 0)
		end
	end)
end)
