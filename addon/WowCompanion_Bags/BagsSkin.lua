-- Bags trial (2026-11-14): Blizzard's bag frame is the one window, in a fight
-- and out; ours is only what it looks like. The game's own focus cycle focuses
-- their frame (natively, in combat too), the cursor walks their real item
-- buttons, and each of those is anchored (Blizzard's own setter,
-- SmartNavigation_SetCustomCursorAnchorPointForFrame) to a proxy frame of ours
-- laid on our slot for the bag and slot it holds, and each bag icon of theirs
-- (GamepadBagBar: where their cursor starts, what the shoulders jump between,
-- what collapses a bag) on our icon for it (their other stops: below).
-- SmartNavigation measures a
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

-- Every stop the cursor can land on in their frame (Blizzard's own test,
-- SmartNavigation_CanFocusFrame and not ignored) is anchored to something of
-- ours, or skipped: nothing of theirs is reachable unseen. What is there
-- varies (the locked backpack slots and their add-slots button only on an
-- account without an authenticator, the keyring with its setting, currency
-- buttons when watched), so the stops are walked on every open.
local anchored = {} -- their stop -> the frame of ours it is anchored to
local skipped = {} -- their stops the cursor skips: ours has its own way
-- the pointer sits where SmartNavigation puts it on any button, at its left
-- (UpdateCursorPosition: RIGHT on LEFT, cursorOffsetX); every stop is measured
-- from that same point, so the d-pad's steps are unchanged
local function anchor(b, p)
	if pcall(SmartNavigation_SetCustomCursorAnchorPointForFrame, b, CreateAnchor("RIGHT", p, "LEFT", SmartNavigation and SmartNavigation.cursorOffsetX or 10, 0)) then
		anchored[b] = p
	end
end
local function skip(b, why)
	if skipped[b] then return end
	skipped[b] = why
	WC.MarkIgnored(b)
end
-- their add-slots button, drawn in the cell our layout keeps for it (f.addCell)
-- (the whole cell, so the stop lines up with the slots' column)
local addSlots = CreateFrame("Frame", nil, f)
addSlots:Hide()
local addIcon = addSlots:CreateTexture(nil, "OVERLAY")
addIcon:SetAtlas("Bags-icon-AddAuthenticator")
addIcon:SetSize(28, 28)
addIcon:SetPoint("CENTER")
local pooled = {}
local function eachStop(fn)
	wipe(pooled)
	if blizz.itemButtonPool then
		for b in blizz.itemButtonPool:EnumerateActive() do pooled[b] = true fn(b, true) end
	end
	local function walk(frame)
		for _, c in ipairs({ frame:GetChildren() }) do
			if not pooled[c] and not skipped[c] and not SmartNavigation_IsFrameIgnored(c) then
				if SmartNavigation_CanFocusFrame(c) then fn(c, false) end
				walk(c)
			end
		end
	end
	walk(blizz)
end
-- a bag icon their bags lay out (GamepadBagBar:GetBagButton over the bags shown)
local function shownBag(b)
	if not (GamepadBagBar and b:GetParent() == GamepadBagBar) then return false end
	for bag = STARTING_BAG_INDEX, ENDING_BAG_INDEX do
		if GamepadBagBar:GetBagButton(bag) == b then return true end
	end
	return false
end
local function anchorNew()
	if InCombatLockdown() then return end
	eachStop(function(b, item)
		if anchored[b] or skipped[b] then return end
		if item or shownBag(b) then
			local p = CreateFrame("Frame", nil, f)
			p:SetSize(1, 1)
			anchor(b, p)
		elseif GamepadBagBar and b:GetParent() == GamepadBagBar then
			-- the keyring's icon, while the keyring is not shown (GetBagButton
			-- leaves it out): not in their layout either
			skip(b, "a bag icon theirs does not lay out")
		elseif b == blizz.AddSlotsButton then
			anchor(b, addSlots)
		elseif b == blizz.CloseButton then
			skip(b, "close (circle closes)")
		elseif b == blizz.PortraitButton then
			skip(b, "bag settings (our triangle menu has sort)")
		else
			skip(b, "unknown")
			WC.Say(("bags: skipped a control of Blizzard's ours has no place for (%s)"):format(b:GetDebugName()))
		end
	end)
