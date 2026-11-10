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

	-- Tell the controller's manager a window of ours closed. FrameHidden is
	-- wrapped by SmartNavigation's SecureHelper: called by addon code in a fight
	-- it does nothing and shows "Interface action failed" (bag close, 2026-11-10).
	-- So in a fight it waits for the fight's end, if the frame is still hidden.
	function WC.FrameHidden(frame)
		local m = GamepadMode and GamepadMode.FrameControlsManager
		if not m or not (InputUtil and InputUtil.IsGamepadUIEnabled()) then return end
		if InCombatLockdown() then
			WC.AfterCombat(function() if not frame:IsShown() then pcall(m.FrameHidden, m, frame) end end)
		else
			pcall(m.FrameHidden, m, frame)
		end
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
			-- wants = { "nav" }: say what is missing instead of failing quietly;
			-- the module still runs (it may do less), and WC.Use answers nil
			m.missing = nil
			for _, cap in ipairs(m.wants or {}) do
				if not WC.Use(cap) then
					m.missing = m.missing or {}
					m.missing[#m.missing + 1] = cap
				end
			end
			if m.missing then
				local needs = {}
				for _, cap in ipairs(m.missing) do needs[#needs + 1] = WC.CapabilityNeeds[cap] or ("a provider of " .. cap) end
				pcall(WC.Board.Post, "", ("%s needs %s"):format(m.name, table.concat(needs, " and ")))
			end
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
		for _, name in ipairs(order) do
			out[#out + 1] = { name = name, enabled = mods[name].enabled and true or false, missing = mods[name].missing }
		end
		return out
	end

	-- Capabilities (the player, 2026-11-10): other addons are factored into what
	-- they do, so a feature works with whatever is installed. A capability is a
	-- small fixed interface named by its job:
	--   price: auction(itemID) -> copper per item | nil, vendor(itemID) -> copper | nil
	--   nav:   aim(map, x, y, label) -> true | nil (x, y the 0-100 coordinates
	--          players quote), nearest(kind) -> place { name, map, x, y }, seconds | nil,
	--          clear()
	--   gear:  slots(), upgrades(slotName, n)          (Providers/Gear.lua)
	--   itemSource: sources(itemID), npcName(id), questName(id) (Providers/ItemSource.lua)
	-- A module may declare WC.Module("Name", { wants = { "nav" } }): when nothing
	-- provides one, the board says what it needs, and WC.List() shows it.
	-- A provider is one file in Providers/ (WC.Provide below); one tied to an
	-- addon counts only while that addon is loaded, checked at each call, so the
	-- load order between us and it never matters. Every call into the other addon
	-- happens inside its provider, under pcall.
	--
	--   local price = WC.Use("price")    -- nil when nothing provides it
	--   price.auction(id)                -- the first provider with an answer, best first
	--   WC.Has("price", "auction")       -- does any loaded provider do this one?
	--   WC.Capabilities()                -- { { name, using = { provider names, best first } } }
	-- Best first: WC.Settings("Capabilities")[cap] when it names a loaded
	-- provider, then rank (higher first). Built-ins rank 0.
	local providers = {}            -- capability -> { { name, impl, addon, rank } }
	-- what to tell the player when a module wants a capability nothing provides
	WC.CapabilityNeeds = {
		price = "a price addon (such as Auctionator)",
		nav = "a navigation addon (such as Polestar)",
		gear = "a gear addon (such as GearQuest Forever)",
		itemSource = "an item database addon (such as Polestar)",
	}
	function WC.Provide(cap, name, impl, opts)
		opts = opts or {}
		local list = providers[cap] or {}
		providers[cap] = list
		for i = #list, 1, -1 do
			if list[i].name == name then table.remove(list, i) end
		end
		list[#list + 1] = { name = name, impl = impl, addon = opts.addon, rank = opts.rank or 0 }
	end
	local function live(p)
		if not p.addon then return true end
		local ok, loaded = pcall(C_AddOns.IsAddOnLoaded, p.addon)
		return ok and loaded and true or false
	end
	local function ranked(cap)
		local out = {}
		for _, p in ipairs(providers[cap] or {}) do
			if live(p) then out[#out + 1] = p end
		end
		-- read, never created here: this may run before the save file is loaded
		local saved = WowCompanionDB and WowCompanionDB.mods and WowCompanionDB.mods.Capabilities
		local chosen = saved and saved[cap]
		table.sort(out, function(a, b)
			if (a.name == chosen) ~= (b.name == chosen) then return a.name == chosen end
			return a.rank > b.rank
		end)
		return out
	end
	function WC.Has(cap, method)
		for _, p in ipairs(ranked(cap)) do
			if type(p.impl[method]) == "function" then return p.name end
		end
	end
	-- each method asks the providers in order and returns the first answer;
	-- a provider that errors or has no answer passes to the next
	local facades = setmetatable({}, { __mode = "k" })
	function WC.Use(cap)
		if #ranked(cap) == 0 then return nil end
		if not facades[cap] then
			facades[cap] = setmetatable({}, { __index = function(_, method)
				return function(...)
					for _, p in ipairs(ranked(cap)) do
						local fn = p.impl[method]
						if type(fn) == "function" then
							local r = { pcall(fn, ...) }
							if r[1] and r[2] ~= nil then return select(2, unpack(r)) end
						end
					end
				end
			end })
		end
		return facades[cap]
	end
	function WC.Capabilities()
		local names = {}
		for cap in pairs(providers) do names[#names + 1] = cap end
		table.sort(names)
		local out = {}
		for _, cap in ipairs(names) do
			local using = {}
			for _, p in ipairs(ranked(cap)) do using[#using + 1] = p.name end
			out[#out + 1] = { name = cap, using = using }
		end
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
