-- Glows the bar button for a watched buff while one is missing (WC module).
-- What is watched is the character's own list (BuffWatch.lua), empty until the
-- player asks; the button is found from what is on the bars: one that casts a
-- watched spell, or opens a wheel holding one. Nothing to watch, nothing glows.
local M = WC.Module('BuffGlow')
local glow = WCBuffGlow or CreateFrame('Frame', 'WCBuffGlow', UIParent)
glow:SetFrameStrata('HIGH')
glow:Hide()
if not glow.tex then
  local t = glow:CreateTexture(nil, 'OVERLAY')
  t:SetTexture('Interface\\Buttons\\CheckButtonHilight')
  t:SetBlendMode('ADD')
  t:SetVertexColor(0.4, 1, 0.4)
  t:SetPoint('TOPLEFT', -6, 6)
  t:SetPoint('BOTTOMRIGHT', 6, -6)
  glow.tex = t
  local ag = glow:CreateAnimationGroup()
  ag:SetLooping('BOUNCE')
  local a = ag:CreateAnimation('Alpha')
  a:SetFromAlpha(1) a:SetToAlpha(0.25) a:SetDuration(0.8)
  glow.ag = ag
end
local function update()
  local show = false
  local watch = WC.BuffWatch
  if watch and not InCombatLockdown() and not UnitIsDeadOrGhost('player') and #watch.Missing() > 0 then
    local b = watch.Button()
    if b then glow:ClearAllPoints() glow:SetAllPoints(b) glow:SetFrameLevel(b:GetFrameLevel() + 5) show = true end
  end
  if show then if not glow:IsShown() then glow:Show() glow.ag:Play() end else glow.ag:Stop() glow:Hide() end
end
function M:Enable()
  glow:UnregisterAllEvents()
  for _, e in ipairs({ 'PLAYER_ENTERING_WORLD', 'PLAYER_REGEN_DISABLED', 'PLAYER_REGEN_ENABLED', 'PLAYER_ALIVE', 'PLAYER_UNGHOST', 'ACTIONBAR_SLOT_CHANGED' }) do
    glow:RegisterEvent(e)
  end
  glow:RegisterUnitEvent('UNIT_AURA', 'player')
  glow:SetScript('OnEvent', function() pcall(update) end)
  self:On('BUFF_WATCH_CHANGED', function() pcall(update) end)
  pcall(update)
end
function M:Disable()
  glow:UnregisterAllEvents()
  glow.ag:Stop()
  glow:Hide()
end
