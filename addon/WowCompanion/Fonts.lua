-- Interface fonts, switched live (the player, 2026-11-10: readable on a TV
-- without a bigger UI). Blizzard's own text-size code walks GetFonts() and
-- changes each font object (TextSizeManager.lua); this does the same with
-- SetFont, keeping each object's size and outline, so no restart and no
-- reload. Only the text fonts change (Friz Quadrata, Arial Narrow): quest
-- titles (Morpheus) and damage numbers (Skurri) keep their look.
-- The files are in Fonts/ (SIL OFL, see Fonts/README.md). A font file that
-- arrived after the game started may not load until a full restart: SetFont
-- says so by returning false, and the window says it.

local DIR = [[Interface\AddOns\WowCompanion\Fonts\]]
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

local Fonts = {}
WC.Fonts = Fonts

-- each font object's own file and size before we touched them, so Default
-- restores it and the size step scales from the original, never compounding
local original = {}
local originalSize = {}

local function replaceable(path)
	path = type(path) == "string" and path:upper() or ""
	return path:find("FRIZQT") or path:find("ARIALN")
end

local function eachTextFont(fn)
	if not GetFonts then return end
	for _, name in ipairs(GetFonts()) do
		local object = _G[name]
		-- each object read under pcall: one odd entry (a font family, a
		-- forbidden object) must not stop the rest (the player saw a Lua error
		-- on switching, 2026-11-10)
		local ok, path, size, flags = pcall(function() return object:GetFont() end)
		if ok and type(object) == "table" then
			if original[name] == nil then
				original[name] = path or false
				originalSize[name] = size
			end
			local base = originalSize[name]
			if original[name] and replaceable(original[name]) and base and base > 0 then
				fn(object, original[name], base, flags)
			end
		end
	end
end

-- Returns how many fonts changed, and why not when none could.
local SCALES = { 0.9, 1, 1.1, 1.2, 1.3, 1.4 }
local function scale()
	return (WowCompanionDB and WowCompanionDB.fontScale) or 1
end

local function apply(entry)
	local changed, refused = 0, 0
	local k = scale()
	eachTextFont(function(object, from, base, flags)
		local size = math.floor(base * k + 0.5)
		local path = entry.file and (DIR .. entry.file) or from
		local ok, took = pcall(object.SetFont, object, path, size, flags or "")
		if not ok or took == false then
			refused = refused + 1
			if not ok then Fonts.lastError = tostring(took) end
			pcall(object.SetFont, object, from, base, flags or "")
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

Fonts.list = FONTS

function Fonts.Current()
	return (WowCompanionDB and WowCompanionDB.font) or "Default"
end

-- Set by name; returns a line for the player. Never raises: an error is
-- returned as the line, and kept in the save file for the agent.
local set
function Fonts.Set(name)
	local ok, said = pcall(set, name)
	if ok then return said end
	WowCompanionDB.fontError = tostring(said)
	return "Font switch failed: " .. tostring(said)
end
set = function(name)
	local _, entry = find(name)
	local changed, refused = apply(entry)
	if entry.file and refused > 0 and changed == 0 then
		apply(FONTS[1])
		WowCompanionDB.font = "Default"
		-- remember where the cycle stood, so the next press tries the next
		-- font instead of this one again (a refused font used to trap the
		-- button: Default, then the same refused font, forever)
		Fonts.tried = entry.name
		WowCompanionDB.fontError = Fonts.lastError or "SetFont returned false"
		return ("%s was refused by the game (%s). Press again for the next font."):format(entry.name, WowCompanionDB.fontError)
	end
	WowCompanionDB.font = entry.name
	return ("Font: %s (%d text styles)"):format(entry.name, changed)
end

-- The next one in the list, for a single button the pad can press.
function Fonts.Next()
	local i = find(Fonts.tried or Fonts.Current())
	Fonts.tried = nil
	return Fonts.Set(FONTS[i % #FONTS + 1].name)
end

-- The text size, a step over the original sizes (the player, 2026-11-10:
-- readable on a TV). Applies with whichever font is chosen.
Fonts.scales = SCALES
function Fonts.Scale() return scale() end
function Fonts.SetScale(k)
	WowCompanionDB.fontScale = k
	local _, entry = find(Fonts.Current())
	apply(entry)
	return ("Text size: %d%%"):format(math.floor(k * 100 + 0.5))
end
function Fonts.NextScale()
	local now, i = scale(), 1
	for j, k in ipairs(SCALES) do if math.abs(k - now) < 0.01 then i = j end end
	return Fonts.SetScale(SCALES[i % #SCALES + 1])
end

WowCompanion_SetFont = Fonts.Set

local login = CreateFrame("Frame")
login:RegisterEvent("PLAYER_LOGIN")
login:SetScript("OnEvent", function()
	-- note every original first, even when the choice is Default
	eachTextFont(function() end)
	if Fonts.Current() ~= "Default" or scale() ~= 1 then pcall(Fonts.Set, Fonts.Current()) end
end)
