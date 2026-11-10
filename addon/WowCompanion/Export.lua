-- The context export (split out of Companion.lua, 2026-11-10): what the agent
-- reads after every reload, written into SavedVariables at logout, and the form
-- notes it rests on. Companion.lua shares what this needs through WC.Core and
-- calls WC.Export.Context() / WC.Export.NoteForms().

local core = WC.Core
local GAMEPAD_BARS = core.GAMEPAD_BARS
local LAST_ACTION_SLOT = core.LAST_ACTION_SLOT
local PAD_WORDS = core.PAD_WORDS
local actionFrames = core.actionFrames
local barLabel = core.barLabel
local barModifier = core.barModifier
local bookEntries = core.bookEntries
local chordFor = core.chordFor
local cvar = core.cvar
local effectiveModules = core.effectiveModules
local itemName = core.itemName
local slotHas = core.slotHas
local spellName = core.spellName

local function noteForms()
	if InCombatLockdown() then
		return
	end
	WowCompanionDB.spellForms = WowCompanionDB.spellForms or {}
	local store = WowCompanionDB.spellForms
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
	local store = WowCompanionDB.spellForms or {}
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
				if not at and (known.flyout or name:find(" Form$")) then
					at = "the L1+L2 form wheel"
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
	local function section(name)
		line("")
		line("== " .. name .. " ==")
	end

	local version, build = GetBuildInfo()
	line(("-- WowCompanion context, %s, client %s build %s")
		:format(date("%Y-%m-%d %H:%M:%S"), tostring(version), tostring(build)))

	section("character")
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
	-- The facts advice rests on (the player, 2026-11-10: an off-hand suggested
	-- beside a two-hander, a pouch already worn, Skinning said to be missing).
	-- Each part under pcall: one bad read must not lose the whole export.
	pcall(function()
		local xp, xpMax = UnitXP("player"), UnitXPMax("player")
		local rested = GetXPExhaustion and GetXPExhaustion()
		line(("xp: %s / %s%s"):format(tostring(xp), tostring(xpMax), rested and (", rested " .. rested) or ""))
		local zone, sub = GetRealZoneText and GetRealZoneText(), GetSubZoneText and GetSubZoneText()
		line(("zone: %s%s"):format(tostring(zone), (sub and sub ~= "" and sub ~= zone) and (" / " .. sub) or ""))
	end)
	pcall(function()
		-- self-buffs worth noticing when missing (Druid; others add theirs here)
		local BUFFS = { DRUID = { "Mark of the Wild", "Thorns" } } -- Omen of Clarity is a proc in Forever, not a buff to cast
		local _, classFile = UnitClass("player")
		local missing = {}
		for _, name in ipairs(BUFFS[classFile] or {}) do
			local info = C_Spell.GetSpellInfo(name)
			local known = info and info.spellID and IsPlayerSpell(info.spellID)
			if known and not C_UnitAuras.GetAuraDataBySpellName("player", name, "HELPFUL") then
				missing[#missing + 1] = name
			end
		end
		line("buffs missing at export: " .. (#missing > 0 and table.concat(missing, ", ") or "none"))
	end)

	section("equipped")
	line("-- inventory slot: item. A two-hand weapon in 16 means 17 cannot hold anything")
	pcall(function()
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

	section("bags")
	line("-- bag: name, slots, free. Bag 0 is the backpack; a bag item inside a bag is a spare")
	pcall(function()
		for bag = 0, 4 do
			local slots = C_Container.GetContainerNumSlots(bag) or 0
			local free = C_Container.GetContainerNumFreeSlots(bag) or 0
			local name = C_Container.GetBagName(bag)
			line(("%d: %s, %d slots, %d free"):format(bag, slots > 0 and (name or "?") or "EMPTY BAG SLOT", slots, free))
		end
	end)

	section("skills")
	line("-- professions and secondary skills, rank / max")
	pcall(function()
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

	section("quest log")
	line("-- id: title [level] (done), then objectives")
	pcall(function()
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

	section("action slots")
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
		-- Measured, and corrected by the player: the frames named StanceBar are not
		-- a bar of their own. They are the in-form page of whichever bar the
		-- GamepadStanceBarOverride setting names (here the R2 bar), which is why they
		-- learn the same chord. Switching forms is the L1+L2 wheel, not a slot.
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
				line(("-- %s is shared by %s: StanceBar is that bar's page while in a form"
					.. " (cat, bear); out of form it is the other"):format(modifier, table.concat(names, " and ")))
			end
		end
		local form = GetShapeshiftForm and GetShapeshiftForm() or 0
		line(("form at export: %s"):format(form == 0 and "none (caster)" or ("%d"):format(form)))
		line(("GamepadStanceBarOverride: %s (the setting that picks which bar shows form actions)")
			:format(tostring(cvar("GamepadStanceBarOverride"))))
		line("-- changing form is the L1+L2 wheel, not an action slot")
		local stats = WowCompanionDB.chordStats
		if stats then
			line(("-- %d d-pad/face presses watched, %d lit a bar button"):format(stats.presses, stats.lit))
		end
		local misses = WowCompanionDB.chordMisses
		if misses and #misses > 0 then
			line("-- presses that lit none of these bars, newest last:")
			for _, miss in ipairs(misses) do
				line("--   " .. (miss:gsub("PAD%u+", function(name) return PAD_WORDS[name] or name end)))
			end
		end
	else
		line("-- HasAction/GetActionInfo unavailable")
	end

	section("action buttons on screen")
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

	section("bindings")
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

	section("macros")
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

	section("spellbook")
	line("-- also the vocabulary the transcriber needs: these are the words you will say")
	-- the name index says this build has no GetNumSpellTabs, GetSpellBookItemInfo or
	-- GetSpellInfo at all: it is a retail-11.x-era API behind a 1.60.1 version
	-- string. The classic branch stays only so a differently-built client says so
	-- out loud instead of exporting an empty spellbook.
	local walked = pcall(function()
		if GetNumSpellTabs and GetSpellTabInfo and GetSpellBookItemInfo then
			for tab = 1, GetNumSpellTabs() do
				local tabName, _, offset, numSpells = GetSpellTabInfo(tab)
				line(("-- %s"):format(tostring(tabName)))
				for at = (offset or 0) + 1, (offset or 0) + (numSpells or 0) do
					local kind, id = GetSpellBookItemInfo(at, "spell")
					local name = GetSpellBookItemName and GetSpellBookItemName(at, "spell")
					if not name and id then
						name = spellName(id)
					end
					if name then
						line(("%s %s (%s)"):format(tostring(kind), tostring(name), tostring(id)))
					end
				end
			end
		elseif C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
			for tab = 1, C_SpellBook.GetNumSpellBookSkillLines() do
				local info = C_SpellBook.GetSpellBookSkillLineInfo(tab)
				local offset = info and info.itemIndexOffset or 0
				line(("-- %s"):format(tostring(info and info.name)))
				-- GetSpellBookItemInfo's second argument is typed SpellBookSpellBank,
				-- so name it rather than passing the 0 I would otherwise have assumed
				local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
				for at = offset + 1, offset + (info and info.numSpellBookItems or 0) do
					local item = C_SpellBook.GetSpellBookItemInfo(at, bank)
					if item and item.name then
						line(("%s %s (%s)"):format(
							tostring(item.itemType), item.name, tostring(item.spellID)))
					end
				end
			end
		else
			line("-- no spellbook API found under either name")
		end
	end)
	if not walked then
		line("-- the spellbook walk failed partway; the lines above are what it reached")
	end

	section("reach")
	local reached, why = pcall(reachLines, line, actionFrames())
	if not reached then
		line("-- the reach check failed: " .. tostring(why))
	end

	section("modules")
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
			line(("%s: modules/%s.lua (%d lines)"):format(name, name, lines))
		else
			line(name .. ": (only in the save file, not in modules/ yet)")
			line("    " .. (tostring(all[name].code):gsub(newline, newline .. "    ")))
		end
	end
	if #stored == 0 then
		line("none")
	end

	section("code runs")
	line("-- the last runs of agent code this session and before, oldest first")
	local runs = WowCompanionDB.runs or {}
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

	section("lua errors")
	line("-- errors from addons that are not Blizzard's (ours, the agent's, the player's),")
	line("-- newest first, with how often each repeated. Read the stack, fix the cause")
	local errors = WowCompanionDB.errors or {}
	for at = #errors, math.max(1, #errors - 9), -1 do
		local err = errors[at]
		line(("%s x%d: %s"):format(date("%m-%d %H:%M:%S", err.at or 0), err.count or 1, tostring(err.message)))
		if err.stack and err.stack ~= "" then
			line("    " .. (err.stack:gsub(newline, newline .. "    ")))
		end
	end
	local blocked = WowCompanionDB.blocked or {}
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

	WowCompanionDB.context = table.concat(out, newline) .. newline
	return #out
end


WC.Export = { Context = exportContext, NoteForms = noteForms }
