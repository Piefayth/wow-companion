-- The conversation list's looks on trial (round 4, docs/looks.md): one layout,
-- each look a style of it. Every look stacks the same compact rows (Main, L1,
-- L2, R1, R2, Quick) under the head crest, the offered button's cell under
-- them and the foot crest closing the list; a row's name at its left, its
-- chord's glyphs or its state ("12s", "new") at its right. What differs is how
-- a row and the open row are drawn, from the window's own parts only:
--   ledger    bare names on the well's stone between thin vines; open: the
--             light stone lit and raised between the thick vines lit
--   bands     a sunk band in turn with the light stone, no vines; open: the
--             light stone raised, the focus glow's bronze along its edges
--   slots     each row a carved groove, the dropdown's; open: the groove
--             lifted and ringed by the controls' glow
--   strung    each chord in a socket, the sockets strung on the thick vine
--             from crest to crest, the names bare; open: the socket lit and
--             ringed, the name large
--   engraved  each row a cell sunk in the stone, its name in heavy type;
--             open: the cell raised instead, the light stone lit, casting its
--             shadow
--   slabs     each row the window's faceted button slab; open: the slab lit as
--             a button under the cursor, glow and bright rim
-- Pure: C.Lay(key, H, offered, open) says where every texture goes in a well
-- H units tall and where each row and its words sit, and ConvList.lua draws
-- it; tools/mock_convlist.py runs this same file to draw the looks over a
-- screenshot.
local C = {}
WC.ConvLooks = C

