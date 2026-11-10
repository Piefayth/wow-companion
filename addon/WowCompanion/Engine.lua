-- Part of WowCompanion; loaded by the .toc in order: Engine, Style, Companion,
-- Pins, Strip, Bags, Status, Modules. A file shares nothing local with another:
-- they talk through globals (WC, WowCompanion_*, WCPins, WCBags).

---------------------------------------------------------------------------
-- WC, the engine modules hang off (the player, 2026-11-10; the shape of the
-- big UI packs: one table, a module registry with a lifecycle, a message bus,
-- per-module settings). Agent modules in modules/*.lua register here:
--
--   local M = WC.Module("Name", { after = { "Other" }, combat = "wait" })
--   function M:Enable() ... end      -- build frames, listen; runs at login and on replace
--   function M:Disable() ... end     -- optional: undo what Enable did
--   M:On("BAGS_CHANGED", fn)         -- bus message; dropped on Disable
--   M:Event("BAG_UPDATE_DELAYED", fn)-- game event via one shared frame; dropped on Disable
--   M.db = WC.Settings("Name", { defaults })   -- WowCompanionDB.mods.Name, defaults filled
--   WC.Send("MSG", ...)              -- to every listener, each under pcall
--   WC.AfterCombat(fn)               -- now, or when the fight ends
--
-- Re-registering a name (a module step replacing its code) disables the old
-- one first, so its listeners and events go away instead of doubling up.
-- Frames it made stay (frames cannot be destroyed): Enable reuses them by name.
---------------------------------------------------------------------------
WC = WC or {}
do
	local mods, order = {}, {}
	local listeners = {}            -- message -> { [owner] = fn }
	local events = {}               -- event -> { [owner] = fn }
	local afterCombat = {}
	local bus = CreateFrame("Frame")
	bus:RegisterEvent("PLAYER_REGEN_ENABLED")
	bus:SetScript("OnEvent", function(_, event, ...)
		if event == "PLAYER_REGEN_ENABLED" and #afterCombat > 0 then
			local queued = afterCombat
			afterCombat = {}
			for _, fn in ipairs(queued) do
				local ok, err = pcall(fn)
				if not ok then geterrorhandler()(err) end
			end
		end
		for owner, fn in pairs(events[event] or {}) do
			local ok, err = pcall(fn, event, ...)
			if not ok then geterrorhandler()(("%s %s: %s"):format(tostring(owner.name or owner), event, tostring(err))) end
		end
	end)

	function WC.AfterCombat(fn)
		if InCombatLockdown() then afterCombat[#afterCombat + 1] = fn else fn() end
	end

	function WC.Send(msg, ...)
		for owner, fn in pairs(listeners[msg] or {}) do
			local ok, err = pcall(fn, ...)
			if not ok then geterrorhandler()(("%s on %s: %s"):format(tostring(owner.name or owner), msg, tostring(err))) end
		end
	end

	-- per-module saved settings, defaults filled in without overwriting
	function WC.Settings(name, defaults)
		WowCompanionDB = WowCompanionDB or {}
		WowCompanionDB.mods = WowCompanionDB.mods or {}
		local db = WowCompanionDB.mods[name] or {}
		WowCompanionDB.mods[name] = db
		for k, v in pairs(defaults or {}) do
			if db[k] == nil then db[k] = type(v) == "table" and CopyTable(v) or v end
		end
		return db
	end

	local proto = {}
	proto.__index = proto
	function proto:On(msg, fn)
		listeners[msg] = listeners[msg] or {}
		listeners[msg][self] = fn
	end
	function proto:Event(event, fn)
		if not events[event] then
			events[event] = {}
			if event ~= "PLAYER_REGEN_ENABLED" then pcall(bus.RegisterEvent, bus, event) end
		end
		events[event][self] = fn
	end
	function proto:Drop()
		for _, t in pairs(listeners) do t[self] = nil end
		for _, t in pairs(events) do t[self] = nil end
	end

	local function enable(m)
		if m.enabled then return end
		for _, dep in ipairs(m.after or {}) do
			local d = mods[dep]
			if d and not d.enabled then enable(d) end
		end
		local function go()
			if m.enabled or m.retired then return end
			m.enabled = true
			if m.Enable then
				local ok, err = pcall(m.Enable, m)
				if not ok then
					m.enabled = false
					m:Drop()
					geterrorhandler()(("module %s: %s"):format(m.name, tostring(err)))
				end
			end
		end
		-- a module that builds secure frames or bindings waits out a fight
		if m.combat == "wait" then WC.AfterCombat(go) else go() end
	end

	local function disable(m)
		if not m.enabled then return end
		m.enabled = false
		if m.Disable then pcall(m.Disable, m) end
		m:Drop()
	end

	-- Register (or replace) a module. Enable runs on the next frame, so the rest
	-- of the module's file has defined its methods by then.
	function WC.Module(name, opts)
		local old = mods[name]
		if old then
			disable(old)
			old.retired = true
		else
			order[#order + 1] = name
		end
		local m = setmetatable({ name = name }, proto)
		for k, v in pairs(opts or {}) do m[k] = v end
		mods[name] = m
		C_Timer.After(0, function() if mods[name] == m then enable(m) end end)
		return m
	end

	function WC.Get(name) return mods[name] end
	function WC.Disable(name) local m = mods[name] if m then disable(m) end end
	function WC.Enable(name) local m = mods[name] if m then enable(m) end end
	-- name, enabled, for /wc and the agents
	function WC.List()
		local out = {}
		for _, name in ipairs(order) do out[#out + 1] = { name = name, enabled = mods[name].enabled and true or false } end
		return out
	end

	-- one place for what agent code may call; the old global names stay
	-- (looked up at call time: some are defined further down this file)
	WC.Board = { Post = function(...) return WowCompanion_Recent(...) end }
	WC.Chat = {
		Preview = function(...) return WowCompanion_Preview(...) end,
		ResolveWhisper = function(...) return WowCompanion_ResolveWhisper(...) end,
	}
	WC.Items = {
		Show = function(...) return WowCompanion_ShowItem(...) end,
		ConfirmDestroy = function(...) return WowCompanion_ConfirmDestroy(...) end,
	}
	setmetatable(WC, { __index = function(_, k)
		if k == "Pins" then return WCPins end
		if k == "Strip" then return WowCompanion_Strip end
		if k == "Style" then return WowCompanion_Style end
		if k == "Wheel" then return WCWheel end
	end })
end
