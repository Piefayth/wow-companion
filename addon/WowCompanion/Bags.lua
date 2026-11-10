-- Part of WowCompanion; loaded by the .toc in order: Engine, Style, Companion,
-- Pins, Strip, Bags, Status, Modules. A file shares nothing local with another:
-- they talk through globals (WC, WowCompanion_*, WCPins, WCBags).

do
-- Our bag window, rebuilt the way Bagnon, AdiBags and BetterBags build theirs
-- (the player, 2026-11-10: "I just want my bags all the time, no matter what").
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
-- down), so they work in combat. It is shown by our secure toggle (the Bags macro
-- and the bag keys) in combat or out, and from plain code out of combat. When
-- Blizzard's bag radial opens bags in combat, BagsStandIn.lua lays ours over
-- Blizzard's own (focused by the game's controller manager) instead.
local COLS, SIZE, GAP = 8, 37, 5
local MAXBAG = 4
local EDGE, TITLE_H, LEGEND_H, GAP_V = 18, 20, 24, 8

local function build()
	if WCBags and WCBags.ready then return end
	local f = CreateFrame("Frame", "WCBags", UIParent, "BackdropTemplate")
	f:SetFrameStrata("DIALOG")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	-- where Blizzard's bags sit (UpdateContainerFrameAnchors): bottom right, 85 up
	local bx = 4
	if GetInitialContainerFrameOffsetX then
		local ok, v = pcall(GetInitialContainerFrameOffsetX)
		if ok and type(v) == "number" then bx = v end
	end
	f.home = { "BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -bx, CONTAINER_OFFSET_Y or 85 }
	f:SetPoint(unpack(f.home))
	f:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	f:Hide()
	-- out of combat a focusable controller panel, as before (marked focusable,
	-- shown with ShowUIPanel with no UIPanelWindows area, FrameHidden on hide);
	-- never useCustomNavigation or FocusGamepad fields (they taint the switch)
	if SmartNavigation_MarkFrameFocusable then pcall(SmartNavigation_MarkFrameFocusable, f) end
	if UIPanelWindows then UIPanelWindows["WCBags"] = nil end

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
		b:SetSize(SIZE, SIZE)
		b:Show()
		meta[b] = { bag = bag, slot = slot }
		-- our own highlight and tooltip follow the pad; the game's controller
		-- cursor must not also land here (two markers and two tooltips, the
		-- player, 2026-11-10). Blizzard's template is a focusable item button.
		if SmartNavigation_MarkFrameIgnored then pcall(SmartNavigation_MarkFrameIgnored, b) end
		-- ours on top of theirs: focus follows the mouse too, without writing to b
		b:HookScript("OnEnter", function(self) if f.mirror then return end f:Focus(meta[self].index) end)
		buttons[key] = b
		return b
	end
	function f:SlotFor(bag, slot) return buttons[bag * 100 + slot] end

	local function region(b, key, global)
		return b[key] or _G[b:GetName() .. global]
	end
	-- the template's own overlays, shown by Blizzard's ContainerFrame updates we
	-- do not run: the store highlight (BattlepayItemTexture, a soft blue outline,
	-- shown by default: on every slot, 2026-11-10), the new-item glow, the flash,
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
			if not C_Container.GetContainerItemID(m.bag, m.slot) then free = free + 1 end
		end
		local held = ""
		local kind, _, link = GetCursorInfo()
		if kind == "item" and link then held = "   |cffffffffholding|r " .. link end
		self.title:SetText(("Bags   |cffffffff%d free of %d|r%s"):format(free, total, held))
		self:Carry()
		if self.focusIndex and self.order[self.focusIndex] and tip:IsShown() then self:Focus(self.focusIndex) end
	end

	-- Which slots exist and where they sit; free at any time (nothing here is
	-- protected). The pad's handler gets the slot names when it may (BagsInput).
	function f:Layout()
		for _, b in pairs(buttons) do b:Hide() end
		wipe(self.order)
		local gridW = COLS * (SIZE + GAP) - GAP
		self.gridX = EDGE + math.floor((math.max(gridW, self.legendW or 0) - gridW) / 2)
		for bag = 0, MAXBAG do
			for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
				self.order[#self.order + 1] = slotButton(bag, slot)
			end
		end
		local n = #self.order
		for i, b in ipairs(self.order) do
			meta[b].index = i
			b:SetParent(holder(meta[b].bag))
			b:ClearAllPoints()
			local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
			b:SetPoint("TOPLEFT", self, "TOPLEFT", self.gridX + col * (SIZE + GAP), -(EDGE + TITLE_H + GAP_V + row * (SIZE + GAP)))
			b:EnableMouse(true)
			b:Show()
		end
		local rows = math.max(1, math.ceil(n / COLS))
		self:SetSize(EDGE * 2 + math.max(gridW, self.legendW or 0),
			EDGE * 2 + TITLE_H + GAP_V + rows * (SIZE + GAP) - GAP + GAP_V + LEGEND_H)
		if WC.BagsInput and WC.BagsInput.Publish then WC.BagsInput.Publish(self) end
		self:Paint()
	end

	-- the highlight and our tooltip on slot i
	function f:Focus(i)
		local b = self.order[i]
		if not b then return end
		self.focusIndex = i
		hl:ClearAllPoints()
		hl:SetPoint("CENTER", b, "CENTER")
		hl:Show()
		if self.mirror then tip:Hide() self:Carry() return end
		local m = meta[b]
		tip:SetOwner(b, "ANCHOR_NONE")
		tip:ClearAllPoints()
		tip:SetPoint("TOPRIGHT", b, "TOPLEFT", -6, 0)
		local id = C_Container.GetContainerItemID(m.bag, m.slot)
		if id then
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
	function f:Closed() hl:Hide() tip:Hide() end

	-- Mirror mode (BagsStandIn.lua, in combat): our slots laid exactly over
	-- Blizzard's, which hold the controller's focus and take the presses; ours
	-- only show. Out of it, our own grid again.
	-- In controller mode Blizzard's combined bags lay one bag button per bag (the
	-- ones that collapse a bag, GamepadBagBar) into the same grid as the slots
	-- (ContainerFrame.lua UpdateItemLayout). Mirrored, those cells were gaps
	-- (the player, 2026-11-10): ours draw the bag's icon there.
	local bagIcons = {}
	local function bagIcon(i)
		local t = bagIcons[i]
		if t then return t end
		t = CreateFrame("Frame", nil, f)
		t:SetSize(SIZE, SIZE)
		t.tex = t:CreateTexture(nil, "ARTWORK")
		t.tex:SetAllPoints()
		t.ring = t:CreateTexture(nil, "OVERLAY")
		t.ring:SetPoint("TOPLEFT", -1, 1)
		t.ring:SetPoint("BOTTOMRIGHT", 1, -1)
		t.ring:SetTexture("Interface\\Buttons\\UI-Quickslot2")
		t.ring:SetTexCoord(0.2, 0.8, 0.2, 0.8)
		bagIcons[i] = t
		return t
	end
	local function mirrorBagButtons()
		for _, t in pairs(bagIcons) do t:Hide() end
		if not (GamepadBagBar and GamepadBagBar.GetBagButton) then return end
		local n = 0
		for bag = 0, MAXBAG do
			local ok, btn = pcall(GamepadBagBar.GetBagButton, GamepadBagBar, bag)
			if ok and btn and btn:IsShown() then
				n = n + 1
				local t = bagIcon(n)
				local tex
				if bag == 0 then
					tex = "Interface\\Buttons\\Button-Backpack-Up"
				else
					local inv = C_Container.ContainerIDToInventoryID and C_Container.ContainerIDToInventoryID(bag)
					tex = inv and GetInventoryItemTexture("player", inv)
				end
				t.tex:SetTexture(tex or "Interface\\Buttons\\UI-EmptySlot-Disabled")
				t:ClearAllPoints()
				t:SetPoint("CENTER", btn, "CENTER")
				t:Show()
			end
		end
	end

	function f:Mirror(blizz)
		self.mirror = blizz and true or nil
		if blizz then mirrorBagButtons() else for _, t in pairs(bagIcons) do t:Hide() end end
		-- The legend stays (the player, 2026-11-10: no prompts in combat looked
		-- broken): Blizzard's controller bags use the same buttons as ours
		-- (square use, cross move, triangle more, circle close), and their own
		-- legend is on their invisible frame. Below their slots, not on them; the
		-- bag-jump prompt is ours alone.
		for i, pr in ipairs(self.prompts) do pr:SetShown(not blizz or i < 5) end
		if not blizz then
			self:ClearAllPoints()
			self:SetPoint(unpack(self.home))
			self:Layout()
			return
		end
		-- our backing spans their slots only (not their header, search box or
		-- money row), with our usual margins and the title above
		self:ClearAllPoints()
		local l, r, t, bm
		if blizz.EnumerateValidItems then
			for _, theirs in blizz:EnumerateValidItems() do
				if theirs:IsShown() and theirs:GetLeft() then
					l = math.min(l or 1e9, theirs:GetLeft())
					r = math.max(r or -1e9, theirs:GetRight())
					t = math.max(t or -1e9, theirs:GetTop())
					bm = math.min(bm or 1e9, theirs:GetBottom())
				end
			end
		end
		if l then
			local k = blizz:GetEffectiveScale() / self:GetEffectiveScale()
			self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l * k - EDGE, t * k + EDGE + TITLE_H + GAP_V)
			self:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMLEFT", math.max(r * k + EDGE, l * k - EDGE + EDGE * 2 + (self.legendW or 0)), bm * k - EDGE - GAP_V - LEGEND_H)
		else
			self:SetPoint("TOPLEFT", blizz, "TOPLEFT", -6, 6)
			self:SetPoint("BOTTOMRIGHT", blizz, "BOTTOMRIGHT", 6, -6)
		end
		for _, b in pairs(buttons) do b:Hide() end
		if blizz.EnumerateValidItems then
			for _, theirs in blizz:EnumerateValidItems() do
				local ok, bag = pcall(theirs.GetBagID, theirs)
				local ours = ok and bag and buttons[bag * 100 + theirs:GetID()]
				if ours then
					ours:ClearAllPoints()
					ours:SetPoint("CENTER", theirs, "CENTER")
					ours:EnableMouse(false)
					ours:Show()
				end
			end
		end
		self:Paint()
	end

	-- the pad's handler, its buttons and the triangle menu (BagsInput, BagsMenu)
	local pad, holdBindings = WC.BagsInput.Build(f)
	f.pad = pad
	local menu = WC.BagsMenu.Build(f, holdBindings, MAXBAG)
	f:HookScript("OnHide", function()
		menu:Hide()
		if CursorHasItem() then ClearCursor() end
		hl:Hide()
		tip:Hide()
		-- the pad's handler follows the window, when it may
		if not InCombatLockdown() and pad:IsShown() then pad:Hide() end
	end)

	-- Opening and closing from plain code: always allowed now. Out of combat the
	-- pad's handler comes too (it is protected, so in combat only our secure
	-- toggle may show it).
	function f:Open()
		if self.mirror then self:Mirror(nil) end
		if not InCombatLockdown() then
			ShowUIPanel(self)
			if not pad:IsShown() then pad:Show() end
		end
		if not self:IsShown() then self:Show() end
	end
	function f:Shut()
		-- in a fight with the pad's bindings up, only circle (secure) may close
		-- both; closing the window alone would leave the d-pad held
		if InCombatLockdown() and pad:IsShown() then return end
		if not InCombatLockdown() then
			HideUIPanel(self)
			if pad:IsShown() then pad:Hide() end
		end
		if self:IsShown() then self:Hide() end
	end
	-- however it closes, the controller's manager hears (or the bars stay dead)
	f:HookScript("OnHide", function(self)
		if GamepadMode and GamepadMode.FrameControlsManager
			and InputUtil and InputUtil.IsGamepadUIEnabled() then
			pcall(GamepadMode.FrameControlsManager.FrameHidden, GamepadMode.FrameControlsManager, self)
		end
	end)
	-- circle with the window focused clicks its CloseButton (SmartNavigation)
	local x = CreateFrame("Button", "WCBagsCloseX", f, "UIPanelCloseButton")
	x:SetPoint("TOPRIGHT", -6, -6)
	x:SetScript("OnClick", function()
		if CursorHasItem() then ClearCursor() f:Paint() return end
		f:Shut()
	end)
	f.CloseButton = x
	if SmartNavigation_MarkFrameIgnored then pcall(SmartNavigation_MarkFrameIgnored, x) end

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
	f:RegisterEvent("PLAYER_REGEN_DISABLED")
	f:RegisterEvent("PLAYER_REGEN_ENABLED")
	pcall(f.RegisterEvent, f, "CURSOR_CHANGED")
	f:SetScript("OnEvent", function(self, event)
		if event == "PLAYER_REGEN_DISABLED" then
			-- the last moment to put the pad's own bindings back (the menu's would
			-- be stuck all fight)
			menu:Hide()
			if pad:IsShown() then ClearOverrideBindings(pad) pad:Execute(pad:GetAttribute("_onshow")) end
			return
		end
		if event == "BAG_UPDATE_DELAYED" or event == "PLAYER_REGEN_ENABLED" then
			local n = 0
			for bag = 0, MAXBAG do n = n + (C_Container.GetContainerNumSlots(bag) or 0) end
			if not self.mirror and (n ~= #self.order or self.layoutOwed) then self:Layout() return end
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
