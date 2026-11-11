-- Interface fonts, switched live (readable on a TV without a bigger UI).
-- Blizzard's own text-size code walks GetFonts() and
-- changes each font object (TextSizeManager.lua); this does the same with
-- SetFont, keeping each object's size and outline, so no restart and no
-- reload. Only the text fonts change (Friz Quadrata, Arial Narrow): quest
-- titles (Morpheus) and damage numbers (Skurri) keep their look.
-- The files are in Fonts/ (SIL OFL, see Fonts/README.md). SetFont answers
-- false while a file loads, the first time it is asked for in the process,
-- and true once it has (measured 2026-11-11): so a switch is retried until
-- every style took. A file the game cannot find raises instead (one that
-- arrived after the game started: a full restart finds it).

WC.Saved("WowCompanion_Fonts", "WowCompanionFontsDB")
local DIR = [[Interface\AddOns\WowCompanion_Fonts\Fonts\]]
local LOADING_LIMIT = 8
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
		-- forbidden object) must not stop the rest
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
	return (WowCompanionFontsDB and WowCompanionFontsDB.fontScale) or 1
end

-- Returns how many styles took, how many wait for the file to load, and how
-- many the game refused (Fonts.lastError says why).
local function apply(entry)
	local changed, loading, refused = 0, 0, 0
	local k = scale()
	eachTextFont(function(object, from, base, flags)
		local size = math.floor(base * k + 0.5)
		local path = entry.file and (DIR .. entry.file) or from
		local ok, took = pcall(object.SetFont, object, path, size, flags or "")
		if not ok then
			refused = refused + 1
			Fonts.lastError = tostring(took)
		elseif took == false then
			loading = loading + 1
		else
			changed = changed + 1
		end
	end)
	return changed, loading, refused
end

local function find(name)
	for i, entry in ipairs(FONTS) do
		if entry.name == name then return i, entry end
	end
	return 1, FONTS[1]
end

Fonts.list = FONTS

function Fonts.Current()
	return (WowCompanionFontsDB and WowCompanionFontsDB.font) or "Default"
end

-- Set by name; returns a line for the player. Never raises: an error is
-- returned as the line, and kept in the save file for the agent.
local set
function Fonts.Set(name)
	local ok, said = pcall(set, name)
	if ok then return said end
	WowCompanionFontsDB.fontError = tostring(said)
	return "Font switch failed: " .. tostring(said)
end

local function refuse(entry)
	apply(FONTS[1])
	WowCompanionFontsDB.font = "Default"
	WowCompanionFontsDB.fontError = Fonts.lastError or "it never finished loading"
	return ("%s was refused by the game (%s). Pick another font."):format(entry.name, WowCompanionFontsDB.fontError)
end

-- the switch in progress: a newer one ends an older one's retries
local switching = 0
set = function(name)
	local _, entry = find(name)
	switching = switching + 1
	local this, started = switching, GetTime()
	local changed, loading, refused = apply(entry)
	if refused > 0 and changed == 0 and loading == 0 then return refuse(entry) end
	WowCompanionFontsDB.font = entry.name
	if loading == 0 then
		WC.Send("FONT_CHANGED")
		return ("Font: %s (%d text styles)"):format(entry.name, changed)
	end
	local function retry()
		if this ~= switching then return end
		local _, still = apply(entry)
		if still == 0 then
			WC.Send("FONT_CHANGED")
		elseif GetTime() - started > LOADING_LIMIT then
			print(refuse(entry))
		else
			C_Timer.After(0.25, retry)
		end
	end
	C_Timer.After(0.25, retry)
	return ("Font: %s (loading)"):format(entry.name)
end


-- The text size, a step over the original sizes (readable on a TV).
-- Applies with whichever font is chosen.
Fonts.scales = SCALES
function Fonts.Scale() return scale() end
function Fonts.SetScale(k)
	WowCompanionFontsDB.fontScale = k
	local _, entry = find(Fonts.Current())
	apply(entry)
	WC.Send("FONT_CHANGED")
	return ("Text size: %d%%"):format(math.floor(k * 100 + 0.5))
end

WowCompanion_SetFont = Fonts.Set

local login = CreateFrame("Frame")
login:RegisterEvent("PLAYER_LOGIN")
login:SetScript("OnEvent", function()
	-- note every original first, even when the choice is Default
	eachTextFont(function() end)
	if Fonts.Current() ~= "Default" or scale() ~= 1 then pcall(Fonts.Set, Fonts.Current()) end
end)
