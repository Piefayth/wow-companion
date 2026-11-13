-- The conversation list's looks on trial (round 6, docs/looks.md): Main, L1,
-- L2, R1, R2, Quick, the offered button's cell under them; a row's name in the
-- normal font, its chord's glyphs or its state ("12s", "new", the mic while it
-- is talked to) beside it. Every look but channel (round 5's, kept to compare)
-- makes an entry of the window's own lines rather than a button, and each
-- pairs one entry with one way of joining the window:
--   bar       no well: every rule springs from the chat's scroll bar (its
--             right border, as the chat's dividers join its left) and runs to
--             the rim, the crests on the first and last; open: the cell the
--             light stone, its two rules lit
--   open      no well: the crests' rules and a rule between rows run from the
--             chat well's wall to the rim; open: the cell the light stone,
--             its two rules lit
--   stems     no well: a thick spine hangs from the title rule down the left,
--             each name on a short stem from it; open: its stem lit
--   spine     the channel well; a thick spine down its right between the
--             crests, each name over an arm branching from it; open: its arm lit
--   ruled     the channel well; the chat's medium dividers between the rows;
--             open: its two rules lit
--   cells     the channel well; thin rules between the rows; open: the cell
--             the light stone, its two rules lit
--   sockets   a well only as tall as the list, centred, the crests on its
--             walls; the chord in a small socket; open: the socket lit
--   hung      a well only as tall as the list, under the title rule, the foot
--             crest hanging from it; open: the cell the light stone
--   channel   round 5's: the list sunk between the crests' rules; the window's
--             button for each row; open: its face the light stone and the glow
-- Pure: C.Lay(key, H, offered, open) says where every texture goes in a well
-- H units tall and where each row and its words sit, and ConvList.lua draws
-- it; tools/mock_convlist.py runs this same file to draw the looks over a
-- screenshot.
local C = {}
WC.ConvLooks = C

-- units, from the well's top left
local W = 130 -- the well (Window.lua's WELL); its walls cover INSET each side
local INSET = 4
local GAP = 7 -- Window.lua's: between the wells, and from the well to the rim
local BAR_RIGHT = -GAP - INSET -- the chat's scroll bar column's right edge (ScrollBar.lua, EDGE in)
local SX0, SX1 = INSET + 1, W - INSET - 1 -- a slab's face: wall to wall, its rim just clear of the walls
local OFFER = 36 -- the offered button's cell
local HEAD_H, HEAD_RULE, FOOT_H, FOOT_RULE, FOOT_DROP = 37, 32, 28, 4, 24 -- the crests: each one's rule; the foot's ornament under its rule
local CAP = 6 -- a crest's room when the well is too short for crests (a thick vine instead)
local FLAT, FLAT_TOP, FLAT_FOOT = 4, 8 / 36, 28.5 / 36 -- a slab's flat face: 4 in from its ends; its art's rows
local CHORD_RIGHT, NAME_RIGHT = 98, 14 -- a chord's centre, a name's left
local SOCKET_W, SOCKET_H = 54, 18 -- a chord's socket, wide enough for two glyphs
local LIT = 0.75 -- a part with no lit art: itself added over itself at this alpha
local DEEP = 0.55 -- the well where it is sunk
local RUN = 64 -- a vine run's art, its length in units
local ARM = 12 -- a joint's art kept beside its spine; the arm runs on from there
C.IDLE_GLYPH = 0.6 -- a resting row's chord, sunk

local AGENT = [[Interface\AddOns\WowCompanion_Agent\Art\]]
local LIT_RUN = { [""] = AGENT .. "ConvVine-Rule-Lit", Thick = AGENT .. "ConvVine-RuleThick-Lit" }

-- what a look may cover across: the well, or past it (bare) to the chat
-- well's wall and the rim, or (reach) to the chat's scroll bar
local X0, X1 = 0, W

-- A texture: tex its path, stone = "you"/"claude" (tiled, shade), or grad, a
-- colour ramp ("VERTICAL": from at the bottom, to at the top; "HORIZONTAL":
-- from at the left), black or, light, white added; x, y, w, h the whole art's
-- place in units; layer and sub its draw layer; rot (quarter turns
-- anticlockwise), flip and vflip (mirrored left to right, top to bottom) turn
-- the art; tileS, tileT: the art repeats that many times across, down; add:
-- blended additively at alpha; clip: { x0, x1, y0, y1 }, the part of it drawn.
-- Every texture is cut to what the look covers too (texcoords).
local function put(t, d)
	local c = d.clip or {}
	local x0, x1 = math.max(d.x, c[1] or X0, X0), math.min(d.x + d.w, c[2] or X1, X1)
	local y0, y1 = math.max(d.y, c[3] or d.y), math.min(d.y + d.h, c[4] or d.y + d.h)
	if x1 <= x0 or y1 <= y0 then return end
	d.cut = { (x0 - d.x) / d.w, (x1 - d.x) / d.w, (y0 - d.y) / d.h, (y1 - d.y) / d.h }
	d.x, d.y, d.w, d.h, d.clip = x0, y0, x1 - x0, y1 - y0, nil
	t[#t + 1] = d
end

-- texcoords for SetTexCoord's eight numbers: what of the art shows at each
-- corner of the drawn rectangle once turned, mirrored, cut and repeated
function C.Coords(d)
	local s0, s1, t0, t1 = unpack(d.cut)
	local function tex(s, t)
		if d.flip then s = 1 - s end
		if d.vflip then t = 1 - t end
		for _ = 1, (d.rot or 0) % 4 do s, t = 1 - t, s end
		return s * (d.tileS or 1), t * (d.tileT or 1)
	end
	local ulx, uly = tex(s0, t0)
	local llx, lly = tex(s0, t1)
	local urx, ury = tex(s1, t0)
	local lrx, lry = tex(s1, t1)
	return ulx, uly, llx, lly, urx, ury, lrx, lry
end

-- lit: added over itself
local function stone(t, which, shade, x, y, w, h, lit, sub)
	put(t, { stone = which, shade = shade, x = x, y = y, w = w, h = h, layer = "BACKGROUND", sub = sub or 0 })
	if lit then
		put(t, { stone = which, shade = shade, x = x, y = y, w = w, h = h, add = true, alpha = LIT,
			layer = "BACKGROUND", sub = (sub or 0) + 1 })
	end
end
-- art cut in a grid: xs and ys the drawn edges, ss and ts the art's (0 to 1)
-- at them, the cells between stretched; hollow: the middle cell left out
local function grid(t, base, xs, ss, ys, ts, hollow)
	for i = 1, #xs - 1 do
		for j = 1, #ys - 1 do
			if not (hollow and i == 2 and j == 2) then
				local a, b, c, e = xs[i], xs[i + 1], ys[j], ys[j + 1]
				local sw, th = (b - a) / (ss[i + 1] - ss[i]), (e - c) / (ts[j + 1] - ts[j])
				local d = { x = a - ss[i] * sw, y = c - ts[j] * th, w = sw, h = th, clip = { a, b, c, e } }
				for k, v in pairs(base) do d[k] = v end
				put(t, d)
			end
		end
	end
end
-- Blizzard's soft shadow (ShadowOverlay) falling from the top edge of the box
-- x, y, w, h into it
local SHADE = 12 -- Style.lua's
local function shadow(t, x, y, w, h, alpha)
	put(t, { tex = [[Interface\Common\ShadowOverlay-Top]], x = x, y = y, w = w, h = math.min(SHADE, h),
		alpha = alpha or 0.7, layer = "BACKGROUND", sub = 2, shadow = "Top" })
end
-- the well's own inset wall (Window.lua's dress: Inset, INSET deep) along
-- the box x, y, w, h's top (edge "Top") or foot ("Bottom")
local function wall(t, edge, x, y, w, h)
	put(t, { tex = AGENT .. "Inset-" .. edge .. "Edge-22", x = x, y = edge == "Top" and y or y + h - INSET, w = w,
		h = INSET, layer = "BACKGROUND", sub = 2 })
end
-- a well of its own, the box x, y, w, h: the window's inset (its walls over
-- everything inside, as the real well's are) round the darker slate
local function inset(t, x, y, w, h)
	stone(t, "you", 1, x + 3, y + 3, w - 6, h - 6)
	local e = INSET
	for _, p in ipairs({
		{ "TopLeftCorner", x, y, e, e }, { "TopRightCorner", x + w - e, y, e, e },
		{ "BottomLeftCorner", x, y + h - e, e, e }, { "BottomRightCorner", x + w - e, y + h - e, e, e },
		{ "TopEdge", x + e, y, w - 2 * e, e }, { "BottomEdge", x + e, y + h - e, w - 2 * e, e },
		{ "LeftEdge", x, y + e, e, h - 2 * e }, { "RightEdge", x + w - e, y + e, e, h - 2 * e } }) do
		put(t, { tex = AGENT .. "Inset-" .. p[1] .. "-22", x = p[2], y = p[3], w = p[4], h = p[5],
			layer = "ARTWORK", sub = 4 })
	end
end
-- A vine run across at y from x0 to x1 (weight "Thin", "" or "Thick"), its
-- ends bare (under a wall, or into a joint); lit: its lit art, or itself added
-- over itself
local function hvine(t, y, x0, x1, weight, lit)
	weight = weight or "Thick"
	local art = lit and LIT_RUN[weight] or WC.Style.Vine(weight .. "Mid")
	put(t, { tex = art, x = x0, y = y - 8, w = x1 - x0, h = 16, tileS = (x1 - x0) / RUN, layer = "BORDER", sub = 1 })
	if lit and not LIT_RUN[weight] then
		put(t, { tex = art, x = x0, y = y - 8, w = x1 - x0, h = 16, tileS = (x1 - x0) / RUN, add = true, alpha = LIT,
			layer = "BORDER", sub = 2 })
	end
end
-- a thick vine down at x from y0 to y1, over its arms' joints (whose own
-- stretch of it, mirrored for an arm to the left, would turn its light); cap:
-- a round end at its foot
local function vvine(t, x, y0, y1, cap)
	if cap then
		put(t, { tex = WC.Style.Vine("ThickBottom"), x = x - 8, y = y1 - 32, w = 16, h = 32, layer = "BORDER", sub = 6 })
		y1 = y1 - 32
	end
	put(t, { tex = WC.Style.Vine("ThickVMid"), x = x - 8, y = y0, w = 16, h = y1 - y0, tileT = (y1 - y0) / RUN,
		layer = "BORDER", sub = 6 })
end
-- a medium arm leaving the thick vine at x, y, to the right (or left) as far
-- as to: the plain joint's fillets, then the run; lit: both added over
-- themselves
local function arm(t, x, y, to, lit)
	local left = to < x
	local clip = { left and x - ARM or x - 3, left and x + 3 or x + ARM, y - 8, y + 8 }
	local tex = WC.Style.Vine("ThickTRightFromMediumPlain")
	put(t, { tex = tex, x = x - 40, y = y - 40, w = 80, h = 80, flip = left, clip = clip, layer = "BORDER", sub = 4 })
	if lit then
		put(t, { tex = tex, x = x - 40, y = y - 40, w = 80, h = 80, flip = left, clip = { unpack(clip) }, add = true,
			alpha = LIT, layer = "BORDER", sub = 5 })
	end
	if left then hvine(t, y, to, x - ARM, "", lit) else hvine(t, y, x + ARM, to, "", lit) end
end
-- a vine across at y springing from the chat's scroll bar: the bar's own
-- joint mirrored onto its right border (the chat's dividers join its left),
-- its knob kept, then the run to x1
local function fromBar(t, y, x1, weight, lit)
	local x = BAR_RIGHT - 26 -- the joint's art, 32 wide, mirrored over the column's right border
	put(t, { tex = [[Interface\AddOns\WowCompanion\Art\Scroll-Joint-19]], x = x, y = y - 8, w = 32, h = 16, flip = true,
		clip = { BAR_RIGHT - 13, BAR_RIGHT + 1 }, layer = "BORDER", sub = 2 })
	hvine(t, y, BAR_RIGHT + 1, x1, weight, lit)
end
-- the kept crests, each on its rule's y, never lit: the open row lights
-- only its own parts (the player, 2026-11-12)
local function crest(t, part, rule)
	put(t, { tex = AGENT .. "Crest-" .. part, x = 0, w = W,
		h = part == "Head" and HEAD_H or FOOT_H, y = rule - (part == "Head" and HEAD_RULE or FOOT_RULE),
		layer = "ARTWORK", sub = 0 })
end
-- a carved socket (the dropdown's closed slot: its round ends, its floor)
-- from x0 to x1, h tall, centred on cy; lit: added over itself
local function socket(t, x0, x1, cy, h, lit)
	local e, y = h / 2, cy - h / 2
	for _, p in ipairs({ { "Choice-Left-Closed", x0, e }, { "Choice-Mid", x0 + e, x1 - x0 - h },
		{ "Choice-Right-Closed", x1 - e, e } }) do
		put(t, { tex = WC.Style.Control(p[1]), x = p[2], y = y, w = p[3], h = h, layer = "ARTWORK", sub = 1 })
		if lit then
			put(t, { tex = WC.Style.Control(p[1]), x = p[2], y = y, w = p[3], h = h, add = true, alpha = LIT,
				layer = "ARTWORK", sub = 2 })
		end
	end
end
-- the focus glow's bronze (FocusArt's texture) round the box x, y, w, h: its
-- rim on the box's edge, the glow OUT past it, over the stones round it
local GLOW_OUT, GLOW_M = 8, 12 -- 4 texels a unit: the rim 32 in, the slices 48
local function glow(t, x, y, w, h)
	local a, b = 48 / 128, 80 / 128
	local x0, x1, y0, y1 = x - GLOW_OUT, x + w + GLOW_OUT, y - GLOW_OUT, y + h + GLOW_OUT
	grid(t, { tex = AGENT .. "Focus-Glow-1", layer = "BACKGROUND", sub = 4 },
		{ x0, x0 + GLOW_M, x1 - GLOW_M, x1 }, { 0, a, b, 1 }, { y0, y0 + GLOW_M, y1 - GLOW_M, y1 }, { 0, a, b, 1 }, true)
end
-- the window's button (Style.Button's art, make_button_art.py's version 1),
-- channel's rows: the face x0..x1, y0..y1, the art 16 past each end and 4 past
-- its top and foot, its ends cut 28 in; resting at sub 1, the lit one at 5
-- over its neighbours, its face the light stone, ringed by the focus glow
local BUTTON = [[Interface\AddOns\WowCompanion\Art\Button-%s-1]]
local function slab(t, y0, y1, lit)
	local function art(base)
		grid(t, base, { SX0 - 16, SX0 + 12, SX1 - 12, SX1 + 16 }, { 0, 28 / 160, 132 / 160, 1 }, { y0 - 4, y1 + 4 },
			{ 0, 1 })
	end
	if not lit then
		art({ tex = BUTTON:format("Rest"), layer = "BACKGROUND", sub = 1 })
		return
	end
	art({ tex = BUTTON:format("Lit"), layer = "BACKGROUND", sub = 5 })
	glow(t, SX0, y0, SX1 - SX0, y1 - y0)
	local h = y1 - y0 + 8
	stone(t, "claude", 1, SX0 + FLAT, y0 - 4 + FLAT_TOP * h, SX1 - SX0 - 2 * FLAT, (FLAT_FOOT - FLAT_TOP) * h, false, 6)
end

-- The places every look shares: the head crest's rule (top), each row (its
-- pitch the look's row, its slab gap short of it), the offered button's cell,
-- the foot crest's rule (foot). lead: from each rule to the rows. The list
-- stands in the middle of the well's height, or at the look's `at`. Too short
-- for the crests, a thick vine stands in for each; shorter still, the rows
-- shrink.
local KEYS = { "", "l1", "l2", "r1", "r2", "quick" }
local function stack(look, H, offered)
	local row, gap, lead = look.row, look.gap or 0, look.lead
	local top, drop = look.head == false and 0 or HEAD_RULE, look.foot == false and 0 or FOOT_DROP
	local extra = offered and OFFER or 0
	local ornate = top + 2 * lead + #KEYS * row + extra + drop <= H
	if not ornate then
		top, drop, lead = CAP, CAP, 2
		row = math.max(12, math.min(row, (H - top - drop - 2 * lead - extra) / #KEYS))
	end
	if look.at then top = top + look.at
	else top = top + math.max(0, (H - (top + 2 * lead + #KEYS * row + extra + drop)) / 2) end
	local rows, y = {}, top + lead
	for i, key in ipairs(KEYS) do
		rows[i] = { key = key, y = y, h = row, y0 = y + gap / 2, y1 = y + row - gap / 2 }
		y = y + row
	end
	return { ornate = ornate, top = top, rows = rows, offer = offered and { y = y, h = OFFER } or nil,
		foot = y + extra + lead }
end
-- the crests (or the thick vines in their place), their rules carried from
-- x0 to x1 when the look reaches past the well
local function ends(t, L, x0, x1)
	x0, x1 = x0 or 0, x1 or W
	if L.ornate then
		crest(t, "Head", L.top)
		crest(t, "Foot", L.foot)
		if x0 < 0 then hvine(t, L.top, x0, 0.5) hvine(t, L.foot, x0, 0.5) end
		if x1 > W then hvine(t, L.top, W - 0.5, x1) hvine(t, L.foot, W - 0.5, x1) end
	else
		hvine(t, L.top, x0, x1)
		hvine(t, L.foot, x0, x1)
	end
end
-- the rules between the rows, x0 to x1; lit: the open row's two
local function rules(t, L, open, x0, x1, weight, lit)
	for i = 2, #L.rows do
		local on = lit and (L.rows[i].key == open or L.rows[i - 1].key == open)
		hvine(t, L.rows[i].y, x0, x1, weight, on)
	end
	if L.offer then hvine(t, L.offer.y, x0, x1, weight, lit and L.rows[#L.rows].key == open) end
end
-- the first and last rows' outer rules are the crests': lit over them alone
-- when that row is open
local function outer(t, L, open, x0, x1)
	if L.rows[1].key == open then hvine(t, L.top, x0, x1, "Thick", true) end
	if L.rows[#L.rows].key == open and not L.offer then hvine(t, L.foot, x0, x1, "Thick", true) end
end
-- the open row's cell, x0 to x1 between its rules: the light stone
local function cell(t, L, open, x0, x1)
	for _, r in ipairs(L.rows) do
		if r.key == open then stone(t, "claude", 1, x0, r.y, x1 - x0, r.h, false, 1) end
	end
end
-- the channel well: the list sunk between the crests' rules, the well's walls
-- under the head rule and over the foot's, the head's shadow falling in
local function channel(t, L)
	stone(t, "you", DEEP, 0, L.top, W, L.foot - L.top)
	wall(t, "Top", 0, L.top, W, L.foot - L.top)
	wall(t, "Bottom", 0, L.top, W, L.foot - L.top)
	shadow(t, 0, L.top, W, L.foot - L.top, 0.9)
end

local looks = {}
C.LOOKS = looks
C.ORDER = { "bar", "open", "stems", "spine", "ruled", "cells", "sockets", "hung", "channel" }

local BARE_X0, BARE_X1 = -GAP, W + GAP -- the chat well's wall, the rim

looks.bar = { label = "From the bar", row = 24, lead = 6, bare = true, reach = true, draw = function(t, L, open)
	if L.ornate then
		crest(t, "Head", L.top)
		crest(t, "Foot", L.foot)
	end
	-- each rule lit with the open row it bounds
	local function lit(i) return L.rows[i] and L.rows[i].key == open end
	fromBar(t, L.top, BARE_X1, "Thick", lit(1))
	fromBar(t, L.foot, BARE_X1, "Thick", lit(#L.rows) and not L.offer)
	for i = 2, #L.rows do fromBar(t, L.rows[i].y, BARE_X1, "", lit(i) or lit(i - 1)) end
	if L.offer then fromBar(t, L.offer.y, BARE_X1, "", lit(#L.rows)) end
	cell(t, L, open, BARE_X0, BARE_X1)
end }

looks.open = { label = "Open", row = 24, lead = 6, bare = true, draw = function(t, L, open)
	ends(t, L, BARE_X0, BARE_X1)
	rules(t, L, open, BARE_X0, BARE_X1, "", true)
	outer(t, L, open, BARE_X0, BARE_X1)
	cell(t, L, open, BARE_X0, BARE_X1)
end }

local STEM_X = 4 -- stems' spine, by the chat well's wall
looks.stems = { label = "Stems", row = 26, lead = 0, at = 6, head = false, foot = false, bare = true, name = 30, rowX = 18,
	draw = function(t, L, open)
		-- from the title rule's foot (GAP over the well) to a round end under the list
		vvine(t, STEM_X, -GAP - 0.5, L.foot + 10, true)
		for _, r in ipairs(L.rows) do arm(t, STEM_X, r.y + r.h / 2, 24, r.key == open) end
	end }

local SPINE_X = W - 12
looks.spine = { label = "Spine", row = 26, lead = 6, chord = 90, offerRight = SPINE_X - 6, draw = function(t, L, open)
	channel(t, L)
	ends(t, L)
	vvine(t, SPINE_X, L.top, L.foot)
	-- each name over its arm, at the row's foot
	for _, r in ipairs(L.rows) do arm(t, SPINE_X, r.y + r.h - 3, 0, r.key == open) end
end }

looks.ruled = { label = "Ruled", row = 24, lead = 0, draw = function(t, L, open)
	channel(t, L)
	ends(t, L)
	rules(t, L, open, 0, W, "", true)
	outer(t, L, open, 0, W)
end }

looks.cells = { label = "Cells", row = 24, lead = 0, draw = function(t, L, open)
	channel(t, L)
	ends(t, L)
	rules(t, L, open, 0, W, "Thin", true)
	outer(t, L, open, 0, W)
	cell(t, L, open, 0, W)
end }

looks.sockets = { label = "Sockets", row = 24, lead = 4, bare = true, draw = function(t, L, open)
	-- a well only as tall as the list, its top and foot walls on the crests' rules
	if L.ornate then
		inset(t, 0, L.top - 2, W, L.foot - L.top + 4)
		crest(t, "Head", L.top)
		crest(t, "Foot", L.foot)
	else
		ends(t, L)
	end
	rules(t, L, open, 0, W, "Thin")
	for _, r in ipairs(L.rows) do
		socket(t, CHORD_RIGHT - SOCKET_W / 2, CHORD_RIGHT + SOCKET_W / 2, r.y + r.h / 2, SOCKET_H, r.key == open)
	end
end }

looks.hung = { label = "Hung", row = 24, lead = 4, at = 0, head = false, bare = true, draw = function(t, L, open)
	inset(t, 0, 0, W, L.foot + 2)
	if L.ornate then crest(t, "Foot", L.foot) end
	rules(t, L, open, 0, W, "Thin")
	cell(t, L, open, 0, W)
end }

looks.channel = { label = "Channel (buttons)", row = 30, gap = 4, lead = 8, draw = function(t, L, open)
	channel(t, L)
	ends(t, L)
	for _, r in ipairs(L.rows) do slab(t, r.y0, r.y1, r.key == open) end
end }

-- The look key laid out in a well H units tall: pieces, every texture; rows,
-- each row's place and its words' (name: its left, chord: the centre of its
-- glyphs, and of its state, which takes the chord's place while there is one;
-- units in from the row's left); offer, the offered button's cell { x, y, w, h };
-- bare, the well's own walls and floor hidden; reach, art over the chat's
-- scroll bar (drawn over the chat well's wall); x0, x1, what the look covers
function C.Lay(key, H, offered, open)
	local look = looks[key]
	X0 = look.reach and BAR_RIGHT - 26 or look.bare and BARE_X0 or 0
	X1 = look.bare and BARE_X1 or W
	local L = stack(look, H, offered)
	local t, rows = {}, {}
	look.draw(t, L, open)
	for _, r in ipairs(L.rows) do
		local x = look.rowX or INSET
		rows[r.key] = { x = x, y = r.y, w = W - INSET - x, h = r.h,
			name = (look.name or NAME_RIGHT) - x, chord = (look.chord or CHORD_RIGHT) - x }
	end
	local o = L.offer
	local ox1 = look.offerRight or W - INSET - 6
	return { pieces = t, rows = rows, offer = o and { INSET + 6, o.y + 6, ox1 - INSET - 6, o.h - 12 },
		bare = look.bare or false, reach = look.reach or false, x0 = X0, x1 = X1 }
end
