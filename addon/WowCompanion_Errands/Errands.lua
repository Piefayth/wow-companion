-- Errands (design:
-- docs/proposals/capabilities-errands.md): a to-do list the player and every
-- conversation share, per character, in WowCompanionErrandsDB. Our own feature;
-- around it, it uses capabilities, each optional: pins (where), nav (take me
-- there), itemSource (where to get it), price (what it is worth).
--
-- Every errand completes itself: Add refuses one without a `done` condition from
-- the kinds below, each checked here, and refuses one already true. Adding,
-- removing and editing happen only when the player asks, through agent code.
--   WC.Errands.Add{ text=, note=, place={ map, x, y, f }, item=, done={...} } -> id | nil, why
--   WC.Errands.Remove(idOrText) -> true | nil, why
--   WC.Errands.Edit(idOrText, { text=, note=, place= }) -> true | nil, why  (done stays)
--   WC.Errands.List() -> open errands, newest first
-- done kinds (all given must hold; momentary ones count once seen):
--   have  = { item = id, count = n }          that many in the bags
--   visit = { npc = id, kind = "merchant"|"trainer"|"gossip"|"bank"|"any" }  window opened with that NPC
--   reach = { zone = "name" } | { map, x, y, r = yards }  zone, subzone, or within r of a point
--   quest = { id = n, state = "accepted"|"complete"|"turnedin" }
--   level = n                                  character level reached
--   skill = { name = "Skinning", rank = n }    profession or secondary skill rank reached
-- Display only, nothing secure, nothing pressed: a tracker in a fixed place
-- under the board, and the Errands tab in the Companion window.
WC.Errands = WC.Errands or {}
local E = WC.Errands
local GOLD = { 1, 0.82, 0 }
WC.Saved("WowCompanion_Errands", "WowCompanionErrandsDB")

local function charKey()
	local name, realm = UnitFullName("player")
	return (name or "?") .. "-" .. (realm or GetNormalizedRealmName() or "?")
end
local function store()
	local k = charKey()
	WowCompanionErrandsDB[k] = WowCompanionErrandsDB[k] or { items = {}, next = 1 }
	return WowCompanionErrandsDB[k]
end

-- the game's answers ---------------------------------------------------------
local function npcID(unit)
	local guid = UnitGUID(unit)
	if not guid then return nil end
	local kind, _, _, _, _, id = strsplit("-", guid)
	if kind == "Creature" or kind == "Vehicle" then return tonumber(id) end
end
local function skillRank(name)
	local want = name:lower()
	for _, index in ipairs({ GetProfessions() }) do
		if index then
			local pname, _, rank = GetProfessionInfo(index)
			if pname and pname:lower() == want then return rank end
		end
	end
end
local function questState(id)
	if C_QuestLog.IsQuestFlaggedCompleted(id) then return "turnedin" end
	if C_QuestLog.GetLogIndexForQuestID(id) then
		return C_QuestLog.IsComplete(id) and "complete" or "accepted"
	end
end
local ORDER = { accepted = 1, complete = 2, turnedin = 3 }
-- yards from the player to a map point, or nil off its continent
local function yardsTo(map, x, y)
	local pn, pw, _, inst = UnitPosition("player")
	if not pn then return nil end
	local ok, cont, world = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x / 100, y / 100))
	if not (ok and world) or (cont and inst and cont ~= inst) then return nil end
	local n, w = world:GetXY()
	local dn, dw = n - pn, w - pw
	return math.sqrt(dn * dn + dw * dw)
end
local function inZone(zone)
	zone = zone:lower()
	for _, z in ipairs({ GetRealZoneText(), GetZoneText(), GetSubZoneText(), GetMinimapZoneText() }) do
		if z and z:lower() == zone then return true end
	end
end

-- whether one condition holds now (momentary ones remember being seen)
local function holds(kind, c)
	if kind == "have" then return (C_Item.GetItemCount(c.item, true) or 0) >= (c.count or 1) end
	if kind == "visit" then return c.seen == true end
	if kind == "reach" then
		if c.seen then return true end
		if c.zone then return inZone(c.zone) end
		local d = yardsTo(c.map, c.x, c.y)
		return d ~= nil and d <= (c.r or 30)
	end
	if kind == "quest" then
		local s = questState(c.id)
		return s ~= nil and ORDER[s] >= ORDER[c.state]
	end
	if kind == "level" then return UnitLevel("player") >= c end
	if kind == "skill" then return (skillRank(c.name) or 0) >= c.rank end
	return false
end
local function allHold(done)
	for kind, c in pairs(done) do
		if not holds(kind, c) then return false end
	end
	return true
end

-- validating a `done` -----------------------------------------------------------
local KINDS = { have = true, visit = true, reach = true, quest = true, level = true, skill = true }
local VISITS = { merchant = true, trainer = true, gossip = true, bank = true, any = true }
local function num(v) return type(v) == "number" and v == v end
local function checkDone(done)
	if type(done) ~= "table" or next(done) == nil then
		return "no done condition: say what the game will report when it is finished (have, visit, reach, quest, level, skill)"
	end
	for kind, c in pairs(done) do
		if not KINDS[kind] then return "unknown done kind " .. tostring(kind) end
		if kind == "have" then
			if type(c) ~= "table" or not num(c.item) then return "have needs { item = id, count = n }" end
			c.count = c.count or 1
			if not (num(c.count) and c.count >= 1) then return "have: count must be 1 or more" end
			if not C_Item.GetItemInfoInstant(c.item) then return "have: no item " .. c.item end
		elseif kind == "visit" then
			if type(c) ~= "table" or not num(c.npc) then return "visit needs { npc = id, kind = ... }" end
			c.kind = c.kind or "any"
			if not VISITS[c.kind] then return "visit: kind is merchant, trainer, gossip, bank or any" end
			c.seen = nil
		elseif kind == "reach" then
			if type(c) ~= "table" then return "reach needs { zone = name } or { map, x, y, r }" end
			if c.zone then
				if type(c.zone) ~= "string" or c.zone == "" then return "reach: zone must be a name" end
			else
				if not (num(c.map) and num(c.x) and num(c.y) and c.x >= 0 and c.x <= 100 and c.y >= 0 and c.y <= 100) then
					return "reach: map, x and y (0-100) needed"
				end
				if not C_Map.GetMapInfo(c.map) then return "reach: no map " .. c.map end
				c.r = c.r or 30
			end
			c.seen = nil
		elseif kind == "quest" then
			if type(c) ~= "table" or not num(c.id) then return "quest needs { id = n, state = ... }" end
			c.state = c.state or "turnedin"
			if not ORDER[c.state] then return "quest: state is accepted, complete or turnedin" end
		elseif kind == "level" then
			if not (num(c) and c >= 2 and c <= 80) then return "level must be a number" end
		elseif kind == "skill" then
			if type(c) ~= "table" or type(c.name) ~= "string" or not num(c.rank) then return "skill needs { name, rank }" end
			if not skillRank(c.name) then return "skill: " .. c.name .. " is not one of this character's professions" end
		end
	end
	if allHold(done) then return "already done now: it would vanish at once" end
