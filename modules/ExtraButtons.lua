if InCombatLockdown() then return end
local owner = WCExtraButtonsOwner or CreateFrame('Frame', 'WCExtraButtonsOwner')
ClearOverrideBindings(owner)
-- PADBACK is left alone: the controller UI uses it as Focus UI
-- autorun off the stick: an L3 click nudges the stick and cancels it
SetOverrideBinding(owner, false, 'PAD5', 'TOGGLEAUTORUN')
print('extra buttons: PAD5 toggles autorun')
