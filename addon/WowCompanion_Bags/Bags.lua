-- WowCompanion_Bags: files share nothing local; they talk through globals (WC, WCBags).

do
-- Our bag window, built the way Bagnon, AdiBags and BetterBags build theirs,
-- usable all the time, in combat too.
--
-- The window holds nothing secure, so it is not protected: anything may show
-- or hide it, in combat too. Each slot is Blizzard's own ContainerFrameItemButton
-- Template under a per-bag holder frame whose ID is the bag (SetID) and whose
-- own ID is the slot: Blizzard's click code reads both through GetID, a C call,
-- so using, equipping, selling and picking up run as Blizzard's trusted code
-- (C_Container.UseContainerItem / PickupContainerItem are AllowedWhenUntainted).
-- We never write a Lua field on a slot button (Blizzard's code would read it and
-- the click would run tainted): our own data about a slot lives in `meta`, and we
-- draw through the template's regions (icon, Count, IconBorder, Cooldown).
--
-- The pad: a separate, invisible secure handler (WCBagsPad, BagsInput.lua) owns
-- the bindings. Its secure snippets bind the d-pad to moving, square to the
-- focused slot's right click (use), cross to its left click (pick up / put
-- down), so they work in combat. Out of a fight the window is a UI panel and the
-- pad follows the controller's focus on it; in a fight the pad holds by itself.
-- It is shown by our secure toggle (the Bags macro and the bag keys) and by
-- Blizzard's bag frame (BagsStandIn.lua), in combat or out, and from plain code
-- out of combat.
local COLS, SIZE, GAP = 8, 37, 5
-- Blizzard's bags, slot for slot: the bags they show (the reagent bag, the
-- keyring when shown) and every slot they draw, the backpack's locked ones too
-- (ContainerFrame_GetContainerNumSlots), so each button of theirs has one of ours.
local function bagSlots(bag) return (ContainerFrame_GetContainerNumSlots(bag)) or 0 end
local EDGE, TITLE_H, LEGEND_H, GAP_V = 18, 20, 24, 8

WC.Saved("WowCompanion_Bags", "WowCompanionBagsDB")

