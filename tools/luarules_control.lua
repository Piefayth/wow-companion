-- every line below breaks one rule tools/luarules.py knows; each must be reported
local f = CreateFrame("Frame", "WCControl", UIParent)
ChatFrame_OpenChat("")                                   -- open-blizzard
ChatFrame1EditBox.chatType = "PARTY"                     -- blizzard-write
ContainerFrameCombinedBags:SetPoint("CENTER")            -- blizzard-call
f.useCustomNavigation = true                             -- custom-nav
function f:FocusGamepad() end                            -- custom-nav
EventRegistry:TriggerEvent("UIParentPanelManager.ShowUIPanel", f) -- panel-event
local b = CreateFrame("Button", "WCControlButton", UIParent, "SecureActionButtonTemplate")
b:RegisterForClicks("AnyUp")                             -- click-edge
local function onShow()
	if InCombatLockdown() then return end
	SmartNavigation_MarkFrameFocusable(f)                -- engine-only (a guard here does not make it fine)
end
local function fine()
	WC.MarkFocusable(f)                                  -- Engine's helper: not reported
	WCControl:SetPoint("CENTER")                         -- our own frame: not reported
	WowCompanionDB.control = true                        -- our saved table: not reported
	GameTooltip:Show()                                   -- shared tooltip: not reported
	SlashCmdList.WCCONTROL = function() end              -- sanctioned: not reported
end
CloseAllBags() -- rules: ok (the control's accepted line: not reported)
