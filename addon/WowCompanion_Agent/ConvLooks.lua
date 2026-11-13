-- The conversation list's looks on trial (round 5, docs/looks.md): every look
-- is the window's button slab (Style.Button's art), one per row, wall to wall
-- in the well, Main, L1, L2, R1, R2, Quick under the head crest, the offered
-- button's cell under them and the foot crest closing the list; a row's name
-- in the normal font, its chord's glyphs or its state ("12s", "new", the mic
-- while it is talked to) beside it. What differs is the slabs' height and
-- spacing, where the chord sits, how the open slab lights, and how the crests
-- join the panel:
--   drawers   slabs touching; the head crest's rule is the first slab's top
--             rim, the foot's the last slab's foot; open: lit, ringed by the
--             focus glow
--   capstone  each crest on a slab of its own the well's width, its rule along
--             that slab's edge; open: the lit slab's face the light stone
--   recess    each crest in a band of the well sunk the well's width, its rule
--             the band's lip; the chord at the left; open: the lit slab
--   plinth    each crest on a raised band of the light stone, its rule the
--             band's edge; compact slabs, the chord in a socket; open: the
--             lit slab's rim doubled
--   channel   the list sunk between the crests' rules, each crest casting its
--             shadow into it; slabs nearly touching; open: the face the light
--             stone and the focus glow
--   panel     the list a panel of the light stone, the crests' rules its top
--             and foot borders; the chord in a socket at the left; open: the
--             lit slab ringed by the focus glow
-- Pure: C.Lay(key, H, offered, open) says where every texture goes in a well
-- H units tall and where each row and its words sit, and ConvList.lua draws
-- it; tools/mock_convlist.py runs this same file to draw the looks over a
-- screenshot.
local C = {}
WC.ConvLooks = C

