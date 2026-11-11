-- The conversations, as the PC names them (src: voice::Slot): "" is Main, a
-- trigger held with the talk button its own (l1, l2, r1, r2), L2+R2 Quick.
-- Dictation (L1+R1) is "say", no conversation. The one list in game; every
-- addon reads it from here.
local LABELS = { [""] = "Main", l1 = "L1", l2 = "L2", r1 = "R1", r2 = "R2", quick = "Quick" }

WC.Conversations = {
	-- in the order the window lists them
	list = { "", "l1", "l2", "r1", "r2", "quick" },
	DICTATION = "say",
}

-- the name a player reads: "Main", "L2", "Quick"
function WC.Conversations.Label(slot)
	return LABELS[slot or ""] or tostring(slot)
end

-- the name in a command to the PC and in the audit: "main" for ""
function WC.Conversations.Wire(slot)
	return (slot == nil or slot == "") and "main" or slot
end
