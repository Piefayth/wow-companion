-- Our bag window, stage 1 (the player, 2026-11-10). Every bag slot is a secure
-- button running "/use bag slot", Blizzard's own right-click: use, equip, sell at
-- a vendor, attach to mail or trade, take a spell's pending item target. A button
-- is welded to its slot, so it never needs re-pointing in combat. Opening,
-- closing and the d-pad run in secure snippets, so they work in combat too.
local COLS, SIZE, GAP, PAD = 8, 40, 4, 14
local MAXBAG = 4

local function build()
	if WCBags and WCBags.SetFrameRef and WCBags.ready then return end
	local f = CreateFrame("Frame", "WCBags", UIParent, "SecureHandlerShowHideTemplate,BackdropTemplate")
	-- BackdropTemplate's OnLoad replaces the secure handler's, which gives SetFrameRef
	if not f.SetFrameRef then SecureHandler_OnLoad(f) end
	f:SetFrameStrata("DIALOG")
	f:SetPoint("RIGHT", UIParent, "RIGHT", -120, 40)
	f:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	f:Hide()
	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", PAD + 4, -PAD - 2)
	f.title = title
	local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hint:SetPoint("BOTTOMLEFT", PAD + 4, PAD)
	hint:SetText("|cffffd100cross|r use   |cffffd100triangle|r sort   |cffffd100circle|r close")
	f:SetAttribute("cols", COLS)

	local tip = CreateFrame("GameTooltip", "WCBagsTip", UIParent, "GameTooltipTemplate")
	local hl = CreateFrame("Frame", nil, f)
	hl:SetSize(SIZE + 8, SIZE + 8)
	hl:SetFrameLevel(f:GetFrameLevel() + 20)
	local hlt = hl:CreateTexture(nil, "OVERLAY")
	hlt:SetAllPoints()
	hlt:SetTexture("Interface\\Buttons\\CheckButtonHilight")
	hlt:SetBlendMode("ADD")
	hl:Hide()

	f.buttons, f.order = {}, {}

	local function slotButton(bag, slot)
		local key = bag * 100 + slot
		local b = f.buttons[key]
		if b then return b end
		b = CreateFrame("Button", ("WCBagsSlot%d_%d"):format(bag, slot), f, "SecureActionButtonTemplate")
		b:SetSize(SIZE, SIZE)
		b:RegisterForClicks("AnyDown")
		b:SetAttribute("type", "macro")
		b:SetAttribute("macrotext", ("/use %d %d"):format(bag, slot))
		b.bag, b.slot = bag, slot
		local bg = b:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetTexture("Interface\\Buttons\\UI-EmptySlot-Disabled")
		bg:SetTexCoord(0.14, 0.86, 0.14, 0.86)
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.icon:SetAllPoints()
		b.border = b:CreateTexture(nil, "OVERLAY")
		b.border:SetPoint("TOPLEFT", -1, 1)
		b.border:SetPoint("BOTTOMRIGHT", 1, -1)
		b.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
		b.border:SetBlendMode("ADD")
		b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
		b.count:SetPoint("BOTTOMRIGHT", -2, 2)
		b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
		b.cd:SetAllPoints()
		b:SetScript("OnEnter", function(self) f:Focus(self.index) end)
		b:SetScript("OnLeave", function() tip:Hide() end)
		f.buttons[key] = b
		return b
	end

	local function paint(b)
		local info = C_Container.GetContainerItemInfo(b.bag, b.slot)
		if info and info.iconFileID then
			b.icon:SetTexture(info.iconFileID)
			b.icon:SetDesaturated(info.isLocked and true or false)
			b.count:SetText((info.stackCount or 1) > 1 and info.stackCount or "")
			local q = info.quality
			if q and q >= 2 then
				local r, g, bl = C_Item.GetItemQualityColor(q)
				b.border:SetVertexColor(r, g, bl)
				b.border:Show()
			else
				b.border:Hide()
			end
			local start, dur, on = C_Container.GetContainerItemCooldown(b.bag, b.slot)
			if on and on ~= 0 and dur and dur > 0 then b.cd:SetCooldown(start, dur) else b.cd:Clear() end
		else
			b.icon:SetTexture(nil)
			b.count:SetText("")
			b.border:Hide()
			b.cd:Clear()
		end
	end

	function f:Paint()
		local free, total = 0, 0
		for _, b in ipairs(self.order) do
			paint(b)
			total = total + 1
			if not C_Container.GetContainerItemID(b.bag, b.slot) then free = free + 1 end
		end
		self.title:SetText(("Bags   |cffffffff%d free of %d|r"):format(free, total))
		if self.focusIndex and self.order[self.focusIndex] and tip:IsShown() then self:Focus(self.focusIndex) end
	end

	-- Out of combat only: which slots exist, where they sit, the secure refs.
	function f:Layout()
		if InCombatLockdown() then self.layoutOwed = true return end
		self.layoutOwed = nil
		for _, b in pairs(self.buttons) do b:Hide() end
		wipe(self.order)
		for bag = 0, MAXBAG do
			for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
				self.order[#self.order + 1] = slotButton(bag, slot)
			end
		end
		local n = #self.order
		for i, b in ipairs(self.order) do
			local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", PAD + col * (SIZE + GAP), -(PAD + 24 + row * (SIZE + GAP)))
			b.index = i
			b:Show()
			self:SetFrameRef("slot" .. i, b)
		end
		self:SetAttribute("count", n)
		local rows = math.max(1, math.ceil(n / COLS))
		self:SetSize(PAD * 2 + COLS * (SIZE + GAP) - GAP, PAD * 2 + 24 + rows * (SIZE + GAP) + 16)
		if (self:GetAttribute("focus") or 1) > n then self:SetAttribute("focus", 1) end
		self:Paint()
	end

	-- insecure half of a move: the highlight and the tooltip
	function f:Focus(i)
		local b = self.order[i]
		if not b then return end
		self.focusIndex = i
		hl:ClearAllPoints()
		hl:SetPoint("CENTER", b, "CENTER")
		hl:Show()
		tip:SetOwner(b, "ANCHOR_NONE")
		tip:ClearAllPoints()
		tip:SetPoint("TOPRIGHT", b, "TOPLEFT", -6, 0)
		if C_Container.GetContainerItemID(b.bag, b.slot) then
			tip:SetBagItem(b.bag, b.slot)
			tip:Show()
		else
			tip:Hide()
		end
	end

	-- secure half: the d-pad walks the grid in order, cross clicks the focused slot
	f:SetAttribute("move", [[
		local dx, dy = ...
		local n = self:GetAttribute("count") or 0
		if n == 0 then return end
		local cols = self:GetAttribute("cols")
		local i = self:GetAttribute("focus") or 1
		if i > n then i = 1 end
		local j = i
		if dx ~= 0 then
			j = i + dx
			if j < 1 then j = n elseif j > n then j = 1 end
		elseif dy ~= 0 then
			j = i + dy * cols
			if j > n then
				j = (i - 1) % cols + 1
			elseif j < 1 then
				j = i
				while j + cols <= n do j = j + cols end
			end
		end
		self:SetAttribute("focus", j)
		local b = self:GetFrameRef("slot" .. j)
		if b then self:SetBindingClick(true, "PAD1", b:GetName(), "LeftButton") end
		self:CallMethod("Focus", j)
	]])
	f:SetAttribute("_onshow", [[
		self:SetBindingClick(true, "PADDUP", "WCBagsUp")
		self:SetBindingClick(true, "PADDDOWN", "WCBagsDown")
		self:SetBindingClick(true, "PADDLEFT", "WCBagsLeft")
		self:SetBindingClick(true, "PADDRIGHT", "WCBagsRight")
		self:SetBindingClick(true, "PAD2", "WCBagsClose")
		self:SetBindingClick(true, "PAD4", "WCBagsSort")
		self:RunAttribute("move", 0, 0)
	]])
	f:SetAttribute("_onhide", [[ self:ClearBindings() self:CallMethod("Closed") ]])
	function f:Closed() hl:Hide() tip:Hide() end

	local function navButton(name, dx, dy)
		local b = CreateFrame("Button", name, UIParent, "SecureHandlerClickTemplate")
		b:RegisterForClicks("AnyDown")
		b:SetFrameRef("bags", f)
		b:SetAttribute("_onclick", ([[ self:GetFrameRef("bags"):RunAttribute("move", %d, %d) ]]):format(dx, dy))
	end
	navButton("WCBagsUp", 0, -1)
	navButton("WCBagsDown", 0, 1)
	navButton("WCBagsLeft", -1, 0)
	navButton("WCBagsRight", 1, 0)

	local close = CreateFrame("Button", "WCBagsClose", UIParent, "SecureHandlerClickTemplate")
	close:RegisterForClicks("AnyDown")
	close:SetFrameRef("bags", f)
	close:SetAttribute("_onclick", [[ self:GetFrameRef("bags"):Hide() ]])

	-- opening: a macro (/click WCBagsToggle) fires once; a key binding fires
	-- WCBagsKey on the press only
	for _, name in ipairs({ "WCBagsToggle", "WCBagsKey" }) do
		local t = CreateFrame("Button", name, UIParent, "SecureHandlerClickTemplate")
		if name == "WCBagsToggle" then t:RegisterForClicks("AnyUp", "AnyDown") else t:RegisterForClicks("AnyDown") end
		t:SetFrameRef("bags", f)
		t:SetAttribute("_onclick", [[
			local bags = self:GetFrameRef("bags")
			if bags:IsShown() then bags:Hide() else bags:Show() end
		]])
	end

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
	f:SetScript("OnEvent", function(self, event)
		if event == "BAG_UPDATE_DELAYED" or event == "PLAYER_REGEN_ENABLED" then
			local n = 0
			for bag = 0, MAXBAG do n = n + (C_Container.GetContainerNumSlots(bag) or 0) end
			if n ~= #self.order or self.layoutOwed then self:Layout() return end
		end
		if self:IsShown() or event == "BAG_UPDATE_DELAYED" then self:Paint() end
	end)
	f:HookScript("OnShow", function(self) self:Paint() end)

	-- the keyboard's own bag key opens ours (the pad uses the macro)
	local keys = CreateFrame("Frame", "WCBagsKeys")
	for _, cmd in ipairs({ "TOGGLEBACKPACK", "OPENALLBAGS" }) do
		for _, key in ipairs({ GetBindingKey(cmd) }) do
			SetOverrideBindingClick(keys, false, key, "WCBagsKey")
		end
	end

	f:Layout()
	f.ready = true
	print(("bags: ready, %d slots; cross uses, circle closes, triangle sorts"):format(#f.order))
end

if InCombatLockdown() then
	local w = CreateFrame("Frame")
	w:RegisterEvent("PLAYER_REGEN_ENABLED")
	w:SetScript("OnEvent", function(self) self:UnregisterAllEvents() build() end)
	print("bags: will build when this fight ends")
else
	build()
end