-- units, from the well's top left
local W = 130 -- the well (Window.lua's WELL); its walls cover INSET each side
local INSET = 4
local ROW, OFFER = 34, 36 -- a row; the offered button's cell
local HEAD_H, HEAD_RULE, FOOT_H, FOOT_RULE, FOOT_DROP = 37, 32, 28, 4, 24 -- the crests: each one's rule; the foot's ornament under its rule
local CAP = 6 -- a crest's room when the well is too short for crests (a thick vine instead)
local NAME_X, CHORD_X = 14, 94 -- a row's name's left and its chord's centre, from the well's left
local SOCKET_W, SOCKET_H = 52, 28 -- a chord's socket, wide enough for two glyphs or "talking"
local LIT = 0.75 -- a part with no lit art: itself added over itself at this alpha (the lit vines' bark is 1.7-1.9x)
local DEEP = 0.55 -- the well where it is sunk
C.IDLE_GLYPH = 0.6 -- a resting row's chord, sunk

local AGENT = [[Interface\AddOns\WowCompanion_Agent\Art\]]
local function vine(piece) return WC.Style.Vine(piece) end

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
local function stone(t, which, shade, x, y, w, h, lit)
	put(t, { stone = which, shade = shade, x = x, y = y, w = w, h = h, layer = "BACKGROUND", sub = 0 })
	if lit then
		put(t, { stone = which, shade = shade, x = x, y = y, w = w, h = h, add = true, alpha = LIT,
			layer = "BACKGROUND", sub = 1 })
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
	elseif side == "BOTTOM" then d.y, d.h, d.grad, d.from, d.to = y + h - depth, depth, "VERTICAL", edge, inner
	elseif side == "LEFT" then d.w, d.grad, d.from, d.to = depth, "HORIZONTAL", edge, inner
	else d.x, d.w, d.grad, d.from, d.to = x + w - depth, depth, "HORIZONTAL", inner, edge end
	put(t, d)
end
-- stone standing up out of the well: lit along its top and left, shaded
-- along its foot and right, a soft light under the top and shade over the foot
local RAISE = {
	{ "TOP", 2, 0.16, 0.16 }, { "TOP", 18, 0.1, 0 }, { "LEFT", 2, 0.16, 0.16 },
	{ "BOTTOM", 2, -0.65, -0.65 }, { "BOTTOM", 14, -0.4, 0 }, { "RIGHT", 2, -0.65, -0.65 },
}
local function raise(t, x, y, w, h)
	for _, b in ipairs(RAISE) do band(t, b[1], x, y, w, h, b[2], b[3], b[4]) end
end
-- the box x, y, w, h sunk in the well: darker, Blizzard's soft shadow
-- inside its top and left edges, as Style.Well sinks a well
local SHADE = 12 -- Style.lua's
local function sink(t, x, y, w, h)
	stone(t, "you", DEEP, x, y, w, h)
	put(t, { tex = [[Interface\Common\ShadowOverlay-Top]], x = x, y = y, w = w, h = math.min(SHADE, h), alpha = 0.7,
		layer = "BACKGROUND", sub = 2, shadow = "Top" })
	put(t, { tex = [[Interface\Common\ShadowOverlay-Left]], x = math.max(x, INSET), y = y, w = SHADE, h = h, alpha = 0.7,
		layer = "BACKGROUND", sub = 2, shadow = "Left" })
end
-- a vine across at y from x0 to x1, its ends bare (under a wall or a
-- junction); lit: the lit art (medium and thick), the thin one added over itself
local function hvine(t, weight, y, x0, x1, lit)
	local d = { x = x0, y = y - 8, w = x1 - x0, h = 16, layer = "BORDER", sub = lit and 5 or 1 }
	if lit and weight ~= "Thin" then
		d.tex = AGENT .. "ConvVine-Rule" .. weight .. "-Lit"
	else
		d.tex = vine(weight .. "Mid")
		if lit then
			put(t, { tex = d.tex, x = x0, y = y - 8, w = x1 - x0, h = 16, layer = "BORDER", sub = 6, add = true, alpha = 1 })
		end
	end
	put(t, d)
end
-- a vine down at x from y0 to y1, its ends bare
local function vvine(t, weight, x, y0, y1)
	put(t, { tex = vine(weight .. "VMid"), x = x - 8, y = y0, w = 16, h = y1 - y0, layer = "BORDER", sub = 0 })
end
-- the thick vine down at x between the crests' rules (or the thick vines in
-- their place), leaving each at a plain joint (Style.VineJoin's, turned so
-- its arm runs down from the top rule and up from the foot rule)
local JOIN = 112 -- ThickTRightBigPlain's size
local function seam(t, x, top, foot)
	for _, j in ipairs({ { top, { rot = 1, vflip = true }, { -1e9, 1e9, top - 2, foot } },
		{ foot, { rot = 1 }, { -1e9, 1e9, top, foot + 2 } } }) do
		local d = { tex = vine("ThickTRightBigPlain"), x = x - JOIN / 2, y = j[1] - JOIN / 2, w = JOIN, h = JOIN,
			layer = "BORDER", sub = 3, clip = j[3] }
		for k, v in pairs(j[2]) do d[k] = v end
		put(t, d)
	end
	vvine(t, "Thick", x, top, foot)
end
-- the kept crests, each on its rule's y
local function crest(t, part, rule, lit)
	put(t, { tex = AGENT .. "Crest-" .. part .. (lit and "-Lit" or ""), x = 0, w = W,
		h = part == "Head" and HEAD_H or FOOT_H, y = rule - (part == "Head" and HEAD_RULE or FOOT_RULE),
		layer = "ARTWORK", sub = 0 })
end
-- a carved groove (the dropdown's closed slot: its round ends, its floor)
-- from x0 to x1, h tall, centred on cy; lit: added over itself and ringed by
-- the controls' glow (each end's glow 4/32 of h past the end, as Settings')
local function groove(t, x0, x1, cy, h, lit)
	local e, y = h / 2, cy - h / 2
	local parts = { { "Choice-Left-Closed", x0, e }, { "Choice-Mid", x0 + e, x1 - x0 - h },
		{ "Choice-Right-Closed", x1 - e, e } }
	for _, p in ipairs(parts) do
		put(t, { tex = WC.Style.Control(p[1]), x = p[2], y = y, w = p[3], h = h, layer = "ARTWORK", sub = 1 })
		if lit then
			put(t, { tex = WC.Style.Control(p[1]), x = p[2], y = y, w = p[3], h = h, add = true, alpha = LIT,
				layer = "ARTWORK", sub = 2 })
		end
	end
	if not lit then return end
	local g = h * 20 / 32
	for _, p in ipairs({ { "Choice-Left-Closed", x0 + e - g }, { "Choice-Mid", x0 + e, x1 - x0 - h },
		{ "Choice-Right-Closed", x1 - e } }) do
		put(t, { tex = WC.Style.Control(p[1] .. "-Highlight"), x = p[2], y = y, w = p[3] or g, h = h, add = true,
			layer = "ARTWORK", sub = 3 })
	end
end
-- the focus glow's bronze (FocusArt's texture) round the box x, y, w, h: its
-- rim on the box's edge, the glow OUT past it, over the stones round it
local GLOW_OUT, GLOW_M = 8, 12 -- 4 texels a unit: the rim 32 in, the slices 48
local function glow(t, x, y, w, h)
	local a, b = 48 / 128, 80 / 128
	local x0, x1, y0, y1 = x - GLOW_OUT, x + w + GLOW_OUT, y - GLOW_OUT, y + h + GLOW_OUT
	grid(t, { tex = AGENT .. "Focus-Glow-1", layer = "BACKGROUND", sub = 1 },
		{ x0, x0 + GLOW_M, x1 - GLOW_M, x1 }, { 0, a, b, 1 }, { y0, y0 + GLOW_M, y1 - GLOW_M, y1 }, { 0, a, b, 1 }, true)
end
-- the window's button (Style.Button's art, make_button_art.py's version 1):
-- the slab's face x0..x1, y0..y1, the art 16 past each end and 4 past its
-- top and foot, its ends cut 28 in
local BUTTON = [[Interface\AddOns\WowCompanion\Art\Button-%s-1]]
local function slab(t, x0, x1, y0, y1, lit)
	local s = { 0, 28 / 160, 132 / 160, 1 }
	grid(t, { tex = BUTTON:format(lit and "Lit" or "Rest"), layer = "BACKGROUND", sub = 1 },
		{ x0 - 16, x0 + 12, x1 - 12, x1 + 16 }, s, { y0 - 4, y1 + 4 }, { 0, 1 })
end

-- The places every look shares: the head crest's rule (top), each row, the
-- offered button's cell, the foot crest's rule (foot). Too short for the
-- crests, a thick vine stands in for each; shorter still, the rows shrink.
local KEYS = { "", "l1", "l2", "r1", "r2", "quick" }
local function stack(H, offered)
	local top, drop, row = HEAD_RULE, FOOT_DROP, ROW
	local extra = offered and OFFER or 0
	local ornate = top + #KEYS * row + extra + drop <= H
	if not ornate then
		top, drop = CAP, CAP
		row = math.max(12, math.min(ROW, (H - top - drop - extra) / #KEYS))
	end
	local rows, y = {}, top
	for i, key in ipairs(KEYS) do
		rows[i] = { key = key, y = y, h = row }
		y = y + row
	end
	return { ornate = ornate, top = top, rows = rows, offer = offered and { y = y, h = OFFER } or nil, foot = y + extra }
end
-- the crests (or the thick vines in their place), lit beside the open row
-- when the look's rows meet their rules
local function ends(t, L, headLit, footLit)
	if L.ornate then
		crest(t, "Head", L.top, headLit)
		crest(t, "Foot", L.foot, footLit)
	else
		hvine(t, "Thick", L.top, 0, W, headLit)
		hvine(t, "Thick", L.foot, 0, W, footLit)
	end
end
-- whether row i is the open one (none past either end)
local function openAt(L, i, open) return L.rows[i] and L.rows[i].key == open end

local looks = {}
C.LOOKS = looks
C.ORDER = { "ledger", "bands", "slots", "strung", "engraved", "slabs" }

looks.ledger = { label = "Ledger", draw = function(t, L, open)
	local n = #L.rows
	ends(t, L, openAt(L, 1, open), openAt(L, n, open) and not L.offer)
	for i, r in ipairs(L.rows) do
		local lit = r.key == open
		if i > 1 then
			local litNow = lit or openAt(L, i - 1, open)
			hvine(t, litNow and "Thick" or "Thin", r.y, 0, W, litNow)
		end
		if lit then
			stone(t, "claude", 1, 0, r.y, W, r.h, true)
			raise(t, 0, r.y, W, r.h)
		end
	end
	if L.offer then hvine(t, openAt(L, n, open) and "Thick" or "Thin", L.offer.y, 0, W, openAt(L, n, open)) end
end }

looks.bands = { label = "Bands", draw = function(t, L, open)
	ends(t, L)
	for i, r in ipairs(L.rows) do
		if r.key == open then
			stone(t, "claude", 1, 0, r.y, W, r.h)
			raise(t, 0, r.y, W, r.h)
			glow(t, 0, r.y, W, r.h)
		else
			stone(t, i % 2 == 1 and "you" or "claude", i % 2 == 1 and DEEP or 1, 0, r.y, W, r.h)
		end
	end
end }

looks.slots = { label = "Slots", draw = function(t, L, open)
	ends(t, L)
	for _, r in ipairs(L.rows) do
		groove(t, INSET + 2, W - INSET - 2, r.y + r.h / 2, r.h - 4, r.key == open)
	end
end }

looks.strung = { label = "Strung", openFont = "GameFontNormalHuge", draw = function(t, L, open)
	ends(t, L)
	seam(t, CHORD_X, L.top, L.foot)
	for _, r in ipairs(L.rows) do
		groove(t, CHORD_X - SOCKET_W / 2, CHORD_X + SOCKET_W / 2, r.y + r.h / 2, math.min(SOCKET_H, r.h - 4), r.key == open)
	end
end }

looks.engraved = { label = "Engraved", font = "GameFontNormalLarge2", draw = function(t, L, open)
	ends(t, L)
	for _, r in ipairs(L.rows) do
		local x, y, w, h = INSET + 2, r.y + 3, W - 2 * INSET - 4, r.h - 6
		if r.key == open then
			stone(t, "claude", 1, x, y, w, h, true)
			raise(t, x, y, w, h)
			-- its shadow on the stone under it and beside it
			band(t, "TOP", x + 3, y + h, w, 5, 5, -0.7, 0)
			band(t, "LEFT", x + w, y + 3, 5, h, 5, -0.7, 0)
		else
			sink(t, x, y, w, h)
		end
	end
end }

looks.slabs = { label = "Slabs", draw = function(t, L, open)
	ends(t, L)
	for _, r in ipairs(L.rows) do
		slab(t, INSET + 3, W - INSET - 3, r.y + 3, r.y + r.h - 3, r.key == open)
	end
end }

-- The look key laid out in a well H units tall: pieces, every texture; rows,
-- each row's place and its words' (name: its left, chord: the centre of its
-- glyphs, and of its state, which takes the chord's place while there is one;
-- units in from the row's left), its font resting and open; offer, the
-- offered button's cell { x, y, w, h }
function C.Lay(key, H, offered, open)
	local look = looks[key]
	local L = stack(H, offered)
	local t, rows = {}, {}
	look.draw(t, L, open)
	local font = look.font or "GameFontNormalLarge"
	for _, r in ipairs(L.rows) do
		rows[r.key] = { x = INSET, y = r.y, w = W - 2 * INSET, h = r.h, name = NAME_X - INSET, chord = CHORD_X - INSET,
			font = font, openFont = look.openFont or font }
	end
	local o = L.offer
	return { pieces = t, rows = rows, offer = o and { INSET + 6, o.y + 6, W - 2 * INSET - 12, o.h - 12 } }
end