local function build()
	if WCBags and WCBags.ready then return end
	local f = CreateFrame("Frame", "WCBags", UIParent, "BackdropTemplate")
	f:SetFrameStrata("MEDIUM") -- Blizzard's bags' own: the controller's pointer and focus hints draw above it
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	-- where Blizzard's bags sit (UpdateContainerFrameAnchors): bottom right, 85 up
	f.home = { "BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -4, CONTAINER_OFFSET_Y or 85 }
	f:SetPoint(unpack(f.home))
	f:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	f:Hide()
	-- a UI panel, so the controller's focus cycle reaches it (WC.ShowPanel), with
	-- no area: ShowUIPanel then only shows it, where it is; the manager is told
	-- of its hide however it closes
	WC.MarkFocusable(f)
	if UIPanelWindows then UIPanelWindows["WCBags"] = {} end
	f:SetScript("OnHide", function(self) WC.FrameHidden(self) end)

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("LEFT", f, "TOPLEFT", EDGE, -(EDGE + TITLE_H / 2))
	f.title = title
	-- the legend: the pad's own glyphs, as Blizzard draws a controller legend
	f.legendW = 0
	f.prompts = {}
	if WowCompanion_Style then
		local prev
		for i, p in ipairs({ { "PAD3", USE or "Use" }, { "PAD1", "Move" }, { "PAD4", "More" },
			{ "PAD2", CLOSE or "Close" }, { "PADRSHOULDER", "Bag" } }) do
			local pr = WowCompanion_Style.Prompt(f, p[1], p[2])
			if i == 1 then f.usePrompt = pr end
			f.prompts[#f.prompts + 1] = pr
			pr:SetHeight(LEGEND_H)
			if prev then pr:SetPoint("LEFT", prev, "RIGHT", 12, 0) else pr:SetPoint("BOTTOMLEFT", EDGE, EDGE) end
			local w = pr:GetWidth()
			if pr.ControlDescText and pr.ControlDescText.GetWidth then
				w = math.max(w, 28 + (pr.ControlDescText.Text and pr.ControlDescText.Text:GetStringWidth() or pr.ControlDescText:GetWidth()))
				pr:SetWidth(w)
			end
			f.legendW = f.legendW + w + (i > 1 and 12 or 0)
			prev = pr
		end
	end

	local tip = CreateFrame("GameTooltip", "WCBagsTip", UIParent, "GameTooltipTemplate")
	local hl = CreateFrame("Frame", nil, f)
	hl:SetSize(SIZE + 8, SIZE + 8)
	hl:SetFrameLevel(f:GetFrameLevel() + 20)
	local hlt = hl:CreateTexture(nil, "OVERLAY")
	hlt:SetAllPoints()
	hlt:SetTexture("Interface\\Buttons\\CheckButtonHilight")
	hlt:SetBlendMode("ADD")
	hl:Hide()
	local carry = CreateFrame("Frame", nil, f)
	carry:SetSize(SIZE - 4, SIZE - 4)
	carry:SetFrameLevel(f:GetFrameLevel() + 30)
	carry.icon = carry:CreateTexture(nil, "OVERLAY")
	carry.icon:SetAllPoints()
	carry:Hide()

	-- per bag: the holder (its ID is the bag); per slot: Blizzard's button and our
	-- data about it, kept off the button
	local holders, buttons, meta = {}, {}, {}
	f.order, f.meta = {}, meta
	local function holder(bag)
		if holders[bag] then return holders[bag] end
		local h = CreateFrame("Frame", "WCBagsBag" .. bag, f)
		h:SetID(bag)
		h:SetAllPoints()
		holders[bag] = h
		return h
	end
	local function slotButton(bag, slot)
		local key = bag * 100 + slot
		if buttons[key] then return buttons[key] end
		local b = CreateFrame("ItemButton", ("WCBagsSlot%d_%d"):format(bag, slot), holder(bag), "ContainerFrameItemButtonTemplate")
		b:SetID(slot)
		b:UpdateExtended() -- a locked backpack slot shows Blizzard's lock, as theirs does
		b:SetSize(SIZE, SIZE)
		b:Show()
		meta[b] = { bag = bag, slot = slot }
		-- our own highlight and tooltip follow the pad; the game's controller
		-- cursor must not also land here (two markers and two
		-- tooltips). Blizzard's template is a focusable item button.
		WC.MarkIgnored(b)
		-- ours on top of theirs: focus follows the mouse too, without writing to b
		b:HookScript("OnEnter", function(self) f:Focus(meta[self].index) end)
		buttons[key] = b
		return b
	end
	function f:SlotFor(bag, slot) return buttons[bag * 100 + slot] end

	local function region(b, key, global)
		return b[key] or _G[b:GetName() .. global]
	end
	-- the template's own overlays, shown by Blizzard's ContainerFrame updates we
	-- do not run: the store highlight (BattlepayItemTexture, a soft blue outline,
	-- shown by default, on every slot), the new-item glow, the flash,
	-- the quest, upgrade and junk marks. Hidden through the regions' own methods.
	local OVERLAYS = { "BattlepayItemTexture", "NewItemTexture", "flash", "IconQuestTexture", "UpgradeIcon", "JunkIcon" }
	local function plain(b)
		for _, key in ipairs(OVERLAYS) do
			local r = b[key] or _G[b:GetName() .. key]
			if r and r.Hide then r:Hide() end
		end
		if b.newitemglowAnim and b.newitemglowAnim:IsPlaying() then b.newitemglowAnim:Stop() end
	end
	local function paint(b)
		plain(b)
		local m = meta[b]
		local info = C_Container.GetContainerItemInfo(m.bag, m.slot)
		-- the verdict: the template's junk coin, recoloured (bags.md)
		local coin = b.JunkIcon or _G[b:GetName() .. "JunkIcon"]
		local c = info and WC.BagsEval and WC.BagsEval.COIN[WC.BagsEval.Of(m.bag, m.slot)]
		if coin and c then coin:SetVertexColor(c[1], c[2], c[3]) coin:Show() end
		local icon = region(b, "icon", "IconTexture")
		local count = region(b, "Count", "Count")
		local border = b.IconBorder
		local cd = region(b, "Cooldown", "Cooldown")
		if info and info.iconFileID then
			if icon then icon:SetTexture(info.iconFileID) icon:SetDesaturated(info.isLocked and true or false) icon:Show() end
			if count then
				local n = info.stackCount or 1
				count:SetText(n > 1 and n or "")
				count:SetShown(n > 1)
			end
			if border then
				local q = info.quality
				if q and q >= 2 then
					local r, g, bl = C_Item.GetItemQualityColor(q)
					border:SetVertexColor(r, g, bl)
					border:Show()
				else
					border:Hide()
				end
			end
			if cd then
				local start, dur, on = C_Container.GetContainerItemCooldown(m.bag, m.slot)
				if on and on ~= 0 and dur and dur > 0 then cd:SetCooldown(start, dur) cd:Show() else cd:Clear() end
			end
		else
			if icon then icon:SetTexture(nil) icon:Hide() end
			if count then count:SetText("") count:Hide() end
			if border then border:Hide() end
			if cd then cd:Clear() end
		end
	end

	function f:Carry()
		local kind, id = GetCursorInfo()
		local b = self.order[self.focusIndex or 1]
		if kind == "item" and id and b then
			carry.icon:SetTexture(C_Item.GetItemIconByID(id))
			carry:ClearAllPoints()
			carry:SetPoint("CENTER", b, "BOTTOMRIGHT", -4, 4)
			carry:Show()
		else
			carry:Hide()
		end
	end

	function f:Paint()
		local free, total = 0, 0
		for _, b in ipairs(self.order) do
			paint(b)
			total = total + 1
			local m = meta[b]
			if not b:IsExtended() and not C_Container.GetContainerItemID(m.bag, m.slot) then free = free + 1 end
		end
		local held = ""
		local kind, _, link = GetCursorInfo()
		if kind == "item" and link then held = "   |cffffffffholding|r " .. link end
		self.title:SetText(("Bags   |cffffffff%d free of %d|r%s"):format(free, total, held))
		self:Carry()
		if self.focusIndex and self.order[self.focusIndex] and tip:IsShown() then self:Focus(self.focusIndex) end
	end

	-- Which slots exist and where they sit. The view (Sections by default, or
	-- storage order) draws items apart from where they are stored. Out of combat
	-- only: in a fight the order stays (the pad's grid is attributes of a
	-- protected frame) and is owed until the fight ends.
	-- the view (sections or storage), saved in WowCompanionBagsDB, read live
	-- (the saved table loads after this file runs)
	function f:View() return WowCompanionBagsDB and WowCompanionBagsDB.view or "sections" end
	local headers = {}
	local function header(n)
		local h = headers[n]
		if not h then
			h = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			h:SetJustifyH("LEFT")
			headers[n] = h
		end
		return h
	end
	local HDR = 16
	function f:Layout()
		if InCombatLockdown() and #self.order > 0 then self.layoutOwed = true self:Paint() return end
		local keep = self.order[self.focusIndex or 0]
		keep = keep and meta[keep]
		for _, b in pairs(buttons) do b:Hide() end
		for _, h in pairs(headers) do h:Hide() end
		wipe(self.order)
		local gridW = COLS * (SIZE + GAP) - GAP
		self.gridX = EDGE + math.floor((math.max(gridW, self.legendW or 0) - gridW) / 2)
		local all = {}
		for bag = STARTING_BAG_INDEX, ENDING_BAG_INDEX do
			for slot = 1, bagSlots(bag) do
				all[#all + 1] = { b = slotButton(bag, slot), bag = bag, slot = slot }
			end
		end
		local sections = self:View() == "sections" and WC.BagsEval
		local groups = {}
		if sections then
			local rank = {}
			for k, key in ipairs(WC.BagsEval.ORDER) do rank[key] = k end
			for _, e in ipairs(all) do
				-- locked slots last, under their own title, as Blizzard sorts them
				e.key = e.b:IsExtended() and (LOCKED or "Locked") or WC.BagsEval.Of(e.bag, e.slot)
				e.rank = rank[e.key] or e.b:IsExtended() and 100 or 99
				e.id = C_Container.GetContainerItemID(e.bag, e.slot) or 0
			end
			table.sort(all, function(a, b)
				if a.rank ~= b.rank then return a.rank < b.rank end
				if a.id ~= b.id then return a.id < b.id end
				if a.bag ~= b.bag then return a.bag < b.bag end
				return a.slot < b.slot
			end)
		end
		-- place, in rows. Blizzard's grid navigation (SmartNavPanelInfoAdded)
		-- takes columns by X and keeps a slot's height counted from the bottom, so
		-- it moves the way the slots look only when every short row is above every
		-- full one, the shorter higher. So each section's last row is finished with
		-- empty slots, and whatever is left (the empty slots, the locked ones,
		-- Blizzard's add-slots button) is one block with its short row on top, at
		-- the top of the bag. A row free slots cannot finish rises to the top.
		local max, now = ContainerFrame_GetContainerNumSlots(Enum.BagIndex.Backpack)
		-- Blizzard's add-slots button (shown while the account has no
		-- authenticator, ContainerFrameExtendedSlotPack) is the last cell
		local add = max > now and not IsAccountSecured()
		local rows = {}
		local function run(list, shortFirst)
			local k, first = 1, shortFirst and #list % COLS or 0
			while k <= #list do
				local r = {}
				for j = k, math.min(k + (first > 0 and first or COLS) - 1, #list) do r[#r + 1] = list[j] end
				rows[#rows + 1] = r
				k, first = k + #r, 0
			end
		end
		if sections then
			local free, locked, secs = {}, {}, {}
			for _, e in ipairs(all) do
				e.label = e.key
				if e.key == "empty" then free[#free + 1] = e
				elseif e.b:IsExtended() then locked[#locked + 1] = e
				else
					local sec = secs[#secs]
					if not sec or sec[1].key ~= e.key then sec = {} secs[#secs + 1] = sec end
					sec[#sec + 1] = e
				end
			end
			for _, sec in ipairs(secs) do
				while #sec % COLS ~= 0 and #free > 0 do
					local e = table.remove(free)
					e.label = sec[1].key
					sec[#sec + 1] = e
				end
			end
			local rest = free
			for _, e in ipairs(locked) do rest[#rest + 1] = e end
			if add then rest[#rest + 1] = { add = true, label = LOCKED or "Locked" } end
			run(rest, true)
			for _, sec in ipairs(secs) do run(sec) end
		else
			local list = {}
			for _, e in ipairs(all) do list[#list + 1] = e end
			if add then list[#list + 1] = { add = true } end
			run(list, true)
		end
		for k, r in ipairs(rows) do r.k = k end
		table.sort(rows, function(a, b)
			local sa, sb = #a < COLS and #a or COLS, #b < COLS and #b or COLS
			if sa ~= sb then return sa < sb end
			return a.k < b.k
		end)
		-- titles where the label changes; room above each titled row
		local titles, prev = {}, nil
		for ri, r in ipairs(rows) do
			for c, e in ipairs(r) do
				if sections and e.label ~= prev then titles[#titles + 1] = { ri = ri, c = c, e = e } r.titled = true end
				prev = e.label
			end
		end
		local y = EDGE + TITLE_H + GAP_V
		for _, r in ipairs(rows) do
			if r.titled then y = y + HDR end
			r.y = y
			y = y + SIZE + GAP
		end
		y = y - GAP
		self.cells = {}
		self.addCell = self.addCell or CreateFrame("Frame", nil, self)
		self.addCell:SetSize(SIZE, SIZE)
		self.addCell:Hide()
		local i = 0
		for _, r in ipairs(rows) do
			for c, e in ipairs(r) do
				local frame = e.add and self.addCell or e.b
				frame:ClearAllPoints()
				frame:SetPoint("TOPLEFT", self, "TOPLEFT", self.gridX + (c - 1) * (SIZE + GAP), -r.y)
				frame:Show()
				if not e.add then
					i = i + 1
					e.index = i
					self.order[i] = e.b
					e.b:SetParent(holder(e.bag))
					self.cells[i] = { col = c - 1, row = r.y }
					if not sections and (i == 1 or self.order[i - 1] and meta[self.order[i - 1]].bag ~= e.bag) then
						groups[#groups + 1] = i
					end
				end
			end
		end
		-- each title as wide as the room to the next title in its row
		for hn, t in ipairs(titles) do
			local nxt = titles[hn + 1]
			local upto = (nxt and nxt.ri == t.ri) and nxt.c or COLS + 1
			local h = header(hn)
			h:ClearAllPoints()
			h:SetPoint("BOTTOMLEFT", self, "TOPLEFT", self.gridX + (t.c - 1) * (SIZE + GAP), -(rows[t.ri].y - 2))
			h:SetWidth((upto - t.c) * (SIZE + GAP) - GAP)
			h:SetWordWrap(false)
			h:SetText(WC.BagsEval.TITLE[t.e.label] or t.e.label)
			h:Show()
			-- the shoulders jump to a section's first slot (the add cell has none)
			local first = t.e.index
			if not first then
				for ri = t.ri, #rows do for c, e in ipairs(rows[ri]) do
					if e.index and (ri > t.ri or c > t.c) then first = e.index break end
				end if first then break end end
			end
			if first and groups[#groups] ~= first then groups[#groups + 1] = first end
		end
		table.sort(groups)
		local g = 0
		for k, b in ipairs(self.order) do
			while groups[g + 1] and groups[g + 1] <= k do g = g + 1 end
			meta[b].index = k
			meta[b].group = math.max(g, 1)
		end
		self.groups = groups
		self:SetSize(EDGE * 2 + math.max(gridW, self.legendW or 0), y + GAP_V + LEGEND_H + EDGE)
		if WC.BagsInput and WC.BagsInput.Publish then WC.BagsInput.Publish(self) end
		-- focus stays on the same slot wherever it moved
		if keep then
			local b = buttons[keep.bag * 100 + keep.slot]
			if b and meta[b].index then
				self.focusIndex = meta[b].index
				if self.pad and not InCombatLockdown() then self.pad:SetAttribute("focus", self.focusIndex) end
			end
		end
		self:Paint()
	end
	function f:SetView(view)
		WowCompanionBagsDB.view = view
		self:Layout()
	end

	-- the highlight and our tooltip on slot i (no tooltip of ours while
	-- self.theirTooltip: BagsSkin moves Blizzard's onto our slot)
	function f:Focus(i)
		local b = self.order[i]
		if not b then return end
		self.focusIndex = i
		hl:ClearAllPoints()
		hl:SetPoint("CENTER", b, "CENTER")
		hl:Show()
		local m = meta[b]
		tip:SetOwner(b, "ANCHOR_NONE")
		tip:ClearAllPoints()
		tip:SetPoint("TOPRIGHT", b, "TOPLEFT", -6, 0)
		local id = C_Container.GetContainerItemID(m.bag, m.slot)
		if id and not self.theirTooltip then
			tip:SetBagItem(m.bag, m.slot)
			-- price addons add to GameTooltip only; ours asks the price capability
			-- (Engine.lua: an auction addon's provider, else the game's vendor price)
			local price = WC.Use and WC.Use("price")
			if price then
				local info = C_Container.GetContainerItemInfo(m.bag, m.slot)
				local n = info and info.stackCount or 1
				local vendor = price.vendor(id)
				local function money(c) return GetMoneyString and GetMoneyString(c, true) or tostring(c) end
				if vendor and vendor > 0 then
					tip:AddDoubleLine("Vendor" .. (n > 1 and (" x" .. n) or ""), money(vendor * n), 1, 0.82, 0, 1, 1, 1)
				end
				if WC.Has("price", "auction") then
					local ah = price.auction(id)
					if ah and ah > 0 then
						tip:AddDoubleLine("Auction" .. (n > 1 and (" x" .. n) or ""), money(ah * n), 1, 0.82, 0, 1, 1, 1)
					else
						tip:AddLine("Auction: not seen in your scans", 0.6, 0.6, 0.6)
					end
				end
			end
			tip:Show()
		else
			tip:Hide()
		end
		self:Carry()
	end
	function f:FocusOn(bag, slot)
		local b = buttons[bag * 100 + slot]
		if b and meta[b].index then self:Focus(meta[b].index) end
	end

	-- the pad's handler, its buttons and the triangle menu (BagsInput, BagsMenu)
	local pad, holdBindings = WC.BagsInput.Build(f)
	f.pad = pad
	local menu = WC.BagsMenu.Build(f)
	-- the pad taken or let go: the menu's bindings went with it
	function f:Held(on)
		menu:Hide()
		holdBindings()
		if not on then hl:Hide() tip:Hide() end
	end
	-- closed (the pad's handler hid): what the window showed is done with
	function f:Closed()
		-- seen now: the New section empties, as Blizzard's bags clear it on close
		if C_NewItems and C_NewItems.RemoveNewItem then
			for _, b in ipairs(f.order) do
				local m = meta[b]
				if C_NewItems.IsNewItem(m.bag, m.slot) then C_NewItems.RemoveNewItem(m.bag, m.slot) end
			end
		end
		menu:Hide()
		if CursorHasItem() then ClearCursor() end
		hl:Hide()
		tip:Hide()
	end

	-- Opening and closing from plain code: through the pad's handler, which is
	-- protected, so only out of combat; in a fight the secure toggle, circle and
	-- Blizzard's bag frame (BagsStandIn.lua) open and close it.
	function f:Open()
		if InCombatLockdown() then return end
		if not pad:IsShown() then pad:Show() end
	end
	function f:Shut()
		if InCombatLockdown() then return end
		if pad:IsShown() then pad:Hide() end
	end
	-- the mouse's close button (the pad's is circle)
	local x = CreateFrame("Button", "WCBagsCloseX", f, "UIPanelCloseButton")
	x:SetPoint("TOPRIGHT", -6, -6)
	WC.MarkIgnored(x)
	x:SetScript("OnClick", function()
		if CursorHasItem() then ClearCursor() f:Paint() return end
		f:Shut()
	end)

	-- the item viewers and the sort
	local sort = CreateFrame("Button", "WCBagsSort", UIParent)
	sort:RegisterForClicks("AnyDown")
	sort:SetScript("OnClick", function()
		if InCombatLockdown() then return end
		C_Container.SortBags()
	end)

	f:RegisterEvent("BAG_UPDATE_DELAYED")
	f:RegisterEvent("ITEM_LOCK_CHANGED")
	f:RegisterEvent("BAG_UPDATE_COOLDOWN")
	f:RegisterEvent("PLAYER_REGEN_ENABLED")
	pcall(f.RegisterEvent, f, "CURSOR_CHANGED")
	f:SetScript("OnEvent", function(self, event)
		if event == "BAG_UPDATE_DELAYED" or event == "PLAYER_REGEN_ENABLED" then
			local n = 0
			for bag = STARTING_BAG_INDEX, ENDING_BAG_INDEX do n = n + bagSlots(bag) end
			if (n ~= #self.order or self.layoutOwed
				or (self:View() == "sections" and not InCombatLockdown())) then self:Layout() return end
			if event == "PLAYER_REGEN_ENABLED" and self.layoutOwed and WC.BagsInput.Publish then WC.BagsInput.Publish(self) end
		end
		if event == "CURSOR_CHANGED" then holdBindings() if self:IsShown() then self:Paint() end return end
		if self:IsShown() or event == "BAG_UPDATE_DELAYED" then self:Paint() end
	end)
	f:HookScript("OnShow", function(self) self:Paint() end)

	-- the keyboard's own bag keys open ours through the secure toggle
	local keys = CreateFrame("Frame", "WCBagsKeys")
	for _, cmd in ipairs({ "TOGGLEBACKPACK", "OPENALLBAGS" }) do
		for _, key in ipairs({ GetBindingKey(cmd) }) do
			SetOverrideBindingClick(keys, false, key, "WCBagsKey")
		end
	end

	f:Layout()
	f.ready = true
	print(("bags: ready, %d slots"):format(#f.order))
end

if InCombatLockdown() then
	local w = CreateFrame("Frame")
	w:RegisterEvent("PLAYER_REGEN_ENABLED")
	w:SetScript("OnEvent", function(self) self:UnregisterAllEvents() build() end)
	print("bags: will build when this fight ends")
else
	build()
end

end
