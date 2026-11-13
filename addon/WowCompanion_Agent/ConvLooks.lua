-- The conversation list's looks on trial (round 7, docs/looks.md): Main, L1,
-- L2, R1, R2, Quick, the offered button's cell under them; a row's name in the
-- normal font, its chord's glyphs or its state ("12s", "new", the mic while it
-- is talked to) beside it. Every look stands in the channel well (the list
-- sunk between the crests' rules, centred in the well's height) and, but for
-- the references, is round 6's ruled list with cells' highlight: the open row's
-- cell the light stone and its two rules lit. They differ in the cells and how
-- they join the well (ruled(), below).
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
local CHORD_RIGHT, NAME_RIGHT = 98, 14 -- a chord's centre, a name's left
local LIT = 0.75 -- a part with no lit art: itself added over itself at this alpha
local DEEP = 0.55 -- the well where it is sunk
local RUN = 64 -- a vine run's art, its length in units
local ARM = 7 -- a joint's art kept beside its spine (its fillets); the arm runs on from there
local CAPW = 32 -- a vine's round end, its art's length
C.IDLE_GLYPH = 0.6 -- a resting row's chord, sunk

local AGENT = [[Interface\AddOns\WowCompanion_Agent\Art\]]
local LIT_RUN = { [""] = AGENT .. "ConvVine-Rule-Lit", Thick = AGENT .. "ConvVine-RuleThick-Lit" }

-- A texture: tex its path, stone = "you"/"claude" (tiled, shade), or grad, a
-- colour ramp ("VERTICAL": from at the bottom, to at the top; "HORIZONTAL":
-- from at the left), black or, light, white added; x, y, w, h the whole art's
-- place in units; layer and sub its draw layer; rot (quarter turns
-- anticlockwise), flip and vflip (mirrored left to right, top to bottom) turn
-- the art; tileS, tileT: the art repeats that many times across, down; add:
-- blended additively at alpha; clip: { x0, x1, y0, y1 }, the part of it drawn.
-- Every texture is cut to the well's sides too (texcoords), so no art reaches
-- past its walls.
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
-- the same run from x0 to x1 with a round end at each (the vine's own Left and
-- Right pieces), cut short of whatever it would meet
local function hcut(t, y, x0, x1, weight, lit)
	for _, e in ipairs({ { "Left", x0 }, { "Right", x1 - CAPW } }) do
		local d = { tex = WC.Style.Vine(weight .. e[1]), x = e[2], y = y - 8, w = CAPW, h = 16, layer = "BORDER", sub = 1 }
		put(t, d)
		if lit then
			put(t, { tex = d.tex, x = e[2], y = y - 8, w = CAPW, h = 16, add = true, alpha = LIT, layer = "BORDER", sub = 2 })
		end
	end
	-- lit as its ends are, itself added over itself
	local d = { tex = WC.Style.Vine(weight .. "Mid"), x = x0 + CAPW, y = y - 8, w = x1 - x0 - 2 * CAPW, h = 16,
		tileS = (x1 - x0 - 2 * CAPW) / RUN, layer = "BORDER", sub = 1 }
	put(t, d)
	if lit then
		put(t, { tex = d.tex, x = d.x, y = d.y, w = d.w, h = 16, tileS = d.tileS, add = true, alpha = LIT, layer = "BORDER",
			sub = 2 })
	end
end
-- a thick vine down at x from y0 to y1, over its joints (whose own stretch of
-- it, mirrored for an arm to the left, would turn its light)
local function vvine(t, x, y0, y1)
	put(t, { tex = WC.Style.Vine("ThickVMid"), x = x - 8, y = y0, w = 16, h = y1 - y0, tileT = (y1 - y0) / RUN,
		layer = "BORDER", sub = 6 })
