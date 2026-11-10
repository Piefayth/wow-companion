-- The guide capability (see Engine.lua, Capabilities): the levelling route the
-- player is following, read live (never from an addon's save file, which is as
-- of the last reload).
--   current() -> { title, step, steps, stepTitle } | nil   nil: no guide open
--   upcoming(n) -> { stepTitle, ... }   the next n step titles after the current
-- Name a guide by its title, never an id: ids are file slugs and can mislead.
-- A guide addon that only has waypoints (TomTom) is nav, not guide.

-- Polestar (Polestar/Core/Engine.lua; GPL: called, never copied).
local function engine()
	local E = Polestar and Polestar.Engine
	return type(E) == "table" and E or nil
end
local function stepTitle(guide, i)
	local s = guide and guide.steps and guide.steps[i]
	return type(s) == "table" and s.title or nil
end
WC.Provide("guide", "Polestar", {
	current = function()
		local E = engine()
		if not (E and E.GetGuide) then return nil end
		local ok, guide = pcall(E.GetGuide)
		if not (ok and type(guide) == "table") then return nil end
		local okI, step = pcall(E.GetStepIndex)
		local okN, steps = pcall(E.GetStepCount)
		step = okI and step or nil
		return { title = guide.title, step = step, steps = okN and steps or nil,
			stepTitle = stepTitle(guide, step) }
	end,
	upcoming = function(n)
		local E = engine()
		if not (E and E.GetGuide and E.GetStepIndex) then return nil end
		local ok, guide = pcall(E.GetGuide)
		local okI, step = pcall(E.GetStepIndex)
		if not (ok and okI and type(guide) == "table" and step) then return nil end
		local out = {}
		for i = step + 1, step + (n or 3) do
			local t = stepTitle(guide, i)
			if not t then break end
			out[#out + 1] = t
		end
		return out
	end,
}, { addon = "Polestar", rank = 10 })
