-- The pins and nav capabilities from our own pins (Pins.lua), minimap and
-- world map, each pin tagged with its layer so other pins stay.
local GOLD = { 1, 0.82, 0 }
local function builtinSet(layer, points)
	local keep = {}
	for _, p in ipairs(WCPins.List()) do
		if p.layer ~= layer then keep[#keep + 1] = p end
	end
	for _, pt in ipairs(points or {}) do
		keep[#keep + 1] = { map = pt.map, x = pt.x, y = pt.y, r = pt.r or 25, label = pt.label,
			color = pt.color or GOLD, layer = layer }
	end
	WCPins.Set(keep)
	return true
end
WC.Provide("pins", "builtin", {
	set = builtinSet,
	clear = function(layer) return builtinSet(layer, {}) end,
}, { rank = 0 })

-- nav: a pin on the minimap and the world map. No arrow, no service lookup.
WC.Provide("nav", "minimap pins", {
	aim = function(map, x, y, label)
		if not (map and x and y) then return nil end
		WCPins.Add({ map = map, x = x, y = y, label = label })
		return true
	end,
	clear = function() WCPins.Clear() return true end,
}, { rank = 0 })
