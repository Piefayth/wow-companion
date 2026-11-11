-- What this needs from Agent.lua comes
-- through its named functions (WC.Companion.<verb>); what Agent.lua calls here is WC.Probes.

local logFrame = WC.Companion.window
local record = WC.Companion.record
local say = WC.Companion.say
local actionButton_now = WC.Companion.offerButton
local blocked_now = WC.Companion.blockedCount
local listenSignal = WC.Companion.listenSignal

local function cvar(name)
	local get = C_CVar and C_CVar.GetCVar or GetCVar
	return get and get(name) or "?"
end

-- controls: a long silent file should play, an empty one shouldn't.
-- an unfocused game mutes everything, so both come back false if you alt-tabbed away;
-- the cvars tell that case apart from a bell that genuinely didn't play
local function probeSound()
	record("sound enabled", cvar("Sound_EnableAllSound"))
	record("background sound", cvar("Sound_EnableSoundWhenGameIsInBG"))
	record("master volume", cvar("Sound_MasterVolume"))
	listenSignal("always.wav", function(playing)
		record("always.wav plays (want true)", playing)
	end)
	listenSignal("never.wav", function(playing)
		record("never.wav plays (want false)", playing)
	end)
end

-- What the gamepad UI gives us to work with. Controller focus matters well beyond
-- one button, and the client's own Lua is not on disk to read, so ask the client.
local function probeGamepad()
	for _, name in ipairs({
		"C_GamePad",
		"SmartNavigation",
		"GamePadSmartNavigation",
		"UIPanelWindows",
		"SetOverrideBinding",
		"GetBindingKey",
		"C_GamePad.GetActiveDeviceID",
		"C_GamePad.GetDeviceMappedState",
		"C_GamePad.SetVibration",
		"SmartNavigationFrameMixin",
		"GamePadCursorMixin",
	}) do
		local holder, member = name:match("^(%w+)%.(%w+)$")
		local found
		if holder then
			local parent = _G[holder]
			found = type(parent) == "table" and parent[member] ~= nil
		else
			found = _G[name] ~= nil
		end
		record("has " .. name, found and "yes" or "no")
	end
	record("interface style", cvar("InputDeviceInterfaceStyle"))

	-- SmartNavigation exists; find out whether it will let us register a frame
	if type(SmartNavigation) == "table" then
		local members = {}
		for key, value in pairs(SmartNavigation) do
			members[#members + 1] = ("%s(%s)"):format(tostring(key), type(value))
		end
		table.sort(members)
		record("SmartNavigation members", table.concat(members, " "))
	end

	-- which pad key names this build will actually accept for an override binding
	local usable = {}
	if SetOverrideBindingClick and actionButton_now() then
		for _, key in ipairs({
			"PAD1", "PAD2", "PAD3", "PAD4",
			"PADDUP", "PADDDOWN", "PADDLEFT", "PADDRIGHT",
			"PADLSHOULDER", "PADRSHOULDER", "PADLSTICK", "PADRSTICK",
			"PADFORWARD", "PADBACK", "PADSYSTEM", "PADSOCIAL",
		}) do
			local ok = pcall(SetOverrideBindingClick, actionButton_now(), true, key, "WowCompanionDo")
			if ok and GetBindingByKey and GetBindingByKey(key) then
				usable[#usable + 1] = key
			elseif ok then
				usable[#usable + 1] = key .. "?"
			end
		end
		ClearOverrideBindings(actionButton_now())
	end
	record("pad keys accepted", #usable > 0 and table.concat(usable, " ") or "none")

	-- 1.60.1's SmartNavigation_* globals are the documented way in. Mark the window,
	-- then ask whether it took: the API can answer for itself, so there is no need
	-- to infer it from whether the cursor happens to land.
	local frame = logFrame()
	WC.MarkFocusable(frame)
	for _, check in ipairs({ "SmartNavigation_IsFrameFocusable", "SmartNavigation_CanFocusFrame" }) do
		local probe = _G[check]
		if probe then
			local ok, answer = pcall(probe, frame)
			record(check, ok and tostring(answer) or "errored")
		else
			record(check, "missing")
		end
	end
	if actionButton_now() and SmartNavigation_IsFrameFocusable then
		local ok, answer = pcall(SmartNavigation_IsFrameFocusable, actionButton_now())
		record("button focusable", ok and tostring(answer) or "errored")
	end
end

-- Can the client tell us its own API? That would beat any external reference, which
-- is written about WoW in general while this is one specific build -- and version
-- drift is exactly what has caught us out repeatedly.
local function probeApi()
	for _, name in ipairs({
		"APIDocumentation",
		"C_ApiDocumentation",
		"GetAPIDocumentation",
		"APIDocumentationMixin",
		"ApiDocumentation",
	}) do
		record("has " .. name, _G[name] ~= nil and type(_G[name]) or "no")
	end

	-- failing that, the globals themselves are a complete list of what exists
	local functions, namespaces, members = 0, 0, 0
	local biggest, biggestCount = "none", 0
	for key, value in pairs(_G) do
		if type(value) == "function" then
			functions = functions + 1
		elseif type(value) == "table" and type(key) == "string" and key:match("^C_%w+$") then
			namespaces = namespaces + 1
			local count = 0
			for _, member in pairs(value) do
				if type(member) == "function" then
					count = count + 1
				end
			end
			members = members + count
			if count > biggestCount then
				biggest, biggestCount = key, count
			end
		end
	end
	record("global functions", functions)
	record("C_ namespaces", namespaces)
	record("C_ functions", members)
	record("largest namespace", ("%s (%d)"):format(biggest, biggestCount))
end

-- Everything this build can call, as one string.
--
-- The client ships no API documentation tables, so signatures are not available
-- locally -- but the *names* are, exhaustively and exactly for this build. That is
-- the half that matters: the agent's failure mode is not forgetting what a function
-- does, it is confidently calling something that exists in retail and not here.
--
-- One string rather than a nested table because the helper has to parse this back
-- out of SavedVariables without a Lua parser.
local function dumpApi()
	local lines, namespaces = {}, 0
	for key, value in pairs(_G) do
		if type(key) == "string" then
			if type(value) == "function" then
				lines[#lines + 1] = key
			elseif type(value) == "table" and key:match("^C_%w+$") then
				namespaces = namespaces + 1
				for name, member in pairs(value) do
					if type(member) == "function" and type(name) == "string" then
						lines[#lines + 1] = key .. "." .. name
					end
				end
			end
		end
	end
	table.sort(lines)
	local version, build = GetBuildInfo()
	-- built with an explicit newline rather than an escape: the escapes in this file
	-- have been through a shell and a script, and one of them arrived as a literal
	-- line break inside a string literal
	local newline = string.char(10)
	WowCompanionAgentDB.api = ("-- World of Warcraft %s build %s%s%s%s"):format(
		tostring(version), tostring(build), newline, table.concat(lines, newline), newline)
	say(("dumped %d names across %d namespaces; /reload to write it to disk")
		:format(#lines, namespaces))
end

-- Signatures, if the client will give them up. The name index came from _G, but
-- retail keeps documentation in a load-on-demand Blizzard addon, and this build has
-- APIDocumentation_LoadUI -- so the table may only be absent because nothing has
-- loaded it yet. Kept separate from dumpApi so a failure here costs nothing.
-- the fields every function entry has; anything else is a flag worth keeping, and
-- the flags are where the documentation says what is restricted
local SHAPE = { Name = true, Type = true, Arguments = true, Returns = true,
	Documentation = true, System = true }

local function describe(fields)
	local parts = {}
	for _, field in ipairs(fields or {}) do
		parts[#parts + 1] = ("%s: %s%s"):format(
			tostring(field.Name), tostring(field.Type), field.Nilable and "?" or "")
	end
	return table.concat(parts, ", ")
end

local function loadDocs()
	if not APIDocumentation then
		for _, loader in ipairs({
			function() APIDocumentation_LoadUI() end,
			function() C_AddOns.LoadAddOn("Blizzard_APIDocumentationGenerated") end,
			function() C_AddOns.LoadAddOn("Blizzard_APIDocumentation") end,
		}) do
			pcall(loader)
			if APIDocumentation then
				break
			end
		end
	end
	if type(APIDocumentation) ~= "table" or type(APIDocumentation.systems) ~= "table" then
		record("api docs", "unavailable: APIDocumentation " .. type(APIDocumentation))
		return false
	end
	return true
end

local function dumpDocs()
	if not loadDocs() then
		return
	end
	local newline = string.char(10)
	local lines, systems = {}, 0
	for _, system in ipairs(APIDocumentation.systems) do
		systems = systems + 1
		local prefix = system.Namespace and (system.Namespace .. ".") or ""
		for _, fn in ipairs(system.Functions or {}) do
			local returns = describe(fn.Returns)
			local flags = {}
			for key, value in pairs(fn) do
				if not SHAPE[key] and type(value) ~= "table" and type(value) ~= "function" then
					flags[#flags + 1] = ("%s=%s"):format(tostring(key), tostring(value))
				end
			end
			table.sort(flags)
			lines[#lines + 1] = ("%s%s(%s)%s%s"):format(prefix, tostring(fn.Name),
				describe(fn.Arguments), returns ~= "" and (" -> " .. returns) or "",
				#flags > 0 and (" [" .. table.concat(flags, " ") .. "]") or "")
		end
		for _, event in ipairs(system.Events or {}) do
			lines[#lines + 1] = ("event %s(%s)"):format(
				tostring(event.LiteralName or event.Name), describe(event.Payload))
		end
		-- the signatures are only half an answer without these: a function that
		-- returns SpellBookItemInfo tells you nothing about what to read off it,
		-- and an argument typed SpellBookSpellBank tells you nothing about what to
		-- pass. Enumerations carry their values, so this is also where the magic
		-- numbers stop being magic.
		for _, entry in ipairs(system.Tables or {}) do
			local kind = tostring(entry.Type)
			if kind == "Enumeration" or kind == "Constants" then
				local values = {}
				for _, value in ipairs(entry.Values or entry.Fields or {}) do
					values[#values + 1] = ("%s = %s"):format(
						tostring(value.Name),
						tostring(value.EnumValue ~= nil and value.EnumValue or value.Value))
				end
				lines[#lines + 1] = ("%s %s { %s }"):format(
					kind == "Enumeration" and "enum" or "constants",
					tostring(entry.Name), table.concat(values, ", "))
			else
				lines[#lines + 1] = ("struct %s { %s }"):format(
					tostring(entry.Name), describe(entry.Fields))
			end
		end
	end
	table.sort(lines)
	WowCompanionAgentDB.apidocs = table.concat(lines, newline) .. newline
	record("api docs", ("%d entries from %d systems; /reload to write"):format(#lines, systems))
end

-- Which documented functions actually answer on this client.
--
-- Documented is not working: Forever carries retail's namespaces, and a function can
-- exist, be documented, and return nothing. Calling it is the only test, and calling
-- blind is only safe for one kind -- a read that needs no arguments. So: every
-- documented function whose name starts Get/Is/Has/Can/Should/Are/Does and whose
-- arguments are all optional is called once, under pcall, and sorted by what came
-- back. Anything that changes state is left alone; those need a test of their own.
--
-- Batched across frames so a few thousand calls do not hitch the game.
--
-- Calling every such read is unsafe: one of them crashes the client outright
-- (ACCESS_VIOLATION reading address 0 inside Wow.exe, under a plain pcall:
-- pcall catches Lua errors, not a C null dereference), and others are refused
-- as ADDON_ACTION_FORBIDDEN. So: only the namespaces this project would use,
-- nothing the docs flag as restricted, and the name of each function in a plain
-- local while it runs, because the crash report prints the locals of the Lua
-- frame that was executing.
-- "%u" after the verb: "^Can" alone matched CancelEmote, which is not a read
local READS = { "^Get%u", "^Is%u", "^Has%u", "^Can%u", "^Should%u", "^Are%u", "^Does%u" }
local SURVEYED = {
	C_ActionBar = true, C_Macro = true, C_Spell = true, C_SpellBook = true,
	C_ClassTalents = true, C_Traits = true, C_SpecializationInfo = true,
	C_EquipmentSet = true, C_CVar = true, C_KeyBindings = true, C_ChatInfo = true,
	C_GamePad = true, C_Container = true, C_Item = true, C_PlayerInfo = true,
	C_UnitAuras = true, C_PetInfo = true, C_MountJournal = true, C_ToyBox = true,
}

local function verdict(ok, ...)
	if not ok then
		return "error"
	end
	local count = select("#", ...)
	if count == 0 then
		return "nothing"
	end
	local first = ...
	if first == nil then
		return "nil"
	elseif type(first) == "table" then
		return next(first) == nil and "empty" or "value"
	elseif first == 0 or first == false or first == "" then
		return "zero"
	end
	return "value"
end

local function surveyApi()
	if InCombatLockdown() then
		say("leave combat first")
		return
	end
	if not loadDocs() then
		return
	end
	local queue = {}
	for _, system in ipairs(APIDocumentation.systems) do
		-- widget methods (frame:Show and friends) need an object; only namespaces
		-- and plain globals can be called bare
		local owner = system.Namespace and SURVEYED[system.Namespace] and _G[system.Namespace] or nil
		for _, fn in ipairs(system.Functions or {}) do
			local name = tostring(fn.Name)
			local read = false
			for _, pattern in ipairs(READS) do
				read = read or name:find(pattern) ~= nil
			end
			local optional = true
			for _, arg in ipairs(fn.Arguments or {}) do
				optional = optional and (arg.Nilable or arg.Default ~= nil)
			end
			if read and optional and owner and not fn.HasRestrictions then
				queue[#queue + 1] = {
					label = (system.Namespace and (system.Namespace .. ".") or "") .. name,
					owner = owner,
					name = name,
				}
			end
		end
	end
	local results, tally, at = {}, {}, 0
	local function batch()
		for _ = 1, 150 do
			at = at + 1
			local job = queue[at]
			if not job then
				table.sort(results)
				local summary = {}
				for kind, count in pairs(tally) do
					summary[#summary + 1] = ("%s %d"):format(kind, count)
				end
				table.sort(summary)
				local newline = string.char(10)
				WowCompanionAgentDB.alive = ("-- %d no-argument reads called: %s"):format(#queue,
					table.concat(summary, ", ")) .. newline .. table.concat(results, newline) .. newline
				record("api survey", table.concat(summary, ", ") .. "; /reload to write")
				return
			end
			local kind
			local fn = type(job.owner) == "table" and rawget(job.owner, job.name)
			-- read by the crash reporter, not by us: see the note above
			local survey_calling = job.label
			if type(fn) ~= "function" then
				kind = "absent"
			else
				local refusedBefore = blocked_now()
				kind = verdict(pcall(fn))
				if blocked_now() ~= refusedBefore then
					kind = "forbidden"
				end
			end
			survey_calling = nil
			tally[kind] = (tally[kind] or 0) + 1
			results[#results + 1] = ("%s %s"):format(kind, job.label)
		end
		C_Timer.After(0, batch)
	end
	say(("calling %d documented no-argument reads..."):format(#queue))
	batch()
end


WC.Probes = WC.Probes or {}
WC.Probes.cvar = cvar
WC.Probes.dumpApi = dumpApi
WC.Probes.dumpDocs = dumpDocs
WC.Probes.probeApi = probeApi
WC.Probes.probeGamepad = probeGamepad
WC.Probes.probeSound = probeSound
WC.Probes.surveyApi = surveyApi
