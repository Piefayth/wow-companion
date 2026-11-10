-- Extra pad buttons (WC module). PADBACK is left alone: the controller UI uses
-- it as Focus UI. Autorun goes off the stick: an L3 click nudges the stick and
-- cancels it, so PAD5 toggles it instead.
local M = WC.Module('ExtraButtons', { combat = 'wait' })
function M:Enable()
  self.owner = self.owner or WCExtraButtonsOwner or CreateFrame('Frame', 'WCExtraButtonsOwner')
  ClearOverrideBindings(self.owner)
  SetOverrideBinding(self.owner, false, 'PAD5', 'TOGGLEAUTORUN')
  print('extra buttons: PAD5 toggles autorun')
end
function M:Disable()
  WC.AfterCombat(function() ClearOverrideBindings(self.owner) end)
end
