-- WowCompanion_Agent: name lookups and chord learning, as WC.Chords. The pad
-- itself is read by WowCompanion_Link (Pad.lua, WC.Pad).

-- Name lookups, asked rather than assumed.
--
-- This client is 1.60.1: not retail, and not any Classic we have a reference for.
-- GetSpellInfo has been removed, restored and reshaped across builds, so which of
-- these exists -- and whether it returns a string or a table -- is a runtime
-- question. Each is tried in turn and the first that answers wins.
local function spellName(id)
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, id)
		if ok and type(info) == "table" and info.name then
			return info.name
		end
	end
	return nil
end

local function itemName(id)
	if C_Item and C_Item.GetItemInfo then
		local ok, name = pcall(C_Item.GetItemInfo, id)
		if ok and type(name) == "string" then
			return name
		end
	end
	return nil
end

-- The action slot space is not 1..120 on this client. The classic bars use the
-- low numbers, but the gamepad UI draws 181..272 (top 181-184, left 185-192, right
-- 193-200, bottom 201-208, stance 265-272) and the extra action button sits at 397.
-- Measured from the live UI. Scan well past that; an invalid slot just errors.
local LAST_ACTION_SLOT = 1024

local function slotHas(slot)
	local ok, has = pcall(HasAction, slot)
	return ok and has
end

-- "GamepadMainActionBarFramePageUnitLeftCenteredAnchorLeftBarActionButton3" -> "LeftBar 3"
local function barLabel(name)
	return (tostring(name):gsub("^GamepadMainActionBarFramePageUnit", "")
		:gsub("^%a-CenteredAnchor", ""):gsub("ActionButton(%d+)$", " %1"))
end

-- Which chord fires which button.
--
-- Not in the bindings: GetBindingKey("ACTIONBUTTON189") is empty for every gamepad
-- button, and no frame field names the trigger. What is measurable is each button's
-- icon -- its SlotArt atlas names the base input, the same eight on every bar
-- (1-4 the d-pad left, up, right, down; 5-8 the face buttons) -- and, by watching,
-- which modifiers are held when a button goes into its pushed state. So the base
-- comes from the art and the modifier is learned from play, keyed by bar position
-- rather than slot, because forms and stances page the slots under the same buttons.
local GAMEPAD_BARS = {
	{ "TopCenteredAnchorTopBar", 4 },
	{ "LeftCenteredAnchorLeftBar", 8 },
	{ "RightCenteredAnchorRightBar", 8 },
	{ "BottomCenteredAnchorBottomBar", 8 },
	{ "TopCenteredAnchorStanceBar", 8 },
}
local ART_INPUT = {
	dpadleft = "left", dpadup = "up", dpadright = "right", dpaddown = "down",
	["ps%-square"] = "square", ["ps%-triangle"] = "triangle",
	["ps%-circle"] = "circle", ["ps%-cross"] = "cross",
}

-- { frame, label = "LeftBar 3", bar = "LeftBar", base = "right" } for each button
local padButtons
local function gamepadButtons()
	if padButtons then
		return padButtons
	end
	padButtons = {}
	for _, bar in ipairs(GAMEPAD_BARS) do
		for i = 1, bar[2] do
			local name = "GamepadMainActionBarFramePageUnit" .. bar[1] .. "ActionButton" .. i
			local button = _G[name]
			if button then
				local art = button.SlotArt and button.SlotArt.GetAtlas and button.SlotArt:GetAtlas() or ""
				local base
				for pattern, input in pairs(ART_INPUT) do
					if art:find(pattern) then
						base = input
					end
				end
				local label = barLabel(name)
				padButtons[#padButtons + 1] = {
					frame = button, label = label, bar = label:gsub(" %d+$", ""), base = base,
				}
			end
		end
	end
	return padButtons
end

local function padState() return WC.Pad.State() end

-- WowCompanionAgentDB.chords[bar] = { [modifier] = presses }. chordStats counts every
-- d-pad or face press and how many lit an action button within a few frames: if
-- "lit" stays at zero, the pushed state is the wrong signal, and the export says so
-- instead of quietly learning nothing.
local CHORD_WINDOW = 0.25

