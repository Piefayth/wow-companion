-- Bags: the pad while our bags are open (2026-11-10 rebuild). Loads before
-- Bags.lua, which calls WC.BagsInput.Build(f) and WC.BagsInput.Publish(f).
--
-- WCBagsPad is an invisible secure handler that owns the bindings, apart from
-- the window, so the window itself stays unprotected (and may open in combat).
-- Its snippets run in the restricted environment, so they may bind keys in
-- combat: the d-pad moves, square right-clicks the focused slot (Blizzard's use),
-- cross left-clicks it (Blizzard's pick up / put down), triangle opens the menu
-- (out of combat), circle closes, the shoulders jump bags. A slot is clicked by
-- its button's name, so the click is the slot's own, Blizzard's trusted code.
-- Shown by our secure toggle (the Bags macro, the bag keys) in combat or out, and
-- by the window's Open out of combat; its show and hide carry the window along.

WC.BagsInput = WC.BagsInput or {}

local pad

-- the slot names and the grid, for the snippets; only out of combat (attributes
-- of a protected frame), else owed until the fight ends
function WC.BagsInput.Publish(f)
	if not pad then return end
	if InCombatLockdown() then f.layoutOwed = true return end
	f.layoutOwed = nil
	for bag = 0, 4 do pad:SetAttribute("bagstart" .. bag, nil) end
	for i, b in ipairs(f.order) do
		local m = f.meta[b]
		pad:SetAttribute("slot" .. i, b:GetName())
		if not pad:GetAttribute("bagstart" .. m.bag) then pad:SetAttribute("bagstart" .. m.bag, i) end
	end
	pad:SetAttribute("count", #f.order)
	if (pad:GetAttribute("focus") or 1) > #f.order then pad:SetAttribute("focus", 1) end
end

function WC.BagsInput.Build(f)
	pad = CreateFrame("Frame", "WCBagsPad", UIParent, "SecureHandlerShowHideTemplate")
	pad:SetSize(1, 1)
	pad:SetPoint("TOPLEFT")
	pad:Hide()
	pad:SetAttribute("cols", 8)
	-- insecure halves, called from the snippets with CallMethod
	function pad:Focus(i) f:Focus(i) end
	function pad:Opened() if f.mirror then f:Mirror(nil) end if not f:IsShown() then f:Show() end end
	function pad:Closed() if f:IsShown() then f:Hide() end f:Closed() end

	pad:SetAttribute("move", [[
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
		local name = self:GetAttribute("slot" .. j)
		if name then
			self:SetBindingClick(true, "PAD3", name, "RightButton")
			self:SetBindingClick(true, "PAD1", name, "LeftButton")
		end
		self:CallMethod("Focus", j)
	]])
	pad:SetAttribute("_onshow", [[
		self:SetBindingClick(true, "PADDUP", "WCBagsUp")
		self:SetBindingClick(true, "PADDDOWN", "WCBagsDown")
		self:SetBindingClick(true, "PADDLEFT", "WCBagsLeft")
		self:SetBindingClick(true, "PADDRIGHT", "WCBagsRight")
		self:SetBindingClick(true, "PAD2", "WCBagsClose")
		self:SetBindingClick(true, "PAD4", "WCBagsMore")
		self:SetBindingClick(true, "PADLSHOULDER", "WCBagsPrevBag")
		self:SetBindingClick(true, "PADRSHOULDER", "WCBagsNextBag")
		self:RunAttribute("move", 0, 0)
		self:CallMethod("Opened")
	]])
	pad:SetAttribute("_onhide", [[ self:ClearBindings() self:CallMethod("Closed") ]])

	local function navButton(name, dx, dy, jump)
		local b = CreateFrame("Button", name, UIParent, "SecureHandlerClickTemplate")
		b:RegisterForClicks("AnyDown")
		b:SetFrameRef("pad", pad)
		b:SetAttribute("_onclick", ([[ self:GetFrameRef("pad"):RunAttribute("move", %d, %d, %d) ]]):format(dx, dy, jump or 0))
	end
	navButton("WCBagsPrevBag", 0, 0, -1)
	navButton("WCBagsNextBag", 0, 0, 1)
	navButton("WCBagsUp", 0, -1)
	navButton("WCBagsDown", 0, 1)
	navButton("WCBagsLeft", -1, 0)
	navButton("WCBagsRight", 1, 0)

	-- circle: put back what is held, then close (the pad's handler hides, and
	-- takes the window with it)
	local close = CreateFrame("Button", "WCBagsClose", UIParent, "SecureHandlerClickTemplate")
	close:RegisterForClicks("AnyDown")
	close:SetFrameRef("pad", pad)
	close:SetAttribute("_onclick", [[ self:GetFrameRef("pad"):Hide() ]])
	close:HookScript("PreClick", function() if CursorHasItem() then ClearCursor() end end)
	-- holding an item out of combat, circle only puts it back
	local drop = CreateFrame("Button", "WCBagsDrop", UIParent)
	drop:RegisterForClicks("AnyDown")
	local function holdBindings()
		if InCombatLockdown() or not pad:IsShown() then return end
		SetOverrideBindingClick(pad, true, "PAD2", CursorHasItem() and "WCBagsDrop" or "WCBagsClose")
	end
	drop:SetScript("OnClick", function()
		ClearCursor()
		holdBindings()
		f:Paint()
	end)

	-- opening: the Bags macro (/click WCBagsToggle) and the bag keys (WCBagsKey).
	-- Secure, so in combat they show the pad's handler, whose show opens the window.
	for _, name in ipairs({ "WCBagsToggle", "WCBagsKey" }) do
		local t = CreateFrame("Button", name, UIParent, "SecureHandlerClickTemplate")
		if name == "WCBagsToggle" then t:RegisterForClicks("AnyUp", "AnyDown") else t:RegisterForClicks("AnyDown") end
		t:SetFrameRef("pad", pad)
		t:SetAttribute("_onclick", [[
			local pad = self:GetFrameRef("pad")
			if PlayerInCombat() then
				if pad:IsShown() then pad:Hide() else pad:Show() end
			else pad:CallMethod("Toggle") end
		]])
	end
	-- out of combat the window decides, not the pad: a pad left shown with the
	-- window hidden (a reload, a close by plain code) made the first press a
	-- Shut and the bags opened only on the second (the player, 2026-11-10)
	function pad:Toggle()
		if f:IsShown() and f:GetAlpha() > 0 then f:Shut() else f:Open() end
	end
	function pad:Open() f:Open() end
	function pad:Shut() f:Shut() end

	-- the window closed by plain code in a fight (a vendor walking off): the
	-- pad's handler may only hide when the fight ends
	local w = CreateFrame("Frame")
	w:RegisterEvent("PLAYER_REGEN_ENABLED")
	w:SetScript("OnEvent", function()
		if pad:IsShown() and not f:IsShown() then pad:Hide() end
	end)
	return pad, holdBindings
end
