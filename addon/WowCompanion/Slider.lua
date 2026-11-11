-- A slider the controller reaches as one stop, the way Blizzard's settings
-- sliders work. A MinimalSliderWithSteppers is three stops (Back, the bar,
-- Forward), so the slider and its steppers are left out of the focus cycle and
-- one button lies over them. While the cursor is on that button, d-pad left and
-- right step the value, one step a press; up and down move on as usual.
--
-- Nothing of ours runs from the navigation: the stop has no scripts the cursor
-- calls. A frame of our own polls which stop the cursor is on (its highlight
-- is locked while it is the cursor's button) and binds left and right to the
-- steppers with override bindings of its own, set and cleared out of combat
-- only (cleared as a fight starts).
--
--   WC.SliderStop(slider)        slider: a MinimalSliderWithSteppersTemplate frame
--   WC.SliderPrompt(window)      the legend's words while a slider in window has
--                                the cursor, else nil

local stops = {}
local current -- the stop the left and right keys step now, or nil
local keys = CreateFrame("Frame", "WCSliderKeys", UIParent)

local less = CreateFrame("Button", "WCSliderLess", UIParent)
less:SetScript("OnClick", function() if current then current.slider.Back:Click() end end)
local more = CreateFrame("Button", "WCSliderMore", UIParent)
more:SetScript("OnClick", function() if current then current.slider.Forward:Click() end end)

local function focused()
	for _, stop in ipairs(stops) do
		if stop:IsVisible() and stop:IsHighlightLocked() then return stop end
	end
end

local function bind(stop)
	if stop == current then return end
	current = stop
	ClearOverrideBindings(keys)
	if stop then
		SetOverrideBindingClick(keys, true, "PADDLEFT", "WCSliderLess")
		SetOverrideBindingClick(keys, true, "PADDRIGHT", "WCSliderMore")
	end
end

local since = 0
keys:SetScript("OnUpdate", function(_, elapsed)
	since = since + elapsed
	if since < 0.05 or InCombatLockdown() then return end
	since = 0
	bind(focused())
end)
-- the bindings go before the lockdown takes them out of reach
keys:RegisterEvent("PLAYER_REGEN_DISABLED")
keys:SetScript("OnEvent", function() bind(nil) end)

function WC.SliderStop(slider)
	local stop = CreateFrame("Button", nil, slider:GetParent())
	stop:SetPoint("TOPLEFT", slider, "TOPLEFT", -4, 2)
	stop:SetPoint("BOTTOMRIGHT", slider, "BOTTOMRIGHT", 4, -2)
	stop:SetFrameLevel(slider:GetFrameLevel() + 5)
	stop:SetHighlightAtlas("Options_List_Hover", "ADD")
	stop.slider = slider
	stops[#stops + 1] = stop
	WC.MarkIgnored(slider)
	WC.MarkFocusable(stop)
	return stop
end

function WC.SliderPrompt(window)
	local stop = current
	if not (stop and window) then return end
	local parent = stop:GetParent()
	while parent and parent ~= window do parent = parent:GetParent() end
	if parent then return WowCompanion_Glyph("PADDLEFT") .. WowCompanion_Glyph("PADDRIGHT") .. " Adjust" end
end
