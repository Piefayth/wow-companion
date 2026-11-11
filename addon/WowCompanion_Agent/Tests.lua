-- What this needs from Agent.lua comes
-- through its named functions (WC.Companion.<verb>); what Agent.lua calls here is WC.Tests.

local function actionFrames(...) return WC.Chords.actionFrames(...) end
local function slotHas(...) return WC.Chords.slotHas(...) end
local activeEditBox = WC.Companion.activeEditBox
local record = WC.Companion.record
local remember = WC.Companion.remember
local say = WC.Companion.say

local function probeChat()
	local open = ChatFrame_OpenChat or (ChatFrameUtil and ChatFrameUtil.OpenChat)
	record("chat opener", ChatFrame_OpenChat and "ChatFrame_OpenChat" or open and "ChatFrameUtil.OpenChat" or "none")
	if not open then
		return
	end
	-- the Enter that submits /wc chat closes the edit box once the command returns,
	-- so opening it from here only sticks if we let that finish first
	C_Timer.After(0.1, function()
		open("hello from the companion")
		C_Timer.After(0.1, function()
			local box = activeEditBox()
			record("chat box", box and box:IsVisible() and ("open, holds %q"):format(box:GetText()) or "not open")
		end)
	end)
end

local function probeMacro()
	if InCombatLockdown() then
		say("leave combat first")
		return
	end
	local created, index = pcall(CreateMacro, "WCPROBE", "INV_MISC_QUESTIONMARK", "/say created", false)
	record("CreateMacro", index)
	if not created or not index then
		return
	end
	local edited, err = pcall(EditMacro, index, nil, nil, "/say edited")
	record("EditMacro", edited and GetMacroBody(index) or err)
	local empty
	for action = 1, 120 do
		if not HasAction(action) then
			empty = action
			break
		end
	end
	if empty then
		PickupMacro(index)
		local placed, placeErr = pcall(PlaceAction, empty)
		ClearCursor()
		local kind = GetActionInfo(empty)
		record("PlaceAction", placed and ("action %d now holds %s"):format(empty, tostring(kind)) or placeErr)
		if kind == "macro" then
			PickupAction(empty)
			ClearCursor()
		end
	else
		record("PlaceAction", "no empty action slot to test with")
	end
	DeleteMacro(index)
end

-- PlaceAction, tested one variable at a time.
--
-- The chat taint taught us that "it seemed fine" means nothing: the damage lands
-- later, on an unrelated keypress, and only sometimes. So the A/B check by hand is
-- kept, but it is not the instrument. The instrument is issecurevariable: every
-- global, and every string-keyed field of every global table, is asked who last
-- wrote it, before and after the action. Anything that turns insecure in between,
-- and is not one of our own names, is taint we caused, named by variable.
--
-- That is a claim about the scanner, so it gets a positive control: `chatopen`
-- does the one thing known to break A and B. If the scan cannot see that, a clean
-- scan for PlaceAction proves nothing.

local function ours(name)
	name = tostring(name)
	return name:find("WowCompanion", 1, true) or name:find("WOWCOMPANION", 1, true)
end

