-- WowCompanion_Link: the pad as the client maps it, and which conversation a
-- talk-button press is for.
--   WC.Pad.State() -> modifiers (sorted names), bases ({ [PADDUP] = true, ... }) | nil
--   WowCompanion_PadSlot() -> "", "l1", "l2", "r1", "r2", "quick" or "say"
-- The pad as the client maps it: modifiers held (triggers, shoulders, sticks,
-- sorted) and the d-pad and face buttons held. nil when there is no pad to read.
local function padState()
	if not (C_GamePad and C_GamePad.GetDeviceMappedState and C_GamePad.ButtonIndexToBinding) then
		return nil
	end
	local ok, state = pcall(C_GamePad.GetDeviceMappedState)
	if not ok or type(state) ~= "table" or type(state.buttons) ~= "table" then
		return nil
	end
	local modifiers, bases = {}, {}
	for index, down in pairs(state.buttons) do
		if down then
			-- state.buttons is a Lua array, from 1; ButtonIndexToBinding counts from 0.
			-- Measured: without the -1, L2 read as R2 and R2 as PADLSTICKUP.
			local name = C_GamePad.ButtonIndexToBinding(index - 1)
			if name then
				if name:find("^PADD") or name:find("^PAD%d") then
					bases[name] = true
				else
					modifiers[#modifiers + 1] = name
				end
			end
		end
	end
	table.sort(modifiers)
	return modifiers, bases
end

-- which conversation slot a talk-button press is for: the trigger held with it,
-- in the PC's order (l1, l2, r1, r2), or "" for the main conversation
local SLOT_BY_MODIFIER = { PADLSHOULDER = "l1", PADLTRIGGER = "l2", PADRSHOULDER = "r1", PADRTRIGGER = "r2" }
function WowCompanion_PadSlot()
	local modifiers = padState()
	if not modifiers then return "" end
	local held = {}
	for _, name in ipairs(modifiers) do
		if SLOT_BY_MODIFIER[name] then held[SLOT_BY_MODIFIER[name]] = true end
	end
	-- L2 and R2 together are the quick conversation, as on the PC
	if held.l2 and held.r2 then return "quick" end
	-- L1 and R1 together are dictation (ChatWheel.lua), no conversation
	if held.l1 and held.r1 then return "say" end
	for _, slot in ipairs({ "l1", "l2", "r1", "r2" }) do
		if held[slot] then return slot end
	end
	return ""
end

WC.Pad = { State = padState }
