-- Bags split (2026-11-10): the pad's buttons while the bags are open (d-pad,
-- circle, cross and the drop button), moved out of Bags.lua build() as is.
-- Loads before Bags.lua, which calls WC.BagsInput.Build(f) for holdBindings.

WC.BagsInput = WC.BagsInput or {}

function WC.BagsInput.Build(f)
	local function navButton(name, dx, dy, jump)
		local b = CreateFrame("Button", name, UIParent, "SecureHandlerClickTemplate")
		b:RegisterForClicks("AnyDown")
		b:SetFrameRef("bags", f)
		b:SetAttribute("_onclick", ([[ self:GetFrameRef("bags"):RunAttribute("move", %d, %d, %d) ]]):format(dx, dy, jump or 0))
	end
	navButton("WCBagsPrevBag", 0, 0, -1)
	navButton("WCBagsNextBag", 0, 0, 1)
	navButton("WCBagsUp", 0, -1)
	navButton("WCBagsDown", 0, 1)
	navButton("WCBagsLeft", -1, 0)
	navButton("WCBagsRight", 1, 0)

	local close = CreateFrame("Button", "WCBagsClose", UIParent, "SecureHandlerClickTemplate")
	close:RegisterForClicks("AnyDown")
	close:SetFrameRef("bags", f)
	close:SetAttribute("_onclick", [[
		local bags = self:GetFrameRef("bags")
		if PlayerInCombat() then bags:Hide() else bags:CallMethod("Shut") end
	]])
	-- Holding an item, circle puts it back (Blizzard's Back). Out of combat the
	-- binding swaps to WCBagsDrop, which only puts it back; in combat it puts it
	-- back and closes.
	close:HookScript("PreClick", function() if CursorHasItem() then ClearCursor() end end)
	local drop = CreateFrame("Button", "WCBagsDrop", UIParent)
	drop:RegisterForClicks("AnyDown")

	-- cross: pick up and put down, as a left click on Blizzard's slot does
	local pick = CreateFrame("Button", "WCBagsPick", UIParent)
	pick:RegisterForClicks("AnyDown")
	local function holdBindings()
		if InCombatLockdown() then return end
		SetOverrideBindingClick(f, true, "PAD2", CursorHasItem() and "WCBagsDrop" or "WCBagsClose")
	end
	pick:SetScript("OnClick", function()
		local b = f.order[f.focusIndex or 1]
		if not b then return end
		C_Container.PickupContainerItem(b.bag, b.slot)
		holdBindings()
		f:Paint()
	end)
	drop:SetScript("OnClick", function()
		ClearCursor()
		holdBindings()
		f:Paint()
	end)
	return holdBindings
end
