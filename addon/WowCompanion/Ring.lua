-- The ring: one radial menu for every wheel of ours (the Wheel addon's secure
-- wheels, the chat wheel's channels). Forever's native radial art, eight slots
-- in its eight segments (top first, clockwise), the right stick aiming, the
-- sticks taken while it is up (the camera stays put) and held a moment after
-- it closes if the right stick is still pushed (so the camera does not swing).
-- Adapted from Improved Forever's Ring.lua by markg, MIT licence (see the Wheel
-- addon's LICENSE-ImprovedForever).
--
-- Only the look and the aim live here; what a slot does is its owner's (the
-- Wheel addon's secure buttons). Nothing here is secure, so it may be built on
-- a secure frame; it is built at load, out of combat.
--
--   local r = WC.Ring.Build(frame, { prompt = "..." })   frame: the owner's
--   r:Open(title, entries)    entries: up to WC.Ring.PAGE of { label, icon,
--                             count }; each gets dx, dy, angle (its segment);
--                             count (text) shows on the icon as on a bar button
--   r:Aim(entries, sticky)    in the owner's OnUpdate: lights what the right
--                             stick points at, else `sticky`; returns it
--   r:Picked(entries)         the slot the right stick points at, or nil
--   WC.Ring.Direction(i)      slot i's segment: dx, dy, angle
--
-- A page is WC.Ring.PAGE slots; owners that page (Later in docs/PLAN.md) open
-- the ring again with the next page's entries.

local Ring = {}
WC.Ring = Ring
Ring.PAGE = 8

local WIDTH, HEIGHT = 540, 541 -- Forever's GamepadRadial, measured by Improved Forever
local SLOT_RADIUS = 150
local ICON_SIZE = 45 -- Blizzard's segment icon size
local PICK_SQ = 0.25
local RELEASE_SQ, RELEASE_MAX = 0.04, 0.5

-- Slot i sits in the art's segment i: the native wheel is always eight
-- triangles centred on the cardinals and diagonals (GamepadRadial.xml), so a
-- ring of three uses three of the eight, from the top, clockwise.
function Ring.Direction(index)
	local angle = math.pi / 2 - (index - 1) * math.pi / 4
	return math.cos(angle), math.sin(angle), angle
end

local function atlas(texture, name, fallback)
	if C_Texture.GetAtlasInfo(name) then
		texture:SetAtlas(name)
	elseif fallback then
		texture:SetColorTexture(unpack(fallback))
	end
end

local function rightStick()
	local ok, state = pcall(C_GamePad.GetDeviceMappedState, C_GamePad.GetActiveDeviceID())
	local stick = ok and state and state.sticks and state.sticks[2]
	if stick and stick.x and stick.y then return stick.x, stick.y end
end

local R = {}
R.__index = R

function Ring.Build(frame, opts)
	opts = opts or {}
	local r = setmetatable({ frame = frame, slots = {} }, R)
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetPoint("CENTER", UIParent, "CENTER", 312, 10) -- where the native radial sits
	frame:SetFrameStrata("DIALOG")

	-- While the ring is up this child takes the sticks: the right stick aims
	-- without turning the camera.
	local capture = CreateFrame("Frame", nil, frame)
	capture:SetAllPoints(frame)
	if capture.EnableGamePadStick then
		capture:EnableGamePadStick(true)
		capture:SetScript("OnGamePadStick", function() end)
	end
	-- After the ring closes the right stick is often still pushed: the sticks
	-- are kept a moment so the camera does not swing round.
	local after = CreateFrame("Frame", nil, UIParent)
	after:SetAllPoints(UIParent)
	after:SetFrameStrata("DIALOG")
	after:Hide()
	if after.EnableGamePadStick then
		after:EnableGamePadStick(true)
		after:SetScript("OnGamePadStick", function() end)
	end
	after:SetScript("OnUpdate", function(self, elapsed)
		self.held = (self.held or 0) + elapsed
		local x, y = rightStick()
		if self.held >= RELEASE_MAX or not x or x * x + y * y <= RELEASE_SQ then self:Hide() end
	end)
	frame:HookScript("OnHide", function()
		local x, y = rightStick()
		if x and x * x + y * y > RELEASE_SQ then
			after.held = 0
			after:Show()
		end
	end)
	frame:HookScript("OnShow", function() after:Hide() end)

	local bg = frame:CreateTexture(nil, "OVERLAY", nil, -3)
	bg:SetPoint("CENTER")
	bg:SetSize(WIDTH, HEIGHT)
	atlas(bg, "gamepad-radial-menu-wheelbg", { 0, 0, 0, 0.6 })
	r.highlight = frame:CreateTexture(nil, "OVERLAY", nil, -2)
	r.highlight:SetSize(169, 165)
	atlas(r.highlight, "gamepad-radial-menu-selected", { 1, 0.82, 0, 0.25 })
	r.highlight:Hide()
	r.header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	r.header:SetPoint("BOTTOM", frame, "TOP", 0, 40)
	local headerBar = frame:CreateTexture(nil, "OVERLAY", nil, -2)
	headerBar:SetSize(487, 75)
	headerBar:SetPoint("TOP", r.header, "BOTTOM", 0, 4)
	atlas(headerBar, "gamepad-radial-menu-toptext")
	local footerBar = frame:CreateTexture(nil, "OVERLAY", nil, -1)
	footerBar:SetSize(570, 151)
	footerBar:SetPoint("CENTER", frame, "BOTTOM", 0, -30)
	atlas(footerBar, "gamepad-radial-menu-bottomtext")
	r.selected = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	r.selected:SetPoint("CENTER", footerBar, "CENTER", 0, 14)
	local prompts = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	prompts:SetPoint("TOP", r.selected, "BOTTOM", 0, -6)
	prompts:SetText(opts.prompt or "")

	for index = 1, Ring.PAGE do
		local slot = {}
		slot.icon = frame:CreateTexture(nil, "OVERLAY")
		slot.icon:SetSize(ICON_SIZE, ICON_SIZE)
		-- round: Blizzard's portrait circle mask, clamped to black outside so
		-- nothing past the circle shows (Blizzard_ArtifactPowerButton.xml)
		local mask = frame:CreateMaskTexture()
		mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
		mask:SetPoint("TOPLEFT", slot.icon, "TOPLEFT", 3, -3)
		mask:SetPoint("BOTTOMRIGHT", slot.icon, "BOTTOMRIGHT", -3, 3)
		slot.icon:AddMaskTexture(mask)
		-- the gamepad bar's own round frame over the icon, its size
		slot.border = frame:CreateTexture(nil, "OVERLAY", nil, 2)
		atlas(slot.border, "gamepad-actionbar-circleslot-border-normal")
		slot.border:SetAllPoints(slot.icon)
		slot.shadow = frame:CreateTexture(nil, "OVERLAY", nil, -1)
		atlas(slot.shadow, "gamepad-actionbar-circleslot-dropshadow")
		slot.shadow:SetPoint("TOPLEFT", slot.icon, "TOPLEFT", -4, 4)
		slot.shadow:SetPoint("BOTTOMRIGHT", slot.icon, "BOTTOMRIGHT", 4, -4)
		-- the bar button's own count: its font, bottom right of the icon
		slot.count = frame:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
		slot.count:SetDrawLayer("OVERLAY", 3) -- over the round border
		slot.count:SetJustifyH("RIGHT")
		slot.count:SetPoint("BOTTOMRIGHT", slot.icon, "BOTTOMRIGHT", 2, -2)
		slot.label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		slot.label:SetSize(80, 40)
		slot.label:SetWordWrap(true)
		-- two lines at most, ending in "..." past that, inside its triangle
		slot.label:SetMaxLines(2)
		slot.label:SetJustifyH("CENTER")
		slot.label:SetJustifyV("MIDDLE")
		r.slots[index] = slot
	end
	return r
end

-- entries get their segment; the slots are laid out and the header set
function R:Open(title, entries)
	self.header:SetText(title or "")
	for index, slot in ipairs(self.slots) do
		local entry = entries[index]
		if entry then
			entry.dx, entry.dy, entry.angle = Ring.Direction(index)
			-- Blizzard draws a segment's icon 20 in from its centre (GetIconOffset)
			local reach = SLOT_RADIUS - 20
			slot.icon:SetPoint("CENTER", self.frame, "CENTER", entry.dx * reach, entry.dy * reach)
			slot.icon:SetTexture(entry.icon or 134400)
			-- its label outward from the icon in an 80x40 box (textAnchorData,
			-- GamepadRadial.xml): 60 out on a cardinal, (30, 45) on a diagonal
			local lx, ly
			if math.abs(entry.dx) < 0.1 then lx, ly = 0, entry.dy > 0 and 60 or -60
			elseif math.abs(entry.dy) < 0.1 then lx, ly = entry.dx > 0 and 60 or -60, 0
			else lx, ly = entry.dx > 0 and 30 or -30, entry.dy > 0 and 45 or -45 end
			slot.label:ClearAllPoints()
			slot.label:SetPoint("CENTER", slot.icon, "CENTER", lx, ly)
			slot.label:SetText(entry.label)
			slot.count:SetText(entry.count or "")
		end
		for _, part in ipairs({ slot.icon, slot.shadow, slot.border, slot.label, slot.count }) do part:SetShown(entry ~= nil) end
	end
	self.lit = false
	self:Light(nil, entries)
end

function R:Light(pick, entries)
	self.lit = pick
	local entry = pick and entries[pick]
	if entry then
		self.highlight:ClearAllPoints()
		self.highlight:SetPoint("CENTER", self.frame, "CENTER", entry.dx * SLOT_RADIUS, entry.dy * SLOT_RADIUS)
		self.highlight:SetRotation(entry.angle + math.pi / 2)
		self.highlight:Show()
		self.selected:SetText(entry.label)
	else
		self.highlight:Hide()
		self.selected:SetText("")
	end
	for index, slot in ipairs(self.slots) do
		if index == pick then slot.label:SetTextColor(1, 1, 1) else slot.label:SetTextColor(1, 0.82, 0) end
		-- the picked one wears the bar's "selected" frame, as a focused button does
		atlas(slot.border, index == pick and "gamepad-actionbar-circleslot-border-selected"
			or "gamepad-actionbar-circleslot-border-normal")
	end
end

function R:Picked(entries)
	local x, y = rightStick()
	if not x or x * x + y * y < PICK_SQ then return nil end
	local best, bestDot
	for index, entry in ipairs(entries) do
		if entry.dx then
			local dot = x * entry.dx + y * entry.dy
			if not bestDot or dot > bestDot then best, bestDot = index, dot end
		end
	end
	return best
end

function R:Aim(entries, sticky)
	local pick = self:Picked(entries) or sticky
	if pick ~= self.lit then self:Light(pick, entries) end
	return pick
end
