-- WowCompanion_Link: the pad as the client maps it, and which conversation the
-- buttons held pick.
--   WC.Pad.State() -> modifiers (sorted names), bases ({ [PADDUP] = true, ... }) | nil
--   WC.Pad.Held()  -> the conversations whose whole chord is held: { l1 = true, ... }
--   WowCompanion_PadSlot() -> the conversation the buttons held now pick
--   WC.Pad.Latch() -> a pick followed through one hold: l:Update() each frame,
--                     l.slot the conversation
--
-- Every conversation key is a chord of one or more buttons, by the WoW names the
-- companion reports in its status (WC.Link.Settings(): "PADLTRIGGER+PADRTRIGGER").
-- The rule is the companion's (crates/voice, the voice loop), written once here:
-- at the press, the fully held chord with the most buttons wins (ties in KEYS
-- order), none held is Main; during the hold each newly pressed button picks the
-- fully held chord with the most buttons among those containing it, and letting
-- go keeps the pick.

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

-- the conversation keys in tie order; each key is also its conversation's slot
-- ("say" is WC.Conversations.DICTATION)
local KEYS = { "l1", "l2", "r1", "r2", "quick", "say" }

-- every button down now, by WoW name
local function down()
	local set = {}
	local modifiers, bases = padState()
	if not modifiers then return set end
	for _, name in ipairs(modifiers) do set[name] = true end
	for name in pairs(bases) do set[name] = true end
	return set
end

-- each key's chord from the companion's status: { key = { names... } }
local function chords()
	local out = {}
	local settings = WC.Link and WC.Link.Settings and WC.Link.Settings()
	if not settings then return out end
	for _, key in ipairs(KEYS) do
		local value = settings[key]
		if type(value) == "string" and value ~= "" then
			local names = {}
			for name in value:gmatch("[^+]+") do names[#names + 1] = name end
			out[key] = names
		end
	end
	return out
end

local function whole(chord, set)
	for _, name in ipairs(chord) do
		if not set[name] then return false end
	end
	return true
end
local function contains(chord, button)
	for _, name in ipairs(chord) do
		if name == button then return true end
	end
	return false
end

-- the fully held chord with the most buttons (ties in KEYS order), among those
-- containing `button` when given; nil when none
local function best(set, all, button)
	local pick, size = nil, 0
	for _, key in ipairs(KEYS) do
		local chord = all[key]
		if chord and #chord > size and whole(chord, set) and (not button or contains(chord, button)) then
			pick, size = key, #chord
		end
	end
	return pick
end

local function held()
	local out, set, all = {}, down(), chords()
	for key, chord in pairs(all) do
		if whole(chord, set) then out[key] = true end
	end
	return out
end

function WowCompanion_PadSlot()
	return best(down(), chords()) or ""
end

local Latch = {}
Latch.__index = Latch
function Latch:Update()
	local now, all = down(), chords()
	for name in pairs(now) do
		if not self.down[name] then
			self.slot = best(now, all, name) or self.slot
		end
	end
	self.down = now
	return self.slot
end

WC.Pad = {
	State = padState,
	Held = held,
	Latch = function()
		local now = down()
		return setmetatable({ down = now, slot = best(now, chords()) or "" }, Latch)
	end,
}
