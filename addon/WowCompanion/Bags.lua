-- Part of WowCompanion; loaded by the .toc in order: Engine, Style, Companion,
-- Pins, Strip, Bags, Status, Modules. A file shares nothing local with another:
-- they talk through globals (WC, WowCompanion_*, WCPins, WCBags).

do
-- Our bag window (the player, 2026-11-10), moved here from modules/Bags.lua.
-- Modules run in the agent sandbox under forced taint (ForceTaint_Strong): the
-- controller's frame manager, touching a window made there, was forbidden
-- SetPreferredGamepadInteractTarget. Made here it carries only this addon's
-- taint, like the Companion window, which takes part in the focus cycle fine. Every bag slot is a secure
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
	-- where Blizzard's bags sit (UpdateContainerFrameAnchors): bottom right, 85 up
	-- (the player, 2026-11-10: "closer to where the blizzard bags show up")
	local bx = 4
	if GetInitialContainerFrameOffsetX then
		local ok, v = pcall(GetInitialContainerFrameOffsetX)
		if ok and type(v) == "number" then bx = v end
	end
	f:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -bx, CONTAINER_OFFSET_Y or 85)
	f:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	f:Hide()
	-- A focusable controller panel (the player, 2026-11-10), the same recipe as
	-- the Companion window: marked focusable, a UIPanelWindows entry, opened with
	-- ShowUIPanel (its secure dispatch tells the frame manager), FrameHidden on
	-- hide. Firing the manager's EventRegistry event ourselves ran its focus code
	-- tainted: SetPreferredGamepadInteractTarget was blocked. Never do that.
	-- It navigates itself (useCustomNavigation: the manager calls FocusGamepad /
	-- UnfocusGamepad on us). In combat ShowUIPanel is refused, so the secure
	-- snippet shows it plainly: usable, not in the focus cycle.
	-- No useCustomNavigation and no FocusGamepad / UnfocusGamepad here: the frame
	-- manager reads those fields while switching focus, and a field this addon
	-- wrote taints that switch, so the action bar's UpdateInteractIcons then calls
	-- SetPreferredGamepadInteractTarget tainted: forbidden (2026-11-10, on L2 / R2).
	-- The Companion window sets neither and switches cleanly.
	if SmartNavigation_MarkFrameFocusable then pcall(SmartNavigation_MarkFrameFocusable, f) end
	if UIPanelWindows then
		-- No area: ShowUIPanel then just shows it and tells the controller
		-- (UIParentPanelManager.lua, the no-area branch), without the panel layout
		-- that closed the vendor beside it (2026-11-10)
		UIPanelWindows["WCBags"] = nil
	end
	function f:Open()
		if InCombatLockdown() then self:Show() return end
		ShowUIPanel(self)
		if not self:IsShown() then self:Show() end
	end
	function f:Shut()
		if InCombatLockdown() then self:Hide() return end
		HideUIPanel(self)
		if self:IsShown() then self:Hide() end
	end
	-- While the bags hold controller focus, circle belongs to the game's
	-- navigation, which closes a window by clicking its CloseButton
	-- (SmartNavigation:AttemptClose keeps a tainted CloseButton's taint to that
	-- click). Without one, circle did nothing there (2026-11-10). Holding an
	-- item, it puts the item back first, as Blizzard's bags do.
	local x = CreateFrame("Button", "WCBagsCloseX", f, "UIPanelCloseButton")
	x:SetPoint("TOPRIGHT", -6, -6)
	x:SetScript("OnClick", function()
		if CursorHasItem() then ClearCursor() if f.Paint then f:Paint() end return end
		if not InCombatLockdown() then f:Shut() end
	end)
	f.CloseButton = x
	-- circle clicks CloseButton (SmartNavigation:AttemptClose), but the cursor must
	-- never land on it: the slots are what focus means here (the player, 2026-11-10)
	if SmartNavigation_MarkFrameIgnored then SmartNavigation_MarkFrameIgnored(x) end
	-- even margins all round (the player, 2026-11-10): EDGE from the border's
	-- inside on every side, a title row, the grid, a legend row
	local EDGE, TITLE_H, LEGEND_H, GAP_V = 18, 20, 24, 8
	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("LEFT", f, "TOPLEFT", EDGE, -(EDGE + TITLE_H / 2))
	f.title = title
	local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hint:SetPoint("BOTTOMLEFT", PAD + 4, PAD)
	-- the buttons Blizzard's controller bags use (ContainerFrame.lua, SetupGamepad)
	local g = WowCompanion_Glyph or function(key) return key end
	hint:SetText(("%s use   %s move   %s more   %s close   %s %s bags"):format(
		g("PAD3"), g("PAD1"), g("PAD4"), g("PAD2"), g("PADLSHOULDER"), g("PADRSHOULDER")))
	-- the controller legend as Blizzard draws it: the pad's own glyphs
	if WowCompanion_Style then
		hint:Hide()
		local prev
		f.legendW = 0
		for i, p in ipairs({ { "PAD3", USE or "Use" }, { "PAD1", "Move" }, { "PAD4", "More" },
			{ "PAD2", CLOSE or "Close" }, { "PADRSHOULDER", "Bag" } }) do
			local pr = WowCompanion_Style.Prompt(f, p[1], p[2])
			if i == 1 then f.usePrompt = pr end
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
	-- the item in hand, drawn on the focused slot's corner as Blizzard's gamepad
	-- cursor carries it
	local carry = CreateFrame("Frame", nil, f)
	carry:SetSize(SIZE - 4, SIZE - 4)
	carry:SetFrameLevel(f:GetFrameLevel() + 30)
	carry.icon = carry:CreateTexture(nil, "OVERLAY")
	carry.icon:SetAllPoints()
	carry:Hide()
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
		local held = ""
		local kind, _, link = GetCursorInfo()
		if kind == "item" and link then held = "   |cffffffffholding|r " .. link end
		self.title:SetText(("Bags   |cffffffff%d free of %d|r%s"):format(free, total, held))
		self:Carry()
		if self.focusIndex and self.order[self.focusIndex] and tip:IsShown() then self:Focus(self.focusIndex) end
	end

	-- Out of combat only: which slots exist, where they sit, the secure refs.
	function f:Layout()
		if InCombatLockdown() then self.layoutOwed = true return end
		self.layoutOwed = nil
		for _, b in pairs(self.buttons) do b:Hide() end
		wipe(self.order)
		self.gridX = EDGE + math.floor((math.max(COLS * (SIZE + GAP) - GAP, self.legendW or 0) - (COLS * (SIZE + GAP) - GAP)) / 2)
		for bag = 0, MAXBAG do
			for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
				self.order[#self.order + 1] = slotButton(bag, slot)
			end
		end
		local n = #self.order
		for bag = 0, MAXBAG do self:SetAttribute("bagstart" .. bag, nil) end
		for i, b in ipairs(self.order) do
			if not self:GetAttribute("bagstart" .. b.bag) then self:SetAttribute("bagstart" .. b.bag, i) end
			local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", self.gridX + col * (SIZE + GAP), -(EDGE + TITLE_H + GAP_V + row * (SIZE + GAP)))
			b.index = i
			b:Show()
			self:SetFrameRef("slot" .. i, b)
		end
		self:SetAttribute("count", n)
		local rows = math.max(1, math.ceil(n / COLS))
		local gridW = COLS * (SIZE + GAP) - GAP
		local inner = math.max(gridW, self.legendW or 0)
		self:SetSize(EDGE * 2 + inner, EDGE * 2 + TITLE_H + GAP_V + rows * (SIZE + GAP) - GAP + GAP_V + LEGEND_H)
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
			-- Auctionator adds its prices to GameTooltip only; this tooltip is ours,
			-- so its prices come from its API (the player, 2026-11-10)
			local A = Auctionator and Auctionator.API and Auctionator.API.v1
			local id = C_Container.GetContainerItemID(b.bag, b.slot)
			if A and id then
				local info = C_Container.GetContainerItemInfo(b.bag, b.slot)
				local n = info and info.stackCount or 1
				local ok, ah = pcall(A.GetAuctionPriceByItemID, "WowCompanion", id)
				local ok2, vendor = pcall(A.GetVendorPriceByItemID, "WowCompanion", id)
				local function money(c) return GetMoneyString and GetMoneyString(c, true) or tostring(c) end
				if ok2 and vendor and vendor > 0 then
					tip:AddDoubleLine("Vendor" .. (n > 1 and (" x" .. n) or ""), money(vendor * n), 1, 0.82, 0, 1, 1, 1)
				end
				if ok and ah and ah > 0 then
					tip:AddDoubleLine("Auction" .. (n > 1 and (" x" .. n) or ""), money(ah * n), 1, 0.82, 0, 1, 1, 1)
				elseif ok then
					tip:AddLine("Auction: not seen in your scans", 0.6, 0.6, 0.6)
				end
				tip:Show()
			end
			tip:Show()
		else
			tip:Hide()
		end
		self:Carry()
	end

	-- secure half: the d-pad walks the grid in order, cross clicks the focused slot
	f:SetAttribute("move", [[
		local dx, dy, jump = ...
		local n = self:GetAttribute("count") or 0
		if n == 0 then return end
		local cols = self:GetAttribute("cols")
		local i = self:GetAttribute("focus") or 1
		if i > n then i = 1 end
		local j = i
		if jump and jump ~= 0 then
			local here = 0
			for bag = 4, 0, -1 do
				local s0 = self:GetAttribute("bagstart" .. bag)
				if s0 and s0 <= i then here = bag break end
			end
			local bag = here
			for _ = 1, 5 do
				bag = bag + jump
				if bag > 4 then bag = 0 elseif bag < 0 then bag = 4 end
				local s0 = self:GetAttribute("bagstart" .. bag)
				if s0 then j = s0 break end
			end
		elseif dx ~= 0 then
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
		if b then self:SetBindingClick(true, "PAD3", b:GetName(), "LeftButton") end
		self:CallMethod("Focus", j)
	]])
	f:SetAttribute("_onshow", [[
		self:SetBindingClick(true, "PADDUP", "WCBagsUp")
		self:SetBindingClick(true, "PADDDOWN", "WCBagsDown")
		self:SetBindingClick(true, "PADDLEFT", "WCBagsLeft")
		self:SetBindingClick(true, "PADDRIGHT", "WCBagsRight")
		self:SetBindingClick(true, "PAD2", "WCBagsClose")
		self:SetBindingClick(true, "PAD1", "WCBagsPick")
		self:SetBindingClick(true, "PAD4", "WCBagsMore")
		self:SetBindingClick(true, "PADLSHOULDER", "WCBagsPrevBag")
		self:SetBindingClick(true, "PADRSHOULDER", "WCBagsNextBag")
		self:RunAttribute("move", 0, 0)
	]])
	f:SetAttribute("_onhide", [[ self:ClearBindings() self:CallMethod("Closed") ]])
	function f:Closed() hl:Hide() tip:Hide() end

	-- the d-pad, circle, cross and drop buttons (BagsInput.lua)
	local holdBindings = WC.BagsInput.Build(f)

	-- triangle: more actions, out of combat (BagsMenu.lua)
	local menu = WC.BagsMenu.Build(f, holdBindings, MAXBAG)
	f:HookScript("OnHide", function() menu:Hide() if CursorHasItem() then ClearCursor() end end)
	f:RegisterEvent("PLAYER_REGEN_DISABLED")

	-- opening: a macro (/click WCBagsToggle) fires once; a key binding fires
	-- WCBagsKey on the press only
	for _, name in ipairs({ "WCBagsToggle", "WCBagsKey" }) do
		local t = CreateFrame("Button", name, UIParent, "SecureHandlerClickTemplate")
		if name == "WCBagsToggle" then t:RegisterForClicks("AnyUp", "AnyDown") else t:RegisterForClicks("AnyDown") end
		t:SetFrameRef("bags", f)
		t:SetAttribute("_onclick", [[
			local bags = self:GetFrameRef("bags")
			if PlayerInCombat() then
				if bags:IsShown() then bags:Hide() else bags:Show() end
			elseif bags:IsShown() then bags:CallMethod("Shut") else bags:CallMethod("Open") end
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
	pcall(f.RegisterEvent, f, "CURSOR_CHANGED")
	f:SetScript("OnEvent", function(self, event)
		-- fires just before the lockdown: the last moment to put the window's own
		-- bindings back (menu keys or put-back on circle would be stuck all fight)
		if event == "PLAYER_REGEN_DISABLED" then
			menu:Hide()
			if self:IsShown() then ClearOverrideBindings(self) self:Execute(self:GetAttribute("_onshow")) end
			return
		end
		if event == "BAG_UPDATE_DELAYED" or event == "PLAYER_REGEN_ENABLED" then
			local n = 0
			for bag = 0, MAXBAG do n = n + (C_Container.GetContainerNumSlots(bag) or 0) end
			if n ~= #self.order or self.layoutOwed then self:Layout() return end
		end
		if event == "CURSOR_CHANGED" then if self:IsShown() then self:Paint() end return end
		if self:IsShown() or event == "BAG_UPDATE_DELAYED" then self:Paint() end
	end)
	f:HookScript("OnShow", function(self)
		self:Paint()
	end)
	-- however it closes, the manager hears (or the bars stay dead after it)
	f:HookScript("OnHide", function(self)
		if GamepadMode and GamepadMode.FrameControlsManager
			and InputUtil and InputUtil.IsGamepadUIEnabled() then
			GamepadMode.FrameControlsManager:FrameHidden(self)
		end
	end)
	-- the keyboard's own bag key opens ours (the pad uses the macro)
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