-- The scan asks about some 265,000 variables, about 300 ms in one go: a frame the
-- player sees freeze. So it is spread over frames, at most BUDGET_MS of each, and
-- done(tainted, checked) is called when it has asked about every one. The names
-- are taken first (one pass over _G, and over a table's fields when it is reached),
-- since a table must not be walked across frames while others add to it.
local BUDGET_MS = 2
local scanner = CreateFrame("Frame")
local scans = {}
local function startScan(scan)
	local names = {}
	for name, value in pairs(_G) do
		if type(name) == "string" and not ours(name) then names[#names + 1] = name end
	end
	scan.names, scan.at, scan.fields, scan.f = names, 0, nil, 0
end
-- one variable asked about; false when the scan is through
local function step(scan)
	local fields = scan.fields
	if fields and scan.f < #fields then
		scan.f = scan.f + 1
		local field = fields[scan.f]
		local ok, secure, by = pcall(issecurevariable, scan.table, field)
		scan.checked = scan.checked + 1
		if ok and not secure then scan.tainted[scan.name .. "." .. field] = tostring(by) end
		return true
	end
	scan.at = scan.at + 1
	local name = scan.names[scan.at]
	if not name then return false end
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
				if type(field) == "string" and not ours(field) then list[#list + 1] = field end
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

local PLACE_MACRO = "WCPLACE"

local function placeMacro()
	local index = GetMacroIndexByName(PLACE_MACRO)
	if index and index > 0 then
		return index
	end
	return CreateMacro(PLACE_MACRO, "INV_MISC_QUESTIONMARK", "/wc ping", false)
end

-- chosen fresh each run, so each variant reports exactly where it acted
local function pickSlots()
	local frames = actionFrames()
	local picked = {}
	for slot = 1, WC.Chords.LAST_ACTION_SLOT do
		local drawn = frames[slot] and frames[slot].visible
		if not slotHas(slot) then
			if drawn and not picked.emptyVisible then
				picked.emptyVisible = slot
			elseif not frames[slot] and slot <= 120 and not picked.emptyHidden then
				picked.emptyHidden = slot
			end
		elseif drawn and not picked.filledVisible then
			picked.filledVisible = slot
		end
	end
	return picked
end

local placeVariants = {}

placeVariants.none = function()
	return "did nothing: the scan's own noise floor"
end

placeVariants.chatopen = function()
	local open = ChatFrame_OpenChat or (ChatFrameUtil and ChatFrameUtil.OpenChat)
	if not open then
		return "no chat opener on this client"
	end
	-- deferred a tick, as the slash-command path requires, then closed again so the
	-- only thing measured is having opened it
	C_Timer.After(0.1, function()
		open("")
		C_Timer.After(0.1, function()
			local box = activeEditBox()
			if box and ChatEdit_DeactivateChat then
				pcall(ChatEdit_DeactivateChat, box)
			end
		end)
	end)
	return "opened and closed the chat box from addon code (the known-bad control)"
end

placeVariants.pickup = function()
	PickupMacro(placeMacro())
	ClearCursor()
	return "picked up the test macro and cleared the cursor, placing nothing"
end

local function placeInto(slot, how)
	PickupMacro(placeMacro())
	if how == "put" then
		C_ActionBar.PutActionInSlot(slot)
	else
		PlaceAction(slot)
	end
	ClearCursor()
	local kind, id = GetActionInfo(slot)
	return ("slot %d now holds %s %s"):format(slot, tostring(kind), tostring(id))
end

placeVariants.hidden = function(slots)
	if not slots.emptyHidden then
		return "no empty undrawn slot"
	end
	return "PlaceAction into an undrawn slot: " .. placeInto(slots.emptyHidden, "place")
end

placeVariants.visible = function(slots)
	if not slots.emptyVisible then
		return "no empty drawn slot"
	end
	return "PlaceAction into a drawn slot: " .. placeInto(slots.emptyVisible, "place")
end

placeVariants.put = function(slots)
	if not (C_ActionBar and C_ActionBar.PutActionInSlot) then
		return "no C_ActionBar.PutActionInSlot"
	end
	if not slots.emptyVisible then
		return "no empty drawn slot"
	end
	return "PutActionInSlot into a drawn slot: " .. placeInto(slots.emptyVisible, "put")
end

-- A real rearrangement that undoes itself: a filled, drawn slot moves to an empty
-- undrawn one and back. The bars end where they started, but every call a
-- rearrangement needs has run, including holding a live action on the cursor.
placeVariants.move = function(slots)
	local from, to = slots.filledVisible, slots.emptyHidden
	if not (from and to) then
		return "need a filled drawn slot and an empty undrawn one"
	end
	local was, wasId = GetActionInfo(from)
	PickupAction(from)
	PlaceAction(to)
	PickupAction(to)
	PlaceAction(from)
	ClearCursor()
	local now, nowId = GetActionInfo(from)
	return ("moved slot %d to %d and back: holds %s %s, held %s %s"):format(from, to,
		tostring(now), tostring(nowId), tostring(was), tostring(wasId))
end

placeVariants.clean = function()
	local removed = 0
	local index = GetMacroIndexByName(PLACE_MACRO)
	if index and index > 0 then
		for slot = 1, WC.Chords.LAST_ACTION_SLOT do
			local ok, kind, id = pcall(GetActionInfo, slot)
			if ok and kind == "macro" and id == index then
				PickupAction(slot)
				ClearCursor()
				removed = removed + 1
			end
		end
		DeleteMacro(index)
	end
	return ("removed the test macro from %d slot(s) and deleted it"):format(removed)
end

local PLACE_ORDER = { "none", "chatopen", "pickup", "hidden", "visible", "put", "move", "clean" }

-- One per UI session. Taint lasts until /reload, so a second test inherits the
-- first one's damage and the hand check cannot tell them apart.
local placeRan
-- the test in flight, so a blocked-action notice can be pinned to it
local placeEntry

-- "Interface action failed because of an AddOn" is shown by this function, and it
-- fires even when ADDON_ACTION_BLOCKED does not reach us. hooksecurefunc runs after
-- the original without tainting it. Every hit is kept with its time, so the hand
-- check stops being the only witness.
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
		if placeEntry then
			placeEntry.notices = (placeEntry.notices or 0) + 1
		end
		-- the window's log must never break this hook
		pcall(remember, "probe", "interface action failed notice at " .. stamp
			.. (placeEntry and (" during place " .. placeEntry.variant) or ""))
	end)
end

local function placeTest(variant)
	local act = placeVariants[variant]
	if not act then
		return "variants: " .. table.concat(PLACE_ORDER, ", ")
	end
	if InCombatLockdown() then
		return "refused: in combat"
	end
	if placeRan and variant ~= "clean" then
		return ("refused: %s already ran this session; /reload first"):format(placeRan)
	end
	placeRan = variant
	WowCompanionAgentDB.placeTests = WowCompanionAgentDB.placeTests or {}
	taintScan(function(before, checked)
		if InCombatLockdown() then
			remember("probe", ("place %s: refused, a fight began during the scan"):format(variant))
			return
		end
		local ok, result = pcall(act, pickSlots())
		if not ok then
			result = "error: " .. tostring(result)
		end
		local entry = { at = time(), variant = variant, result = result, checked = checked }
		placeEntry = entry
		table.insert(WowCompanionAgentDB.placeTests, entry)
		remember("probe", ("place %s: %s"):format(variant, tostring(result)))
		-- long enough for whatever the action set off to have run: events, OnUpdate,
		-- the deferred chat open
		C_Timer.After(1.5, function() taintScan(function(after)
			local new = fresh(before, after)
			entry.tainted = #new
			entry.taint = #new == 0 and "none" or table.concat(new, "; ")
			remember("probe", ("place %s: %d newly tainted of %d checked%s"):format(variant, #new,
				checked, #new > 0 and (": " .. table.concat(new, "; ", 1, math.min(#new, 6))) or ""))
			remember("probe", "now A on an NPC, B out of a menu; then /wc verdict ok or /wc verdict broken")
		end) end)
	end)
	return "scanning first; the result follows"
end

local function placeVerdict(word)
	local tests = WowCompanionAgentDB.placeTests
	local last = tests and tests[#tests]
	if not last then
		return "no place test to judge"
	end
	last.verdict = word
	remember("probe", ("place %s judged %s"):format(last.variant, word))
	return word
end


WC.Tests = WC.Tests or {}
WC.Tests.placeTest = placeTest
WC.Tests.placeVerdict = placeVerdict
WC.Tests.probeChat = probeChat
WC.Tests.probeMacro = probeMacro
WC.Tests.taintScan = taintScan
WC.Tests.fresh = fresh
