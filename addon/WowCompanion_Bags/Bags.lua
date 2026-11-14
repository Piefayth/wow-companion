-- WowCompanion_Bags: files share nothing local; they talk through globals (WC, WCBags).

do
-- What the bags look like: sections, verdicts, Blizzard's bag icons. Blizzard's
-- own bag frame is the window (BagsSkin.lua): it is focused, walked and pressed,
-- and wears this one. Nothing here is secure, so it shows and hides in combat.
-- Each slot is drawn on Blizzard's ContainerFrameItemButtonTemplate under a
-- per-bag holder whose ID is the bag (the template reads bag and slot through
-- GetID); our data about a slot lives in `meta`, never on the button, and we
-- draw through the template's regions (icon, Count, IconBorder, Cooldown).
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
		-- the cursor walks Blizzard's buttons, never these (the template is a
		-- focusable item button)
		WC.MarkIgnored(b)
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
		local b = self.focused
		if kind == "item" and id and b then
			carry.icon:SetTexture(C_Item.GetItemIconByID(id))
			carry:ClearAllPoints()
			carry:SetPoint("CENTER", b, "BOTTOMRIGHT", -4, 4)
			carry:Show()
		else
			carry:Hide()
		end
	end

	-- Blizzard's bag icons (GamepadBagBar, the controller's bags only), each a
	-- cell of ours drawn from theirs; a bag collapsed on its icon shows no slots,
	-- as in theirs (ContainerFrameMixin:UpdateItemLayout)
	local icons = {}
	local function theirIcon(bag) return GamepadBagBar and GamepadBagBar:GetBagButton(bag) end
	local function bagIcon(bag)
		local theirs = theirIcon(bag)
		if not theirs then return end
		local c = icons[theirs]
		if not c then
			c = CreateFrame("Frame", nil, f)
			c:SetSize(SIZE, SIZE)
			c.icon = c:CreateTexture(nil, "ARTWORK")
			c.icon:SetAllPoints()
			c.rim = c:CreateTexture(nil, "OVERLAY")
			c.rim:SetPoint("TOPLEFT", -3, 3)
			c.rim:SetPoint("BOTTOMRIGHT", 3, -3)
			c.count = c:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
			c.count:SetPoint("BOTTOMRIGHT", -2, 2)
			c.theirs = theirs
			icons[theirs] = c
		end
		return c
	end
	function f:BagIconFor(theirs) local c = icons[theirs] return c and c:IsShown() and c end
	local function paintIcon(c)
		local t = c.theirs
		local tex = t.icon and t.icon:GetTexture()
		c.icon:SetTexture(tex)
		c.icon:SetDesaturated(t.isCollapsed == true)
		local n = t:GetNormalTexture()
		local atlas = n and n:GetAtlas()
		if atlas then c.rim:SetAtlas(atlas) c.rim:Show() else c.rim:Hide() end
		c.count:SetText(t.Count and t.Count:IsShown() and t.Count:GetText() or "")
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
		for _, c in pairs(icons) do if c:IsShown() then paintIcon(c) end end
		self.title:SetText(("Bags   |cffffffff%d free of %d|r%s"):format(free, total, held))
		self:Carry()
	end

	-- Which slots exist and where they sit. The view (Sections by default, or
	-- storage order) draws items apart from where they are stored. In a fight
	-- the order stays, so no slot moves under the cursor, and is owed until the
	-- fight ends. The view is saved in WowCompanionBagsDB, read live (the saved
	-- table loads after this file runs)
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
		for _, b in pairs(buttons) do b:Hide() end
		for _, h in pairs(headers) do h:Hide() end
		for _, c in pairs(icons) do c:Hide() end
		wipe(self.order)
		local gridW = COLS * (SIZE + GAP) - GAP
		self.gridX = EDGE + math.floor((math.max(gridW, self.legendW or 0) - gridW) / 2)
		local all, bagIcons = {}, {}
		for bag = STARTING_BAG_INDEX, ENDING_BAG_INDEX do
			local icon, theirs = bagIcon(bag), theirIcon(bag)
			if icon and theirs:IsShown() then
				bagIcons[#bagIcons + 1] = { icon = icon, bag = bag, label = "Bags" }
			end
			if not (theirs and theirs.isCollapsed == true) then
				for slot = 1, bagSlots(bag) do
					all[#all + 1] = { b = slotButton(bag, slot), bag = bag, slot = slot }
				end
			end
		end
		local sections = self:View() == "sections" and WC.BagsEval
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
		-- takes columns by X and keeps a cell's height counted from the bottom, so
		-- it moves the way the cells look only when every short row is above every
		-- full one, the shorter higher (right from a short row's end then drops to
		-- the row below, as from the top row of theirs). So each section's last
		-- row is finished with empty slots; the bag icons are a row of their own;
		-- the empty slots left, the locked ones and Blizzard's add-slots button
		-- are one block, its short row first; and the short rows rise to the top.
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
			run(bagIcons)
			local rest = free
			for _, e in ipairs(locked) do rest[#rest + 1] = e end
			if add then rest[#rest + 1] = { add = true, label = LOCKED or "Locked" } end
			run(rest, true)
			for _, sec in ipairs(secs) do run(sec) end
		else
			-- each bag's icon before its slots, as theirs
			local list, k = {}, 1
			for _, ic in ipairs(bagIcons) do
				while all[k] and all[k].bag < ic.bag do list[#list + 1] = all[k] k = k + 1 end
				list[#list + 1] = ic
			end
			for j = k, #all do list[#list + 1] = all[j] end
			if add then list[#list + 1] = { add = true } end
			run(list, true)
		end
		-- every short row above every full one, the shorter higher
		for k, r in ipairs(rows) do r.k = k end
		table.sort(rows, function(a, b)
			local sa, sb = math.min(#a, COLS), math.min(#b, COLS)
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
		self.addCell = self.addCell or CreateFrame("Frame", nil, self)
		self.addCell:SetSize(SIZE, SIZE)
		self.addCell:Hide()
		for _, r in ipairs(rows) do
			for c, e in ipairs(r) do
				local frame = e.add and self.addCell or e.icon or e.b
				if e.icon then paintIcon(e.icon) end
				frame:ClearAllPoints()
				frame:SetPoint("TOPLEFT", self, "TOPLEFT", self.gridX + (c - 1) * (SIZE + GAP), -r.y)
				frame:Show()
				if e.b then
					self.order[#self.order + 1] = e.b
					e.b:SetParent(holder(e.bag))
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
		end
		self:SetSize(EDGE * 2 + math.max(gridW, self.legendW or 0), y + GAP_V + LEGEND_H + EDGE)
		self:Paint()
	end
	function f:SetView(view)
		WowCompanionBagsDB.view = view
		self:Layout()
	end

	-- the highlight, on the frame Blizzard's cursor is anchored to (none: hidden);
	-- on a slot, the carried item is drawn on that slot
	function f:Mark(frame, bag, slot)
		self.focused = bag and buttons[bag * 100 + slot]
		hl:ClearAllPoints()
		if frame then hl:SetPoint("CENTER", frame, "CENTER") hl:Show() else hl:Hide() end
		self:Carry()
	end

	f:RegisterEvent("BAG_UPDATE_DELAYED")
	f:RegisterEvent("ITEM_LOCK_CHANGED")
	f:RegisterEvent("BAG_UPDATE_COOLDOWN")
	f:RegisterEvent("PLAYER_REGEN_ENABLED")
	pcall(f.RegisterEvent, f, "CURSOR_CHANGED")
	f:RegisterEvent("MERCHANT_SHOW")
	f:RegisterEvent("MERCHANT_CLOSED")
	-- square sells while a vendor is open, so the legend says so
	local function sellPrompt(selling)
		local pr = f.usePrompt
		if not (pr and pr.SetPromptText) then return end
		pcall(pr.SetPromptText, pr, selling and (SELL or "Sell") or (USE or "Use"))
		if pr.RefreshInputPromptSize then pcall(pr.RefreshInputPromptSize, pr) end
	end
	f:SetScript("OnEvent", function(self, event)
		if event == "BAG_UPDATE_DELAYED" or event == "PLAYER_REGEN_ENABLED" then
			local n = 0
			for bag = STARTING_BAG_INDEX, ENDING_BAG_INDEX do n = n + bagSlots(bag) end
			if (n ~= #self.order or self.layoutOwed
				or (self:View() == "sections" and not InCombatLockdown())) then self.layoutOwed = nil self:Layout() return end
		end
		if event == "MERCHANT_SHOW" or event == "MERCHANT_CLOSED" then sellPrompt(event == "MERCHANT_SHOW") return end
		if self:IsShown() or event == "BAG_UPDATE_DELAYED" then self:Paint() end
	end)
	f:HookScript("OnShow", function(self) self:Paint() end)

	f:Layout()
	f.ready = true
	WC.BagsSkin() -- Blizzard's frame wears it (BagsSkin.lua)
end

if InCombatLockdown() then
	local w = CreateFrame("Frame")
	w:RegisterEvent("PLAYER_REGEN_ENABLED")
	w:SetScript("OnEvent", function(self) self:UnregisterAllEvents() build() end)
	WC.Say("bags: will build when this fight ends")
else
	build()
end

end
