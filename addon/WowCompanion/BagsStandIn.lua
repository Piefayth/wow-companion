-- Bags split (2026-11-10): standing in for Blizzard's bags, and the vendor
-- legend. Loads after Bags.lua; shares nothing local with it (WCBags is global).

-- Our bags stand in for Blizzard's (the player, 2026-11-10): whatever opens
-- Blizzard's combined bags (a vendor, mail, the controller's bag radial or
-- shortcut) opens ours, and theirs stays open but unseen and out of the focus
-- cycle. Nothing of Blizzard's is closed or written from here:
--  * hiding: an alpha animation of ours aimed at their frame (ImprovedForever's
--    Focus.Fade): no property of theirs is set from Lua
--  * the focus cycle: GamepadMode.FrameControlsManager:FrameHidden(frame), the one
--    manager call Blizzard wraps for insecure callers (SecureHelper:WrapFunction)
--  * the trigger: EventRegistry callbacks (run through secureexecuterange) and
--    hooksecurefunc post-hooks, which leave the caller's secure state as it was
-- WowCompanionDB.standInBags = false turns it off.
do
	local fader = CreateFrame("Frame")
	local function fadeGroup(alpha)
		local g = fader:CreateAnimationGroup()
		local a = g:CreateAnimation("Alpha")
		a:SetFromAlpha(alpha == 0 and 1 or 0)
		a:SetToAlpha(alpha)
		a:SetDuration(0.01)
		g:SetToFinalAlpha(true)
		return g, a
	end
	local hideGroup, hideAnim = fadeGroup(0)
	local showGroup, showAnim = fadeGroup(1)
	local function theirs() return ContainerFrameCombinedBags end
	local function on() return WowCompanionDB.standInBags ~= false and WCBags and WCBags.ready end

	local function standIn()
		local blizz = theirs()
		if not on() or not blizz or not blizz:IsShown() then return end
		hideAnim:SetTarget(blizz)
		hideGroup:Play()
		if GamepadMode and GamepadMode.FrameControlsManager and InputUtil and InputUtil.IsGamepadUIEnabled() then
			pcall(GamepadMode.FrameControlsManager.FrameHidden, GamepadMode.FrameControlsManager, blizz)
		end
		if not WCBags:IsShown() then WCBags:Open() end
	end
	local function restore()
		local blizz = theirs()
		if blizz then showAnim:SetTarget(blizz) showGroup:Play() end
	end
	-- no flicker (the player, 2026-11-10): their frame stays at alpha 0 between
	-- opens while the stand-in is on, so it is already invisible when it shows.
	-- Their ContainerFrame code never sets alpha, so ours holds.
	if WowCompanionDB == nil or WowCompanionDB.standInBags ~= false then
		local blizz = theirs()
		if blizz then hideAnim:SetTarget(blizz) hideGroup:Play() end
	end

	if EventRegistry and EventRegistry.RegisterCallback then
		EventRegistry:RegisterCallback("ContainerFrame.OpenBag", function()
			C_Timer.After(0, standIn)
		end, "WowCompanionStandIn")
		EventRegistry:RegisterCallback("ContainerFrame.CloseBag", function()
			C_Timer.After(0, function()
				local blizz = theirs()
				if blizz and not blizz:IsShown() then
					if not on() then restore() end
					-- the vendor or mail closing their bags closes ours too
					if on() and WCBags:IsShown() and WCBags.followBlizzard then WCBags:Shut() end
				end
			end)
		end, "WowCompanionStandIn")
	end
	-- the radial and shortcut-bar bag button: a press there toggles ours, also
	-- when their bags were already open (and so just closed)
	local function toggled()
		if not on() then return end
		C_Timer.After(0, function()
			local blizz = theirs()
			if blizz and blizz:IsShown() then standIn()
			elseif WCBags:IsShown() then WCBags:Shut()
			else WCBags:Open() end
		end)
	end
	if ToggleBackpack_Combined then hooksecurefunc("ToggleBackpack_Combined", toggled) end
	if ToggleAllBags then hooksecurefunc("ToggleAllBags", toggled) end
	if WCBags then WCBags.followBlizzard = true end
end

-- square sells while a vendor is open, so the legend says so (the player, 2026-11-10)
do
	local w = CreateFrame("Frame")
	w:RegisterEvent("MERCHANT_SHOW")
	w:RegisterEvent("MERCHANT_CLOSED")
	w:SetScript("OnEvent", function(_, event)
		local pr = WCBags and WCBags.usePrompt
		if not (pr and pr.SetPromptText) then return end
		pcall(pr.SetPromptText, pr, event == "MERCHANT_SHOW" and (SELL or "Sell") or (USE or "Use"))
		if pr.RefreshInputPromptSize then pcall(pr.RefreshInputPromptSize, pr) end
	end)
end
