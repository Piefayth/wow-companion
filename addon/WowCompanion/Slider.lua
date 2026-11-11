-- A slider the controller reaches as one stop. Blizzard's
-- MinimalSliderWithSteppers is three stops (Back, the bar, Forward), and
-- SmartNavigation has no slider handling of its own. So the slider and its
-- steppers are left out of the focus cycle and one button lies over them:
-- confirm enters it (drawn as being edited); while in it the d-pad's left and
-- right step the value, one step a press, up and down do nothing; confirm or
-- cancel leaves it, and the cursor moves on as before.
--
-- While editing, the d-pad and confirm/cancel are override bindings of our own
-- owner frame, set and cleared out of combat only; entering is refused in a
-- fight, and a fight's start, the slider hidden, or leaving ends the editing.
--
--   WC.SliderStop(slider)   slider: a MinimalSliderWithSteppersTemplate frame

local editing -- the stop being edited, or nil
local keys = CreateFrame("Frame", "WCSliderKeys", UIParent)

local function button(name, fn)
	local b = CreateFrame("Button", name, UIParent)
	b:SetScript("OnClick", fn)
	return b
end

local function leave()
	local stop = editing
	if not stop then return end
	editing = nil
	if not InCombatLockdown() then ClearOverrideBindings(keys) end
	stop.active:Hide()
end

button("WCSliderLess", function() if editing then editing.slider.Back:Click() end end)
button("WCSliderMore", function() if editing then editing.slider.Forward:Click() end end)
button("WCSliderStill", function() end)
button("WCSliderDone", leave)

local function enter(stop)
	if editing == stop or InCombatLockdown() then return end
	leave()
	editing = stop
	stop.active:Show()
	SetOverrideBindingClick(keys, true, "PADDLEFT", "WCSliderLess")
	SetOverrideBindingClick(keys, true, "PADDRIGHT", "WCSliderMore")
	SetOverrideBindingClick(keys, true, "PADDUP", "WCSliderStill")
	SetOverrideBindingClick(keys, true, "PADDDOWN", "WCSliderStill")
	SetOverrideBindingClick(keys, true, "PAD1", "WCSliderDone")
	SetOverrideBindingClick(keys, true, "PAD2", "WCSliderDone")
end

-- the bindings go before the lockdown takes them out of reach
keys:RegisterEvent("PLAYER_REGEN_DISABLED")
keys:SetScript("OnEvent", leave)

function WC.SliderStop(slider)
	local stop = CreateFrame("Button", nil, slider:GetParent())
	stop:SetPoint("TOPLEFT", slider, "TOPLEFT", -4, 2)
	stop:SetPoint("BOTTOMRIGHT", slider, "BOTTOMRIGHT", 4, -2)
	stop:SetFrameLevel(slider:GetFrameLevel() + 5)
	stop:SetHighlightAtlas("Options_List_Hover", "ADD")
	stop.active = stop:CreateTexture(nil, "BACKGROUND")
	stop.active:SetAtlas("Options_List_Active")
	stop.active:SetAllPoints()
	stop.active:Hide()
	stop.slider = slider
	stop:SetScript("OnClick", function(self)
		if editing == self then leave() else enter(self) end
	end)
	stop:SetScript("OnHide", function(self) if editing == self then leave() end end)
	WC.MarkIgnored(slider)
	WC.MarkFocusable(stop)
	return stop
end
