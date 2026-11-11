-- Bags: the triangle menu (put on a bar, split, destroy, sort). Loads before
-- Bags.lua, which calls WC.BagsMenu.Build(f, holdBindings, MAXBAG) and keeps the menu it returns.

WC.BagsMenu = WC.BagsMenu or {}

function WC.BagsMenu.Build(f, holdBindings, MAXBAG)
	-- triangle: more actions, out of combat (Blizzard's list has bind to the
	-- bar and split the stack; sorting is added here)
	-- drawn as Blizzard's context menu (WowCompanion_Style, in the addon)
	local menu = CreateFrame("Frame", "WCBagsMenu", f)
	menu:SetFrameStrata("FULLSCREEN_DIALOG")
	menu:Hide()
	if WowCompanion_Style then WowCompanion_Style.Menu(menu) end
	menu.hl = WowCompanion_Style and WowCompanion_Style.Highlight(menu) or menu:CreateTexture(nil, "ARTWORK")
	menu.rows = {}
	if WowCompanion_Style then
		local pick = WowCompanion_Style.Prompt(menu, "PAD1", ACCEPT or "Select")
		pick:SetPoint("TOPLEFT", menu, "BOTTOMLEFT", 2, -10)
		local back = WowCompanion_Style.Prompt(menu, "PAD2", BACK or "Back")
		back:SetPoint("LEFT", pick, "RIGHT", 14, 0)
	end
	local function firstFree()
		for bag = 0, MAXBAG do
			for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
				if not C_Container.GetContainerItemID(bag, slot) then return bag, slot end
			end
		end
	end
	local function split(b, n)
		local m = f.meta[b]
		local bag, slot = firstFree()
		if not bag then print("bags: no free slot to split into") return end
		C_Container.SplitContainerItem(m.bag, m.slot, n)
		C_Container.PickupContainerItem(bag, slot)
	end
	local BARS = { { 181, "d-pad" }, { 185, "L2" }, { 193, "R2" }, { 201, "L2+R2" } }
	local KEYS = { "left", "up", "right", "down", "square", "triangle", "circle", "cross" }
	local function toBar(b)
		for _, bar in ipairs(BARS) do
			for k = 0, 7 do
				if not GetActionInfo(bar[1] + k) then
					C_Container.PickupContainerItem(f.meta[b].bag, f.meta[b].slot)
					PlaceAction(bar[1] + k)
					ClearCursor()
					print(("bags: put on %s + %s"):format(bar[2], KEYS[k + 1]))
					return
				end
			end
		end
		print("bags: no empty bar button")
	end
	local closeMenu
	local function entries(b)
		local m = f.meta[b]
		local info = C_Container.GetContainerItemInfo(m.bag, m.slot)
		local list = {}
		if info then
			if C_Item.IsUsableItem(info.itemID) then list[#list + 1] = { "Put on action bar", function() toBar(b) end } end
			local n = info.stackCount or 1
			if n > 1 then
				list[#list + 1] = { "Split stack in half", function() split(b, math.floor(n / 2)) end }
				list[#list + 1] = { "Split one off", function() split(b, 1) end }
			end
		end
		-- a spare bag: swap it in, emptying the bag it replaces (modules/BagSwap.lua)
		if info and WCSwapBag and select(4, C_Item.GetItemInfoInstant(info.itemID)) == "INVTYPE_BAG" then
			list[#list + 1] = { "Equip this bag", function() WCSwapBag(info.itemID) end }
		end
		-- linking is by voice (\"link X to Y\"), not a menu entry
		if info and WowCompanion_ConfirmDestroy then
			list[#list + 1] = { "|cffff6060Destroy|r", function()
				-- the confirmation takes cross and circle; ours come back when it closes
				ClearOverrideBindings(f.pad)
				if not WowCompanion_ConfirmDestroy(m.bag, m.slot, function() closeMenu() end) then closeMenu() end
			end }
		end
		-- at a vendor: sell everything the verdicts call Sell (BagsEvaluate.lua);
		-- the player's pick, and Buyback undoes it
		local sell = WC.BagsEval and MerchantFrame and MerchantFrame:IsShown() and WC.BagsEval.SellList()
		if sell and #sell > 0 then
			list[#list + 1] = { ("Sell all marked Sell (%d)"):format(#sell), function()
				for _, e in ipairs(WC.BagsEval.SellList()) do C_Container.UseContainerItem(e[1], e[2]) end
			end }
		end
		if f.SetView then
			local sections = f.settings.view == "sections"
			list[#list + 1] = { sections and "View: storage order" or "View: sections", function()
				f:SetView(sections and "storage" or "sections")
			end }
		end
		list[#list + 1] = { "Sort bags", function() C_Container.SortBags() end }
		list[#list + 1] = { "Cancel", function() end }
		return list
	end
	closeMenu = function()
		menu:Hide()
		if not InCombatLockdown() and f:IsShown() then
			ClearOverrideBindings(f.pad)
			f.pad:Execute(f.pad:GetAttribute("_onshow"))
			holdBindings()
		end
	end
	local function paintMenu()
		for i, row in ipairs(menu.rows) do
			local on = i == menu.sel
			row:SetTextColor(1, 1, 1)
			row:SetText(menu.list[i] and menu.list[i][1] or "")
			row:SetShown(menu.list[i] ~= nil)
			if on then
				menu.hl:ClearAllPoints()
				menu.hl:SetPoint("LEFT", menu, "LEFT", 2, 0)
				menu.hl:SetPoint("RIGHT", menu, "RIGHT", -2, 0)
				menu.hl:SetPoint("TOP", menu, "TOP", 0, -(6 + (i - 1) * 20))
				menu.hl:SetHeight(20)
				menu.hl:Show()
			end
		end
	end
	local function plainButton(name, fn)
		local b = CreateFrame("Button", name, UIParent)
		b:RegisterForClicks("AnyDown")
		b:SetScript("OnClick", fn)
	end
	plainButton("WCBagsMenuUp", function() menu.sel = menu.sel > 1 and menu.sel - 1 or #menu.list paintMenu() end)
	plainButton("WCBagsMenuDown", function() menu.sel = menu.sel < #menu.list and menu.sel + 1 or 1 paintMenu() end)
	plainButton("WCBagsMenuPick", function()
		local e = menu.list[menu.sel]
		closeMenu()
		if e then pcall(e[2]) end
		f:Paint()
	end)
	plainButton("WCBagsMenuBack", closeMenu)
	plainButton("WCBagsMore", function()
		if InCombatLockdown() or CursorHasItem() then return end
		local b = f.order[f.focusIndex or 1]
		if not b then return end
		menu.list, menu.sel = entries(b), 1
		for i = #menu.rows + 1, #menu.list do
			-- MenuStyle2's insets: 6 above, 7 below; each row a 20 px cell, text centred in it
			local row = menu:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row:SetPoint("LEFT", menu, "TOPLEFT", 12, -(6 + (i - 0.5) * 20))
			row:SetJustifyH("LEFT")
			menu.rows[i] = row
		end
		menu:SetSize(190, 6 + #menu.list * 20 + 7)
		menu:ClearAllPoints()
		menu:SetPoint("TOPLEFT", b, "BOTTOMRIGHT", 4, 4)
		paintMenu()
		menu:Show()
		SetOverrideBindingClick(f.pad, true, "PADDUP", "WCBagsMenuUp")
		SetOverrideBindingClick(f.pad, true, "PADDDOWN", "WCBagsMenuDown")
		SetOverrideBindingClick(f.pad, true, "PAD1", "WCBagsMenuPick")
		for _, key in ipairs({ "PAD2", "PAD3", "PAD4", "PADDLEFT", "PADDRIGHT" }) do
			SetOverrideBindingClick(f.pad, true, key, "WCBagsMenuBack")
		end
	end)
	return menu
end
