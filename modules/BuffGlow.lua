-- Glows the Buffs button while Mark of the Wild or Thorns is missing (WC module).
local M = WC.Module('BuffGlow')
local WANT = { 'Mark of the Wild', 'Thorns' }
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
local NAMES = { 'GamepadMainActionBarFramePageUnitBottomCenteredAnchorBottomBarActionButton', 'GamepadMainActionBarFramePageUnitBottomCenteredAnchorLeftBarActionButton', 'GamepadMainActionBarFramePageUnitBottomCenteredAnchorRightBarActionButton', 'GamepadMainActionBarFramePageUnitBottomCenteredAnchorTopBarActionButton' }
local function buffsSlot()
  for slot = 181, 272 do
    local kind, id = GetActionInfo(slot)
    if kind == 'macro' and id and GetMacroInfo(id) == 'Buffs' then return slot end
  end
end
local function button()
  local slot = buffsSlot()
  if not slot then return end
  for _, base in ipairs(NAMES) do
    for i = 1, 8 do
      local b = _G[base .. i]
      if b and b:IsVisible() and (b.action == slot or (b.GetAttribute and tonumber(b:GetAttribute('action')) == slot)) then return b end
    end
  end
end
local function missing()
  for _, name in ipairs(WANT) do
    local info = C_Spell.GetSpellInfo(name)
    if info and info.spellID and IsPlayerSpell(info.spellID) and not C_UnitAuras.GetAuraDataBySpellName('player', name, 'HELPFUL') then return true end
  end
end
local function update()
  local show = false
  if not InCombatLockdown() and not UnitIsDeadOrGhost('player') then
    local ok, m = pcall(missing)
    if ok and m then
      local b = button()
      if b then glow:ClearAllPoints() glow:SetAllPoints(b) glow:SetFrameLevel(b:GetFrameLevel() + 5) show = true end
    end
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
  pcall(update)
end
function M:Disable()
  glow:UnregisterAllEvents()
  glow.ag:Stop()
  glow:Hide()
end
