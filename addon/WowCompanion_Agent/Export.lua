-- What the bags hold, one line per item (stacks summed), for the export and for
-- an on-demand read (WowCompanion_Strip.Send(WowCompanion_BagText(), 30)).
function WowCompanion_BagLines()
	local out, seen, order = {}, {}, {}
	out[1] = "-- item (id) xcount @bag:slot..., flags: quest, spare bag, grey (junk), soulbound"
	for bag = 0, 4 do
		for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.itemID then
				local e = seen[info.itemID]
				if not e then
					e = { id = info.itemID, name = info.itemName, n = 0, at = {}, flags = {} }
					local _, _, _, loc, _, class = C_Item.GetItemInfoInstant(info.itemID)
					local q = C_Container.GetContainerItemQuestInfo(bag, slot)
					if q and (q.isQuestItem or q.questID) then e.flags[#e.flags + 1] = "quest" end
					if class == 1 and loc == "INVTYPE_BAG" then e.flags[#e.flags + 1] = "spare bag" end
					if info.quality == 0 then e.flags[#e.flags + 1] = "grey" end
					if info.isBound then e.flags[#e.flags + 1] = "soulbound" end
					seen[info.itemID] = e
					order[#order + 1] = e
				end
				e.n = e.n + (info.stackCount or 1)
				e.at[#e.at + 1] = bag .. ":" .. slot
			end
		end
	end
	for _, e in ipairs(order) do
		out[#out + 1] = ("%s (%d) x%d @%s%s"):format(e.name or C_Item.GetItemInfo(e.id) or "?", e.id, e.n,
			table.concat(e.at, ","), #e.flags > 0 and (", " .. table.concat(e.flags, ", ")) or "")
	end
	if #order == 0 then out[#out + 1] = "(empty)" end
	return out
end
function WowCompanion_BagText() return table.concat(WowCompanion_BagLines(), "\n") end

-- the character's forms or stances, from the game (none for most classes):
-- names in bar order, and a set of the names
local function shapeshiftForms()
	local names, set = {}, {}
	for i = 1, (GetNumShapeshiftForms and GetNumShapeshiftForms() or 0) do
		local _, _, _, spellID = GetShapeshiftFormInfo(i)
		local info = spellID and C_Spell.GetSpellInfo(spellID)
		if info and info.name then names[#names + 1] = info.name set[info.name] = true end
	end
	return names, set
end

-- The context export: what the agent
-- reads after every reload, written into SavedVariables at logout, and the form
-- notes it rests on. It reads Chords, Probes and Companion through their named
-- functions; Agent.lua calls WC.Export.Context() / WC.Export.NoteForms().

local chords = WC.Chords
local GAMEPAD_BARS = chords.GAMEPAD_BARS
local LAST_ACTION_SLOT = chords.LAST_ACTION_SLOT
local PAD_WORDS = chords.PAD_WORDS
local actionFrames = chords.actionFrames
local barLabel = chords.barLabel
local barModifier = chords.barModifier
local bookEntries = chords.bookEntries
local chordFor = chords.chordFor
local itemName = chords.itemName
local slotHas = chords.slotHas
local spellName = chords.spellName
local cvar = WC.Probes.cvar
local effectiveModules = WC.Companion.modules

local function noteForms()
	if InCombatLockdown() then
		return
	end
	WowCompanionAgentDB.spellForms = WowCompanionAgentDB.spellForms or {}
	local store = WowCompanionAgentDB.spellForms
	local form = tostring(GetShapeshiftForm and GetShapeshiftForm() or 0)
	for _, entry in ipairs(bookEntries()) do
		local key = tostring(entry.id)
		local known = store[key] or { forms = {} }
		known.name = known.name or entry.name
		known.passive = entry.passive
		known.flyout = entry.flyout
		local override = entry.override
		if (not override or override == 0) and C_Spell and C_Spell.GetOverrideSpell then
			local ok, id = pcall(C_Spell.GetOverrideSpell, entry.id)
			override = ok and id or nil
		end
		local shown = entry.name
		if override and override ~= 0 and override ~= entry.id then
			shown = spellName(override) or shown
		else
			override = nil
		end
		known.forms[form] = { id = override or entry.id, name = shown }
		store[key] = known
	end
end

local function trim(text)
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function reachLines(line, frames)
	pcall(noteForms)
	local store = WowCompanionAgentDB.spellForms or {}
	local where = {}
	local function reach(name, place)
		if type(name) == "string" and name ~= "" then
			local key = name:lower()
			where[key] = where[key] or place
		end
	end
	-- a slot counts if it is drawn now or sits on a gamepad bar or form page
	local function pageOf(slot)
		local drawn = frames and frames[slot]
		if drawn and drawn.visible then
			return tostring(drawn.label)
		end
		if (slot >= 181 and slot <= 208) or (slot >= 265 and slot <= 288) then
			return "slot " .. slot .. " (form page)"
		end
	end
	local function fromMacroBody(body, place)
		for verb, rest in (body or ""):gmatch("/(%a+)%s+([^\n]+)") do
			verb = verb:lower()
			if verb == "cast" or verb == "use" or verb == "castsequence" then
				rest = rest:gsub("%b[]", "")
				for name in rest:gmatch("[^,;]+") do
					name = trim(name):gsub("^reset=%S+%s*", ""):gsub("^!", "")
					reach(trim(name), place)
				end
			end
		end
	end
	for slot = 1, LAST_ACTION_SLOT do
		local place = pageOf(slot)
		if place and HasAction(slot) then
			local kind, id = GetActionInfo(slot)
			if kind == "spell" then
				local held = spellName(id)
				reach(held, place)
				-- a slot holding the base spell fires its form's version too. The slot
				-- reports whichever version the current form shows, so "Feral Charge"
				-- (1238122) in caster is "Feral Charge (Cat)" (414924) in cat: match on
				-- the shared base spell, or on the name with a "(Form)" suffix
				local function baseOf(spell)
					local ok, base = pcall(C_SpellBook.FindBaseSpellByID, spell)
					return ok and base or spell
				end
				local heldBase = C_SpellBook and C_SpellBook.FindBaseSpellByID and baseOf(id) or id
				-- in cat the slot reads "Feral Charge (Cat)"; its bear twin shares the stem
				local stem = held and held:gsub("%s*%b()$", "")
				local prefix = stem and (stem:lower() .. " (")
				for key, known in pairs(store) do
					local match = tonumber(key) == id
					for _, variant in pairs(known.forms or {}) do
						if variant.id == id then match = true end
						if variant.id and C_SpellBook and C_SpellBook.FindBaseSpellByID
							and baseOf(variant.id) == heldBase then
							match = true
						end
						if prefix and type(variant.name) == "string"
							and variant.name:lower():sub(1, #prefix) == prefix then
							match = true
						end
					end
					if match then
						for _, variant in pairs(known.forms or {}) do
							reach(variant.name, place)
						end
					end
				end
			elseif kind == "macro" then
				-- a macro with #showtooltip reports its spell's ID here, not its
				-- index, so find it by the name the slot shows
				-- and that spell is what the macro casts now, so it counts as reached
				if id and spellName(id) then
					reach(spellName(id), place .. " via macro")
				end
				local index = id
				local named = GetActionText and GetActionText(slot)
				if named and GetMacroIndexByName then
					local found = GetMacroIndexByName(named)
					if found and found > 0 then index = found end
				end
				local _, _, body = GetMacroInfo(index)
				fromMacroBody(body, place .. " via macro")
			end
		end
	end
	local wheels = WowCompanionWheelDB and WowCompanionWheelDB.wheels or {}
	for wheel, def in pairs(wheels) do
		for _, slot in ipairs(def.slots or {}) do
			if slot.spell then
				local name = tonumber(slot.spell) and spellName(tonumber(slot.spell)) or tostring(slot.spell)
				reach(name, "wheel " .. wheel)
			elseif slot.macro then
				local _, _, body = GetMacroInfo(slot.macro)
				fromMacroBody(body, "wheel " .. wheel .. " via macro")
			elseif slot.macrotext then
				fromMacroBody(slot.macrotext, "wheel " .. wheel)
			end
		end
	end

	local keys = {}
	for key in pairs(store) do keys[#keys + 1] = key end
	table.sort(keys, function(a, b) return (store[a].name or "") < (store[b].name or "") end)
	local rows, missing, done, formsSeen = {}, {}, {}, {}
	for _, key in ipairs(keys) do
		local known = store[key]
		local variants = {}
		for form, variant in pairs(known.forms or {}) do
			formsSeen[form] = true
			variants[#variants + 1] = ("form %s: %s (%s)"):format(form, variant.name, tostring(variant.id))
		end
		table.sort(variants)
		if not known.passive then
			local names = {}
			for _, variant in pairs(known.forms or {}) do
				if not done[variant.name] then
					done[variant.name] = true
					names[#names + 1] = variant.name
				end
			end
			table.sort(names)
			for _, name in ipairs(names) do
				local at = where[name:lower()]
				if not at and (known.flyout or select(2, shapeshiftForms())[name]) then
					at = "the game's stance/form bar (where the player changes it is in their profile)"
				end
				rows[#rows + 1] = ("%s: %s%s"):format(name, at or "NOT REACHABLE",
					#variants > 1 and ("  [" .. table.concat(variants, "; ") .. "]") or "")
				if not at then
					missing[#missing + 1] = name
				end
			end
		end
	end
	local list = {}
	for form in pairs(formsSeen) do list[#list + 1] = form end
	table.sort(list)
	line("-- every castable spell (passives left out) and what presses it. Spells turn")
	line("-- into other spells in a form, and the book shows only the current form's,")
	line("-- so this is the union over forms recorded so far: " .. table.concat(list, ", ")
		.. " (0 is caster); a form not listed has not been entered since this began.")
	line("-- A layout must give every line a place: a bar slot, a wheel, or a macro.")
	for _, row in ipairs(rows) do
		line(row)
	end
	line(("-- %d not reachable%s"):format(#missing,
		#missing > 0 and (": " .. table.concat(missing, ", ")) or ""))
end

local function exportContext()
	local newline = string.char(10)
	local out = {}
	local function line(text)
		out[#out + 1] = text
	end
	-- Every section, and every part of one, runs through part(): a failure is
	-- written where the data would have been and kept in exportFailures (the
	-- Status tab shows them), never swallowed. A reader that gets nothing where
	-- the game must answer raises, rather than writing that nothing as data.
	-- A reader that proves the game has let go of the character (at a quit the
	-- export runs after it has: equipped, money and bars all read empty) raises
	-- { released = why }; the export then keeps the last one written while the
	-- character was there, with a line saying so, instead of a blank one.
	local failures, current, released = {}, "header", nil
	local function part(fn, ...)
		local ok, why = pcall(fn, ...)
		if not ok then
			if type(why) == "table" and why.released then
				released = released or (current .. ": " .. why.released)
				why = why.released
			end
			why = tostring(why)
			line("-- FAILED, this part is missing: " .. why)
			failures[#failures + 1] = current .. ": " .. why
		end
		return ok
	end
	local function section(name, fn)
		current = name
		line("")
		line("== " .. name .. " ==")
		part(fn)
	end

	local version, build = GetBuildInfo()
	line(("-- WowCompanion context, %s, client %s build %s")
		:format(date("%Y-%m-%d %H:%M:%S"), tostring(version), tostring(build)))

	section("character", function()
		line(("name: %s"):format(tostring(UnitName("player"))))
		line(("level: %s"):format(tostring(UnitLevel("player"))))
		line(("class: %s"):format(tostring(UnitClass("player"))))
		line(("race: %s"):format(tostring(UnitRace("player"))))
		line(("faction: %s"):format(tostring(UnitFactionGroup("player"))))
		if GetSpecialization and GetSpecializationInfo then
			local index = GetSpecialization()
			if index then
				local _, specName = GetSpecializationInfo(index)
				line(("spec: %s"):format(tostring(specName)))
			end
		end
		if GetMoney then
			line(("copper: %s"):format(tostring(GetMoney())))
		end
		-- The facts advice rests on, so it never suggests an off-hand beside a
		-- two-hander, a pouch already worn, or a profession already known.
		part(function()
			local xp, xpMax = UnitXP("player"), UnitXPMax("player")
			local rested = GetXPExhaustion and GetXPExhaustion()
			line(("xp: %s / %s%s"):format(tostring(xp), tostring(xpMax), rested and (", rested " .. rested) or ""))
			local zone, sub = GetRealZoneText and GetRealZoneText(), GetSubZoneText and GetSubZoneText()
			line(("zone: %s%s"):format(tostring(zone), (sub and sub ~= "" and sub ~= zone) and (" / " .. sub) or ""))
		end)
		part(function()
			-- the character's own watch list (WowCompanion_Buffs), empty until asked for
			if not WC.BuffWatch then
				line("buffs watched: the WowCompanion_Buffs addon is not loaded")
				return
			end
			local watched = WC.BuffWatch.List()
			if #watched == 0 then
				line("buffs watched: none (set with WowCompanion_WatchBuffs when the player asks)")
			else
				local missing = WC.BuffWatch.Missing()
				line(("buffs watched: %s; missing at export: %s"):format(table.concat(watched, ", "),
					#missing > 0 and table.concat(missing, ", ") or "none"))
			end
		end)

	end)

	section("equipped", function()
		line("-- inventory slot: item. A two-hand weapon in 16 means 17 cannot hold anything")
		part(function()
			local SLOTS = { [1] = "head", [2] = "neck", [3] = "shoulder", [4] = "shirt", [5] = "chest",
				[6] = "waist", [7] = "legs", [8] = "feet", [9] = "wrist", [10] = "hands", [11] = "finger1",
				[12] = "finger2", [13] = "trinket1", [14] = "trinket2", [15] = "back", [16] = "main hand",
				[17] = "off hand", [18] = "ranged", [19] = "tabard" }
			for slot = 1, 19 do
				local link = GetInventoryItemLink("player", slot)
				local text = "empty"
				if link then
					local name, _, quality, ilvl, _, _, _, _, equipLoc = C_Item.GetItemInfo(link)
					local id = C_Item.GetItemInfoInstant(link)
					text = ("%s (%s) ilvl %s%s"):format(name or link:match("%[(.-)%]") or "?", tostring(id),
						tostring(ilvl), equipLoc == "INVTYPE_2HWEAPON" and ", TWO-HAND" or "")
					local cur, max = GetInventoryItemDurability(slot)
					if cur and max and max > 0 then text = text .. (", durability %d/%d"):format(cur, max) end
				end
				line(("%2d %s: %s"):format(slot, SLOTS[slot], text))
			end
		end)

	end)

	section("bags", function()
		line("-- bag: name, slots, free. Bag 0 is the backpack; a bag item inside a bag is a spare")
		part(function()
			for bag = 0, 4 do
				local slots = C_Container.GetContainerNumSlots(bag) or 0
			if bag == 0 and slots == 0 then
				error({ released = "the backpack reports no slots" })
			end
				local free = C_Container.GetContainerNumFreeSlots(bag) or 0
				local name = C_Container.GetBagName(bag)
				line(("%d: %s, %d slots, %d free"):format(bag, slots > 0 and (name or "?") or "EMPTY BAG SLOT", slots, free))
			end
		end)

	end)

	section("bag contents", function()
		part(function()
			for _, l in ipairs(WowCompanion_BagLines()) do line(l) end
		end)

	end)

	section("skills", function()
		line("-- professions and secondary skills, rank / max")
		part(function()
			local any = false
			if GetProfessions and GetProfessionInfo then
				local profs = { GetProfessions() }
				for i = 1, 5 do
					local index = profs[i]
					if index then
						local name, _, rank, maxRank = GetProfessionInfo(index)
						if name then any = true line(("%s %s/%s"):format(name, tostring(rank), tostring(maxRank))) end
					end
				end
			end
			if not any and C_SkillInfo and C_SkillInfo.GetNumSkillLines and C_SkillInfo.GetSkillLineInfo then
				for i = 1, C_SkillInfo.GetNumSkillLines() or 0 do
					local info = C_SkillInfo.GetSkillLineInfo(i)
					if info and not info.isHeader and info.name then
						any = true
						line(("%s %s/%s"):format(info.name, tostring(info.rank), tostring(info.maxRank)))
					end
				end
			end
			if not any then line("-- none read: ask with a lua step before claiming they lack one") end
		end)

	end)

	section("quest log", function()
		line("-- id: title [level] (done), then objectives")
		part(function()
			for i = 1, C_QuestLog.GetNumQuestLogEntries() or 0 do
				local info = C_QuestLog.GetInfo(i)
				if info and not info.isHeader and info.questID then
					local done = C_QuestLog.IsComplete(info.questID)
					line(("%d: %s [%s]%s"):format(info.questID, tostring(info.title), tostring(info.level),
						done and " (done: turn it in)" or ""))
					if not done then
						for _, o in ipairs(C_QuestLog.GetQuestObjectives(info.questID) or {}) do
							if o.text and not o.finished then line("    " .. o.text) end
						end
					end
				end
			end
		end)

	end)

	section("action slots", function()
		line("-- addressed by number; empty slots omitted. 'on screen' names the bar that")
		line("-- draws it now; anything without it is stored but not shown")
		if HasAction and GetActionInfo then
			local frames = actionFrames()
			local filled = 0
			for slot = 1, LAST_ACTION_SLOT do
				if slotHas(slot) then
					filled = filled + 1
					local kind, id, subType = GetActionInfo(slot)
					local what
					if kind == "spell" then
						what = ("spell %s (%s)"):format(tostring(id), tostring(spellName(id) or "?"))
					elseif kind == "macro" then
						local name = GetMacroInfo and GetMacroInfo(id)
						if not name and GetActionText then
							name = GetActionText(slot)
						end
						what = ("macro %s (%s)"):format(tostring(id), tostring(name or "?"))
					elseif kind == "item" then
						what = ("item %s (%s)"):format(tostring(id), tostring(itemName(id) or "?"))
					else
						what = ("%s %s"):format(tostring(kind), tostring(id))
					end
					if subType and subType ~= "" then
						what = what .. " [" .. tostring(subType) .. "]"
					end
					local drawn = frames[slot]
					if drawn and drawn.visible then
						what = what .. " -- on screen: " .. tostring(drawn.label)
						local chord = chordFor(drawn.label)
						if chord then
							what = what .. " (" .. chord .. ")"
						end
					end
					line(("%3d: %s"):format(slot, what))
				end
			end
			line(("-- %d filled"):format(filled))

			section("empty slots on screen")
			line("-- where a new action can go and be seen")
			local open = {}
			for slot = 1, LAST_ACTION_SLOT do
				local drawn = frames[slot]
				if drawn and drawn.visible and not slotHas(slot) then
					local chord = chordFor(drawn.label)
					open[#open + 1] = ("%d (%s%s)"):format(slot, tostring(drawn.label),
						chord and (", " .. chord) or "")
				end
			end
			line(#open > 0 and table.concat(open, ", ") or "none")

			section("controller")
			line("-- the chord for each bar. Buttons 1-4 are the d-pad left, up, right, down;")
			line("-- 5-8 the face buttons square, triangle, circle, cross (from each button's")
			line("-- icon). The modifier is learned by watching which triggers are held when a")
			line("-- button fires; '?' means not seen yet, and is not to be guessed")
			for _, bar in ipairs(GAMEPAD_BARS) do
				local name = barLabel(bar[1] .. "ActionButton1"):gsub(" 1$", "")
				local modifier, presses = barModifier(name)
				line(("%s: %s"):format(name, modifier and ("%s (seen %d times)"):format(modifier, presses) or "?"))
			end
			-- Measured: the frames named StanceBar are not
			-- a bar of their own. They are the in-form page of whichever bar the
			-- GamepadStanceBarOverride setting names (here the R2 bar), which is why they
			-- learn the same chord.
			local formNames = shapeshiftForms()
			local byModifier = {}
			for _, bar in ipairs(GAMEPAD_BARS) do
				local name = barLabel(bar[1] .. "ActionButton1"):gsub(" 1$", "")
				local modifier = barModifier(name)
				if modifier then
					byModifier[modifier] = byModifier[modifier] or {}
					table.insert(byModifier[modifier], name)
				end
			end
			for modifier, names in pairs(byModifier) do
				if #names > 1 then
					line(("-- %s is shared by %s: StanceBar is that bar's page while in a form or stance"
						.. "%s; out of it it is the other"):format(modifier, table.concat(names, " and "),
						#formNames > 0 and (" (" .. table.concat(formNames, ", ") .. ")") or ""))
				end
			end
			if #formNames > 0 then
				local form = GetShapeshiftForm and GetShapeshiftForm() or 0
				line(("forms/stances: %s; at export: %s"):format(table.concat(formNames, ", "),
					form == 0 and "none" or (formNames[form] or tostring(form))))
				line(("GamepadStanceBarOverride: %s (the setting that picks which bar shows form actions)")
					:format(tostring(cvar("GamepadStanceBarOverride"))))
				line("-- changing form or stance: where the player does it is in their profile, never assumed")
			end
			local stats = WowCompanionAgentDB.chordStats
			if stats then
				line(("-- %d d-pad/face presses watched, %d lit a bar button"):format(stats.presses, stats.lit))
			end
			local misses = WowCompanionAgentDB.chordMisses
			if misses and #misses > 0 then
				line("-- presses that lit none of these bars, newest last:")
				for _, miss in ipairs(misses) do
					line("--   " .. (miss:gsub("PAD%u+", function(name) return PAD_WORDS[name] or name end)))
				end
			end
		else
			line("-- HasAction/GetActionInfo unavailable")
		end

	end)

	section("action buttons on screen", function()
		line("-- every frame bound to an action slot: which of the 120 the UI draws, and where")
		if EnumerateFrames then
			local seen, walked = {}, 0
			local frame = EnumerateFrames()
			while frame and walked < 50000 do
				walked = walked + 1
				local slot
				if type(frame.action) == "number" then
					slot = frame.action
				elseif frame.GetAttribute then
					local ok, value = pcall(frame.GetAttribute, frame, "action")
					if ok and type(value) == "number" then
						slot = value
					end
				end
				if slot then
					local name = frame.GetName and frame:GetName() or nil
					local shown = frame.IsVisible and frame:IsVisible()
					seen[#seen + 1] = ("%3d: %s%s"):format(slot,
						tostring(name or "(anonymous)"), shown and "" or " (hidden)")
				end
				frame = EnumerateFrames(frame)
			end
			table.sort(seen)
			for _, entry in ipairs(seen) do
				line(entry)
			end
			line(("-- %d action-bound frames out of %d walked"):format(#seen, walked))
		else
			line("-- EnumerateFrames unavailable")
		end

	end)

	section("bindings", function()
		line("-- what is already taken. PAD* are the controller's; those are the scarce ones")
		if GetNumBindings and GetBinding then
			local total = GetNumBindings()
			local bound = 0
			for index = 1, total do
				-- GetBinding's return shape differs between builds (some insert a
				-- category before the keys), so take everything after the command and
				-- report it rather than indexing positions we have not verified
				local bits = { GetBinding(index) }
				if index == 1 then
					line(("-- GetBinding returns %d values per binding"):format(#bits))
				end
				local keys = {}
				for at = 2, #bits do
					if type(bits[at]) == "string" and bits[at] ~= "" then
						keys[#keys + 1] = bits[at]
					end
				end
				if #keys > 0 then
					bound = bound + 1
					line(("%s = %s"):format(tostring(bits[1]), table.concat(keys, ", ")))
				end
			end
			line(("-- %d bound of %d bindings"):format(bound, total))
		else
			line("-- GetNumBindings/GetBinding unavailable")
		end

	end)

	section("macros", function()
		if GetNumMacros and GetMacroInfo then
			local global, perChar = GetNumMacros()
			line(("-- %s global, %s character"):format(tostring(global), tostring(perChar)))
			for index = 1, 200 do
				local name, _, body = GetMacroInfo(index)
				if name then
					line(("%d: %s"):format(index, name))
					local shown = (tostring(body or "")):gsub(newline, newline .. "    ")
					line("    " .. shown)
				end
			end
		else
			line("-- GetNumMacros/GetMacroInfo unavailable")
		end

	end)

	section("spellbook", function()
		line("-- also the vocabulary the transcriber needs: these are the words you will say")
		-- C_SpellBook only: this build has no GetNumSpellTabs or GetSpellTabInfo
		-- (docs/api-1.60.1.txt). A skill line the count promised but the game
		-- gives no info for means it has released the character (a quit); say
		-- so instead of writing nothing (four "-- nil" lines at a quit, 2026-11-11).
		local bank = Enum.SpellBookSpellBank.Player
		for tab = 1, C_SpellBook.GetNumSpellBookSkillLines() do
			local info = C_SpellBook.GetSpellBookSkillLineInfo(tab)
			if not info then
				error({ released = ("skill line %d of %d gave no info")
					:format(tab, C_SpellBook.GetNumSpellBookSkillLines()) })
			end
			line("-- " .. tostring(info.name))
			for at = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
				local item = C_SpellBook.GetSpellBookItemInfo(at, bank)
				if item and item.name then
					line(("%s %s (%s)"):format(tostring(item.itemType), item.name, tostring(item.spellID)))
				end
			end
		end
	end)

	section("reach", function()
		reachLines(line, actionFrames())

	end)

	section("modules", function()
		line("-- Lua the agent stored; each runs at every login. A module from a file is")
		line("-- modules/<Name>.lua in the repo: read it there, it is the current code")
		local all = effectiveModules()
		local stored = {}
		for name in pairs(all) do
			stored[#stored + 1] = name
		end
		table.sort(stored)
		for _, name in ipairs(stored) do
			if all[name].disk then
				local _, lines = tostring(all[name].code):gsub(newline, "")
				local m = WC.Get and WC.Get(name)
				local needs = m and m.missing and (", needs " .. table.concat(m.missing, ", ")) or ""
				line(("%s: modules/%s.lua (%d lines%s)"):format(name, name, lines, needs))
			else
				line(name .. ": (only in the save file, not in modules/ yet)")
				line("    " .. (tostring(all[name].code):gsub(newline, newline .. "    ")))
			end
		end
		if #stored == 0 then
			line("none")
		end

	end)

	section("capabilities", function()
		line("-- what other addons (and the game alone) provide, best first: call")
		line("-- WC.Use(name).method(...), never an integration directly (Engine.lua)")
		local caps = WC.Capabilities and WC.Capabilities() or {}
		if #caps == 0 then
			line("none")
		else
			for _, cap in ipairs(caps) do
				line(("%s: %s"):format(cap.name, #cap.using > 0 and table.concat(cap.using, ", ") or "nothing loaded"))
			end
		end
		-- providers whose self-check failed: the other addon changed; repair the provider
		for _, p in ipairs(WC.ProviderProblems and WC.ProviderProblems() or {}) do
			line(("BROKEN %s provider %s: %s (fix Providers/)"):format(p.cap, p.provider, p.why))
		end
	end)

	section("errands", function()
		line("-- the player's errands, newest first: WC.Errands.Add/Remove/Edit (rules)")
		local open = WC.Errands and WC.Errands.List() or {}
		if #open == 0 then line("none") end
		for _, e in ipairs(open) do
			local kinds = {}
			for k in pairs(e.done or {}) do kinds[#kinds + 1] = k end
			table.sort(kinds)
			line(("%d: %s%s  [done: %s]"):format(e.id, e.text, e.place and (" @%d %.1f,%.1f"):format(e.place.map, e.place.x, e.place.y) or "",
				table.concat(kinds, ", ")))
		end

	end)

	section("focus log", function()
		line("-- the controller's window focus, step by step (FocusLog.lua), oldest first:")
		line("-- time, C in combat, method, frame | focused frame, ui focused, bars caught | list")
		line("-- \"!!\" marks an impossible state, with why at the end")
		local flog = WowCompanionAgentDB.focusLog or {}
		for _, l in ipairs(flog) do line(l) end
		if #flog == 0 then line("none") end

	end)

	section("code runs", function()
		line("-- the last runs of agent code this session and before, oldest first")
		local runs = WowCompanionAgentDB.runs or {}
		for at = math.max(1, #runs - 9), #runs do
			local run = runs[at]
			line(("%s %s: %s; taint %s"):format(date("%H:%M:%S", run.at or 0), tostring(run.label),
				tostring(run.outcome), tostring(run.taint or "unchecked")))
			if run.printed and run.printed ~= "" then
				line("    " .. (run.printed:gsub(newline, newline .. "    ")))
			end
		end
		if #runs == 0 then
			line("none")
		end

	end)

	section("lua errors", function()
		line("-- errors from addons that are not Blizzard's (ours, the agent's, the player's),")
		line("-- newest first, with how often each repeated. Read the stack, fix the cause")
		local errors = WowCompanionAgentDB.errors or {}
		for at = #errors, math.max(1, #errors - 9), -1 do
			local err = errors[at]
			line(("%s x%d: %s"):format(date("%m-%d %H:%M:%S", err.at or 0), err.count or 1, tostring(err.message)))
			if err.stack and err.stack ~= "" then
				line("    " .. (err.stack:gsub(newline, newline .. "    ")))
			end
		end
		local wc = WowCompanionAgentDB.windowCombat
		if wc then
			line(("-- Companion window at the last fight's start: still protected=%s, extra secure children stowed: %s; last close: %s; last hidden: %s")
				:format(tostring(wc.protectedAfter), wc.stowedExtra ~= "" and tostring(wc.stowedExtra) or "none", tostring(wc.lastHide), tostring(wc.lastOnHide)))
		end
		local blocked = WowCompanionAgentDB.blocked or {}
		if #blocked > 0 then
			line("-- actions the game blocked (\"Interface action failed\"), newest first")
			for at = #blocked, math.max(1, #blocked - 9), -1 do
				local b = blocked[at]
				line(("%s x%d: %s %s%s"):format(date("%m-%d %H:%M:%S", b.at or 0), b.count or 1, tostring(b.event), tostring(b.what), b.combat and " (in combat)" or ""))
			end
		end
		if #errors == 0 then
			line("none")
		end
	end)

	if released and WowCompanionAgentDB.context then
		local kept = WowCompanionAgentDB.context:gsub("^%-%- kept: [^\n]*\n", "")
		WowCompanionAgentDB.context = ("-- kept: the export at %s found the character released (%s), "
			.. "so this is the one before it\n"):format(date("%Y-%m-%d %H:%M:%S"), released) .. kept
		WowCompanionAgentDB.exportFailures = { "kept the last export: " .. released }
		return #out
	end
	WowCompanionAgentDB.exportFailures = #failures > 0 and failures or nil
	WowCompanionAgentDB.context = table.concat(out, newline) .. newline
	return #out
end


WC.Export = { Context = exportContext, NoteForms = noteForms }
