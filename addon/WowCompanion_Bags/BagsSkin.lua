-- Bags trial (2026-11-14): Blizzard's bag frame is the one window, in a fight
-- and out; ours is only what it looks like. The game's own focus cycle focuses
-- their frame (natively, in combat too), the cursor walks their real item
-- buttons, and each of those is anchored (Blizzard's own setter,
-- SmartNavigation_SetCustomCursorAnchorPointForFrame) to a proxy frame of ours
-- laid on our slot for the bag and slot it holds: SmartNavigation measures a
-- button where its anchor is (GetButtonPositionInfo), so the d-pad walks our
-- layout and cross and square are their buttons. Their frame is kept at alpha 0
-- (an animation of ours; no property of theirs is set). Ours opens and closes
-- with theirs, so the two can never disagree.
--
-- Their buttons are pooled and dealt out afresh on every open
-- (ContainerFrameMixin:UpdateItemSlots), so a proxy belongs to a button, and is
-- moved, on every open, onto the slot that button holds now. Proxies are ours,
-- so they move in a fight; anchoring a new button is wrapped by SecureHelper,
-- so only out of one: a button first made in a fight (the first open since a
-- reload) has none, and that fight shows their bags as they are.
--
-- On while WowCompanionBagsDB.skin is true (a reload applies it), read at our
-- load, when the saved table is there.

local function start()
local blizz = ContainerFrameCombinedBags
local f = WCBags
if not (blizz and f and SmartNavigation_SetCustomCursorAnchorPointForFrame and CreateAnchor) then return end

local fader = CreateFrame("Frame")
local function alphaGroup(to)
	local g = fader:CreateAnimationGroup()
	local a = g:CreateAnimation("Alpha")
	a:SetFromAlpha(1 - to)
	a:SetToAlpha(to)
	a:SetDuration(0.01)
	a:SetTarget(blizz)
	g:SetToFinalAlpha(true)
	return g
end
local hide, show = alphaGroup(0), alphaGroup(1)

local proxies = {} -- their button -> our proxy frame
local function eachButton(fn)
	local pool = blizz.itemButtonPool
	if not pool then return end
	for b in pool:EnumerateActive() do fn(b) end
end
local function anchorNew()
	if InCombatLockdown() then return end
	eachButton(function(b)
		if proxies[b] then return end
		local p = CreateFrame("Frame", nil, f)
		p:SetSize(1, 1)
		p:SetPoint("CENTER")
		if pcall(SmartNavigation_SetCustomCursorAnchorPointForFrame, b, CreateAnchor("CENTER", p, "CENTER")) then
			proxies[b] = p
		end
	end)
	-- the bag icons Blizzard lays among the slots: the cursor skips them
	if GamepadBagBar and GamepadBagBar.GetBagButton then
		for bag = 0, 4 do
			local ok, btn = pcall(GamepadBagBar.GetBagButton, GamepadBagBar, bag)
			if ok and btn then WC.MarkIgnored(btn) end
		end
	end
end
-- every shown button's proxy on our slot; false when one has none
local function lay()
	local all = true
	eachButton(function(b)
		if not b:IsShown() then return end
		local p = proxies[b]
		local ours = f:SlotFor(b:GetBagID(), b:GetID())
		if p and ours then
			p:ClearAllPoints()
			p:SetAllPoints(ours)
		else
			all = false
		end
	end)
	return all
end

local function opened()
	if not blizz:IsShown() then return end
	anchorNew()
	if lay() then
		hide:Play()
		if not f:IsShown() then f:Show() end
	else
		show:Play()
		if f:IsShown() then f:Hide() end
	end
end
local function closed()
	if blizz:IsShown() then return end
	if f:IsShown() then f:Hide() end
end
EventRegistry:RegisterCallback("ContainerFrame.OpenBag", function() C_Timer.After(0, opened) end, "WCBagsSkin")
EventRegistry:RegisterCallback("ContainerFrame.CloseBag", function() C_Timer.After(0, closed) end, "WCBagsSkin")
-- our highlight follows their cursor over their (unseen) buttons
EventRegistry:RegisterCallback("ContainerFrameItemButton.EnterButton", function(_, b)
	if f:IsShown() and b and b.GetBagID then f:FocusOn(b:GetBagID(), b:GetID()) end
end, "WCBagsSkin")
-- our layout changed (a sort, a section moving): the proxies follow
hooksecurefunc(f, "Layout", function() if blizz:IsShown() then lay() end end)
hide:Play()
print("bags: trial on, Blizzard's frame wears ours")
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, name)
	if name ~= "WowCompanion_Bags" then return end
	self:UnregisterAllEvents()
	if WowCompanionBagsDB.skin then start() end
end)
