-- WowCompanion_Agent: the steps an answer carries (a batch of them, a macro,
-- a bar slot) and what each did, in its conversation.
-- What this needs from Agent.lua comes through WC.Companion; what it
-- offers, the other files reach through their message kinds.

local remember = WC.Companion.remember
local handlers = {}

function handlers.macro(inbox)
	if InCombatLockdown() then
		return "refused: in combat"
	end
	if not inbox.name then
		return "refused: no macro name"
	end
	local index = GetMacroIndexByName(inbox.name)
	if index and index > 0 then
		EditMacro(index, inbox.name, inbox.icon, inbox.body)
		return ("edited macro %s at %d"):format(inbox.name, index)
	end
	index = CreateMacro(inbox.name, inbox.icon or "INV_MISC_QUESTIONMARK", inbox.body, false)
	-- deliberately not placed on a bar: PlaceAction taints the UI, so bar edits are
	-- their own operation followed by a reload
	return index and ("created macro %s at %d"):format(inbox.name, index) or "CreateMacro failed"
end

-- What a step did, in the window, so a refusal ("in combat", "no macro named")
-- is seen rather than silently dropped. Only kinds whose result is news: chat,
-- lua and press already show themselves.
-- a lua or module step reports itself when it has run (Sandbox.lua)
local REPORTED = { bar = true, macro = true }
local function report(step, ok, outcome)
	if not ok then
		remember("error", ("%s failed: %s"):format(tostring(step.kind), tostring(outcome)))
	elseif REPORTED[step.kind] and type(outcome) == "string" then
		remember(outcome:find("^refused") and "error" or "game", outcome)
	end
end

-- Several steps from one answer, in order, each reported. One failing does not
-- stop the rest: they were asked for together, but each stands on its own, and
-- the report says which landed. Agent code runs after a taint scan spread over
-- frames (Sandbox.lua), so the steps after it wait for it, in the same
-- conversation.
function handlers.batch(inbox)
	local slot = WC.Link.Current()
	local steps = inbox.steps or {}
	local function from(first)
		for at = first, #steps do
			if WC.Sandbox.Busy() then
				WC.Sandbox.Queue(function(done)
					WC.Link.As(slot, from, at)
					done()
				end)
				return
			end
			report(steps[at], WC.Link.Run(steps[at]))
		end
	end
	from(1)
end

-- Put a spell, macro or item on a bar slot, or empty one.
--
-- Cleared by measurement, not assumed: PlaceAction and PutActionInSlot into the
-- slots the gamepad UI draws (189, 202) newly tainted 0 of ~265,000 variables and
-- raised no blocked-action notice. Configuration, out of combat, like a macro.
--
-- Whatever the slot held comes back on the cursor and is dropped. It leaves the bar
-- only: spells stay in the spellbook, macros in the macro list. The reply names it,
-- so "put it back" has something to go on.
local function describeSlot(slot)
	local ok, kind, id = pcall(GetActionInfo, slot)
	if not ok or not kind then
		return "nothing"
	end
	if kind == "spell" then
		return "spell " .. tostring(WC.Chords.spellName(id) or id)
	elseif kind == "macro" then
		return "macro " .. tostring(GetMacroInfo(id) or id)
	elseif kind == "item" then
		return "item " .. tostring(WC.Chords.itemName(id) or id)
	end
	return tostring(kind) .. " " .. tostring(id)
end

function handlers.bar(inbox)
	if InCombatLockdown() then
		return "refused: in combat"
	end
	local slot = tonumber(inbox.slot)
	if not slot or slot < 1 or slot > WC.Chords.LAST_ACTION_SLOT or slot ~= math.floor(slot) then
		return "refused: no valid slot"
	end
	local before = describeSlot(slot)
	local what, name = inbox.what, inbox.name
	ClearCursor()
	if what == "empty" then
		PickupAction(slot)
		ClearCursor()
		remember("claude", ("slot %d emptied (held %s)"):format(slot, before))
		return ("slot %d emptied, held %s"):format(slot, before)
	elseif what == "spell" then
		C_Spell.PickupSpell(tonumber(name) or name)
	elseif what == "macro" then
		local index = GetMacroIndexByName(name or "")
		if not index or index == 0 then
			return ("refused: no macro named %q"):format(tostring(name))
		end
		PickupMacro(index)
	elseif what == "item" then
		C_Item.PickupItem(tonumber(name) or name)
	else
		return "refused: what must be spell, macro, item or empty"
	end
	-- nothing on the cursor means the name did not resolve: do not place nothing,
	-- which would just empty the slot
	if not GetCursorInfo() then
		return ("refused: could not pick up %s %q"):format(tostring(what), tostring(name))
	end
	PlaceAction(slot)
	ClearCursor()
	local after = describeSlot(slot)
	remember("claude", ("slot %d now %s (was %s)"):format(slot, after, before))
	return ("slot %d: %s, was %s"):format(slot, after, before)
end

-- a follow-up step (an answer's andThen) ran
WC.Module("Steps"):On("LINK_STEP", function(step, ok, outcome) report(step, ok, outcome) end)
for kind, fn in pairs(handlers) do WC.Link.Handle(kind, fn) end
