-- What this needs from Agent.lua comes
-- through its named functions (WC.Companion.<verb>); what Agent.lua calls here is WC.Sandbox.

local effectiveModules = WC.Companion.modules
local remember = WC.Companion.remember
local replySlot_now = WC.Companion.replySlot
local handlers = {}

-- The taint scan. issecurevariable asks of every global, and every
-- string-keyed field of every global table, who last wrote it; a name that
-- turns insecure between a scan before agent code and one after, and is not
-- ours, is taint that code caused, named by variable.
local function ours(name)
	name = tostring(name)
	return name:find("WowCompanion", 1, true) or name:find("WOWCOMPANION", 1, true)
end

-- The scan asks about some 265,000 variables, about 300 ms in one go: a frame the
-- player sees freeze. So it is spread over frames, at most BUDGET_MS of each, and
-- done(tainted, checked) is called when it has asked about every one. The names
-- are taken first (one bare pass over _G, and over a table's fields when it is
-- reached; the filtering is in the budgeted steps), since a table must not be
-- walked across frames while others add to it.
local BUDGET_MS = 2
local scanner = CreateFrame("Frame")
local scans = {}
local function startScan(scan)
	local names = {}
	for name, value in pairs(_G) do
		if type(name) == "string" then names[#names + 1] = name end
	end
	scan.names, scan.at, scan.fields, scan.f = names, 0, nil, 0
end
-- one variable asked about; false when the scan is through
local function step(scan)
	local fields = scan.fields
	if fields and scan.f < #fields then
		scan.f = scan.f + 1
		local field = fields[scan.f]
		if ours(field) then return true end
		local ok, secure, by = pcall(issecurevariable, scan.table, field)
		scan.checked = scan.checked + 1
		if ok and not secure then scan.tainted[scan.name .. "." .. field] = tostring(by) end
		return true
	end
	scan.at = scan.at + 1
	local name = scan.names[scan.at]
	if not name then return false end
	scan.fields = nil
	if ours(name) then return true end
	local ok, secure, by = pcall(issecurevariable, name)
	scan.checked = scan.checked + 1
	if ok and not secure then scan.tainted[name] = tostring(by) end
	local value = rawget(_G, name)
	scan.fields, scan.f, scan.name, scan.table = nil, 0, name, nil
	if type(value) == "table" then
		-- forbidden frames refuse to be walked; pcall keeps one from ending the scan
		local list = {}
		if pcall(function()
			for field in pairs(value) do
				if type(field) == "string" then list[#list + 1] = field end
			end
		end) then
			scan.fields, scan.table = list, value
		end
	end
	return true
end
scanner:Hide()
scanner:SetScript("OnUpdate", function(self)
	local scan = scans[1]
	if not scan then return self:Hide() end
	if not scan.names then
		startScan(scan)
		return
	end
	local stop = debugprofilestop() + BUDGET_MS
	repeat
		if not step(scan) then
			table.remove(scans, 1)
			pcall(scan.done, scan.tainted, scan.checked)
			return
		end
	until debugprofilestop() >= stop
end)
local function taintScan(done)
	scans[#scans + 1] = { done = done, tainted = {}, checked = 0 }
	scanner:Show()
end

-- the variables newly tainted between two scans, each with who tainted it
local function fresh(before, after, skip)
	local list = {}
	for label, by in pairs(after) do
		if before[label] == nil and not (skip and skip(label)) then
			list[#list + 1] = ("%s (by %s)"):format(label, by)
		end
	end
	table.sort(list)
	return list
end

-- "Interface action failed because of an AddOn" is shown by this function, and it
-- fires even when ADDON_ACTION_BLOCKED does not reach us. hooksecurefunc runs after
-- the original without tainting it. Every hit is kept with its time.
if hooksecurefunc and DisplayInterfaceActionBlockedMessage then
	hooksecurefunc("DisplayInterfaceActionBlockedMessage", function()
		WowCompanionAgentDB.blockedNotices = WowCompanionAgentDB.blockedNotices or {}
		local stamp = date("%H:%M:%S")
		-- who asked: SecureHelper's wrapped calls (FrameHidden, MarkFrame*) fail
		-- here without ADDON_ACTION_BLOCKED, so the stack is the only name for it
		local stack = debugstack and debugstack(2, 8, 0) or ""
		local ours = stack:match("(WowCompanion[%w_]*[/%.%w_]*:%d+)")
		table.insert(WowCompanionAgentDB.blockedNotices, stamp .. (ours and (" " .. ours) or ""))
		-- the whole stack, kept apart: the caller is often Blizzard code run for us
		WowCompanionAgentDB.blockedStacks = WowCompanionAgentDB.blockedStacks or {}
		table.insert(WowCompanionAgentDB.blockedStacks, stamp .. " " .. (stack:gsub("\n", " | ")):sub(1, 2000))
		while #WowCompanionAgentDB.blockedStacks > 10 do table.remove(WowCompanionAgentDB.blockedStacks, 1) end
		while #WowCompanionAgentDB.blockedNotices > 40 do table.remove(WowCompanionAgentDB.blockedNotices, 1) end
		-- the window's log must never break this hook
		pcall(remember, "probe", "interface action failed notice at " .. stamp)
	end)
end

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
--  * Taint and crashes. Every run is followed by the taint scan above, so code
--    that would break A and B says so by name, and nothing runs in combat. A
--    C-level crash cannot be caught.
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
		local fresh = fresh(before, after, function(name) return moduleGlobals[name] end)
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
WC.Sandbox.taintScan = taintScan
WC.Sandbox.fresh = fresh

for kind, fn in pairs(handlers) do WC.Link.Handle(kind, fn) end
