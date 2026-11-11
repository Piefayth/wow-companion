-- The pins capability (see Engine.lua, Capabilities): points on the world map
-- and the minimap, in named layers, so features never fight over one list.
--   set(layer, points) -> true   replaces the layer; point { map, x, y, f, label, color }
--     map is a uiMapID, x and y the 0-100 coordinates players quote, f = "e" when
--     they come from Polestar's data (its Era frame), color { r, g, b } optional
--   clear(layer) -> true

-- Polestar: its pin layers, world map and minimap (Polestar/Nav/Pins.lua,
-- Pins.SetLayer/ClearLayer; GPL, called, never copied). Internal, with no public
-- promise, so the check below takes this provider out of use the moment the
-- functions are gone, and says so (Status tab, export).
local function P() return Polestar and Polestar.Pins end
local GOLD = { 1, 0.82, 0 }
WC.Provide("pins", "Polestar", {
	set = function(layer, points)
		local pins = {}
		for _, pt in ipairs(points or {}) do
			local c = pt.color or GOLD
			pins[#pins + 1] = { map = pt.map, x = pt.x, y = pt.y, f = pt.f, icon = "map:pin",
				color = { r = c[1], g = c[2], b = c[3], a = 1 }, tooltip = pt.label }
		end
		P().SetLayer("WowCompanion." .. layer, pins, { world = true, minimap = true })
		return true
	end,
	clear = function(layer)
		P().ClearLayer("WowCompanion." .. layer)
		return true
	end,
}, { addon = "Polestar", rank = 10, check = function()
	local pins = P()
	if type(pins) ~= "table" then return false, "Polestar.Pins is gone" end
	if type(pins.SetLayer) ~= "function" or type(pins.ClearLayer) ~= "function" then
		return false, "Polestar.Pins.SetLayer/ClearLayer are gone"
	end
	return true
end })
