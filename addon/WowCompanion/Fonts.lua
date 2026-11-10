-- Interface fonts, switched live (the player, 2026-11-10: readable on a TV
-- without a bigger UI). Blizzard's own text-size code walks GetFonts() and
-- changes each font object (TextSizeManager.lua); this does the same with
-- SetFont, keeping each object's size and outline, so no restart and no
-- reload. Only the text fonts change (Friz Quadrata, Arial Narrow): quest
-- titles (Morpheus) and damage numbers (Skurri) keep their look.
-- The files are in Fonts/ (SIL OFL, see Fonts/README.md). A font file that
-- arrived after the game started may not load until a full restart: SetFont
-- says so by returning false, and the window says it.

local DIR = "Interface\AddOns\WowCompanion\Fonts\\"
local FONTS = {
	{ name = "Default" },
	{ name = "Roboto Condensed", file = "RobotoCondensed.ttf" },
	{ name = "PT Sans Narrow", file = "PTSansNarrow.ttf" },
	{ name = "Fira Sans Condensed", file = "FiraSansCondensed.ttf" },
	{ name = "Barlow Semi Condensed", file = "BarlowSemiCondensed.ttf" },
	{ name = "IBM Plex Sans Condensed", file = "IBMPlexSansCondensed.ttf" },
	{ name = "Saira Semi Condensed", file = "SairaSemiCondensed.ttf" },
	{ name = "Atkinson Hyperlegible", file = "AtkinsonHyperlegible.ttf" },
}

-- each font object's own file before we touched it, so Default restores it
local original = {}

local function replaceable(path)
	path = type(path) == "string" and path:upper() or ""
	return path:find("FRIZQT") or path:find("ARIALN")
end

local function eachTextFont(fn)
	if not GetFonts then return end
	for _, name in ipairs(GetFonts()) do
		local object = _G[name]
		if type(object) == "table" and object.GetFont and object.SetFont then
			local path, size, flags = object:GetFont()
			if original[name] == nil then original[name] = path or false end
			if original[name] and replaceable(original[name]) and size and size > 0 then
				fn(object, original[name], size, flags)
			end
		end
	end
end

-- Returns how many fonts changed, and why not when none could.
local function apply(entry)
	local changed, refused = 0, 0
	eachTextFont(function(object, from, size, flags)
		local path = entry.file and (DIR .. entry.file) or from
		if object:SetFont(path, size, flags or "") == false then
			refused = refused + 1
			object:SetFont(from, size, flags or "")
		else
			changed = changed + 1
		end
	end)
	return changed, refused
end

local function find(name)
	for i, entry in ipairs(FONTS) do
		if entry.name == name then return i, entry end
	end
	return 1, FONTS[1]
end

local Fonts = {}
WC.Fonts = Fonts
Fonts.list = FONTS

function Fonts.Current()
	return (WowCompanionDB and WowCompanionDB.font) or "Default"
end

-- Set by name; returns a line for the player.
function Fonts.Set(name)
	local _, entry = find(name)
	local changed, refused = apply(entry)
	if entry.file and refused > 0 and changed == 0 then
		apply(FONTS[1])
		WowCompanionDB.font = "Default"
		return ("%s did not load: the game only sees font files that were there when it started, so it needs one full restart."):format(entry.name)
	end
	WowCompanionDB.font = entry.name
	return ("Font: %s (%d text styles)"):format(entry.name, changed)
end

-- The next one in the list, for a single button the pad can press.
function Fonts.Next()
	local i = find(Fonts.Current())
	return Fonts.Set(FONTS[i % #FONTS + 1].name)
end

WowCompanion_SetFont = Fonts.Set

local login = CreateFrame("Frame")
login:RegisterEvent("PLAYER_LOGIN")
login:SetScript("OnEvent", function()
	-- note every original first, even when the choice is Default
	eachTextFont(function() end)
	if Fonts.Current() ~= "Default" then pcall(Fonts.Set, Fonts.Current()) end
end)
