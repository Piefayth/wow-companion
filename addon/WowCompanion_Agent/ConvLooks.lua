-- The conversation list's looks on trial (round 5, docs/looks.md), each built
-- only from the window's own parts: the two stones, the vines and their plain
-- joints, the kept crests, the scroll bar's column and thumb, the dropdown's
-- closed groove as a glyph's socket. Pure: lay(H, offered, open, counts) says
-- where every texture goes in a well H units tall and where each row and its
-- words sit, and ConvList.lua draws it; tools/mock_convlist.py runs this same
-- file to draw the looks over a screenshot.
--   shelf     one run of rows between the chat's vines, the chord in a socket
--             at the right; the foot crest closes them as a shelf, and the well
--             under it sits back, darker, in the shelf's shadow
--   spine     the thick vine down the left from crest to crest, each row's
--             vines leaving it at plain joints, the pad's groups (Main; L1 L2;
--             R1 R2; Quick) spread down it; the chord bare at the right
--   chapters  Main, the shoulders and Quick each between its own head and foot
--             crest, the chapters spread down the well; thin vines inside one;
--             the chord before the name
--   table     the Status tab's rows: the chord in a dark column, the thick vine
--             down the seam with plain joints, the names on the well's stone;
--             the table runs from crest to crest, the whole well
--   bands     the rows alternate the two stones as the chat's turns do, thin
--             vines between, the chord in a socket before the name; the list
--             stands on the foot crest at the well's foot, by the newest turns,
--             and the well over it sits back
--   track     the chat's scroll bar mirrored down the list's left, the whole
--             well's height; the vines between rows join it as the chat's do,
--             and the heartwood thumb rides beside the open row
-- The open row is its neighbours' structure lit: the light stone, the lit
-- vines (ConvVine-*-Lit, kept with the crests), the crest lit beside it, its
-- chord at full strength, and, for parts with no lit art, the texture added
-- over itself.
local C = {}
WC.ConvLooks = C

