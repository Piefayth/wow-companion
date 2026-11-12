-- The controller's focus visuals on the Companion window, in the window's own
-- bronze (tools/make_focus_art.py): the glow round the focused window and the
-- pointer at the selected element. Blizzard's are a saturated yellow.
--
-- The glow: the window's FrameGlow (ButtonFrameTemplate's child, shown by
-- Blizzard while the window has the controller's focus) keeps its show and
-- hide; its own texture is hidden and ours drawn in its place, nine pieces cut
-- from one texture so the corners keep their shape at any window size.
--
-- The pointer is SmartNavigation's one shared texture. Its art (not Lua
-- state) is swapped while it points into our window and put back as it was
-- when it points anywhere else, from post-hooks on the calls that move or
-- repaint it, so Blizzard's callers stay secure.

local ART = [[Interface\AddOns\WowCompanion_Agent\Art\%s-1]]

-- the glow texture: 128 texels, slice margins 48, the rim's outer edge 32 in
-- from its edge; 2 texels a screen pixel at the window's 1.333 px a unit
local TEX, MARGIN, INSET = 128, 48, 32
local UNIT = 2 * 4 / 3 -- texels a unit
local M, OUT = MARGIN / UNIT, INSET / UNIT -- 18 and 12 units

local function glow(frame)
	local holder = frame.FrameGlow
	if not holder or holder.wcPieces then return end
	if holder.GlowTexture then holder.GlowTexture:SetAlpha(0) end
	local path = ART:format("Focus-Glow")
	local a, b = MARGIN / TEX, (TEX - MARGIN) / TEX
	local cols = { { 0, a }, { a, b }, { b, 1 } }
	local pieces = {}
	for row = 1, 3 do
		for col = 1, 3 do
			if not (row == 2 and col == 2) then
				local t = holder:CreateTexture(nil, "BACKGROUND", nil, 1)
				t:SetTexture(path)
				t:SetTexCoord(cols[col][1], cols[col][2], cols[row][1], cols[row][2])
				pieces[#pieces + 1] = { t = t, row = row, col = col }
			end
		end
	end
	-- the box: the frame's bounds (the rim's outer edge) set out by OUT
	local function x(col, side) -- side 1 = left edge of the piece, 2 = right
		if col == 1 then return side == 1 and { "LEFT", -OUT } or { "LEFT", M - OUT } end
		if col == 2 then return side == 1 and { "LEFT", M - OUT } or { "RIGHT", OUT - M } end
		return side == 1 and { "RIGHT", OUT - M } or { "RIGHT", OUT }
	end
	local function y(row, side) -- side 1 = top, 2 = bottom
		if row == 1 then return side == 1 and { "TOP", OUT } or { "TOP", OUT - M } end
		if row == 2 then return side == 1 and { "TOP", OUT - M } or { "BOTTOM", M - OUT } end
		return side == 1 and { "BOTTOM", M - OUT } or { "BOTTOM", -OUT }
	end
	for _, p in ipairs(pieces) do
		local l, r, tp, bt = x(p.col, 1), x(p.col, 2), y(p.row, 1), y(p.row, 2)
		p.t:SetPoint("TOPLEFT", frame, tp[1] .. l[1], l[2], tp[2])
		p.t:SetPoint("BOTTOMRIGHT", frame, bt[1] .. r[1], r[2], bt[2])
	end
	holder.wcPieces = pieces
end

-- the pointer
local POINTER = ART:format("Focus-Pointer")
local SIZE = 24 / 0.8 -- 24 units on screen; the cursor texture is drawn at 0.8
local saved -- Blizzard's art while ours is up: atlas, r, g, b, a

local function ours(button)
	local window = _G.WowCompanionLog
	local f = button
	while f do
		if f == window then return true end
		f = f.GetParent and f:GetParent()
	end
	return false
end

local function cursor()
	local nav = _G.SmartNavigation
	return nav and nav.Pointer and nav.Pointer.Icon and nav.Pointer.Icon.Cursor, nav
end

local function sync()
	local tex, nav = cursor()
	if not tex then return end
	if ours(nav.currentButton) then
		pcall(glow, _G.WowCompanionLog)
		if not saved then
			local r, g, b, a = tex:GetVertexColor()
			saved = { tex:GetAtlas(), r, g, b, a }
		end
		tex:SetTexture(POINTER)
		tex:SetTexCoord(0, 1, 0, 1)
		tex:SetSize(SIZE, SIZE)
		tex:SetVertexColor(1, 1, 1, 1)
	elseif saved then
		local s = saved
		saved = nil
		if s[1] then tex:SetAtlas(s[1], true) end
		tex:SetVertexColor(s[2] or 1, s[3] or 1, s[4] or 1, s[5] or 1)
	end
end

local hooked = false
local function hook()
	local nav = _G.SmartNavigation
	if hooked or not nav then return end
	hooked = true
	for _, name in ipairs({ "SelectButton", "ClearActiveFrames", "UpdateCursorColor",
		"SetOverrideIconAtlas", "ClearOverrideIconAtlas" }) do
		if type(nav[name]) == "function" then
			hooksecurefunc(nav, name, function() pcall(sync) end)
		end
	end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
	pcall(hook)
	if _G.WowCompanionLog then pcall(glow, _G.WowCompanionLog) end
end)

WC.FocusArt = { Dress = glow }
