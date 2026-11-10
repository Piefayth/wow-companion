-- Part of WowCompanion; loaded by the .toc in order: Engine, Style, Companion,
-- Pins, Strip, Bags, Status, Modules. A file shares nothing local with another:
-- they talk through globals (WC, WowCompanion_*, WCPins, WCBags).

-- Agent pins: places the agent talks about ("they're around 72, 69"), drawn on
-- the minimap as a dot, with a shaded disc for an area. The agent sets them from
-- a lua step; they live in WowCompanionDB.pins, so they survive a reload.
--   WCPins.Set({ { map = 1440, x = 72.5, y = 69.5, r = 40, label = "Outrunners" }, ... })
--   WCPins.Add({ ... })    WCPins.Clear()
-- map is a uiMapID, x and y are the 0-100 map coordinates players quote, r is a
-- radius in yards (0 or nil for a dot alone), color an optional { r, g, b }.
-- Drawn only while the player stands on the pin's map, in the open world.
WCPins = WCPins or {}
do
	-- Agent pins: dots and areas on the minimap at coordinates from the
	-- conversation. How it works and what went wrong: docs/api-useful.md, "Minimap pins".
	local layer, pool = nil, {}
	local function makeLayer()
		if layer or not Minimap then return layer end
		layer = CreateFrame("Frame", nil, Minimap)
		layer:SetAllPoints(Minimap)
		layer:SetFrameLevel(Minimap:GetFrameLevel() + 5)
		-- the minimap is round: anything past its edge is masked away
		-- the CircleMask atlas, not the portrait file: a texture or mask made from
		-- that file drew nothing on the minimap, while plain colour did
		-- (measured: a red square showed, every disc did not)
		layer.mask = layer:CreateMaskTexture()
		layer.mask:SetAtlas("CircleMask")
		layer.mask:SetAllPoints(Minimap)
		return layer
	end
	local function piece(i)
		local p = pool[i]
		if p then return p end
		-- solid colour cut to a circle by a mask: the alpha-mask file drawn as a
		-- plain texture may come out invisible, a masked colour cannot
		local function disc(level, sub)
			local t = layer:CreateTexture(nil, level, nil, sub)
			t:SetColorTexture(1, 1, 1, 1)
			local m = layer:CreateMaskTexture()
			m:SetAtlas("CircleMask")
			m:SetAllPoints(t)
			t:AddMaskTexture(m)
			return t
		end
		p = {}
		p.area = disc("ARTWORK", 0)
		p.area:AddMaskTexture(layer.mask)
		p.dot = disc("OVERLAY", 1)
		p.dot:SetSize(9, 9)
		p.edge = disc("OVERLAY", 0)
		p.edge:SetSize(12, 12)
		p.edge:SetVertexColor(0, 0, 0, 0.8)
		pool[i] = p
		return p
	end
	local function hideFrom(n)
		for i = n, #pool do
			local p = pool[i]
			p.area:Hide(); p.dot:Hide(); p.edge:Hide()
		end
	end
	local function draw()
		local pins = WowCompanionDB and WowCompanionDB.pins
		if not (layer and pins and #pins > 0) then hideFrom(1) return end
		local yards = C_Minimap and C_Minimap.GetViewRadius and C_Minimap.GetViewRadius()
		local half = Minimap:GetWidth() / 2
		if not (yards and yards > 0 and half > 0) then hideFrom(1) return end
		local scale = half / yards
		local rotate = GetCVar and GetCVar("rotateMinimap") == "1"
		local facing = rotate and GetPlayerFacing and GetPlayerFacing() or 0
		local sin, cos = math.sin(facing), math.cos(facing)
		local shown = 0
		-- World yards, not map positions: GetPlayerMapPosition errors on this
		-- client. UnitPosition and GetWorldPosFromMapPos both give (north, west),
		-- the order HereBeDragons relies on, so the difference is the offset.
		local pn, pw = UnitPosition("player")
		for _, pin in ipairs(pins) do
			local okPin, cont, world
			if pn and pin.map then
				okPin, cont, world = pcall(C_Map.GetWorldPosFromMapPos, pin.map,
					CreateVector2D((pin.x or 0) / 100, (pin.y or 0) / 100))
			end
			WCPins.probe = { ok = okPin, cont = cont, world = type(world), pn = pn, pw = pw }
			if okPin and world then
				local n, wv = world:GetXY()
				WCPins.probe.n, WCPins.probe.w = n, wv
				local east, north = -(wv - pw), n - pn
				local ox, oy = east * scale, north * scale
				if rotate then ox, oy = ox * cos - oy * sin, ox * sin + oy * cos end
				shown = shown + 1
				local p = piece(shown)
				local c = pin.color or { 1, 0.82, 0 }
				local dist = math.sqrt(ox * ox + oy * oy)
				WCPins.probe.ox, WCPins.probe.oy, WCPins.probe.half = ox, oy, half
				-- a texture keeps only one working mask here, so the minimap's
				-- round edge never clipped the area: keep it inside by size
				-- instead. Off the map there is no area, only the rim dot.
				local r = math.min((pin.r or 0) * scale, half - 2 - dist)
				if r > 2 then
					p.area:ClearAllPoints()
					p.area:SetPoint("CENTER", layer, "CENTER", ox, oy)
					p.area:SetSize(r * 2, r * 2)
					p.area:SetVertexColor(c[1], c[2], c[3], 0.28)
					p.area:Show()
				else
					p.area:Hide()
				end
				-- past the edge the dot sits on the rim, pointing the way
				local limit = half - 6
				local dx, dy = ox, oy
				if dist > limit then dx, dy = ox / dist * limit, oy / dist * limit end
				p.dot:ClearAllPoints(); p.dot:SetPoint("CENTER", layer, "CENTER", dx, dy)
				p.dot:SetVertexColor(c[1], c[2], c[3], 1)
				p.edge:ClearAllPoints(); p.edge:SetPoint("CENTER", p.dot, "CENTER")
				p.dot:Show(); p.edge:Show()
			end
		end
		hideFrom(shown + 1)
	end
	local ticker
	local function start()
		if not makeLayer() then return end
		if ticker then ticker:Cancel() end
		ticker = C_Timer.NewTicker(0.05, function()
			local ok, err = pcall(draw)
			-- kept, not printed: twenty a second would bury the window
			WCPins.lastError = not ok and tostring(err) or nil
			WCPins.drawn = ok
		end)
	end
	function WCPins.Set(list)
		WowCompanionDB.pins = list or {}
		start()
		return #WowCompanionDB.pins
	end
	function WCPins.Add(pin)
		WowCompanionDB.pins = WowCompanionDB.pins or {}
		table.insert(WowCompanionDB.pins, pin)
		start()
		return #WowCompanionDB.pins
	end
	function WCPins.Clear()
		WowCompanionDB.pins = {}
		hideFrom(1)
	end
	local boot = CreateFrame("Frame")
	boot:RegisterEvent("PLAYER_LOGIN")
	boot:SetScript("OnEvent", function()
		if WowCompanionDB and WowCompanionDB.pins and #WowCompanionDB.pins > 0 then start() end
	end)
end

-- The same pins on the world map. Not a data provider: AcquirePin and
-- AddDataProvider reach into Blizzard's map tables, and writing into those from
-- insecure code is the kind of thing that taints. Instead one frame of ours rides
-- on the map's canvas (WorldMapFrame:GetCanvas(), the ScrollContainer child that
-- pans and zooms), and each pin is placed by its position on whatever map is shown.
-- A pin given on a zone map is carried to the shown map through world yards:
-- GetWorldPosFromMapPos, then GetMapPosFromWorldPos(continent, pos, shownMap).
do
	local layer, pool, lastKey = nil, {}, nil
	local function piece(i)
		if pool[i] then return pool[i] end
		local function disc(level, sub)
			local t = layer:CreateTexture(nil, level, nil, sub)
			t:SetColorTexture(1, 1, 1, 1)
			local m = layer:CreateMaskTexture()
			m:SetAtlas("CircleMask")
			m:SetAllPoints(t)
			t:AddMaskTexture(m)
			return t
		end
		local p = { area = disc("ARTWORK", 0), edge = disc("OVERLAY", 0), dot = disc("OVERLAY", 1) }
		p.edge:SetVertexColor(0, 0, 0, 0.8)
		pool[i] = p
		return p
	end
	local function hideFrom(n)
		for i = n, #pool do
			local p = pool[i]
			p.area:Hide(); p.dot:Hide(); p.edge:Hide()
		end
	end
	local function onMap(pin, shown)
		local ok, cont, world = pcall(C_Map.GetWorldPosFromMapPos, pin.map,
			CreateVector2D((pin.x or 0) / 100, (pin.y or 0) / 100))
		if not (ok and cont and world) then return end
		local okPos, mapID, pos = pcall(C_Map.GetMapPosFromWorldPos, cont, world, shown)
		if not (okPos and pos and mapID == shown) then return end
		local x, y = pos:GetXY()
		local rx
		if (pin.r or 0) > 0 then
			-- the radius in map units: a point r yards north, measured on this map
			local n, w = world:GetXY()
			local okR, _, edge = pcall(C_Map.GetMapPosFromWorldPos, cont, CreateVector2D(n + pin.r, w), shown)
			if okR and edge then
				local ex, ey = edge:GetXY()
				rx = math.sqrt((ex - x) ^ 2 + (ey - y) ^ 2)
			end
		end
		return x, y, rx
	end
	local function draw()
		local map = WorldMapFrame
		local pins = WowCompanionDB and WowCompanionDB.pins
		if not (map and map:IsShown() and pins and #pins > 0) then hideFrom(1) return end
		local shown = map:GetMapID()
		local canvas = map:GetCanvas()
		local w, h = canvas:GetWidth(), canvas:GetHeight()
		-- dots keep their size on screen while the canvas zooms
		local scale = map.GetCanvasScale and map:GetCanvasScale() or 1
		if not scale or scale <= 0 then scale = 1 end
		local n = 0
		for _, pin in ipairs(pins) do
			local x, y, rx = onMap(pin, shown)
			if x then
				n = n + 1
				local p = piece(n)
				local c = pin.color or { 1, 0.82, 0 }
				local px, py = x * w, -y * h
				if rx and rx * w > 4 / scale then
					p.area:ClearAllPoints()
					p.area:SetPoint("CENTER", layer, "TOPLEFT", px, py)
					p.area:SetSize(rx * w * 2, rx * w * 2)
					p.area:SetVertexColor(c[1], c[2], c[3], 0.3)
					p.area:Show()
				else
					p.area:Hide()
				end
				p.dot:ClearAllPoints(); p.dot:SetPoint("CENTER", layer, "TOPLEFT", px, py)
				p.dot:SetSize(12 / scale, 12 / scale)
				p.dot:SetVertexColor(c[1], c[2], c[3], 1)
				p.edge:ClearAllPoints(); p.edge:SetPoint("CENTER", p.dot, "CENTER")
				p.edge:SetSize(16 / scale, 16 / scale)
				p.dot:Show(); p.edge:Show()
			end
		end
		hideFrom(n + 1)
	end
	local function attach()
		if layer or not (WorldMapFrame and WorldMapFrame.GetCanvas) then return end
		local canvas = WorldMapFrame:GetCanvas()
		layer = CreateFrame("Frame", nil, canvas)
		layer:SetAllPoints(canvas)
		-- above the map's art, below Blizzard's own pins' tooltips
		layer:SetFrameLevel(canvas:GetFrameLevel() + 20)
		local elapsed = 0
		layer:SetScript("OnUpdate", function(_, dt)
			elapsed = elapsed + dt
			if elapsed < 0.1 then return end
			elapsed = 0
			local ok, err = pcall(draw)
			WCPins.mapError = not ok and tostring(err) or nil
		end)
	end
	local f = CreateFrame("Frame")
	f:RegisterEvent("PLAYER_LOGIN")
	f:RegisterEvent("ADDON_LOADED")
	f:SetScript("OnEvent", function(_, event, name)
		if event == "PLAYER_LOGIN" or name == "Blizzard_WorldMap" then attach() end
	end)
end