end
-- every shown stop on its place in ours; false when one has none
local function lay()
	local all = true
	eachStop(function(b, item)
		if not b:IsShown() or skipped[b] then return end
		local p, ours = anchored[b], nil
		if item then
			ours = f:SlotFor(b:GetBagID(), b:GetID())
		elseif b:GetParent() == GamepadBagBar then
			ours = f:BagIconFor(b)
		elseif p == addSlots then
			ours = f.addCell and f.addCell:IsShown() and f.addCell
		end
		if not (p and ours) then all = false return end
		p:ClearAllPoints()
		p:SetAllPoints(ours)
	end)
	local a = blizz.AddSlotsButton
	addSlots:SetShown(a and a:IsShown() and anchored[a] and f.addCell and f.addCell:IsShown() and true or false)
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
-- anchored at once, so a button new this session carries its anchor when their
-- cursor first lands on it; placed a frame later, once theirs are laid out
EventRegistry:RegisterCallback("ContainerFrame.OpenBag", function()
	if blizz:IsShown() then anchorNew() lay() end
	C_Timer.After(0, opened)
end, "WCBagsSkin")
EventRegistry:RegisterCallback("ContainerFrame.CloseBag", function() C_Timer.After(0, closed) end, "WCBagsSkin")
-- one tooltip, theirs (with what addons add to it), moved onto our slot each
-- time they place it
f.theirTooltip = true
hooksecurefunc("ContainerFrameItemButton_CalculateItemTooltipAnchors", function(b, tooltip)
	if not (f:IsShown() and anchored[b] and b.GetBagID) then return end
	local ours = f:SlotFor(b:GetBagID(), b:GetID())
	if not ours then return end
	tooltip:ClearAllPoints()
	tooltip:SetPoint("TOPRIGHT", ours, "TOPLEFT", -6, 0)
end)
-- the controller's focus marks Blizzard gives a window (the glow while it has
-- the focus, the trigger and focus-button hints at its foot while it is one
-- step away; FrameControlsManager:RefreshJumpHints) land on their frame, so
-- ours carries the same, from Blizzard's own templates, shown as theirs are
local marks = {}
do
	local glow = CreateFrame("Frame", nil, f, "FrameGlowTemplate")
	glow.layoutType = "Dialog" -- our rim is the dialog border: Blizzard's glow for it
	glow:OnLoad() -- again, under that layout
	glow:SetFrameLevel(f:GetFrameLevel() + 50) -- over the slots, as Blizzard lays it (505)
	marks.FrameGlow = glow
	for key, template in pairs({ LeftJumpHint = "FrameLeftJumpHintTemplate",
		RightJumpHint = "FrameRightJumpHintTemplate", FocusJumpHint = "FrameFocusJumpHintTemplate" }) do
		marks[key] = CreateFrame("Frame", nil, f, template)
	end
	for _, m in pairs(marks) do m:Hide() end
	-- and our highlight sits on whatever of ours their cursor is on (read each
	-- frame: it lands on a bag icon as the bags open, which no event reports)
	local mirror, cur = CreateFrame("Frame", nil, f), nil
	mirror:SetScript("OnHide", function() cur = nil end)
	mirror:SetScript("OnUpdate", function()
		local b = SmartNavigation and SmartNavigation.currentButton
		if b ~= cur then
			cur = b
			local p = b and anchored[b]
			if p == addSlots then f:Mark(p)
			elseif p and b:GetParent() == GamepadBagBar then f:Mark(f:BagIconFor(b))
			elseif p then f:FocusOn(b:GetBagID(), b:GetID()) end
		end
		for key, m in pairs(marks) do
			local theirs = blizz[key]
			local on = theirs and theirs:IsShown() or false
			if m:IsShown() ~= on then m:SetShown(on) end
		end
	end)
end
-- a bag collapsed or opened on their bag icon (Gamepad_ToggleCollapseBag)
-- deals their buttons out again: ours follows
hooksecurefunc("ContainerFrame_GenerateFrame", function(frame)
	if frame == blizz then C_Timer.After(0, function() if blizz:IsShown() then f:Layout() anchorNew() lay() end end) end
end)
-- triangle's menu (their MoreActions, tagged MORE_CONTEXT_ACTIONS) opens beside
-- its owner, their unseen button (MenuManagerMixin:OpenContextMenu): moved
-- beside our cell for it, by the same rule, through the menu API addons are
-- given (Menu.ModifyMenu, AddMenuAcquiredCallback). Their placing runs right
-- after the acquired callback, so ours waits for the next frame.
if Menu and Menu.ModifyMenu and FrameUtil and FrameUtil.GetScreenQuadrant then
	Menu.ModifyMenu("MORE_CONTEXT_ACTIONS", function(owner, root)
		local ours = owner and anchored[owner]
		if not (ours and f:IsShown()) then return end
		root:AddMenuAcquiredCallback(function(menu)
			C_Timer.After(0, function()
				-- (moved shown or not: the first menu made is hidden as it fades
				-- in; a menu closed by then is placed afresh when next opened)
				local q = FrameUtil.GetScreenQuadrant(ours)
				local Q = FrameUtilQuadrantEnum
				menu:ClearAllPoints()
				if q == Q.BottomRight then menu:SetPoint("BOTTOMRIGHT", ours, "BOTTOMLEFT")
				elseif q == Q.BottomLeft then menu:SetPoint("BOTTOMLEFT", ours, "BOTTOMRIGHT")
				elseif q == Q.TopRight then menu:SetPoint("TOPRIGHT", ours, "TOPLEFT")
				else menu:SetPoint("TOPLEFT", ours, "TOPRIGHT") end
			end)
		end)
	end)
end
-- our layout changed (a sort, a section moving): the proxies follow
hooksecurefunc(f, "Layout", function() if blizz:IsShown() then lay() end end)
hide:Play()
WC.Say("bags: trial on, Blizzard's frame wears ours")
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, name)
	if name ~= "WowCompanion_Bags" then return end
	self:UnregisterAllEvents()
	if WowCompanionBagsDB.skin then start() end
end)
