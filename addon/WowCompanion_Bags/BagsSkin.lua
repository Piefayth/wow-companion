-- Bags trial (2026-11-14): Blizzard's bag frame is the one window, in a fight
-- and out; ours is only what it looks like. The game's own focus cycle focuses
-- their frame (natively, in combat too), the cursor walks their real item
-- buttons, and each of those is anchored (Blizzard's own setter,
-- SmartNavigation_SetCustomCursorAnchorPointForFrame) to a proxy frame of ours
-- laid on our slot for the bag and slot it holds (their other stops: below).
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
local function anchorNew()
	if InCombatLockdown() then return end
	eachStop(function(b, item)
		if anchored[b] or skipped[b] then return end
		if item then
			local p = CreateFrame("Frame", nil, f)
			p:SetSize(1, 1)
			anchor(b, p)
		elseif b == blizz.AddSlotsButton then
			anchor(b, addSlots)
		elseif GamepadBagBar and b:GetParent() == GamepadBagBar then
			skip(b, "bag icon")
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
		-- the slot their cursor chose as the bags opened (its EnterButton came
		-- before ours were laid)
		local b = SmartNavigation and SmartNavigation.currentButton
		if b and anchored[b] and b.GetBagID then f:FocusOn(b:GetBagID(), b:GetID()) end
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
	local mirror = CreateFrame("Frame", nil, f)
	mirror:SetScript("OnUpdate", function()
		for key, m in pairs(marks) do
			local theirs = blizz[key]
			local on = theirs and theirs:IsShown() or false
			if m:IsShown() ~= on then m:SetShown(on) end
		end
	end)
end
-- our highlight follows their cursor over their (unseen) buttons
EventRegistry:RegisterCallback("ContainerFrameItemButton.EnterButton", function(_, b)
	if f:IsShown() and b and b.GetBagID then f:FocusOn(b:GetBagID(), b:GetID()) end
end, "WCBagsSkin")
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