end
-- the plain joint (Style's ThickTRightFromMediumPlain) of a medium arm leaving
-- a thick vine at x, y, to the right (or the left), its fillets and ARM of the
-- arm; lit: added over itself
local function joint(t, x, y, left, lit)
	local clip = { left and x - ARM or x - 3, left and x + 3 or x + ARM, y - 8, y + 8 }
	local tex = WC.Style.Vine("ThickTRightFromMediumPlain")
	put(t, { tex = tex, x = x - 40, y = y - 40, w = 80, h = 80, flip = left, clip = clip, layer = "BORDER", sub = 4 })
	if lit then
		put(t, { tex = tex, x = x - 40, y = y - 40, w = 80, h = 80, flip = left, clip = { unpack(clip) }, add = true,
			alpha = LIT, layer = "BORDER", sub = 5 })
	end
end
-- the kept crests, each on its rule's y, never lit: the open row lights
-- only its own parts (the player, 2026-11-12)
local function crest(t, part, rule)
	put(t, { tex = AGENT .. "Crest-" .. part, x = 0, w = W,
		h = part == "Head" and HEAD_H or FOOT_H, y = rule - (part == "Head" and HEAD_RULE or FOOT_RULE),
		layer = "ARTWORK", sub = 0 })
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
-- stands in the middle of the well's height. Too short for the crests, a thick
-- vine stands in for each; shorter still, the rows shrink.
local KEYS = { "", "l1", "l2", "r1", "r2", "quick" }
local function stack(look, H, offered)
	local row, gap, lead = look.row, look.gap or 0, look.lead or 0
	local top, drop = HEAD_RULE, FOOT_DROP
	local extra = offered and OFFER or 0
	local ornate = top + 2 * lead + #KEYS * row + extra + drop <= H
	if not ornate then
		top, drop, lead = CAP, CAP, 2
		row = math.max(12, math.min(row, (H - top - drop - 2 * lead - extra) / #KEYS))
	end
	top = top + math.max(0, (H - (top + 2 * lead + #KEYS * row + extra + drop)) / 2)
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
-- the channel well: the list sunk between the crests' rules, the well's walls
-- under the head rule and over the foot's, the head's shadow falling in
local function channel(t, L)
	stone(t, "you", DEEP, 0, L.top, W, L.foot - L.top)
	wall(t, "Top", 0, L.top, W, L.foot - L.top)
	wall(t, "Bottom", 0, L.top, W, L.foot - L.top)
	shadow(t, 0, L.top, W, L.foot - L.top, 0.9)
end

-- The ruled list, every look but channel: a rule over each row, lit with the
-- open row it bounds, the open row's cell the light stone. The look says how:
--   weight   the rules' vine: "Thin" or "" (medium)
--   meet     how a rule meets the well's walls: nil (runs under them),
--            "joint" (a plain joint growing out of each wall), "cut" (round
--            ends CUT short of them), "frame" (a thick vine down each side
--            FRAME inside the walls, each rule a plain T on it)
--   own      the first and last rows have rules of their own, a lead under
--            and over the crests'; else they share the crests'
--   floor    every cell the light stone at this shade, the open one at full, lit
--   split    a thick vine down the rows at this x, each rule crossing it in a
--            pair of plain joints
--   nocell   the open row lit by its rules alone (round 6's ruled)
local CUT, FRAME = 10, 10
local function ruled(t, L, open, o)
	channel(t, L)
	ends(t, L)
	local x0, x1 = 0, W
	if o.meet == "frame" then x0, x1 = FRAME, W - FRAME elseif o.meet == "cut" then x0, x1 = CUT, W - CUT end
	local rows, n = L.rows, #L.rows
	for _, r in ipairs(rows) do
		local on = r.key == open and not o.nocell
		-- on a floor of light stone, the open cell's is lit too, to stand out
		if on or o.floor then stone(t, "claude", on and 1 or o.floor, x0, r.y, x1 - x0, r.h, on and o.floor, 1) end
	end
	local function rule(y, lit)
		if o.meet == "cut" then
			hcut(t, y, CUT, W - CUT, o.weight, lit)
		elseif o.meet == "joint" or o.meet == "frame" then
			-- a joint's thick vine under the wall (2 in), or the frame's
			local a, b = o.meet == "joint" and 2 or x0, o.meet == "joint" and W - 2 or x1
			joint(t, a, y, false, lit)
			joint(t, b, y, true, lit)
			hvine(t, y, a + ARM, b - ARM, o.weight, lit)
		else
			hvine(t, y, 0, W, o.weight, lit)
		end
		if o.split then
			joint(t, o.split, y, true, lit)
			joint(t, o.split, y, false, lit)
		end
	end
	local function openAt(i) return rows[i] and rows[i].key == open end
	for i = 2, n do rule(rows[i].y, openAt(i) or openAt(i - 1)) end
	local last = rows[n].y + rows[n].h
	if L.offer then rule(last, openAt(n)) end
	if o.own then
		rule(rows[1].y, openAt(1))
		if not L.offer then rule(last, openAt(n)) end
	else
		-- the crests' rules are the first and last rows' too: lit over them alone
		if openAt(1) then hvine(t, L.top, 0, W, "Thick", true) end
		if openAt(n) and not L.offer then hvine(t, L.foot, 0, W, "Thick", true) end
	end
	if o.meet == "frame" then
		vvine(t, x0, L.top, L.foot)
		vvine(t, x1, L.top, L.foot)
	end
	-- the split stops over the offered button
	if o.split then vvine(t, o.split, L.top, L.offer and last or L.foot) end
end
local function look(label, row, o, extra)
	local l = { label = label, row = row, lead = o.own and 6 or 0, draw = function(t, L, open) ruled(t, L, open, o) end }
	for k, v in pairs(extra or {}) do l[k] = v end
	return l
end

local looks = {}
C.LOOKS = looks
C.ORDER = { "joined", "framed", "own", "split", "floor", "cut", "tall", "ruled", "cells", "channel" }

looks.joined = look("Joined", 24, { weight = "", meet = "joint" })
looks.framed = look("Framed", 24, { weight = "", meet = "frame" }, { name = 20 })
looks.own = look("Own rules", 24, { weight = "", meet = "joint", own = true })
looks.split = look("Split", 24, { weight = "", split = 74 }, { chord = 100 })
looks.floor = look("Floor", 24, { weight = "", floor = 0.8 })
looks.cut = look("Cut ends", 24, { weight = "", meet = "cut" }, { name = 18 })
looks.tall = look("Tall", 28, { weight = "Thin", meet = "joint" }, { name = 20, chord = 96 })
-- the references: round 6's ruled and cells, round 5's buttons
looks.ruled = look("Ruled (round 6)", 24, { weight = "", nocell = true })
looks.cells = look("Cells (round 6)", 24, { weight = "Thin" })
looks.channel = { label = "Channel (buttons)", row = 30, gap = 4, lead = 8, draw = function(t, L, open)
	channel(t, L)
	ends(t, L)
	for _, r in ipairs(L.rows) do slab(t, r.y0, r.y1, r.key == open) end
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