end

-- distance, travel time and "on your route": decoration
-- to decide by. Straight-line yards always (nav.world/here, our own fallback);
-- travel time from Polestar's public estimate; the route flag from the guide's next
-- steps' places. Measured every few seconds; never part of the route itself.
local NEAR_ROUTE = 300 -- yards between an errand and a coming step's goal
local function yardsBetween(c1, a1, b1, c2, a2, b2)
	if not (c1 and c2 and c1 == c2) then return nil end
	local da, db = a1 - a2, b1 - b2
	return math.sqrt(da * da + db * db)
end
local measured = {} -- errand id -> { yards, eta, etaAt, step, stepTitle }
local function measure(full)
	local nav = WC.Use("nav")
	if not nav then return end
	local hc, ha, hb = nav.here()
	local route = full and WC.Use("guide") and WC.Use("guide").places(6) or nil
	local routePts
	if route then
		routePts = {}
		for _, p in ipairs(route) do
			local c, a, b = nav.world(p.map, p.x, p.y, p.f)
			if c then routePts[#routePts + 1] = { c = c, a = a, b = b, step = p.step, title = p.title } end
		end
	end
	for _, e in ipairs(E.List()) do
		if e.place then
			local m = measured[e.id] or {}
			measured[e.id] = m
			local c, a, b = nav.world(e.place.map, e.place.x, e.place.y, e.place.f)
			m.yards = c and yardsBetween(hc, ha, hb, c, a, b) or nil
			if full then
				-- Polestar plans the trip in the background and answers "busy" until
				-- it has: ask again in 3 s while there is no answer, every 20 s after
				local wait = m.eta and 20 or 3
				if not InCombatLockdown() and (not m.etaAt or GetTime() - m.etaAt > wait) then
					m.eta, m.etaAt = nav.eta(e.place.map, e.place.x, e.place.y) or m.eta, GetTime()
				end
				m.step, m.stepTitle = nil, nil
				for _, p in ipairs(routePts or {}) do
					local d = c and yardsBetween(c, a, b, p.c, p.a, p.b)
					if d and d <= NEAR_ROUTE and (not m.step or p.step < m.step) then
						m.step, m.stepTitle = p.step, p.title
					end
				end
			end
		end
	end
end
-- colours for the detail line, so it does not read as one grey blob: place soft blue, distance light grey, time soft gold, count white
local C_PLACE, C_DIST, C_TIME, C_COUNT = "|cff8fc8ff", "|cffd8d8d8", "|cffffd27a", "|cffffffff"
local function decoration(e)
	local m = measured[e.id]
	if not m then return "" end
	local parts = {}
	if m.yards then
		parts[#parts + 1] = C_DIST .. (m.yards >= 1000 and ("%.1f km"):format(m.yards / 1000) or ("%d yd"):format(m.yards)) .. "|r"
	end
	if m.eta then parts[#parts + 1] = C_TIME .. ("%d min away"):format(math.max(1, math.floor(m.eta / 60 + 0.5))) .. "|r" end
	return table.concat(parts, "   ")
end
function E.Measured(id) return measured[id] end

-- display -------------------------------------------------------------------------
local tracker
local function trackerFonts()
	return _G.ObjectiveTrackerHeaderFont and "ObjectiveTrackerHeaderFont" or "GameFontNormal",
		_G.ObjectiveTrackerLineFont and "ObjectiveTrackerLineFont" or "GameFontHighlightSmall"
end
-- the board's tallest (Board.lua: 2*10 pad + 20 header + 6 rows * 16) and a gap
local TRACKER_TOP = -(4 + 136 + 10)
local function buildTracker()
	local head, line = trackerFonts()
	local f = CreateFrame("Frame", "WowCompanionErrands", UIParent)
	f:SetSize(266, 30)
	f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, TRACKER_TOP)
	f:SetFrameStrata("LOW")
	-- the header as Blizzard's module header is built (Blizzard_ObjectiveTrackerModule.xml):
	-- a 260x26 strip, the art centred on it, the text 7 in from the left
	f.headerFrame = CreateFrame("Frame", nil, f)
	f.headerFrame:SetSize(260, 26)
	f.headerFrame:SetPoint("TOPLEFT", 6, 0)
	f.header = f.headerFrame:CreateTexture(nil, "BACKGROUND")
	f.header:SetAtlas("UI-QuestTracker-Secondary-Objective-Header", true)
	f.header:SetPoint("CENTER")
	f.title = f.headerFrame:CreateFontString(nil, "ARTWORK", head)
	f.title:SetPoint("LEFT", 7, 0)
	f.title:SetText("Errands")
	f.lineFont = line
	-- a soft dark backing that fades out to the right, so the lines read on
	-- bright ground (grey on sand is unreadable)
	f.back = f:CreateTexture(nil, "BACKGROUND", nil, -1)
	f.back:SetTexture("Interface/Tooltips/UI-Tooltip-Background")
	f.back:SetPoint("TOP", 0, -22)
	f.back:SetPoint("LEFT", UIParent, "LEFT", 0, 0)
	f.back:SetPoint("BOTTOMRIGHT", 20, -2)
	if f.back.SetGradient and CreateColor then
		f.back:SetGradient("HORIZONTAL", CreateColor(0, 0, 0, 0.6), CreateColor(0, 0, 0, 0))
	else
		f.back:SetVertexColor(0, 0, 0, 0.45)
	end
	f.lines = {}
	f:Hide()
	return f
end
-- what is left, for a line: "3/20" for an item count, else the place
local function progress(e)
	local out = {}
	local h = e.done.have
	if h and h.count > 1 then
		out[#out + 1] = C_COUNT .. ("%d/%d"):format(math.min(C_Item.GetItemCount(h.item, true) or 0, h.count), h.count) .. "|r"
	end
	if e.place then
		local info = C_Map.GetMapInfo(e.place.map)
		out[#out + 1] = C_PLACE .. ("%s%d, %d"):format(info and (info.name .. " ") or "", math.floor(e.place.x + 0.5), math.floor(e.place.y + 0.5)) .. "|r"
	end
	return table.concat(out, "   ")
end
local function here(e)
	if not e.place then return false end
	local info = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	return info == e.place.map
end
function E.List()
	local out = {}
	for _, e in ipairs(store().items) do
		if not e.doneAt then out[#out + 1] = e end
	end
	table.sort(out, function(a, b) return a.added > b.added end)
	return out
end
-- The tracker as Blizzard's objective tracker lays out a quest: an icon, the title in the tracker's
-- title colour, then short indented "- " lines in its objective grey, one fact
-- each and never wrapped: what is left, where and how far, the route flag.
local T_TITLE, T_OBJ = { 1, 0.82, 0 }, { 0.8, 0.8, 0.8 }
-- what is left, without repeating the title: "Skinning 125" shows "- 99/125",
-- not "- Skinning 99/125"; a single item named in the title shows nothing
-- what is left, always saying of what ("3/20 Wrathtail Head"), as a quest does
local function objectiveLine(e)
	local d = e.done
	if d.have then
		-- one of a thing is the title itself; "0/1 Half Pendant of..." only repeated and wrapped
		if d.have.count <= 1 then return "" end
		local name = C_Item.GetItemNameByID(d.have.item) or "item"
		return ("%d/%d %s"):format(math.min(C_Item.GetItemCount(d.have.item, true) or 0, d.have.count), d.have.count, name)
	end
	if d.level then return ("Level %d/%d"):format(UnitLevel("player"), d.level) end
	if d.skill then return ("%s %d/%d"):format(d.skill.name, skillRank(d.skill.name) or 0, d.skill.rank) end
	if d.quest then return ("Quest %d: %s"):format(d.quest.id, d.quest.state) end
	if d.reach then return d.reach.zone and ("Reach " .. d.reach.zone) or "Reach the spot" end
	if d.visit then return "Talk to them" end
	return ""
end
-- the facts about getting there, as categories (not a list item, no commas):
-- one row of fixed columns under the objective, each a small flat glyph of Blizzard's own and its value in its colour, so the same
-- fact sits in the same place in every errand. Glyphs are separate textures
-- centred on the text, not inline markup (which sat off the baseline).
local FACT_GLYPHS = {
	where = "Waypoint-MapPin-Untracked", -- the title pin's quiet twin: same family, full size (the minimap one drew half as big as the clock)
	time = "auctionhouse-icon-clock",
	route = "QuestNormal",
}
local FACT_KEYS = { "where", "time", "route" }
-- the arrow: the minimap's own player arrow (Interface/Minimap/MinimapArrow)
local ARROW, ARROW_SIZE, ARROW_TURN = "Interface/Minimap/MinimapArrow", 20, 0
-- the tracker's measures, Blizzard's own (Blizzard_ObjectiveTracker: module header
-- 26 tall, text at 7; blocks at x=20 from the module, 10 below the header; lines 4
-- apart, blocks 10 after; the POI hangs left of the title)
local MX = 6                          -- module origin; room for the hanging icon
local T, RIGHT = MX + 20, MX + 260    -- title edge; module width
local LINE_SPACING, BLOCK_SPACING, FIRST_BLOCK = 4, 10, 26 + 10
local GLYPH, GLYPH_GAP, FACT_GAP = 14, 3, 12
local FACT_COL = { time = 52, route = 120 } -- glyph lefts, from the value column
local function facts(e)
	if not e.place then return nil end
	local m = measured[e.id]
	local out = {}
	if m and m.yards then
		out.where = C_PLACE .. (m.yards >= 1000 and ("%.1f km"):format(m.yards / 1000) or ("%d yd"):format(m.yards)) .. "|r"
	else
		local info = C_Map.GetMapInfo(e.place.map)
		out.where = C_PLACE .. (info and info.name or "") .. "|r"
	end
	if m and m.eta then out.time = C_TIME .. ("%d min"):format(math.max(1, math.floor(m.eta / 60 + 0.5))) .. "|r" end
	if m and m.step then out.route = ("|cff6ee06eStep %d|r"):format(m.step) end
	return out
end
local glyphOk = {}
local function hasAtlas(name)
	if glyphOk[name] == nil then
		glyphOk[name] = (C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name)) and true or false
	end
	return glyphOk[name]
end
local ICON
local function trackerIcon()
	if ICON == nil then
		ICON = false
		for _, name in ipairs({ "Waypoint-MapPin-Tracked", "QuestNormal" }) do
			if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) then ICON = name break end
		end
	end
	return ICON
end
local function drawTracker()
	tracker = tracker or buildTracker()
	local list = E.List()
	-- this zone's first, then newest
	table.sort(list, function(a, b)
		local ha, hb = here(a), here(b)
		if ha ~= hb then return ha end
		return a.added > b.added
	end)
	tracker.blocks = tracker.blocks or {}
	for _, l in ipairs(tracker.lines) do l:Hide() end
	for _, bk in ipairs(tracker.blocks) do bk.icon:Hide() bk.title:Hide() bk.dash:Hide() for _, o in ipairs(bk.objs) do o:Hide() end for _, c in pairs(bk.cells) do c.glyph:Hide() c.text:Hide() end end
	if #list == 0 then tracker:Hide() return end
	local function fs(color)
		local f = tracker:CreateFontString(nil, "OVERLAY", tracker.lineFont)
		f:SetJustifyH("LEFT")
		f:SetWordWrap(false)
		f:SetWidth(232)
		f:SetShadowColor(0, 0, 0, 1)
		f:SetShadowOffset(1, -1)
		f:SetTextColor(color[1], color[2], color[3])
		return f
	end
	local y = -FIRST_BLOCK
	for i, e in ipairs(list) do
		if i > 6 then break end
		local bk = tracker.blocks[i]
		if not bk then
			bk = { icon = tracker:CreateTexture(nil, "ARTWORK"), title = fs(T_TITLE), dash = fs(T_OBJ), objs = {}, cells = {} }
			bk.icon:SetSize(18, 18)
			bk.dash:SetWidth(0)
			bk.dash:SetText(QUEST_DASH or "- ")
			tracker.blocks[i] = bk
		end
		bk.eid = e.id
		local title = bk.title
		title:SetWidth(RIGHT - T) title:SetWordWrap(true) title:SetMaxLines(2)
		title:SetText(e.text)
		title:ClearAllPoints()
		title:SetPoint("TOPLEFT", tracker, "TOPLEFT", T, y)
		title:Show()
		local icon = trackerIcon()
		if icon then
			bk.icon:SetAtlas(icon)
			bk.icon:ClearAllPoints()
			-- Blizzard's POI: a 20x20 TOPRIGHT at (-7,+5) of the title = centre (-17,-5)
			bk.icon:SetPoint("CENTER", title, "TOPLEFT", -17, -5)
			bk.icon:Show()
		end
		y = y - title:GetStringHeight()
		local V = T + bk.dash:GetStringWidth() -- every value's left edge
		local lines = false
		-- the objective: the dash its own string at the title's edge, as Blizzard's
		-- line template has it, so a wrapped objective hangs under its text
		local text = objectiveLine(e)
		if text ~= "" then
			local o = bk.objs[1]
			if not o then o = fs(T_OBJ) bk.objs[1] = o end
			y = y - LINE_SPACING
			o:SetWidth(RIGHT - V) o:SetWordWrap(true) o:SetMaxLines(2)
			o:SetText(text)
			o:ClearAllPoints()
			o:SetPoint("TOPLEFT", tracker, "TOPLEFT", V, y)
			o:Show()
			bk.dash:ClearAllPoints()
			bk.dash:SetPoint("TOPLEFT", tracker, "TOPLEFT", T, y + 1)
			bk.dash:Show()
			y = y - o:GetStringHeight()
			lines = true
		end
		-- the travel facts: the first glyph takes the dash's place, as Blizzard's
		-- check does; the rest keep their columns unless a long value pushes them on
		local fx = facts(e)
		if fx then
			y = y - LINE_SPACING
			local rowH, cursor = 0, 0
			for _, key in ipairs(FACT_KEYS) do
				if fx[key] then
					local c = bk.cells[key]
					if not c then
						c = { glyph = tracker:CreateTexture(nil, "ARTWORK"), text = fs(T_OBJ) }
						c.glyph:SetSize(GLYPH, GLYPH)
						c.glyph:SetAlpha(0.9)
						c.text:SetWidth(0)
						bk.cells[key] = c
					end
					local tx = key == "where" and V
						or math.max(V + FACT_COL[key], cursor + FACT_GAP) + GLYPH + GLYPH_GAP
					c.text:SetText(fx[key])
					c.yd = nil
					c.text:ClearAllPoints()
					c.text:SetPoint("TOPLEFT", tracker, "TOPLEFT", tx, y)
					c.text:Show()
					local live = key == "where" and measured[e.id] and measured[e.id].yards
					c.live = live
					if live then
						-- the live arrow takes the pin's place (sized to the atlas's shape)
						c.glyph:SetTexture(ARROW)
						c.glyph:SetTexCoord(0, 1, 0, 1)
						c.glyph:SetSize(ARROW_SIZE, ARROW_SIZE)
						-- the distance's blue, so arrow and yards read as one fact
						c.glyph:SetDesaturated(true)
						c.glyph:SetVertexColor(0.56, 0.78, 1)
						c.glyph:ClearAllPoints()
						c.glyph:SetPoint("CENTER", c.text, "LEFT", -GLYPH_GAP - GLYPH / 2, 0)
						c.glyph:Show()
					elseif hasAtlas(FACT_GLYPHS[key]) then
						c.glyph:SetSize(GLYPH, GLYPH)
						c.glyph:SetRotation(0)
						c.glyph:SetDesaturated(false)
						c.glyph:SetVertexColor(1, 1, 1)
						c.glyph:SetAtlas(FACT_GLYPHS[key])
						c.glyph:ClearAllPoints()
						c.glyph:SetPoint("RIGHT", c.text, "LEFT", -GLYPH_GAP, 0)
						c.glyph:Show()
					end
					rowH = math.max(rowH, c.text:GetStringHeight())
					cursor = tx + c.text:GetStringWidth()
				end
			end
			y = y - rowH
			lines = true
		end
		y = y - (lines and LINE_SPACING or 0) - BLOCK_SPACING
	end
	tracker:SetHeight(-y)
	tracker:Show()
end
local function drawPins()
	local pins = WC.Use("pins")
	if not pins then return end
	local points = {}
	for _, e in ipairs(E.List()) do
		if e.place and e.pinned ~= false then
			points[#points + 1] = { map = e.place.map, x = e.place.x, y = e.place.y, f = e.place.f, label = e.text, color = GOLD }
		end
	end
	pins.set("errands", points)
end

-- the Errands tab (Window.lua makes the page and calls this)
local page
-- where the item comes from, in words, not "object 100%; object 100%"
local SOURCE_WORDS = { vendor = "Sold by", drop = "Drops from", object = "Found in a container",
	quest = "Quest reward", gift = "Given by", craft = "Crafted", rep = "Reputation vendor",
	pvp = "PvP vendor", container = "Inside another item", world = "World drop" }
local function sourcesOf(e)
	if not e.item then return nil end
	local src = WC.Use("itemSource")
	local ok, list = pcall(function() return src and src.sources(e.item) end)
	if not (ok and type(list) == "table" and #list > 0) then return nil end
	local parts, seen = {}, {}
	for _, s in ipairs(list) do
		if #parts >= 2 then break end
		if type(s) == "table" then
			local who = s.npc and src.npcName and src.npcName(s.npc)
			local what = SOURCE_WORDS[s.type] or tostring(s.type or "?")
			if who then what = what .. " " .. who end
			if s.chance and s.chance < 100 then what = ("%s (%.0f%%)"):format(what, s.chance) end
			if not seen[what] then seen[what] = true parts[#parts + 1] = what end
		end
	end
	return table.concat(parts, "; ")
end
local function valueOf(e)
	if not e.item then return nil end
	local price = WC.Use("price")
	local ok, v = pcall(function() return price and price.auction(e.item) end)
	if ok and type(v) == "number" and v > 0 then return GetMoneyString(v) end
end
local function describeDone(done)
	local parts = {}
	if done.have then parts[#parts + 1] = ("%d x %s in your bags"):format(done.have.count,
		C_Item.GetItemNameByID(done.have.item) or ("item " .. done.have.item)) end
	if done.visit then parts[#parts + 1] = ("open %s with NPC %d"):format(done.visit.kind == "any" and "any window" or done.visit.kind, done.visit.npc) end
	if done.reach then parts[#parts + 1] = done.reach.zone and ("reach " .. done.reach.zone)
		or ("reach %.0f, %.0f"):format(done.reach.x, done.reach.y) end
	if done.quest then parts[#parts + 1] = ("quest %d %s"):format(done.quest.id, done.quest.state) end
	if done.level then parts[#parts + 1] = "level " .. done.level end
	if done.skill then parts[#parts + 1] = ("%s %d"):format(done.skill.name, done.skill.rank) end
	return table.concat(parts, ", ")
end
-- The Errands tab: a
-- list well on the left like the quest log, the chosen errand's details in a well
-- on the right, three buttons along its bottom. The details follow the cursor;
-- every colour names a kind of fact. Nothing secure: works in combat.
local NL = string.char(10)
local C_WHITE, C_GREY = "|cffffffff", "|cffa0a0a0"
local C_BLUE, C_GREEN = "|cff71d5ff", "|cff1eff00"
local list, detail, rows, selectedId = nil, nil, {}, nil
local MAX_ROWS = 6
local function atlasOK(name) return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil end
local function inset(parent)
	local made, f = pcall(CreateFrame, "Frame", nil, parent, "InsetFrameTemplate")
	if not made or not f then f = CreateFrame("Frame", nil, parent) end
	return f
end
local function font(parent, object, width)
	local fs = parent:CreateFontString(nil, "OVERLAY", object)
	fs:SetJustifyH("LEFT")
	fs:SetJustifyV("TOP")
	if width then fs:SetWidth(width) end
	return fs
end
local function distText(m)
	local parts = {}
	if m and m.yards then parts[#parts + 1] = m.yards >= 1000 and ("%.1f km"):format(m.yards / 1000) or ("%d yd"):format(m.yards) end
	if m and m.eta then parts[#parts + 1] = ("%d min away"):format(math.max(1, math.floor(m.eta / 60 + 0.5))) end
	return table.concat(parts, ", ")
end
local function rowLine2(e)
	local m = measured[e.id]
	if m and m.step then return C_GREEN .. ("On route, step %d"):format(m.step) .. "|r" end
	local d = distText(m)
	if d ~= "" then return C_BLUE .. d .. "|r" end
	local h = e.done.have
	if h and h.count > 1 then return C_WHITE .. ("%d/%d"):format(math.min(C_Item.GetItemCount(h.item, true) or 0, h.count), h.count) .. "|r" end
	if e.place then
		local info = C_Map.GetMapInfo(e.place.map)
		return C_GREY .. (info and info.name or "") .. "|r"
	end
	return ""
end
local drawPage
local function choose(id) if selectedId ~= id then selectedId = id drawPage() end end
local function rowFor(i)
	if rows[i] then return rows[i] end
	local b = CreateFrame("Button", nil, list)
	b:SetSize(198, 48)
	-- the nav-button art, its select glow and highlight all cover the title
	-- band only, one size (a bigger glow overhangs the art)
	b.band = CreateFrame("Frame", nil, b)
	b.band:SetPoint("TOPLEFT")
	b.band:SetPoint("TOPRIGHT")
	b.band:SetHeight(21)
	-- Blizzard's geometry (AuctionCategoryButtonTemplate): the art 32 tall from
	-- (-2, 0) over a 21-tall band, the glow on the art's exact bounds
	local function art(layer, atlas, sub)
		local t = b.band:CreateTexture(nil, layer, nil, sub)
		t:SetAtlas(atlas)
		t:SetPoint("TOPLEFT", -2, 0)
		t:SetSize(198 + 4, 32)
		return t
	end
	art("BACKGROUND", "auctionhouse-nav-button")
	-- the glow and highlight cover only the art's visible part, the band
	local function glowOn(t)
		t:ClearAllPoints()
		t:SetPoint("TOPLEFT", -2, 0)
		t:SetPoint("BOTTOMRIGHT", 2, 0)
		return t
	end
	b.sel = glowOn(art("ARTWORK", "auctionhouse-nav-button-select"))
	b.sel:SetBlendMode("ADD")
	b.sel:Hide()
	b.hl = glowOn(art("ARTWORK", "auctionhouse-nav-button-highlight", 1))
	b.hl:SetBlendMode("ADD")
	b.hl:Hide()
	b:SetScript("OnLeave", function(self) self.hl:Hide() end)
	-- one line at the art's own height, as the conversation picker has it: the
	-- art stretched to two lines makes the select glow a thick slab. The
	-- full name is in the detail pane.
	-- one button per errand: the name on the left, its
	-- detail ("19 min away") on the band itself, right-aligned short of the pin
	b.l2 = font(b.band, "GameFontHighlightSmall")
	b.l2:SetPoint("RIGHT", b.band, "RIGHT", -30, 0)
	b.l2:SetJustifyH("RIGHT")
	b.l2:SetJustifyV("MIDDLE")
	b.l2:SetWordWrap(false)
	b.l1 = font(b.band, "GameFontNormal")
	b.l1:SetPoint("LEFT", 12, 0)
	b.l1:SetPoint("RIGHT", b.l2, "LEFT", -8, 0)
	b.l1:SetJustifyV("MIDDLE")
	b.l1:SetWordWrap(false)
	if atlasOK("Waypoint-MapPin-Tracked") then
		b.pinMark = b.band:CreateTexture(nil, "OVERLAY")
		b.pinMark:SetAtlas("Waypoint-MapPin-Tracked")
		b.pinMark:SetSize(14, 14)
		b.pinMark:SetPoint("RIGHT", b.band, "RIGHT", -10, 0)
	end
	-- the details follow the cursor; A goes on to the first button
	b:SetScript("OnEnter", function(self) self.hl:Show() if self.errand then choose(self.errand.id) end end)
	b:SetScript("OnClick", function(self)
		if self.errand then choose(self.errand.id) end
	end)
	WC.MarkFocusable(b)
	rows[i] = b
	return b
end
local function build(p)
	list = inset(p)
	list:SetPoint("TOPLEFT")
	list:SetPoint("BOTTOMLEFT")
	list:SetWidth(214)
	local bg = list:CreateTexture(nil, "BACKGROUND", nil, 1)
	bg:SetAtlas("auctionhouse-background-categories")
	bg:SetPoint("TOPLEFT", 3, -3)
	bg:SetPoint("BOTTOMRIGHT", -3, 3)
	-- a real header: the section font, centred, a thin gold rule under it
	list.header = font(list, "GameFontNormal")
	list.header:SetPoint("TOP", list, "TOP", 0, -10)
	list.header:SetJustifyH("CENTER")
	list.rule = list:CreateTexture(nil, "ARTWORK")
	list.rule:SetColorTexture(1, 0.82, 0, 0.18)
	list.rule:SetHeight(1)
	list.rule:SetPoint("TOPLEFT", 10, -30)
	list.rule:SetPoint("TOPRIGHT", -10, -30)
	list.doneHead = font(list, "GameFontDisableSmall")
	list.doneHead:SetText("Done")
	list.done = font(list, "GameFontDisableSmall", 190)
	list.done:SetSpacing(6)
	detail = inset(p)
	detail:SetPoint("TOPLEFT", list, "TOPRIGHT", 8, 0)
	detail:SetPoint("BOTTOMRIGHT")
	detail.title = font(detail, "GameFontNormalLarge", 300)
	detail.title:SetPoint("TOPLEFT", 14, -12)
	detail.title:SetMaxLines(2)
	detail.added = font(detail, "GameFontDisableSmall")
	detail.added:SetPoint("TOPRIGHT", -14, -15)
	detail.added:SetJustifyH("RIGHT")
	-- sections the way the quest log has them: a gold header, then its text
	detail.whenLabel = font(detail, "GameFontNormal")
	detail.whenLabel:SetText("Objective")
	detail.when = font(detail, "GameFontHighlight", 360)
	detail.noteLabel = font(detail, "GameFontNormal")
	detail.noteLabel:SetText("Notes")
	detail.note = font(detail, "GameFontHighlight", 370)
	detail.note:SetMaxLines(4)
	detail.note:SetSpacing(2)
	detail.note:SetTextColor(0.8, 0.8, 0.8)
	local function rule()
		local r = detail:CreateTexture(nil, "ARTWORK")
		r:SetColorTexture(1, 0.82, 0, 0.18)
		r:SetHeight(1)
		return r
	end
	detail.rule = rule()
	detail.rule2 = rule()
	-- facts: labels right-aligned in one column, values in the next
	detail.facts = {}
	for i = 1, 6 do
		local label = font(detail, "GameFontNormalSmall", 72)
		label:SetJustifyH("RIGHT")
		detail.facts[i] = { label = label, value = font(detail, "GameFontHighlight", 290) }
	end
	local function button(label, x, onClick)
		local made, b = pcall(CreateFrame, "Button", nil, detail, "UIPanelButtonTemplate")
		if not made or not b then return nil end
		b:SetSize(124, 26)
		b:SetPoint("BOTTOMLEFT", x, 10)
		b:SetText(label)
		b:SetScript("OnClick", function(self) pcall(onClick, self) end)
		WC.MarkFocusable(b)
		return b
	end
	local function current()
		for _, e in ipairs(E.List()) do if e.id == selectedId then return e end end
	end
	detail.arrow = button("Point arrow", 10, function()
		local e = current()
		local nav = e and e.place and WC.Use("nav")
		if nav and nav.aim(e.place.map, e.place.x, e.place.y, e.text) then
			WC.Board.toast("|cffffd100Arrow|r  " .. e.text, 0.9, 0.9, 0.9, 4)
		end
	end)
	detail.pin = button("Pin: On", 142, function()
		local e = current()
		if not e then return end
		e.pinned = e.pinned == false and true or false
		E.Show()
	end)
	detail.remove = button("Remove", 274, function(self)
		local e = current()
		if not e then return end
		if detail.confirm == e.id and GetTime() - (detail.confirmAt or 0) < 4 then
			detail.confirm = nil
			E.Remove(e.id)
		else
			detail.confirm, detail.confirmAt = e.id, GetTime()
			self:SetText("|cffff2020Press again|r")
			C_Timer.After(4, function()
				if detail.confirm == e.id then detail.confirm = nil self:SetText("Remove") end
			end)
		end
	end)
	detail.empty = font(detail, "GameFontNormalLarge")
	detail.empty:SetPoint("CENTER", 0, 20)
	detail.empty:SetText("No errands")
	detail.emptyHint = font(detail, "GameFontDisable", 300)
	detail.emptyHint:SetPoint("CENTER", 0, -14)
	detail.emptyHint:SetJustifyH("CENTER")
	detail.emptyHint:SetText("Ask the companion to add one, for example: remind me to get the other half pendant.")
end
drawPage = function()
	if not (page and page:IsVisible()) then return end
	if not list then build(page) end
	local open = E.List()
	list.header:SetText(("Errands  |cff9d9d9d%d|r"):format(#open))
	local found = false
	for _, e in ipairs(open) do if e.id == selectedId then found = true end end
	if not found then selectedId = open[1] and open[1].id or nil end
	local y = -40
	for i = 1, math.max(#open, #rows) do
		local e = open[i]
		if e and i <= MAX_ROWS then
			local b = rowFor(i)
			b.errand = e
			b.l1:SetText(e.text)
			local band = 21
			local line2 = rowLine2(e)
			b.l2:SetText(line2)
			b:SetHeight(band)
			b.sel:SetShown(e.id == selectedId)
			if b.pinMark then b.pinMark:SetShown(e.place ~= nil and e.pinned ~= false) end
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", list, "TOPLEFT", 8, y)
			b:Show()
			y = y - b:GetHeight() - 6
		elseif rows[i] then
			rows[i]:Hide()
			rows[i].errand = nil
		end
	end
	-- done: up to three, greyed
	local finished = {}
	for _, e in ipairs(store().items) do if e.doneAt then finished[#finished + 1] = e end end
	table.sort(finished, function(a, b) return a.doneAt > b.doneAt end)
	list.doneHead:ClearAllPoints()
	list.doneHead:SetPoint("TOPLEFT", list, "TOPLEFT", 10, y - 10)
	list.done:ClearAllPoints()
	list.done:SetPoint("TOPLEFT", list.doneHead, "BOTTOMLEFT", 0, -6)
	local lines = {}
	for i, e in ipairs(finished) do
		if i > 3 then lines[#lines + 1] = ("+%d more"):format(#finished - 3) break end
		lines[#lines + 1] = e.text .. "  " .. date("%b %d", e.doneAt)
	end
	list.doneHead:SetShown(#finished > 0)
	list.done:SetText(table.concat(lines, NL))
	-- the chosen errand
	local e
	for _, x in ipairs(open) do if x.id == selectedId then e = x end end
	local showing = e ~= nil
	for _, r in ipairs({ detail.title, detail.added, detail.whenLabel, detail.when, detail.note, detail.noteLabel, detail.rule, detail.rule2 }) do r:SetShown(showing) end
	for _, f in ipairs(detail.facts) do f.label:Hide() f.value:Hide() end
	for _, b in ipairs({ detail.arrow, detail.pin, detail.remove }) do
		if b then b:SetShown(showing) end
	end
	detail.empty:SetShown(not showing)
	detail.emptyHint:SetShown(not showing)
	if not showing then return end
	detail.title:SetText(e.text)
	detail.added:SetText("Added " .. date("%b %d", e.added))
	-- Objective
	detail.whenLabel:ClearAllPoints()
	detail.whenLabel:SetPoint("TOPLEFT", detail.title, "BOTTOMLEFT", 0, -12)
	detail.when:ClearAllPoints()
	detail.when:SetPoint("TOPLEFT", detail.whenLabel, "BOTTOMLEFT", 10, -5)
	local h = e.done.have
	local when = describeDone(e.done)
	if h then
		local name = C_Item.GetItemNameByID(h.item) or "the item"
		when = h.count > 1 and ("Collect %s: %d/%d"):format(name, math.min(C_Item.GetItemCount(h.item, true) or 0, h.count), h.count)
			or ("Get %s into your bags"):format(name)
	end
	detail.when:SetText("- " .. C_WHITE .. when .. "|r")
	local function ruleUnder(r, anchor)
		r:ClearAllPoints()
		r:SetPoint("TOP", anchor, "BOTTOM", 0, -12)
		r:SetPoint("LEFT", detail, "LEFT", 14, 0)
		r:SetPoint("RIGHT", detail, "RIGHT", -14, 0)
	end
	ruleUnder(detail.rule, detail.when)
	-- facts: one fact per row, the same spacing throughout
	local facts = {}
	local m = measured[e.id]
	if e.place then
		local info = C_Map.GetMapInfo(e.place.map)
		facts[#facts + 1] = { "Location", C_WHITE .. (info and info.name or "?") .. "|r  " .. C_GREY .. ("%.1f, %.1f"):format(e.place.x, e.place.y) .. "|r" }
		local d = distText(m)
		if d ~= "" then facts[#facts + 1] = { "Travel", C_BLUE .. d .. "|r" } end
		if m and m.step then
			facts[#facts + 1] = { "Route", C_GREEN .. ("Near step %d%s"):format(m.step, m.stepTitle and (", " .. m.stepTitle) or "") .. "|r" }
		end
	end
	local src = sourcesOf(e)
	if src then facts[#facts + 1] = { "Source", C_WHITE .. src .. "|r" } end
	local worth = valueOf(e)
	if worth then facts[#facts + 1] = { "Value", worth } end
	local y = -10
	local last = detail.rule
	for i, f in ipairs(facts) do
		local slot = detail.facts[i]
		if not slot then break end
		slot.label:SetText(f[1])
		slot.value:SetText(f[2])
		slot.label:ClearAllPoints()
		slot.value:ClearAllPoints()
		slot.label:SetPoint("TOPLEFT", detail.rule, "BOTTOMLEFT", 0, y - 1)
		slot.value:SetPoint("TOPLEFT", detail.rule, "BOTTOMLEFT", 84, y)
		slot.label:Show()
		slot.value:Show()
		y = y - math.max(slot.value:GetStringHeight(), 14) - 7
		last = slot.value
	end
	-- Notes last, under their own rule
	if e.note then
		ruleUnder(detail.rule2, last)
		detail.noteLabel:ClearAllPoints()
		detail.noteLabel:SetPoint("TOPLEFT", detail.rule2, "BOTTOMLEFT", 0, -10)
		detail.note:ClearAllPoints()
		detail.note:SetPoint("TOPLEFT", detail.noteLabel, "BOTTOMLEFT", 10, -5)
		detail.note:SetText(e.note)
	else
		detail.rule2:Hide() detail.noteLabel:Hide() detail.note:Hide()
	end
	local has = e.place ~= nil
	if detail.arrow then detail.arrow:SetEnabled(has and WC.Has("nav", "aim") ~= nil) end
	if detail.pin then
		detail.pin:SetEnabled(has)
		detail.pin:SetText(e.pinned == false and "Pin: Off" or "Pin: On")
	end
	if detail.remove and detail.confirm ~= e.id then detail.remove:SetText("Remove") end
end
function E.Page(p)
	page = p
	p:HookScript("OnShow", drawPage)
end
-- the window may have been built before this file loaded
if WC.ErrandsPage and not page then E.Page(WC.ErrandsPage) end

function E.Show()
	pcall(drawTracker)
	pcall(drawPins)
	pcall(drawPage)
end

-- the agent's calls ------------------------------------------------------------------
local function find(what)
	for i, e in ipairs(store().items) do
		if e.id == what or (type(what) == "string" and e.text:lower():find(what:lower(), 1, true)) then return i, e end
	end
end
local function checkPlace(place)
	if place == nil then return nil end
	if type(place) ~= "table" or not (num(place.map) and num(place.x) and num(place.y)) then
		return "place needs { map, x, y }"
	end
	if not C_Map.GetMapInfo(place.map) then return "place: no map " .. place.map end
end
function E.Add(e)
	if type(e) ~= "table" or type(e.text) ~= "string" or e.text == "" then return nil, "an errand needs text" end
	local why = checkPlace(e.place) or checkDone(e.done)
	if why then return nil, why end
	local s = store()
	local item = { id = s.next, added = time(), text = e.text, note = e.note, place = e.place,
		item = e.item or (e.done.have and e.done.have.item), done = e.done }
	s.next = s.next + 1
	s.items[#s.items + 1] = item
	E.Show()
	return item.id
end
function E.Remove(what)
	local i = find(what)
	if not i then return nil, "no errand like " .. tostring(what) end
	table.remove(store().items, i)
	E.Show()
	return true
end
function E.Edit(what, fields)
	local _, e = find(what)
	if not e then return nil, "no errand like " .. tostring(what) end
	if type(fields) ~= "table" then return nil, "nothing to change" end
	local why = checkPlace(fields.place)
	if why then return nil, why end
	if fields.text then e.text = fields.text end
	if fields.note then e.note = fields.note end
	if fields.place then e.place = fields.place end
	E.Show()
	return true
end

-- completing ---------------------------------------------------------------------------
local function finish(e)
	e.doneAt = time()
	WC.Board.toast("|cffffd100Errand done|r  " .. e.text, 0.9, 0.9, 0.9, 6)
end
local function sweep()
	local changed = false
	for _, e in ipairs(store().items) do
		if not e.doneAt and allHold(e.done) then
			finish(e)
			changed = true
		end
	end
	return changed
end
local function anyPositional()
	for _, e in ipairs(E.List()) do
		local r = e.done.reach
		if r and not r.zone and not r.seen then return true end
	end
end
local VISIT_EVENTS = { MERCHANT_SHOW = "merchant", TRAINER_SHOW = "trainer", GOSSIP_SHOW = "gossip", BANKFRAME_OPENED = "bank" }
local watch = CreateFrame("Frame")
for _, ev in ipairs({ "PLAYER_LOGIN", "BAG_UPDATE_DELAYED", "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_LOG_UPDATE",
	"PLAYER_LEVEL_UP", "SKILL_LINES_CHANGED", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA",
	"MERCHANT_SHOW", "TRAINER_SHOW", "GOSSIP_SHOW", "BANKFRAME_OPENED" }) do
	pcall(watch.RegisterEvent, watch, ev)
end
watch:SetScript("OnEvent", function(_, event)
	if not WowCompanionErrandsDB then return end
	local ok = pcall(function()
		local window = VISIT_EVENTS[event]
		if window then
			local id = npcID("npc")
			for _, e in ipairs(E.List()) do
				local v = e.done.visit
				if v and id == v.npc and (v.kind == "any" or v.kind == window) then v.seen = true end
			end
		end
		if event:find("^ZONE_CHANGED") then
			for _, e in ipairs(E.List()) do
				local r = e.done.reach
				if r and r.zone and inZone(r.zone) then r.seen = true end
			end
		end
		local changed = sweep()
		if changed or event == "PLAYER_LOGIN" or event == "BAG_UPDATE_DELAYED" or event:find("^ZONE_CHANGED") then
			if event == "PLAYER_LOGIN" then C_Timer.After(2, E.Show) else E.Show() end
		end
	end)
	if not ok then WC.Errands.lastError = event end
end)
-- a place to reach: looked at every two seconds, only while one is open
-- the first full measure soon after login, then every 10 s (3 s while a time is owed)
-- the live arrow and yards ("live GPS" beside each distance):
-- 20 times a second while the tracker shows, a few multiplications per errand.
-- UnitPosition and GetWorldPosFromMapPos both give (north, west) yards; facing is
-- 0 at north and grows counter-clockwise, as SetRotation does.
-- Positions come from the nav capability (Polestar's own frames when it is loaded,
-- the same ones its working arrow uses; they honour a place's frame f, which the
-- raw map API ignores, so an arrow from it points wrong).
local targets = {} -- errand id -> { c, n, w, map, x, y, f }
local function targetOf(e, nav)
	local p, t = e.place, targets[e.id]
	if t and t.map == p.map and t.x == p.x and t.y == p.y and t.f == p.f then return t end
	t = { map = p.map, x = p.x, y = p.y, f = p.f }
	local ok, c, n, w = pcall(nav.world, p.map, p.x, p.y, p.f)
	if ok and c then t.c, t.n, t.w = c, n, w end
	targets[e.id] = t
	return t
end
local byId = {}
local function liveTick()
	if not (tracker and tracker:IsShown() and tracker.blocks) then return end
	local nav = WC.Use("nav")
	if not (nav and nav.here and nav.world) then return end
	local ok, inst, pn, pw = pcall(nav.here)
	local facing = GetPlayerFacing and GetPlayerFacing()
	if not (ok and pn) then return end
	wipe(byId)
	for _, e in ipairs(E.List()) do byId[e.id] = e end
	for _, bk in ipairs(tracker.blocks) do
		local c = bk.cells and bk.cells.where
		local e = bk.eid and byId[bk.eid]
		if c and c.live and c.text:IsShown() and e and e.place then
			local t = targetOf(e, nav)
			if t.n and t.c == inst then
				local dn, dw = t.n - pn, t.w - pw
				if facing then
					c.rot = math.atan2(dw, dn) - facing
					c.glyph:SetRotation(c.rot + ARROW_TURN)
					c.glyph:SetAlpha(0.9)
				else
					c.glyph:SetAlpha(0) -- no facing (an instance): no direction to give
				end
				local yd = math.floor(math.sqrt(dn * dn + dw * dw) + 0.5)
				if yd ~= c.yd then
					c.yd = yd
					c.text:SetText(C_PLACE .. (yd >= 1000 and ("%.1f km"):format(yd / 1000) or ("%d yd"):format(yd)) .. "|r")
				end
			else
				c.glyph:SetAlpha(0) -- this map has no world position here: no false direction
			end
		end
	end
end
local liveAt = 0
function E.LiveAngle(i) local bk = tracker and tracker.blocks and tracker.blocks[i] local c = bk and bk.cells and bk.cells.where return c and c.rot, bk and bk.eid end
local since, measureAt, fullAt = 0, 2, 9
watch:SetScript("OnUpdate", function(_, dt)
	measureAt, fullAt = measureAt + dt, fullAt + dt
	liveAt = liveAt + dt
	if liveAt >= 0.05 then liveAt = 0 pcall(liveTick) end
	if measureAt >= 3 and WowCompanionErrandsDB then
		local owed = false
		for _, m in pairs(measured) do if m.yards and not m.eta then owed = true end end
		local full = fullAt >= (owed and 3 or 10)
		measureAt = 0
		if full then fullAt = 0 end
		if pcall(measure, full) then pcall(drawTracker) pcall(drawPage) end
	end
	since = since + dt
	if since < 2 then return end
	since = 0
	if not (WowCompanionErrandsDB and anyPositional()) then return end
	pcall(function()
		for _, e in ipairs(E.List()) do
			local r = e.done.reach
			if r and not r.zone then
				local d = yardsTo(r.map, r.x, r.y)
				if d and d <= r.r then r.seen = true end
			end
		end
		if sweep() then E.Show() end
	end)
end)
