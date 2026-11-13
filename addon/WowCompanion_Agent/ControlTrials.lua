-- Control trials, temporary: slot floors and button faces for the settings
-- page, at real size on the window's slate, while the player chooses (art:
-- tools/make_demo_art.py). Shown only: nothing here is a stop. Goes with its
-- art when one is chosen.
local FLOORS = {
	{ "Grey", "A. Grey (now)" },
	{ "Ink", "B. Ink navy" },
	{ "DeepInk", "C. Deep ink" },
	{ "Leather", "D. Oiled leather" },
}
local BUTTONS = {
	{ "Slate", "1. Slate (now)" },
	{ "Heartwood", "2. Heartwood" },
	{ "Bronze", "3. Bronze plate", dark = true },
	{ "Lacquer", "4. Navy lacquer" },
}
local ART = [[Interface\AddOns\WowCompanion\Art\Demo-]]
local BRONZE = { 0.78, 0.66, 0.45 }
local INK = { 0.16, 0.11, 0.07 }

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
		local function piece(name, w, h, x, y, word, colour)
			local t = box:CreateTexture(nil, "ARTWORK")
			t:SetTexture(ART .. name)
			t:SetSize(w, h)
			t:SetPoint("TOPLEFT", x, y)
			local fs = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			fs:SetPoint("CENTER", t, "CENTER", 0, 1)
			fs:SetTextColor(unpack(colour))
			fs:SetText(word)
		end
		label("Slot floors (dropdowns, key slots)", 12, -10)
		for i, f in ipairs(FLOORS) do
			local y = -36 - (i - 1) * 56
			label(f[2], 12, y)
			piece("Floor-" .. f[1], 240, 32, 12, y - 18, "Default", BRONZE)
		end
		label("Buttons", 320, -10)
		for i, b in ipairs(BUTTONS) do
			local y = -36 - (i - 1) * 56
			label(b[2], 320, y)
			piece("Button-" .. b[1], 128, 28, 320, y - 18, "Clear", b.dark and INK or BRONZE)
		end
	end)
end)
