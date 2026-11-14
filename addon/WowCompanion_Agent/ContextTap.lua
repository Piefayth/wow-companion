-- Minus tap is the companion's one contextual button: with the controller's
-- cursor on a spell, a bag item, a worn item or a macro in a game window
-- (SmartNavigation's current button, only read: measured clean, 2026-11-14),
-- a tap places that thing on a wheel (WCWheel.Place: open a wheel and flick).
-- Anything else, and a tap while placing stops it; otherwise the tap opens
-- the Companion window (Agent.lua).

-- the slot for a wheel and its name, or nil and why (nil, nil: not a thing)
local function Thing(button)
    local context = button.buttonContext
    if context == "ButtonContext_SpellButton" then
        local item = button:GetParent()
        local info = item and item.slotIndex and C_SpellBook.GetSpellBookItemInfo(item.slotIndex, item.spellBank)
        if not (info and info.spellID) then return nil, nil end
        if info.isPassive then return nil, info.name .. " is passive" end
        return { spell = info.spellID }, info.name
    elseif context == "ButtonContext_MacroButton" then
        local index = MacroFrame:GetMacroDataIndex(button:GetElementData())
        local name = index and GetMacroInfo(index)
        if not name then return nil, nil end
        return { macro = name }, name
    end
    local id
    if context == "ButtonContext_ContainerFrameItemButton" then
        local info = C_Container.GetContainerItemInfo(button:GetBagID(), button:GetID())
        id = info and info.itemID
    elseif context == "ButtonContext_PaperDollItemSlotButton" then
        id = GetInventoryItemID("player", button:GetID())
    else
        return nil, nil
    end
    if not id then return nil, nil end
    local name = C_Item.GetItemNameByID(id) or ("item " .. id)
    if not C_Item.GetItemSpell(id) then return nil, name .. " has no use" end
    return { item = id }, name
end

-- true when the tap was the companion button's (a thing placed, or placing stopped)
function WC.Companion.ContextTap()
    if InCombatLockdown() or not WCWheel then return false end
    local button = SmartNavigation and SmartNavigation:GetCurrentButton()
    if button and button:IsVisible() then
        local ok, slot, name = pcall(Thing, button)
        if ok and slot then
            WCWheel.Place(slot, name)
            return true
        elseif ok and name then
            WC.Say("Wheel: " .. name .. ", so it cannot go on a wheel")
            return true
        end
    end
    if WCWheel.Placing() then
        WCWheel.CancelPlacing()
        return true
    end
    return false
end
