-- WowCompanion_Link: the pad as the client maps it, and which conversation the
-- buttons held pick.
--   WC.Pad.State() -> modifiers (sorted names), bases ({ [PADDUP] = true, ... }) | nil
--   WC.Pad.Held()  -> the conversation buttons held: { l1 = true, ... }, by the
--                     WoW names the companion reports for them (settings in its
--                     status, WC.Link.Settings()); none while it has reported none
--   WowCompanion_PadSlot() -> the conversation the buttons held now pick
--   WC.Pad.Latch() -> a pick followed through one hold: l:Update() each frame,
--                     l.slot the conversation
--
-- The rule is the companion's (crates/voice, the voice loop), written once here:
-- at the press, L2+R2 is Quick and L1+R1 dictation, else the first held of l1,
-- l2, r1, r2, else Main; during the hold the last button pulled picks (with its
-- partner held, the pair), and letting it go keeps the pick.

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

local KEYS = { "l1", "l2", "r1", "r2" }
-- each key's partner and the conversation the two make together
local PAIR = { l1 = { "r1", WC.Conversations.DICTATION }, r1 = { "l1", WC.Conversations.DICTATION },
	l2 = { "r2", "quick" }, r2 = { "l2", "quick" } }

local function held()
	local out = {}
	local settings = WC.Link and WC.Link.Settings and WC.Link.Settings()
	local modifiers, bases = padState()
	if not (settings and modifiers) then return out end
	local down = {}
	for _, name in ipairs(modifiers) do down[name] = true end
	for name in pairs(bases) do down[name] = true end
	for _, key in ipairs(KEYS) do
		if settings[key] and down[settings[key]] then out[key] = true end
	end
	return out
end

-- the pick at the press, from the buttons held then
local function pickNow(h)
	if h.l2 and h.r2 then return "quick" end
	if h.l1 and h.r1 then return WC.Conversations.DICTATION end
	for _, key in ipairs(KEYS) do
		if h[key] then return key end
	end
	return ""
end

function WowCompanion_PadSlot()
	return pickNow(held())
end

local Latch = {}
Latch.__index = Latch
function Latch:Update()
	local now = held()
	for _, key in ipairs(KEYS) do
		if now[key] and not self.held[key] then
			self.slot = now[PAIR[key][1]] and PAIR[key][2] or key
		end
	end
	self.held = now
	return self.slot
end

WC.Pad = {
	State = padState,
	Held = held,
	Latch = function()
		local now = held()
		return setmetatable({ held = now, slot = pickNow(now) }, Latch)
	end,
}
