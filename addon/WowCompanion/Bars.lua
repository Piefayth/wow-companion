-- The gamepad action bars, the one description every addon reads: each bar's
-- frame name in Blizzard's gamepad UI, its first action slot, its button count,
-- and the triggers held to press it. A bar's buttons are, in order, d-pad left,
-- up, right, down, then square, triangle, circle, cross (KEYS: the game's key
-- names, so a prompt draws the pad's own glyph with WowCompanion_Glyph).
WC.GamepadBars = {
	{ frame = "TopCenteredAnchorTopBar", first = 181, count = 4, held = {} },
	{ frame = "LeftCenteredAnchorLeftBar", first = 185, count = 8, held = { "PADLTRIGGER" } },
	{ frame = "RightCenteredAnchorRightBar", first = 193, count = 8, held = { "PADRTRIGGER" } },
	{ frame = "BottomCenteredAnchorBottomBar", first = 201, count = 8, held = { "PADLTRIGGER", "PADRTRIGGER" } },
	-- the in-form page of the bar GamepadStanceBarOverride names (R2 here)
	{ frame = "TopCenteredAnchorStanceBar", first = 265, count = 8, held = { "PADRTRIGGER" }, inForm = true },
}
WC.GamepadBars.KEYS = { "PADDLEFT", "PADDUP", "PADDRIGHT", "PADDDOWN", "PAD3", "PAD4", "PAD2", "PAD1" }
