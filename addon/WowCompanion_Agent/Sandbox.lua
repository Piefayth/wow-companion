-- What this needs from Agent.lua comes
-- through its named functions (WC.Companion.<verb>); what Agent.lua calls here is WC.Sandbox.

local effectiveModules = WC.Companion.modules
local remember = WC.Companion.remember
local function taintScan(...) return WC.Tests.taintScan(...) end
local replySlot_now = WC.Companion.replySlot
local handlers = {}

-- Code the agent writes, run here.
--
-- This replaces "the model never writes Lua" with something that holds up better
-- than a rule: the client's own security. Insecure addon code cannot cast, target,
-- move or use protected actions at all -- that is what protection is -- so code
-- from the agent can do no more for the player than any addon they install. What
-- is left to guard is what the client does *not* protect, and two failure modes we
-- have actually hit:
--
--  * Things an addon may do that are not ours to do: delete items, send chat as the
--    player, spend gold, leave groups. Those names are refused in the environment
--    the code runs in. This is a guard against mistakes, not an adversary: Lua has
--    ways around an environment, and getfenv/loadstring, the obvious ones, are shut.
--  * Taint and crashes. Every run is followed by the same issecurevariable diff as
--    /wc place, so code that would break A and B says so by name, and nothing runs
--    in combat. A C-level crash cannot be caught; see /wc alive.
--
-- Code arrives two ways: `lua` runs once and reports what it printed and returned;
-- `module` is also stored in SavedVariables and run again at every login, which is
-- as close to the agent writing its own addon as the client allows without a
-- restart (new addon folders are only seen at launch).

local REFUSED = {
	DeleteCursorItem = true, SendChatMessage = true, BNSendWhisper = true,
	BNSendGameData = true, SendMail = true, AcceptTrade = true, InitiateTrade = true,
	BuyMerchantItem = true, BuybackItem = true, RepairAllItems = true,
	PlaceAuctionBid = true, Logout = true, Quit = true, ForceQuit = true,
	LeaveParty = true, GuildLeave = true, GuildDisband = true, GuildUninvite = true,
	AbandonQuest = true, SetAbandonQuest = true,
	RunScript = true, loadstring = true, load = true, getfenv = true, setfenv = true,
	C_AuctionHouse = true, C_TradeInfo = true, C_Mail = true,
}
-- inside namespaces we otherwise allow
local REFUSED_IN = {
	C_ChatInfo = { SendAddonMessage = true, SendChatMessage = true },
	C_Container = { UseContainerItem = true },
	C_PartyInfo = { LeaveParty = true, ConfirmLeaveParty = true },
	C_Macro = { RunMacroText = true },
}

-- globals that modules created, so a module may update its own but never replace
-- one of Blizzard's: overwriting a Blizzard global is a textbook taint source
local moduleGlobals = {}

local function refuse(name)
	return function()
		error(("%s is not available to companion code"):format(name), 2)
	end
end

