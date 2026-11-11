-- The nav capability (see Engine.lua, Capabilities): aim(map, x, y, label),
-- nearest(kind), clear(). x and y are the 0-100 map coordinates players quote.

-- Built in: positions from the game alone (aiming is a pins addon's or
-- Polestar's).
WC.Provide("nav", "builtin", {
	-- world(map, x, y, f) -> continent, a, b in yards; here() -> the player's
	-- the same way. Only compare points from the same provider.
	world = function(map, x, y)
		local ok, cont, pos = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x / 100, y / 100))
		if not (ok and pos) then return nil end
		local a, b = pos:GetXY()
		return cont, a, b
	end,
	here = function()
		local a, b, _, inst = UnitPosition("player")
		if not a then return nil end
		return inst, a, b
	end,
}, { rank = 0 })

-- Polestar: its arrow and its NPC database (Polestar/Nav/Nav.lua, Nearby.lua).
-- GPL: called, never copied. Counts only while Polestar is loaded.
local function nav()
	local N = Polestar and Polestar.Nav
	return type(N) == "table" and N or nil
end
WC.Provide("nav", "Polestar", {
	-- its documented public API (Nav.API.Navigate, x and y as 0-1 fractions),
	-- with the internal SetTarget only when an older Polestar lacks it
	aim = function(map, x, y, label)
		local N = nav()
		if not N then return nil end
		if N.API and N.API.Navigate then
			local ok, set = pcall(N.API.Navigate, "WowCompanion", map, x / 100, y / 100, label)
			if ok and set then return true end
			return nil
		end
		if not N.SetTarget then return nil end
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
	-- seconds of travel from here (Nav.API.Estimate, documented), paths and flights
	eta = function(map, x, y)
		local N = nav()
		if not (N and N.API and N.API.Estimate) then return nil end
		local ok, seconds = pcall(N.API.Estimate, nil, nil, nil, map, x / 100, y / 100)
		if ok and type(seconds) == "number" then return seconds end
	end,
	-- Polestar's own frames (its Era maps, f = "e") for points from its data
	world = function(map, x, y, f)
		local C = Polestar and Polestar.Compat
		if not (C and C.MapToWorld) then return nil end
		local c, a, b = C.MapToWorld(map, x, y, f)
		if c then return c, a, b end
	end,
	here = function()
		local C = Polestar and Polestar.Compat
		if not (C and C.GetPlayerWorldPosition) then return nil end
		local c, a, b = C.GetPlayerWorldPosition()
		if c then return c, a, b end
	end,
	clear = function()
		local N = nav()
		if not (N and N.ClearTarget) then return nil end
		local ok = pcall(N.ClearTarget)
		if ok then return true end
	end,
}, { addon = "Polestar", rank = 10, check = function()
	local N = nav()
	if not N then return false, "Polestar.Nav is gone" end
	if not ((N.API and N.API.Navigate) or N.SetTarget) then return false, "no Nav.API.Navigate or SetTarget" end
	return true
end })
