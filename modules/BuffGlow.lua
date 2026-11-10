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
glow:UnregisterAllEvents()
glow:RegisterEvent('PLAYER_ENTERING_WORLD')
glow:RegisterEvent('PLAYER_REGEN_DISABLED')
glow:RegisterEvent('PLAYER_REGEN_ENABLED')
glow:RegisterEvent('PLAYER_ALIVE')
glow:RegisterEvent('PLAYER_UNGHOST')
glow:RegisterEvent('ACTIONBAR_SLOT_CHANGED')
glow:RegisterUnitEvent('UNIT_AURA', 'player')
glow:SetScript('OnEvent', function() pcall(update) end)
pcall(update)
print('buff glow: watching Mark of the Wild and Thorns', button() and 'on your Buffs button' or '(Buffs button not found)')