-- The first learner read every button one place off (see padState). Its record is
-- still good once renamed: what it called R2 was L2, and PADLSTICKUP was R2.
local function fixFirstChords()
	if not WowCompanionAgentDB.chords or WowCompanionAgentDB.chordsFixed then
		WowCompanionAgentDB.chordsFixed = true
		return
	end
	local renamed = { PADRTRIGGER = "PADLTRIGGER", PADLSTICKUP = "PADRTRIGGER" }
	for bar, seen in pairs(WowCompanionAgentDB.chords) do
		local fixed = {}
		for chord, count in pairs(seen) do
			local parts = {}
			for part in chord:gmatch("[^+]+") do
				parts[#parts + 1] = renamed[part] or part
			end
			table.sort(parts)
			local key = table.concat(parts, "+")
			fixed[key] = (fixed[key] or 0) + count
		end
		WowCompanionAgentDB.chords[bar] = fixed
	end
	WowCompanionAgentDB.chordsFixed = true
end

-- every pushed button the UI has, by name: what lit when none of ours did
local function pushedElsewhere()
	local found = {}
	local frame, walked = EnumerateFrames(), 0
	while frame and walked < 50000 and #found < 4 do
		walked = walked + 1
		if frame.GetButtonState then
			local ok, state = pcall(frame.GetButtonState, frame)
			if ok and state == "PUSHED" then
				local named = frame.GetName and frame:GetName()
				found[#found + 1] = ("%s (action %s)"):format(tostring(named or frame:GetDebugName()), tostring(frame.action))
			end
		end
		frame = EnumerateFrames(frame)
	end
	return #found > 0 and table.concat(found, ", ") or "nothing pushed"
end

-- the presses that taught nothing, newest last, so the next reload shows why
local function missedChord(press)
	-- a face button alone is jump or interact, never a bar; twenty jumps would
	-- push out the one miss worth reading
	if press.chord == "none" and tostring(press.base):find("^PAD%d") then
		return
	end
	WowCompanionAgentDB.chordMisses = WowCompanionAgentDB.chordMisses or {}
	local misses = WowCompanionAgentDB.chordMisses
	local form = GetShapeshiftForm and GetShapeshiftForm() or "?"
	misses[#misses + 1] = ("%s + %s, form %s, page %s: %s"):format(press.chord, press.base,
		tostring(form), tostring(C_ActionBar and C_ActionBar.GetActionBarPage and C_ActionBar.GetActionBarPage()),
		press.scanned or "not scanned")
	while #misses > 20 do
		table.remove(misses, 1)
	end
end

local function learnChords()
	fixFirstChords()
	local watcher = CreateFrame("Frame")
	local was, wasBase = {}, {}
	local pending -- the modifiers of the last base press, until a button lights or it expires
	watcher:SetScript("OnUpdate", function()
		local modifiers, bases = padState()
		if not modifiers then
			return
		end
		WowCompanionAgentDB.chordStats = WowCompanionAgentDB.chordStats or { presses = 0, lit = 0 }
		local stats = WowCompanionAgentDB.chordStats
		for name in pairs(bases) do
			if not wasBase[name] then
				stats.presses = stats.presses + 1
				pending = {
					chord = #modifiers > 0 and table.concat(modifiers, "+") or "none",
					base = name, at = GetTime(), frames = 0,
				}
			end
		end
		wasBase = bases
		if pending then
			pending.frames = pending.frames + 1
			-- two frames and none of our buttons lit: look at everything once, while
			-- whatever did light is still held down
			-- (13,000 frames is a visible hitch; never in combat, and a jump is a miss too)
			if pending.frames == 3 and not pending.scanned and not InCombatLockdown() then
				pending.scanned = pushedElsewhere()
			end
			if GetTime() - pending.at > CHORD_WINDOW then
				missedChord(pending)
				pending = nil
			end
		end
		for _, entry in ipairs(gamepadButtons()) do
			local ok, state = pcall(entry.frame.GetButtonState, entry.frame)
			local pushed = ok and state == "PUSHED"
			if pushed and not was[entry.label] and pending then
				stats.lit = stats.lit + 1
				WowCompanionAgentDB.chords = WowCompanionAgentDB.chords or {}
				local bar = WowCompanionAgentDB.chords[entry.bar] or {}
				bar[pending.chord] = (bar[pending.chord] or 0) + 1
				WowCompanionAgentDB.chords[entry.bar] = bar
				pending = nil
			end
			was[entry.label] = pushed
		end
	end)
end

-- "L2+R2" from "PADLTRIGGER+PADRTRIGGER": the words the player says
local PAD_WORDS = {
	PADLTRIGGER = "L2", PADRTRIGGER = "R2", PADLSHOULDER = "L1", PADRSHOULDER = "R1",
	PADLSTICK = "L3", PADRSTICK = "R3",
}
local function spoken(chord)
	if chord == "none" then
		return "no modifier"
	end
	return (chord:gsub("PAD%u+", function(name) return PAD_WORDS[name] or name end))
end

-- bar -> modifier words, from the most-seen chord, or nil while none is learned
local function barModifier(bar)
	local seen = WowCompanionAgentDB.chords and WowCompanionAgentDB.chords[bar]
	if not seen then
		return nil
	end
	local best, most = nil, 0
	for chord, count in pairs(seen) do
		if count > most then
			best, most = chord, count
		end
	end
	return best and spoken(best), most
end

-- "L2+R2 + right", or "? + right" while the bar's modifier is unlearned
local function chordFor(label)
	for _, entry in ipairs(gamepadButtons()) do
		if entry.label == label then
			local modifier = barModifier(entry.bar)
			if modifier == "no modifier" then
				return entry.base or "?"
			end
			return ("%s + %s"):format(modifier or "?", entry.base or "?")
		end
	end
	return nil
end

-- slot -> { visible = bool, label = "LeftBar 3" } for every slot some frame draws.
-- The label is the first visible frame's, since several frames (edit mode, the
-- hidden classic bars) can point at the same slot.
local function actionFrames()
	local slots = {}
	if not EnumerateFrames then
		return slots
	end
	local frame, walked = EnumerateFrames(), 0
	while frame and walked < 50000 do
		walked = walked + 1
		local slot = type(frame.action) == "number" and frame.action or nil
		if not slot and frame.GetAttribute then
			local ok, value = pcall(frame.GetAttribute, frame, "action")
			if ok and type(value) == "number" then
				slot = value
			end
		end
		if slot and slot > 0 then
			local entry = slots[slot] or { visible = false }
			local shown = frame.IsVisible and frame:IsVisible() or false
			if shown and not entry.visible then
				entry.label = barLabel(frame.GetName and frame:GetName())
			end
			entry.visible = entry.visible or shown
			slots[slot] = entry
		end
		frame = EnumerateFrames(frame)
	end
	return slots
end

-- What the agent needs to know about this character, as one string.
--
-- The same shape as dumpApi and for the same reason: the helper has no Lua parser,
-- so one string it can slice out of SavedVariables beats a nested table. Sections
-- are marked "== name ==" so either side can take just the part it needs -- the
-- whole thing is too big for every prompt, but "macros" or "action slots" is not.
--
-- Two sections answer open questions rather than feed the agent. "action buttons on
-- screen" walks every frame in the UI looking for one bound to an action slot,
-- which is how we learn which of the flat 1..120 space the gamepad UI actually
-- draws -- measured from the live UI instead of guessed from the classic bar
-- layout. "bindings" is the other half: what the controller can already press, and
-- therefore what is left for us.
-- Every spell the player can cast, and where each one can be pressed.
--
-- The spellbook lists what it shows in the form you are in: Feral Charge reads
-- "(Bear)" out of form and is a different spell in cat, and a layout designed from
-- one export left the cat one off the bars. So each walk records what every entry
-- turns into in the current form (its override, and the name the book shows), and
-- keeps the union across forms in SavedVariables, refreshed whenever the form
-- changes. A flyout ("Shapeshift") is opened up into its spells. The reach section
-- then checks each castable one against the bar pages, wheels and macros, so a
-- spell nothing can press is listed by name instead of quietly missing.
local function bookEntries()
	local found = {}
	if not (C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines) then
		return found
	end
	local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
	local flyoutType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Flyout
	for tab = 1, C_SpellBook.GetNumSpellBookSkillLines() do
		local info = C_SpellBook.GetSpellBookSkillLineInfo(tab)
		local offset = info and info.itemIndexOffset or 0
		for at = offset + 1, offset + (info and info.numSpellBookItems or 0) do
			local item = C_SpellBook.GetSpellBookItemInfo(at, bank)
			if item and item.name then
				if flyoutType and item.itemType == flyoutType and GetFlyoutInfo and GetFlyoutSlotInfo then
					-- called the way Blizzard's SpellFlyout.lua calls them
					local _, _, numSlots = GetFlyoutInfo(item.actionID)
					for i = 1, numSlots or 0 do
						local spellID, overrideID, known, name = GetFlyoutSlotInfo(item.actionID, i)
						if spellID and known then
							found[#found + 1] = { id = spellID, override = overrideID,
								name = name or spellName(spellID), flyout = item.name }
						end
					end
				elseif item.spellID then
					found[#found + 1] = { id = item.spellID, name = item.name, passive = item.isPassive or nil }
				end
			end
		end
	end
	return found
end


WC.Chords = WC.Chords or {}
WC.Chords.GAMEPAD_BARS = GAMEPAD_BARS
WC.Chords.LAST_ACTION_SLOT = LAST_ACTION_SLOT
WC.Chords.PAD_WORDS = PAD_WORDS
WC.Chords.barLabel = barLabel
WC.Chords.barModifier = barModifier
WC.Chords.bookEntries = bookEntries
WC.Chords.chordFor = chordFor
WC.Chords.actionFrames = actionFrames
WC.Chords.itemName = itemName
WC.Chords.learnChords = learnChords
WC.Chords.slotHas = slotHas
WC.Chords.spellName = spellName
WC.Chords.spoken = spoken