-- units, from the well's top left
local W = 130 -- the well (Window.lua's WELL); its walls cover INSET each side
local INSET = 4
local SX0, SX1 = INSET + 1, W - INSET - 1 -- a slab's face: wall to wall, its rim just clear of the walls
local OFFER = 36 -- the offered button's cell
local HEAD_H, HEAD_RULE, FOOT_H, FOOT_RULE, FOOT_DROP = 37, 32, 28, 4, 24 -- the crests: each one's rule; the foot's ornament under its rule
local CAP = 6 -- a crest's room when the well is too short for crests (a thick vine instead)
local FLAT, FLAT_TOP, FLAT_FOOT = 4, 8 / 36, 28.5 / 36 -- a slab's flat face: 4 in from its ends; its art's rows
local CHORD_RIGHT, CHORD_LEFT, NAME_RIGHT, NAME_LEFT = 98, 33, 14, 62 -- a chord's centre, a name's left
local SOCKET_W, SOCKET_H = 54, 22 -- a chord's socket, wide enough for two glyphs
local LIT = 0.75 -- a part with no lit art: itself added over itself at this alpha
local DEEP = 0.55 -- the well where it is sunk
C.IDLE_GLYPH = 0.6 -- a resting row's chord, sunk

local AGENT = [[Interface\AddOns\WowCompanion_Agent\Art\]]

-- A texture: tex its path, stone = "you"/"claude" (tiled, shade), or grad, a
-- colour ramp ("VERTICAL": from at the bottom, to at the top; "HORIZONTAL":
-- from at the left), black or, light, white added; x, y, w, h the whole art's
-- place in units; layer and sub its draw layer; rot (quarter turns
-- anticlockwise), flip and vflip (mirrored left to right, top to bottom) turn
-- the art; add: blended additively at alpha; clip: { x0, x1, y0, y1 }, the
-- part of it drawn. Every texture is cut to the well's sides too (texcoords),
-- so no art reaches past its walls.
local function put(t, d)
	local c = d.clip or {}
	local x0, x1 = math.max(d.x, c[1] or 0, 0), math.min(d.x + d.w, c[2] or W, W)
	local y0, y1 = math.max(d.y, c[3] or d.y), math.min(d.y + d.h, c[4] or d.y + d.h)
	if x1 <= x0 or y1 <= y0 then return end
	d.cut = { (x0 - d.x) / d.w, (x1 - d.x) / d.w, (y0 - d.y) / d.h, (y1 - d.y) / d.h }
	d.x, d.y, d.w, d.h, d.clip = x0, y0, x1 - x0, y1 - y0, nil
	t[#t + 1] = d
end

-- texcoords for SetTexCoord's eight numbers: what of the art shows at each
-- corner of the drawn rectangle once turned, mirrored and cut
function C.Coords(d)
	local s0, s1, t0, t1 = unpack(d.cut)
	local function tex(s, t)
		if d.flip then s = 1 - s end
		if d.vflip then t = 1 - t end
		for _ = 1, (d.rot or 0) % 4 do s, t = 1 - t, s end
		return s, t
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
-- a ramp along one side of the box x, y, w, h, depth deep: edge its alpha at
-- the side, inner its alpha inward (+ light, - shade)
local function band(t, side, x, y, w, h, depth, edge, inner)
	local d = { x = x, y = y, w = w, h = h, layer = "BACKGROUND", sub = 3, light = edge > 0 }
	edge, inner = math.abs(edge), math.abs(inner)
	if side == "TOP" then d.h, d.grad, d.from, d.to = depth, "VERTICAL", inner, edge
	else d.y, d.h, d.grad, d.from, d.to = y + h - depth, depth, "VERTICAL", edge, inner end
	put(t, d)
end
-- stone standing up out of the well: lit along its top, shaded along its
-- foot, a soft light under the top and shade over the foot
local function raise(t, x, y, w, h)
	band(t, "TOP", x, y, w, h, 2, 0.16, 0.16)
	band(t, "TOP", x, y, w, h, 12, 0.1, 0)
	band(t, "BOTTOM", x, y, w, h, 2, -0.65, -0.65)
	band(t, "BOTTOM", x, y, w, h, 10, -0.4, 0)
end
-- Blizzard's soft shadow (ShadowOverlay) falling from the top edge of the box
-- x, y, w, h into it
local SHADE = 12 -- Style.lua's
local function shadow(t, x, y, w, h, alpha)
	put(t, { tex = [[Interface\Common\ShadowOverlay-Top]], x = x, y = y, w = w, h = math.min(SHADE, h),
		alpha = alpha or 0.7, layer = "BACKGROUND", sub = 2, shadow = "Top" })
end
-- the box x, y, w, h sunk in the well: darker, the shadow inside its top, as
-- Style.Well sinks a well, the light catching its lower lip
local function sink(t, x, y, w, h)
	stone(t, "you", DEEP, x, y, w, h)
	shadow(t, x, y, w, h)
	band(t, "BOTTOM", x, y, w, h, 2, 0.14, 0.14)
end
-- the well's own inset wall (Window.lua's dress: Inset, INSET deep) along
-- the box x, y, w, h's top (edge "Top") or foot ("Bottom")
local function wall(t, edge, x, y, w, h)
	put(t, { tex = AGENT .. "Inset-" .. edge .. "Edge-21", x = x, y = edge == "Top" and y or y + h - INSET, w = w,
		h = INSET, layer = "BACKGROUND", sub = 2 })
end
-- the thick vine across at y from x0 to x1, its ends bare (under the walls)
local function hvine(t, y, x0, x1)
	put(t, { tex = WC.Style.Vine("ThickMid"), x = x0, y = y - 8, w = x1 - x0, h = 16, layer = "BORDER", sub = 1 })
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
-- the window's button (Style.Button's art, make_button_art.py's version 1):
-- the face x0..x1, y0..y1, the art 16 past each end and 4 past its top and
-- foot, its ends cut 28 in; resting at sub 1, the lit one at 5 over its
-- neighbours. lit, what lights it besides its lit art: glow, ringed by the
-- focus glow; stone, its face the light stone; double, its lit art added
-- over itself
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
	if lit.glow then glow(t, SX0, y0, SX1 - SX0, y1 - y0) end
	if lit.stone then
		local h = y1 - y0 + 8
		stone(t, "claude", 1, SX0 + FLAT, y0 - 4 + FLAT_TOP * h, SX1 - SX0 - 2 * FLAT, (FLAT_FOOT - FLAT_TOP) * h, false, 6)
	end
	if lit.double then art({ tex = BUTTON:format("Lit"), layer = "BACKGROUND", sub = 6, add = true, alpha = 0.6 }) end
end

-- The places every look shares: the head crest's rule (top), each row (its
-- pitch the look's row, its slab gap short of it), the offered button's cell,
-- the foot crest's rule (foot). lead: from each rule to the slabs. Too short
-- for the crests, a thick vine stands in for each; shorter still, the rows
-- shrink.
local KEYS = { "", "l1", "l2", "r1", "r2", "quick" }
local function stack(look, H, offered)
	local row, gap, lead = look.row, look.gap, look.lead
	local top, drop = HEAD_RULE, FOOT_DROP
	local extra = offered and OFFER or 0
	local ornate = top + 2 * lead + #KEYS * row + extra + drop <= H
	if not ornate then
		top, drop, lead = CAP, CAP, 2
		row = math.max(12, math.min(row, (H - top - drop - 2 * lead - extra) / #KEYS))
	end
	local rows, y = {}, top + lead
	for i, key in ipairs(KEYS) do
		rows[i] = { key = key, y = y, h = row, y0 = y + gap / 2, y1 = y + row - gap / 2 }
		y = y + row
	end
	return { ornate = ornate, top = top, rows = rows, offer = offered and { y = y, h = OFFER } or nil,
		foot = y + extra + lead }
end
-- the crests (or the thick vines in their place)
local function ends(t, L)
	if L.ornate then
		crest(t, "Head", L.top)
		crest(t, "Foot", L.foot)
	else
		hvine(t, L.top, 0, W)
		hvine(t, L.foot, 0, W)
	end
end
-- each row's slab, the open one lit as the look lights it
local function slabs(t, L, open, lit)
	for _, r in ipairs(L.rows) do slab(t, r.y0, r.y1, r.key == open and lit) end
end
-- each row's chord in a socket centred at x
local function sockets(t, L, open, x)
	for _, r in ipairs(L.rows) do
		local h = math.min(SOCKET_H, r.y1 - r.y0 - 4)
		socket(t, x - SOCKET_W / 2, x + SOCKET_W / 2, (r.y0 + r.y1) / 2, h, r.key == open)
	end
end
-- the foot crest's ornament's foot
local function footEnd(L) return L.foot - FOOT_RULE + FOOT_H end

local looks = {}
C.LOOKS = looks
C.ORDER = { "drawers", "capstone", "recess", "plinth", "channel", "panel" }

looks.drawers = { label = "Drawers", row = 28, gap = 0, lead = -1, draw = function(t, L, open)
	ends(t, L)
	slabs(t, L, open, { glow = true })
end }

looks.capstone = { label = "Capstone", row = 30, gap = 4, lead = 3, draw = function(t, L, open)
	ends(t, L)
	if L.ornate then
		slab(t, 2, L.top + 1)
		slab(t, L.foot - 1, footEnd(L) + 1)
	end
	slabs(t, L, open, { stone = true })
end }

looks.recess = { label = "Recess", row = 32, gap = 2, lead = 3, chord = CHORD_LEFT, name = NAME_LEFT,
	draw = function(t, L, open)
		ends(t, L)
		if L.ornate then
			sink(t, 0, 0, W, L.top)
			sink(t, 0, L.foot, W, footEnd(L) + 3 - L.foot)
		end
		slabs(t, L, open, {})
	end }

looks.plinth = { label = "Plinth", row = 26, gap = 4, lead = 3, chord = 96, draw = function(t, L, open)
	ends(t, L)
	if L.ornate then
		stone(t, "claude", 1, 0, 0, W, L.top)
		raise(t, 0, 0, W, L.top)
		stone(t, "claude", 1, 0, L.foot, W, footEnd(L) + 3 - L.foot)
		raise(t, 0, L.foot, W, footEnd(L) + 3 - L.foot)
	end
	slabs(t, L, open, { double = true })
	sockets(t, L, open, 96)
end }

looks.channel = { label = "Channel", row = 30, gap = 4, lead = 0, draw = function(t, L, open)
	ends(t, L)
	-- an inset of its own between the rules: the well's walls under the head
	-- rule and over the foot's, the head's shadow falling in
	stone(t, "you", DEEP, 0, L.top, W, L.foot - L.top)
	wall(t, "Top", 0, L.top, W, L.foot - L.top)
	wall(t, "Bottom", 0, L.top, W, L.foot - L.top)
	shadow(t, 0, L.top, W, L.foot - L.top, 0.9)
	slabs(t, L, open, { stone = true, glow = true })
end }

looks.panel = { label = "Panel", row = 30, gap = 6, lead = 4, chord = CHORD_LEFT, name = NAME_LEFT,
	draw = function(t, L, open)
		ends(t, L)
		stone(t, "claude", 1, 0, L.top, W, L.foot - L.top, true)
		shadow(t, 0, L.top, W, L.foot - L.top, 0.5)
		slabs(t, L, open, { glow = true })
		sockets(t, L, open, CHORD_LEFT)
	end }

-- The look key laid out in a well H units tall: pieces, every texture; rows,
-- each row's place and its words' (name: its left, chord: the centre of its
-- glyphs, and of its state, which takes the chord's place while there is one;
-- units in from the row's left); offer, the offered button's cell { x, y, w, h }
function C.Lay(key, H, offered, open)
	local look = looks[key]
	local L = stack(look, H, offered)
	local t, rows = {}, {}
	look.draw(t, L, open)
	for _, r in ipairs(L.rows) do
		rows[r.key] = { x = INSET, y = r.y, w = W - 2 * INSET, h = r.h,
			name = (look.name or NAME_RIGHT) - INSET, chord = (look.chord or CHORD_RIGHT) - INSET }
	end
	local o = L.offer
	return { pieces = t, rows = rows, offer = o and { INSET + 6, o.y + 6, W - 2 * INSET - 12, o.h - 12 } }
end
