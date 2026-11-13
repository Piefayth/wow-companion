-- The conversation list's looks on trial (round 8, docs/looks.md): Main, L1,
-- L2, R1, R2, Quick, the offered button's cell under them; a row's name in the
-- normal font, its chord's glyphs or its state ("12s", "new", the mic while it
-- is talked to) beside it. Round 7's floor, at the well's top or centred, with
-- its crests or without.
-- Pure: C.Lay(key, H, offered, open) says where every texture goes in a well
-- H units tall and where each row and its words sit, and ConvList.lua draws
-- it; tools/mock_convlist.py runs this same file to draw the looks over a
-- screenshot.
local C = {}
WC.ConvLooks = C

-- units, from the well's top left
local W = 130 -- the well (Window.lua's WELL); its walls cover INSET each side
local INSET = 4
local OFFER = 36 -- the offered button's cell
local CREST_H, CREST_RULE = 28, 4 -- the crest: its rule 4 into its art, its ornament the rest
local ORNAMENT = CREST_H - CREST_RULE -- a crest's ornament past its rule
local CAP = 6 -- a crest's room when the well is too short for crests (a thick vine instead)
local CHORD_RIGHT, NAME_RIGHT = 98, 14 -- a chord's centre, a name's left
local LIT = 0.75 -- a part with no lit art: itself added over itself at this alpha
local DEEP = 0.55 -- the well where it is sunk
local RUN = 64 -- a vine run's art, its length in units
local ROW = 24 -- a row's height
local SHADE_AT_REST = 0.8 -- a resting cell's light stone
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
-- ends bare (under the walls); lit: its lit art, or itself added
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
-- the crest, the same at both ends (tools/make_crest_art.py): standing on
-- the head's rule, hung under the foot's; never lit: the open row lights only
-- its own parts (the player, 2026-11-12)
local function crest(t, rule, head)
	put(t, { tex = AGENT .. (head and "Crest-Head-3" or "Crest-Foot-3"), x = 0, w = W, h = CREST_H,
		y = head and rule - CREST_H + CREST_RULE or rule - CREST_RULE, layer = "ARTWORK", sub = 0 })
end


-- The places every look shares: the head crest's rule (top), each row, the
-- offered button's cell, the foot crest's rule (foot). plain: thick vines in
-- the crests' place, as when the well is too short for the crests (and
-- shorter still, the rows shrink); centre: the list in the middle of the
-- well's height, else at its top.
local KEYS = { "", "l1", "l2", "r1", "r2", "quick" }
local function stack(look, H, offered)
	local row, extra = ROW, offered and OFFER or 0
	local ornate = not look.plain and ORNAMENT + #KEYS * row + extra + ORNAMENT <= H
	local top, drop = ORNAMENT, ORNAMENT
	if not ornate then
		top, drop = CAP, CAP
		row = math.max(12, math.min(row, (H - top - drop - extra) / #KEYS))
	end
	if look.centre then top = top + math.max(0, (H - (top + #KEYS * row + extra + drop)) / 2) end
	local rows, y = {}, top
	for i, key in ipairs(KEYS) do
		rows[i] = { key = key, y = y, h = row }
		y = y + row
	end
	return { ornate = ornate, top = top, rows = rows, offer = offered and { y = y, h = OFFER } or nil, foot = y + extra }
end
-- the crests (or the thick vines in their place)
local function ends(t, L)
	if L.ornate then
		crest(t, L.top, true)
		crest(t, L.foot, false)
	else
		hvine(t, L.top, 0, W)
		hvine(t, L.foot, 0, W)
	end
end

-- Floor: the list sunk between the crests' rules, the well's walls under the
-- head rule and over the foot's, the head's shadow falling in; every cell the
-- light stone at rest, a medium rule between rows; the open cell the light
-- stone at full, lit, its two rules lit (over the crests' rules at the ends)
local function floor(t, L, open)
	stone(t, "you", DEEP, 0, L.top, W, L.foot - L.top)
	wall(t, "Top", 0, L.top, W, L.foot - L.top)
	wall(t, "Bottom", 0, L.top, W, L.foot - L.top)
	shadow(t, 0, L.top, W, L.foot - L.top, 0.9)
	ends(t, L)
	local rows, n = L.rows, #L.rows
	local function openAt(i) return rows[i] and rows[i].key == open end
	for i, r in ipairs(rows) do
		local on = openAt(i)
		stone(t, "claude", on and 1 or SHADE_AT_REST, 0, r.y, W, r.h, on, 1)
		if i > 1 then hvine(t, r.y, 0, W, "", on or openAt(i - 1)) end
	end
	local last = rows[n].y + rows[n].h
	if L.offer then hvine(t, last, 0, W, "", openAt(n)) end
	if openAt(1) then hvine(t, L.top, 0, W, "Thick", true) end
	if openAt(n) and not L.offer then hvine(t, L.foot, 0, W, "Thick", true) end
end

local looks = {}
C.LOOKS = looks
C.ORDER = { "top", "topPlain", "centred", "centredPlain" }
looks.top = { label = "Floor, top", draw = floor }
looks.topPlain = { label = "Floor, top, no crests", plain = true, draw = floor }
looks.centred = { label = "Floor, centred", centre = true, draw = floor }
looks.centredPlain = { label = "Floor, centred, no crests", centre = true, plain = true, draw = floor }

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
			name = NAME_RIGHT - INSET, chord = CHORD_RIGHT - INSET }
	end
	local o = L.offer
	return { pieces = t, rows = rows, offer = o and { INSET + 6, o.y + 6, W - 2 * INSET - 12, o.h - 12 } }
end
