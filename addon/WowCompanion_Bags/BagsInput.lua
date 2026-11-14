-- Bags: the pad while our bags are open. Loads before
-- Bags.lua, which calls WC.BagsInput.Build(f) and WC.BagsInput.Publish(f).
--
-- WCBagsPad is an invisible secure handler that owns the bindings, apart from
-- the window, so the window itself stays unprotected (and may open in combat).
-- Its snippets run in the restricted environment, so they may bind keys in
-- combat: the d-pad moves, square right-clicks the focused slot (Blizzard's use),
-- cross left-clicks it (Blizzard's pick up / put down), triangle opens the menu
-- (out of combat), circle closes, the shoulders jump bags. A slot is clicked by
-- its button's name, so the click is the slot's own, Blizzard's trusted code.
--
-- Shown is open; held is having the pad ("grab" and "release"). Out of a fight
-- the window is a UI panel and held follows the controller's focus on it, so
-- the triggers, the focus button and the other windows work as for any of the
-- game's own. In a fight the window is out of the focus cycle (WC.ShowPanel),
-- so the pad holds by itself: the focus button, bound while the bags are open,
-- releases and grabs, and opening the bags grabs. Opened by our secure toggle
-- (the Bags macro, the bag keys), Blizzard's bag frame (BagsStandIn.lua) and
-- the window's Open; the pad's show and hide carry the window along.

WC.BagsInput = WC.BagsInput or {}

local pad

-- the slot names and the grid, for the snippets; only out of combat (attributes
-- of a protected frame), else owed until the fight ends
function WC.BagsInput.Publish(f)
	if not pad then return end
	if InCombatLockdown() then f.layoutOwed = true return end
	f.layoutOwed = nil
	local n = #f.order
	-- each slot's neighbours from where it is drawn (sections break rows), and
	-- the groups the shoulders jump between
	local rows, rowOf = {}, {}
	for i = 1, n do
		local c = f.cells and f.cells[i] or { col = (i - 1) % 8, row = math.floor((i - 1) / 8) }
		local r = rowOf[c.row]
		if not r then r = { y = c.row } rows[#rows + 1] = r rowOf[c.row] = r end
		r[#r + 1] = i
	end
	table.sort(rows, function(a, b) return a.y < b.y end)
	local where = {}
	for ri, r in ipairs(rows) do for ci, i in ipairs(r) do where[i] = { ri, ci } end end
	local function at(ri, ci) local r = rows[ri] return r[math.min(ci, #r)] end
	for i = 1, n do
		local ri, ci = where[i][1], where[i][2]
		pad:SetAttribute("L" .. i, i > 1 and i - 1 or n)
		pad:SetAttribute("R" .. i, i < n and i + 1 or 1)
		pad:SetAttribute("U" .. i, at(ri > 1 and ri - 1 or #rows, ci))
		pad:SetAttribute("D" .. i, at(ri < #rows and ri + 1 or 1, ci))
		pad:SetAttribute("slot" .. i, f.order[i]:GetName())
		pad:SetAttribute("group" .. i, f.meta[f.order[i]].group or 1)
	end
	local groups = f.groups or { 1 }
	for g, start in ipairs(groups) do pad:SetAttribute("gstart" .. g, start) end
	pad:SetAttribute("groups", #groups)
	pad:SetAttribute("count", n)
	if (pad:GetAttribute("focus") or 1) > n then pad:SetAttribute("focus", 1) end
end

function WC.BagsInput.Build(f)
	pad = CreateFrame("Frame", "WCBagsPad", UIParent, "SecureHandlerShowHideTemplate")
	pad:SetSize(1, 1)
	pad:SetPoint("TOPLEFT")
	pad:Hide()
	pad:SetAttribute("cols", 8)
	pad:SetAttribute("held", false)
	local function holds() return pad:GetAttribute("held") and true or false end
	-- insecure halves, called from the snippets with CallMethod
	function pad:Focus(i) f:Focus(i) end
	function pad:Held() f:Held(holds()) end
	-- out of a fight a frame later: ShowUIPanel from a snippet's CallMethod
	-- tainted the focus switch (2026-11-10). Opened again while open, the window
	-- takes the controller back (leaving the cycle and joining it again).
	function pad:Opened()
		if InCombatLockdown() then return WC.ShowPanel(f, holds) end
		C_Timer.After(0, function()
			if not pad:IsShown() then return end
			if WC.PanelShown(f) then
				if InCombatLockdown() or WC.IsFocused(f) then return end
				f:Hide()
			end
			WC.ShowPanel(f, holds)
		end)
	end
	function pad:Closed() WC.HidePanel(f) f:Closed() end

	pad:SetAttribute("move", [[
		local dx, dy, jump = ...
		local n = self:GetAttribute("count") or 0
		if n == 0 then return end
		local i = self:GetAttribute("focus") or 1
		if i > n then i = 1 end
		local j = i
		if jump and jump ~= 0 then
			local g = (self:GetAttribute("group" .. i) or 1) + jump
			local ng = self:GetAttribute("groups") or 1
			if g > ng then g = 1 elseif g < 1 then g = ng end
			j = self:GetAttribute("gstart" .. g) or i
		elseif dx ~= 0 or dy ~= 0 then
			local key = (dx < 0 and "L") or (dx > 0 and "R") or (dy < 0 and "U") or "D"
			j = self:GetAttribute(key .. i) or i
		end
		self:SetAttribute("focus", j)
		local name = self:GetAttribute("slot" .. j)
		if name and self:GetAttribute("held") then
			self:SetBindingClick(true, "PAD3", name, "RightButton")
			self:SetBindingClick(true, "PAD1", name, "LeftButton")
		end
		self:CallMethod("Focus", j)
	]])
	-- in a fight the focus button's keys (read as it began) are the bags': held,
	-- they release; released, they grab
	pad:SetAttribute("focusKeys", [[
		local to = ...
		if not self:GetAttribute("fight") then return end
		for i = 1, self:GetAttribute("focusKeyCount") or 0 do
			self:SetBindingClick(true, self:GetAttribute("focusKey" .. i), to)
		end
	]])
	pad:SetAttribute("grab", [[
		self:ClearBindings()
		self:SetAttribute("held", true)
		self:SetBindingClick(true, "PADDUP", "WCBagsUp")
		self:SetBindingClick(true, "PADDDOWN", "WCBagsDown")
		self:SetBindingClick(true, "PADDLEFT", "WCBagsLeft")
		self:SetBindingClick(true, "PADDRIGHT", "WCBagsRight")
		self:SetBindingClick(true, "PAD2", "WCBagsClose")
		self:SetBindingClick(true, "PAD4", "WCBagsMore")
		self:SetBindingClick(true, "PADLSHOULDER", "WCBagsPrevBag")
		self:SetBindingClick(true, "PADRSHOULDER", "WCBagsNextBag")
		self:RunAttribute("focusKeys", "WCBagsRelease")
		self:RunAttribute("move", 0, 0)
		self:CallMethod("Held")
	]])
	pad:SetAttribute("release", [[
		self:ClearBindings()
		self:SetAttribute("held", false)
		self:RunAttribute("focusKeys", "WCBagsGrab")
		self:CallMethod("Held")
	]])
	pad:SetAttribute("opened", [[
		if self:GetAttribute("fight") then self:RunAttribute("grab") end
		self:CallMethod("Opened")
	]])
	-- what Blizzard's bag frame runs: opens, or takes the pad back when open
	pad:SetAttribute("open", [[
		if self:IsShown() then self:RunAttribute("opened") else self:Show() end
	]])
	pad:SetAttribute("_onshow", [[ self:RunAttribute("opened") ]])
	pad:SetAttribute("_onhide", [[
		self:ClearBindings()
		self:SetAttribute("held", false)
		self:CallMethod("Closed")
	]])

	local function padButton(name, body)
		local b = CreateFrame("Button", name, UIParent, "SecureHandlerClickTemplate")
		b:RegisterForClicks("AnyDown")
		b:SetFrameRef("pad", pad)
		b:SetAttribute("_onclick", body)
		return b
	end
	local function navButton(name, dx, dy, jump)
		padButton(name, ([[ self:GetFrameRef("pad"):RunAttribute("move", %d, %d, %d) ]]):format(dx, dy, jump or 0))
	end
	navButton("WCBagsPrevBag", 0, 0, -1)
	navButton("WCBagsNextBag", 0, 0, 1)
	navButton("WCBagsUp", 0, -1)
	navButton("WCBagsDown", 0, 1)
	navButton("WCBagsLeft", -1, 0)
	navButton("WCBagsRight", 1, 0)
	padButton("WCBagsGrab", [[ self:GetFrameRef("pad"):RunAttribute("grab") ]])
	padButton("WCBagsRelease", [[ self:GetFrameRef("pad"):RunAttribute("release") ]])

	-- circle: put back what is held, then close (the pad's handler hides, and
	-- takes the window with it)
	local close = padButton("WCBagsClose", [[ self:GetFrameRef("pad"):Hide() ]])
	close:HookScript("PreClick", function() if CursorHasItem() then ClearCursor() end end)
	-- holding an item out of combat, circle only puts it back
	local drop = CreateFrame("Button", "WCBagsDrop", UIParent)
	drop:RegisterForClicks("AnyDown")
	local function holdBindings()
		if InCombatLockdown() or not pad:IsShown() or not holds() then return end
		SetOverrideBindingClick(pad, true, "PAD2", CursorHasItem() and "WCBagsDrop" or "WCBagsClose")
	end
	drop:SetScript("OnClick", function()
		ClearCursor()
		holdBindings()
		f:Paint()
	end)

	-- opening: the Bags macro (/click WCBagsToggle) and the bag keys (WCBagsKey).
	-- Secure, so the same in a fight and out of one: they show or hide the pad's
	-- handler, whose show opens the window.
	for _, name in ipairs({ "WCBagsToggle", "WCBagsKey" }) do
		local t = padButton(name, [[
			local pad = self:GetFrameRef("pad")
			if pad:IsShown() then pad:Hide() else pad:Show() end
		]])
		if name == "WCBagsToggle" then t:RegisterForClicks("AnyUp", "AnyDown") end
	end

	-- out of a fight, held follows the controller's focus on the window
	local watch = CreateFrame("Frame", nil, f)
	watch:SetScript("OnUpdate", function()
		if InCombatLockdown() or not pad:IsShown() then return end
		local focused = WC.IsFocused(f)
		if focused ~= holds() then pad:Execute(pad:GetAttribute(focused and "grab" or "release")) end
	end)
	-- a fight: the focus button's keys become the bags' (the last moment the
	-- pad's attributes may change); its end gives them back
	local fight = CreateFrame("Frame")
	fight:RegisterEvent("PLAYER_REGEN_DISABLED")
	fight:RegisterEvent("PLAYER_REGEN_ENABLED")
	fight:SetScript("OnEvent", function(_, event)
		local on = event == "PLAYER_REGEN_DISABLED"
		if on then
			local keys = { GetBindingKey("TOGGLEUIFOCUS") }
			for i, k in ipairs(keys) do pad:SetAttribute("focusKey" .. i, k) end
			pad:SetAttribute("focusKeyCount", #keys)
		end
		pad:SetAttribute("fight", on or nil)
		if pad:IsShown() then pad:Execute(pad:GetAttribute(holds() and "grab" or "release")) end
	end)
	return pad, holdBindings
end