local function sandbox(output)
	local env = {}
	-- C functions that take or return a vector or a color look its mixin up in
	-- the calling code's environment directly, so the proxy below is not
	-- enough: "unable to find mixin or metatable (Vector2DMixin)". Put the
	-- mixins the API needs into the environment itself.
	for _, name in ipairs({ "Vector2DMixin", "Vector3DMixin", "ColorMixin", "ItemLocationMixin",
		"ItemTransmogInfoMixin", "PlayerLocationMixin", "TransmogLocationMixin" }) do
		if _G[name] ~= nil then rawset(env, name, _G[name]) end
	end
	local wrapped = {}
	setmetatable(env, {
		__index = function(_, key)
			if key == "_G" then
				return env
			elseif key == "print" then
				return function(...)
					local parts = {}
					for i = 1, select("#", ...) do
						parts[#parts + 1] = tostring((select(i, ...)))
					end
					local text = table.concat(parts, " ")
					-- after the run, from a slash command or an event the code set up:
					-- nobody is collecting any more, so straight to the window
					if output.done then
						remember("probe", text)
					else
						output[#output + 1] = text
					end
				end
			end
			if REFUSED[key] then
				return refuse(key)
			end
			local value = _G[key]
			local blocked = REFUSED_IN[key]
			if blocked and type(value) == "table" then
				wrapped[key] = wrapped[key] or setmetatable({}, {
					__index = function(_, name)
						if blocked[name] then
							return refuse(key .. "." .. name)
						end
						return value[name]
					end,
				})
				return wrapped[key]
			end
			return value
		end,
		__newindex = function(_, key, value)
			if rawget(_G, key) ~= nil and not moduleGlobals[key] then
				error(("refusing to replace the global %s"):format(tostring(key)), 2)
			end
			moduleGlobals[key] = true
			rawset(_G, key, value)
		end,
	})
	return env
end

local function results(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[#parts + 1] = tostring((select(i, ...)))
	end
	return table.concat(parts, ", ")
end

-- Run one chunk. Returns the outcome line. With `before` (a taint scan taken
-- just now), a moment later it scans again and reports any taint the chunk
-- caused. Everything lands in the window and in WowCompanionAgentDB.runs, which
-- reaches disk at the next reload -- the agent's way of seeing what happened.
local function runCode(label, code, before)
	if InCombatLockdown() then
		remember("probe", label .. " refused: in combat")
		return "refused: in combat"
	end
	local chunk, syntax = loadstring(code, "=" .. label)
	if not chunk then
		remember("probe", ("%s did not compile: %s"):format(label, tostring(syntax)))
		return "syntax error: " .. tostring(syntax)
	end
	local output = {}
	setfenv(chunk, sandbox(output))
	local ok, outcome = (function(okay, ...)
		return okay, okay and results(...) or tostring((...))
	end)(pcall(chunk))
	output.done = true
	local line = ok and ("ran" .. (outcome ~= "" and (", returned " .. outcome) or ""))
		or ("failed: " .. outcome)
	for _, printed in ipairs(output) do
		remember("probe", label .. ": " .. printed)
	end
	if before or not ok then
		remember("probe", ("%s %s"):format(label, line))
	end
	WowCompanionAgentDB.runs = WowCompanionAgentDB.runs or {}
	local run = { at = time(), label = label, outcome = line, printed = table.concat(output, "\n") }
	table.insert(WowCompanionAgentDB.runs, run)
	while #WowCompanionAgentDB.runs > 50 do
		table.remove(WowCompanionAgentDB.runs, 1)
	end
	if not before then
		return line
	end
	local whose = replySlot_now()
	C_Timer.After(1.5, function() taintScan(function(after)
		local fresh = WC.Tests.fresh(before, after, function(name) return moduleGlobals[name] end)
		run.taint = #fresh == 0 and "none" or table.concat(fresh, "; ")
		if #fresh > 0 then
			remember("probe", ("%s tainted %d variable(s): %s -- /reload clears it"):format(
				label, #fresh, table.concat(fresh, "; ", 1, math.min(#fresh, 4))), nil, whose)
		end
	end) end)
	return line
end

-- Agent code waits for a taint scan, spread over frames (Tests.lua), so no frame
-- freezes; whatever must follow it (the rest of its batch) waits in this queue.
-- One job at a time; a job calls done() when it has finished.
local queue, busy = {}, false
local function pump()
	if busy then return end
	local job = table.remove(queue, 1)
	if not job then return end
	busy = true
	job(function()
		busy = false
		pump()
	end)
end
local function enqueue(job)
	queue[#queue + 1] = job
	pump()
end

-- a chunk from an agent: scanned before, run in its conversation, scanned after
local function runMeasured(label, code)
	local slot = WC.Link.Current()
	enqueue(function(done)
		taintScan(function(before)
			WC.Link.As(slot, runCode, label, code, before)
			done()
		end)
	end)
	return "runs after a taint scan of a second or two"
end

function handlers.lua(inbox)
	return runMeasured("code", inbox.code or "")
end

function handlers.module(inbox)
	local name = tostring(inbox.name or "")
	if not name:match("^[%w_]+$") then
		return "refused: a module name is letters, digits and underscores"
	end
	WowCompanionAgentDB.modules = WowCompanionAgentDB.modules or {}
	if inbox.remove then
		WowCompanionAgentDB.modules[name] = nil
		remember("claude", ("module %s removed; what it already did stays until /reload"):format(name))
		return "removed " .. name
	end
	WowCompanionAgentDB.modules[name] = { code = inbox.code or "", at = time() }
	return runMeasured("module " .. name, inbox.code or "")
end

-- at login: every stored module, in name order so the order is stable; each was
-- scanned when it was first written, so none is scanned again
local function loadModules()
	local all = effectiveModules()
	local names = {}
	for name in pairs(all) do
		names[#names + 1] = name
	end
	table.sort(names)
	for _, name in ipairs(names) do
		runCode("module " .. name, all[name].code)
	end
end

WC.Sandbox = WC.Sandbox or {}
WC.Sandbox.loadModules = loadModules
WC.Sandbox.results = results
WC.Sandbox.Busy = function() return busy or #queue > 0 end
WC.Sandbox.Queue = enqueue

for kind, fn in pairs(handlers) do WC.Companion.addHandler(kind, fn) end
