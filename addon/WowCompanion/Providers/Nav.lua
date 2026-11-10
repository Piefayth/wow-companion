-- The nav capability (see Engine.lua, Capabilities): aim(map, x, y, label),
-- nearest(kind), clear(). x and y are the 0-100 map coordinates players quote.

-- Built in: a pin on the minimap (Pins.lua). No arrow, no service lookup.
WC.Provide("nav", "builtin", {
	aim = function(map, x, y, label)
		if not (WCPins and WCPins.Add and map and x and y) then return nil end
		WCPins.Add({ map = map, x = x, y = y, label = label })
		return true
	end,
	clear = function()
		if WCPins and WCPins.Clear then WCPins.Clear() return true end
	end,
}, { rank = 0 })

-- Polestar: its arrow and its NPC database (Polestar/Nav/Nav.lua, Nearby.lua).
-- GPL: called, never copied. Counts only while Polestar is loaded.
local function nav()
	local N = Polestar and Polestar.Nav
	return type(N) == "table" and N or nil
end
WC.Provide("nav", "Polestar", {
	aim = function(map, x, y, label)
		local N = nav()
		if not (N and N.SetTarget) then return nil end
		local ok, set = pcall(N.SetTarget, map, x, y, label)
		if ok and set then return true end
	end,
	-- kinds: innkeeper, repair, vendor, food, reagents, trainer, class, weapon,
	-- bank, mailbox, auction, flight, stable. Finds; does not aim.
	nearest = function(kind)
		local N = nav()
		local near = N and N.nearby
		if not (near and near.Find) then return nil end
		local ok, place, seconds = pcall(near.Find, kind)
		if ok and type(place) == "table" then
			return { name = place.name, map = place.map, x = place.x, y = place.y }, seconds
		end
	end,
	clear = function()
		local N = nav()
		if not (N and N.ClearTarget) then return nil end
		local ok = pcall(N.ClearTarget)
		if ok then return true end
	end,
}, { addon = "Polestar", rank = 10 })
