-- The chat's scroll bar (the player's pick, 2026-11-12): a groove carved in
-- the stone between two bark borders, the fleur-de-lis arrows in bark over its
-- ends, a heartwood thumb riding in it, and each divider between turns joining
-- its left border. The turns' stone runs on behind it to the well's edge.
-- Drawn by tools/make_scrollbar_art.py.

local ART = [[Interface\AddOns\WowCompanion_Agent\Art\Scroll-]]
local VERSION = 11 -- the generator's VERSION
local function art(piece)
	return ART .. piece .. "-" .. VERSION
end

local WIDTH = 20 -- the column; the art is 32 wide over it, the groove its middle 8
-- the thumb art's opaque width (5.25 of its 32) widened to the groove floor's 7.8
local FILL = 7.8 / 5.25
-- where the thumb stops at each end: a pixel short of the groove's round end
-- at 4K (the round end's centre 24 of each 32-tall cap, radius 4)
local INSET = 20.4

WC.ChatBar = {}
-- the text keeps clear of the bar: the column and its border's art beside it
WC.ChatBar.ROOM = WIDTH + 6

-- A divider between turns, spanning the turn's full width: the vine's left end,
-- its middle stretched, and the Joint taking it into the bar's left border. A
-- frame above the bar's column (the column is its content's level + 1), so the
-- Joint lies over the border; it scrolls with the turns, so dividers meet the
-- border at every scroll position.
function WC.ChatBar.Divider(content)
	local rule = CreateFrame("Frame", nil, content)
	rule:SetHeight(16)
	rule:SetFrameLevel(content:GetFrameLevel() + 2)
	local left = rule:CreateTexture(nil, "ARTWORK")
	left:SetTexture(art("RuleLeft"))
	left:SetSize(32, 16)
	left:SetPoint("LEFT")
	local joint = rule:CreateTexture(nil, "ARTWORK")
	joint:SetTexture(art("Joint"))
	joint:SetSize(32, 16)
	joint:SetPoint("LEFT", rule, "RIGHT", -(WIDTH + 6), 0) -- its x 6 the column's left edge
	local mid = rule:CreateTexture(nil, "ARTWORK")
	mid:SetTexture(art("RuleMid"))
	mid:SetHeight(16)
	mid:SetPoint("LEFT", left, "RIGHT")
	mid:SetPoint("RIGHT", joint, "LEFT")
	return rule
end

-- The bar in the well's right edge, over `scroll` (which spans the well, so the
-- turns run on behind it). `level` is the well's frame level; the scroll's
-- child sits at level + 2, the column + 3, the dividers + 4, the arrows + 6,
-- the thumb + 7. Returns the column and the two arrow buttons.
function WC.ChatBar.Build(well, scroll, edge, level)
	local column = CreateFrame("Frame", nil, well)
	-- Shorter than the well, with the same clear stone past each tip, measured
	-- at 4K: the inset's top border reads thicker than its bottom one, and the
	-- down arrow's art carries its cast shadow below the tip.
	column:SetPoint("TOPRIGHT", -edge, -9)
	column:SetPoint("BOTTOMRIGHT", -edge, 4)
	column:SetWidth(WIDTH)
	column:SetFrameLevel(level + 3)

	-- Scrolling on a controller without the right stick (the camera): the
	-- arrows, which the cursor reaches like any button. Each press moves most
	-- of a view.
	local function by(pages)
		local step = math.max(40, (scroll:GetHeight() or 200) * 0.75)
		local range = scroll:GetVerticalScrollRange()
		scroll:SetVerticalScroll(math.max(0, math.min(range, scroll:GetVerticalScroll() + pages * step)))
	end
	local caps = {}
	for _, spec in ipairs({ { "Up", "TOP", -1 }, { "Down", "BOTTOM", 1 } }) do
		local b = CreateFrame("Button", nil, column)
		b:SetSize(32, 32)
		b:SetPoint(spec[2])
		b:SetHitRectInsets(6, 6, 0, 0) -- the column, not the art's spare width
		b:SetNormalTexture(art(spec[1] .. "-Normal"))
		b:SetPushedTexture(art(spec[1] .. "-Pushed"))
		-- glows round the arrow alone, never the groove's border
		b:SetHighlightTexture(art(spec[1] .. "-Highlight"), "ADD")
		b:SetDisabledTexture(art(spec[1] .. "-Disabled"))
		b:SetFrameLevel(level + 6)
		b:SetScript("OnClick", function() by(spec[3]) end)
		caps[spec[1]] = b
	end
	local groove = column:CreateTexture(nil, "BACKGROUND")
	groove:SetTexture(art("Mid"))
	groove:SetWidth(32)
	groove:SetPoint("TOP", caps.Up, "BOTTOM")
	groove:SetPoint("BOTTOM", caps.Down, "TOP")

	-- the thumb: its round ends, its centre, and the shaft stretched between,
	-- widened to fill the groove's floor; above the caps, which would hide its ends
	local thumb = CreateFrame("Frame", nil, column)
	thumb:SetFrameLevel(level + 7)
	thumb:SetWidth(32 * FILL)
	local function piece(name, height, point)
		local t = thumb:CreateTexture(nil, "ARTWORK")
		t:SetTexture(art(name))
		t:SetSize(32 * FILL, height)
		t:SetPoint(point)
		return t
	end
	local top, centre, bottom = piece("Thumb-Top", 8, "TOP"), piece("Thumb-Centre", 16, "CENTER"), piece("Thumb-Bottom", 8, "BOTTOM")
	for _, span in ipairs({ { top, centre }, { centre, bottom } }) do
		local shaft = thumb:CreateTexture(nil, "ARTWORK")
		shaft:SetTexture(art("Thumb-Mid"))
		shaft:SetPoint("TOPLEFT", span[1], "BOTTOMLEFT")
		shaft:SetPoint("BOTTOMRIGHT", span[2], "TOPRIGHT")
	end

	-- Its share of the groove is the share of the conversation in view, its
	-- place the scroll's: whatever moves the turns (arrows, wheel, stick), the
	-- thumb follows from here.
	local function paint()
		local view = scroll:GetHeight() or 0
		local range = scroll:GetVerticalScrollRange() or 0
		local room = column:GetHeight() - 2 * INSET
		if view <= 0 or room <= 0 then return end
		local size = math.max(24, room * view / (view + range))
		local at = range > 0 and math.min(1, scroll:GetVerticalScroll() / range) or 0
		thumb:SetHeight(size)
		thumb:ClearAllPoints()
		thumb:SetPoint("TOP", column, "TOP", 0, -(INSET + (room - size) * at))
	end
	scroll:HookScript("OnVerticalScroll", paint)
	scroll:HookScript("OnScrollRangeChanged", paint)
	scroll:HookScript("OnSizeChanged", paint)
	column:SetScript("OnShow", paint)
	return column, caps.Up, caps.Down
end