-- units, from the well's top left
local W = 130 -- the well (Window.lua's WELL); its walls cover INSET each side
local INSET = 4
local ROW, OFFER = 34, 36 -- a row; the offered button's cell
local HEAD_H, HEAD_RULE, FOOT_H, FOOT_RULE, FOOT_DROP = 37, 32, 28, 4, 24 -- the crests: each one's rule; the foot's ornament under its rule
local CAP = 6 -- a crest's room when the well is too short for crests (a thick vine instead)
local GAP_MIN = 10
-- a chord's glyphs as the game draws them: each key 14 wide, the next 25 on
-- (the padded prompt art and a space, measured at 4K)
local GLYPH_W, GLYPH_STEP = 14, 25
local SOCKET_W, SOCKET_H = 52, 28 -- the socket's art, wide enough for two glyphs or "talking"; its groove shows 3.75 in from top and foot
local LIT = 0.75 -- a part with no lit art: itself added over itself at this alpha (the lit vines' bark is 1.7-1.9x)
local DEEP = 0.55 -- the well where it sits back
C.W, C.INSET, C.OFFER = W, INSET, OFFER
C.IDLE_GLYPH = 0.6 -- a resting row's chord, sunk

local AGENT = [[Interface\AddOns\WowCompanion_Agent\Art\]]
local function vine(piece) return WC.Style.Vine(piece) end

-- A texture: tex its path, or stone = "you"/"claude" (tiled, shade); x, y,
-- w, h the whole art's place in units; layer and sub its draw layer; rot
-- (quarter turns anticlockwise), flip and vflip (mirrored left to right, top
-- to bottom) turn the art; add: blended additively at alpha; clip: { x0, x1,
-- y0, y1 }, the part of it drawn. Every texture is cut to the well's sides too (texcoords), so
-- no art reaches past its walls.
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

local function stone(t, which, shade, x, y, w, h)
	put(t, { stone = which, shade = shade, x = x, y = y, w = w, h = h, layer = "BACKGROUND", sub = 0 })
end
-- the well's stone from y0 to y1 sunk back: darker, Blizzard's soft shadow
-- inside its top and left edges, as Style.Well sinks a well
local SHADE = 12 -- Style.lua's
local function recess(t, y0, y1)
	put(t, { stone = "you", shade = DEEP, x = 0, y = y0, w = W, h = y1 - y0, layer = "BACKGROUND", sub = 0 })
	put(t, { tex = [[Interface\Common\ShadowOverlay-Top]], x = 0, y = y0, w = W, h = SHADE, alpha = 0.7,
		layer = "BACKGROUND", sub = 2, shadow = "Top" })
	put(t, { tex = [[Interface\Common\ShadowOverlay-Left]], x = INSET, y = y0, w = SHADE, h = y1 - y0, alpha = 0.7,
		layer = "BACKGROUND", sub = 2, shadow = "Left" })
end
-- a vine across at y from x0 to x1, its ends bare (under a wall, a joint or
-- another vine); lit: the lit art (medium and thick only), over the joints
-- it leaves, whose fillets are lit with it
local function hvine(t, weight, y, x0, x1, lit)
	local tex = lit and (AGENT .. "ConvVine-Rule" .. (weight == "Thick" and "Thick" or "") .. "-Lit")
		or vine(weight .. "Mid")
	put(t, { tex = tex, x = x0, y = y - 8, w = x1 - x0, h = 16, layer = "BORDER", sub = lit and 5 or 1 })
end
-- a vine down at x from y0 to y1, its ends bare
local function vvine(t, weight, x, y0, y1)
	put(t, { tex = vine(weight .. "VMid"), x = x - 8, y = y0, w = 16, h = y1 - y0, layer = "BORDER", sub = 0 })
end
-- a joint (Style.VineJoin's kinds) centred on x, y, turned (rot, flip,
-- vflip as put's); clip: the part drawn, { x0, x1, y0, y1 } (its run kept to
-- the vine it is on); lit: the part of that lit (its arm along the open row),
-- added over itself
local JOIN = { ThickTRightFromMediumPlain = 80, ThickTRightBigPlain = 112 }
local function meet(a, b)
	if not (a and b) then return a or b end
	return { math.max(a[1], b[1]), math.min(a[2], b[2]), math.max(a[3], b[3]), math.min(a[4], b[4]) }
end
local function join(t, kind, x, y, turn, clip, lit)
	local s = JOIN[kind]
	local function at(extra)
		local d = { tex = vine(kind), x = x - s / 2, y = y - s / 2, w = s, h = s, layer = "BORDER", sub = 3 }
		for k, v in pairs(turn or {}) do d[k] = v end
		for k, v in pairs(extra) do d[k] = v end
		put(t, d)
	end
	at({ clip = clip })
	if lit then at({ add = true, alpha = LIT, sub = 4, clip = meet(clip, lit) }) end
end
local ALL = 1e9
local RUN = 1.6 -- the thick vine's half width: a lit vine starts at its edge
local DOWN = { rot = 1, vflip = true } -- a T with its arm down, its light from the left as the vines'
local UP = { rot = 1 }
-- a thick vine down at x between two crests' rules (or the thick vines in
-- their place), leaving each at a plain joint
local function seam(t, x, top, foot)
	join(t, "ThickTRightBigPlain", x, top, DOWN, { -ALL, ALL, top - 2, foot })
	join(t, "ThickTRightBigPlain", x, foot, UP, { -ALL, ALL, top, foot + 2 })
	vvine(t, "Thick", x, top, foot)
end
-- a plain joint where a medium vine leaves the thick one at x (both ways
-- when both), kept to the thick vine's run from top to foot; lit: its arms lit
local function branch(t, x, y, top, foot, both, lit)
	join(t, "ThickTRightFromMediumPlain", x, y, nil, { -ALL, ALL, top, foot }, lit and { x + RUN, ALL, -ALL, ALL })
	if both then
		-- the mirrored one's run would light the thick vine's right side too: its arm alone
		join(t, "ThickTRightFromMediumPlain", x, y, { flip = true }, { -ALL, x - RUN, top, foot },
			lit and { -ALL, x - RUN, -ALL, ALL })
	end
end
-- the kept crests, each on its rule's y, shifted dx
local function crest(t, part, rule, lit, dx)
	put(t, { tex = AGENT .. "Crest-" .. part .. (lit and "-Lit" or ""), x = dx or 0, w = W,
		h = part == "Head" and HEAD_H or FOOT_H, y = rule - (part == "Head" and HEAD_RULE or FOOT_RULE),
		layer = "ARTWORK", sub = 0 })
end
-- a socket for the chord: the dropdown's closed groove, centred on cx, cy;
-- lit: added over itself
local function socket(t, cx, cy, lit)
	local w, h, e = SOCKET_W, SOCKET_H, SOCKET_H / 2
	local x, y = cx - w / 2, cy - h / 2
	for _, p in ipairs({ { "Choice-Left-Closed", x, e }, { "Choice-Mid", x + e, w - 2 * e },
		{ "Choice-Right-Closed", x + w - e, e } }) do
		put(t, { tex = WC.Style.Control(p[1]), x = p[2], y = y, w = p[3], h = h, layer = "ARTWORK", sub = 6 })
		if lit then
			put(t, { tex = WC.Style.Control(p[1]), x = p[2], y = y, w = p[3], h = h, add = true, alpha = LIT,
				layer = "ARTWORK", sub = 7 })
		end
	end
end

-- The rows' column, top to bottom: { "head" } the head crest (its rule the
-- next row's top), { "row", key }, { "gap" } stone shared out of what is
-- left, { "offer" } the offered button's cell (only when one is offered),
-- { "foot" } the foot crest (its rule the last row's foot). Too short for the
-- crests and their gaps, the crests give way to a thick vine; shorter still,
-- the rows shrink. Returns each item placed (y, h; a crest's rule) and
-- whether the crests show.
local function stack(H, items, offered)
	local list = {}
	for _, it in ipairs(items) do
		if it[1] ~= "offer" or offered then list[#list + 1] = it end
	end
	local function need(ornate, row)
		local fixed, gaps = 0, 0
		for _, it in ipairs(list) do
			local k = it[1]
			if k == "head" then fixed = fixed + (ornate and HEAD_RULE or CAP)
			elseif k == "foot" then fixed = fixed + (ornate and FOOT_DROP or CAP)
			elseif k == "row" then fixed = fixed + row
			elseif k == "offer" then fixed = fixed + OFFER
			else gaps = gaps + 1 end
		end
		return fixed, gaps
	end
	local ornate, row = true, ROW
	local fixed, gaps = need(true, ROW)
	if fixed + gaps * GAP_MIN > H then
		ornate = false
		fixed, gaps = need(false, ROW)
		if fixed + gaps * GAP_MIN > H then
			local rows = 0
			for _, it in ipairs(list) do if it[1] == "row" then rows = rows + 1 end end
			row = math.max(12, ROW - (fixed + gaps * GAP_MIN - H) / rows)
			fixed = need(false, row)
		end
	end
	local gap = gaps > 0 and math.max(GAP_MIN, (H - fixed) / gaps) or 0
	local y, placed = 0, {}
	for _, it in ipairs(list) do
		local k, p = it[1], { kind = it[1], key = it[2], y = y }
		if k == "head" then
			p.h = ornate and HEAD_RULE or CAP
			p.rule = y + p.h
		elseif k == "foot" then
			p.h = ornate and FOOT_DROP or CAP
			p.rule = y
		elseif k == "row" then p.h = row
		elseif k == "offer" then p.h = OFFER
		else p.h = gap end
		y = y + p.h
		placed[#placed + 1] = p
	end
	return placed, ornate
end

local ROWS = { { "row", "" }, { "row", "l1" }, { "row", "l2" }, { "row", "r1" }, { "row", "r2" }, { "row", "quick" } }
-- the rows between what comes before and after them
local function around(before, after)
	local items = {}
	for _, it in ipairs(before) do items[#items + 1] = it end
	for _, it in ipairs(ROWS) do items[#items + 1] = it end
	for _, it in ipairs(after) do items[#items + 1] = it end
	return items
end
-- a crest, or the thick vine in its place in a short well; lit beside the open row
local function ends(t, p, ornate, lit, dx)
	if ornate then
		crest(t, p.kind == "head" and "Head" or "Foot", p.rule, lit, dx)
	else
		hvine(t, "Thick", p.rule, 0, W, lit)
	end
end
local function isRow(p) return p and (p.kind == "row" or p.kind == "offer") end
-- each row's place and its words' (units in from the row's left): name, the
-- name's left; chord, the centre of its glyphs, and of its state, which takes
-- the chord's place while there is one
local function rowOf(p, x, w, words)
	local r = { x = x, y = p.y, w = w, h = p.h }
	for k, v in pairs(words) do r[k] = v end
	return r
end
-- how wide each chord's glyphs are
local function widths(counts)
	local cw = {}
	for _, it in ipairs(ROWS) do
		cw[it[2]] = GLYPH_W + GLYPH_STEP * (math.max(1, counts and counts[it[2]] or 1) - 1)
	end
	return cw
end
local function offerIn(p, x0, x1) return { x0 + 6, p.y + 6, x1 - x0 - 12, p.h - 12 } end

local looks = {}
C.LOOKS = looks
C.ORDER = { "shelf", "spine", "chapters", "table", "bands", "track" }

looks.shelf = { label = "Shelf", lay = function(H, offered, open)
	local placed, ornate = stack(H, around({ { "head" } }, { { "offer" }, { "foot" }, { "gap" } }), offered)
	local sx = W - INSET - 6 - SOCKET_W / 2
	local t, rows, offer = {}, {}, nil
	for i, p in ipairs(placed) do
		local before, after = placed[i - 1], placed[i + 1]
		local lit = p.key == open
		if p.kind == "head" then ends(t, p, ornate, after.key == open)
		elseif p.kind == "foot" then
			ends(t, p, ornate, before.key == open)
			recess(t, p.rule, H)
		elseif isRow(p) then
			if before.kind ~= "head" then hvine(t, "", p.y, 0, W, lit or before.key == open) end
			if p.kind == "offer" then
				offer = offerIn(p, INSET, W - INSET)
			else
				if lit then stone(t, "claude", 1, 0, p.y, W, p.h) end
				socket(t, sx, p.y + p.h / 2, lit)
				rows[p.key] = rowOf(p, INSET, W - 2 * INSET, { name = 10, chord = sx - INSET })
			end
		end
	end
	return { pieces = t, rows = rows, offer = offer }
end }

local SP = 13 -- the spine's centre
looks.spine = { label = "Spine", lay = function(H, offered, open, counts)
	local placed, ornate = stack(H, { { "head" }, ROWS[1], { "gap" }, ROWS[2], ROWS[3], { "gap" }, ROWS[4], ROWS[5],
		{ "gap" }, ROWS[6], { "offer" }, { "foot" } }, offered)
	local cw = widths(counts)
	local t, rows, offer = {}, {}, nil
	local top, foot = placed[1].rule, placed[#placed].rule
	-- a row's vine where it leaves the spine
	local function edge(y, lit)
		hvine(t, "", y, lit and SP + RUN or SP, W, lit)
		branch(t, SP, y, top, foot, false, lit)
	end
	for i, p in ipairs(placed) do
		local before, after = placed[i - 1], placed[i + 1]
		local lit = p.key == open
		if p.kind == "head" then ends(t, p, ornate, after.key == open)
		elseif p.kind == "foot" then ends(t, p, ornate, before.key == open)
		elseif isRow(p) then
			if before.kind ~= "head" then edge(p.y, lit or before.key == open) end
			if after.kind == "gap" then edge(p.y + p.h, lit) end
			if p.kind == "offer" then
				offer = offerIn(p, SP + 2, W - INSET)
			else
				if lit then stone(t, "claude", 1, SP, p.y, W - SP, p.h) end
				-- wall to wall, the pad's pointer by the wall as in every look
				local w = W - 2 * INSET
				rows[p.key] = rowOf(p, INSET, w, { name = SP + 9, chord = w - 8 - cw[p.key] / 2 })
			end
		end
	end
	seam(t, SP, top, foot)
	return { pieces = t, rows = rows, offer = offer }
end }

looks.chapters = { label = "Chapters", lay = function(H, offered, open, counts)
	local placed, ornate = stack(H, { { "head" }, ROWS[1], { "foot" }, { "gap" }, { "head" }, ROWS[2], ROWS[3],
		ROWS[4], ROWS[5], { "foot" }, { "gap" }, { "head" }, ROWS[6], { "offer" }, { "foot" } }, offered)
	local cw = widths(counts)
	local t, rows, offer = {}, {}, nil
	for i, p in ipairs(placed) do
		local before, after = placed[i - 1], placed[i + 1]
		local lit = p.key == open
		if p.kind == "head" then ends(t, p, ornate, after.key == open)
		elseif p.kind == "foot" then ends(t, p, ornate, before.key == open)
		elseif isRow(p) then
			if before.kind ~= "head" then
				local litNow = lit or before.key == open
				hvine(t, litNow and "" or "Thin", p.y, 0, W, litNow)
			end
			if p.kind == "offer" then
				offer = offerIn(p, INSET, W - INSET)
			else
				if lit then stone(t, "claude", 1, 0, p.y, W, p.h) end
				local w = W - 2 * INSET
				rows[p.key] = rowOf(p, INSET, w, { name = 10, chord = w - 8 - cw[p.key] / 2 })
			end
		end
	end
	return { pieces = t, rows = rows, offer = offer }
end }

looks.table = { label = "Table, as Status", lay = function(H, offered, open)
	local placed, ornate = stack(H, around({ { "head" } }, { { "offer" }, { "gap" }, { "foot" } }), offered)
	local seamX = INSET + SOCKET_W + 4 -- the chords' column, then the seam
	local t, rows, offer = {}, {}, nil
	local top, foot = placed[1].rule, placed[#placed].rule
	local function cross(y, lit)
		if lit then
			hvine(t, "", y, 0, seamX - RUN, true)
			hvine(t, "", y, seamX + RUN, W, true)
		else
			hvine(t, "", y, 0, W)
		end
		branch(t, seamX, y, top, foot, true, lit)
	end
	stone(t, "you", DEEP, 0, 0, seamX, H)
	for i, p in ipairs(placed) do
		local before, after = placed[i - 1], placed[i + 1]
		local lit = p.key == open
		if p.kind == "head" then ends(t, p, ornate, after.key == open)
		elseif p.kind == "foot" then ends(t, p, ornate, false)
		elseif isRow(p) then
			if before.kind ~= "head" then cross(p.y, lit or before.key == open) end
			if after.kind == "gap" then cross(p.y + p.h, lit) end
			if p.kind == "offer" then
				offer = offerIn(p, INSET, W - INSET)
			else
				if lit then stone(t, "claude", 1, 0, p.y, W, p.h) end
				rows[p.key] = rowOf(p, INSET, W - 2 * INSET, { name = seamX - INSET + 10, chord = (seamX - INSET) / 2 })
			end
		end
	end
	seam(t, seamX, top, foot)
	return { pieces = t, rows = rows, offer = offer }
end }

looks.bands = { label = "Bands at the foot", lay = function(H, offered, open)
	local placed, ornate = stack(H, around({ { "gap" }, { "head" } }, { { "offer" }, { "foot" } }), offered)
	local t, rows, offer = {}, {}, nil
	local n = 0
	for i, p in ipairs(placed) do
		local before, after = placed[i - 1], placed[i + 1]
		local lit = p.key == open
		if p.kind == "head" then
			ends(t, p, ornate, after.key == open)
			recess(t, 0, p.rule)
		elseif p.kind == "foot" then ends(t, p, ornate, before.key == open)
		elseif isRow(p) then
			if before.kind ~= "head" then
				local litNow = lit or before.key == open
				hvine(t, litNow and "" or "Thin", p.y, 0, W, litNow)
			end
			if p.kind == "offer" then
				offer = offerIn(p, INSET, W - INSET)
			else
				-- the chat's turns: the dark stone (the well's own), then the light
				n = n + 1
				if lit or n % 2 == 0 then stone(t, "claude", lit and 1 or 0.8, 0, p.y, W, p.h) end
				socket(t, INSET + 5 + SOCKET_W / 2, p.y + p.h / 2, lit)
				rows[p.key] = rowOf(p, INSET, W - 2 * INSET, { name = 5 + SOCKET_W + 7, chord = 5 + SOCKET_W / 2 })
			end
		end
	end
	return { pieces = t, rows = rows, offer = offer }
end }

local TX, TW = INSET + 10, 20 -- the column's centre and width (ScrollBar.lua's WIDTH)
local FILL = 7.8 / 5.25 -- ScrollBar.lua's: the thumb art widened to the groove's floor
local RX = TX + TW / 2 -- the column's right edge, where the rows start
local CREST_DX = (RX + W - INSET) / 2 - W / 2 -- the crests centred over the rows
looks.track = { label = "Scroll track", lay = function(H, offered, open, counts)
	local placed, ornate = stack(H, around({ { "head" } }, { { "offer" }, { "foot" }, { "gap" } }), offered)
	local cw = widths(counts)
	local t, rows, offer = {}, {}, nil
	local S = WC.ScrollBar.Art
	local function column(name, x, y, w, h, sub, extra)
		local d = { tex = S(name), x = x, y = y, w = w, h = h, layer = "ARTWORK", sub = sub }
		for k, v in pairs(extra or {}) do d[k] = v end
		put(t, d)
	end
	local top, foot = 9, H - 12 -- ScrollBar.lua's insets
	column("Up-Normal", TX - 16, top, 32, 32, 2)
	column("Down-Normal", TX - 16, foot - 32, 32, 32, 2)
	column("Mid", TX - 16, top + 32, 32, foot - top - 64, 1)
	local function divider(y, lit)
		hvine(t, "", y, RX + 6, W, lit)
		-- ScrollBar.Divider's joint, mirrored: its x 6 on the column's edge
		column("Joint", RX + 6 - 32, y - 8, 32, 16, 3, { flip = true })
		if lit then column("Joint", RX + 6 - 32, y - 8, 32, 16, 4, { flip = true, add = true, alpha = LIT }) end
	end
	for i, p in ipairs(placed) do
		local before, after = placed[i - 1], placed[i + 1]
		local lit = p.key == open
		if p.kind == "head" then ends(t, p, ornate, after.key == open, CREST_DX)
		elseif p.kind == "foot" then ends(t, p, ornate, before.key == open, CREST_DX)
		elseif isRow(p) then
			if before.kind ~= "head" then divider(p.y, lit or before.key == open) end
			if p.kind == "offer" then
				offer = offerIn(p, RX, W - INSET)
			else
				if lit then
					stone(t, "claude", 1, RX - 4, p.y, W - RX + 4, p.h)
					-- the thumb in the groove beside it: its ends, its centre, the shaft between
					local tw, y0, y1 = 32 * FILL, p.y + 3, p.y + p.h - 3
					local cy = (y0 + y1) / 2
					column("Thumb-Top", TX - tw / 2, y0, tw, 8, 5)
					column("Thumb-Bottom", TX - tw / 2, y1 - 8, tw, 8, 5)
					column("Thumb-Centre", TX - tw / 2, cy - 8, tw, 16, 5)
					column("Thumb-Mid", TX - tw / 2, y0 + 8, tw, cy - 16 - y0, 5)
					column("Thumb-Mid", TX - tw / 2, cy + 8, tw, y1 - 16 - cy, 5)
				end
				local w = W - 2 * INSET
				rows[p.key] = rowOf(p, INSET, w, { name = RX - INSET + 8, chord = w - 6 - cw[p.key] / 2 })
			end
		end
	end
	return { pieces = t, rows = rows, offer = offer }
end }
