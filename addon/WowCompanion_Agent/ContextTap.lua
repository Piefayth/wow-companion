-- TRIAL (2026-11-14): minus tap as the one contextual companion button. With the
-- controller's cursor on something in a game window (SmartNavigation's current
-- button, only read), a tap is for that thing instead of opening the Companion
-- window. For now it only says what it saw, to learn what each window's
-- buttons tell us and that reading them keeps A and B clean; our own menu
-- (Put on wheel) comes after.

local function Seen(button)
    local context = tostring(button.buttonContext)
    if button.GetBagID and button.GetID then
        local bag, slot = button:GetBagID(), button:GetID()
        local link = bag and slot and C_Container.GetContainerItemLink(bag, slot)
        if link then return ("%s: bag %d slot %d, %s"):format(context, bag, slot, link) end
    end
    local parent = button.GetParent and button:GetParent()
    if parent and parent.slotIndex and parent.spellBank then
        local info = C_SpellBook.GetSpellBookItemInfo(parent.slotIndex, parent.spellBank)
        if info then return ("%s: %s (%s)"):format(context, tostring(info.name), tostring(info.spellID)) end
    end
    local id = button.GetID and button:GetID()
    local gear = id and id >= 1 and id <= 19 and GetInventoryItemLink("player", id)
    if gear then return ("%s: worn slot %d, %s"):format(context, id, gear) end
    return ("%s: %s id=%s parent=%s bag=%s"):format(context, tostring(button:GetDebugName()), tostring(id),
        tostring(parent and parent:GetDebugName()), tostring(button.GetBagID and button:GetBagID()))
end

-- every sighting, newest last, for the agent to read live (the strip)
WCContextSeen = {}

-- true when the tap was for the thing under the cursor
function WC.Companion.ContextTap()
    if InCombatLockdown() then return false end
    local button = SmartNavigation and SmartNavigation:GetCurrentButton()
    if not (button and button:IsVisible()) then
        WCContextSeen[#WCContextSeen + 1] = "no button: " .. tostring(button and button:GetDebugName())
        return false
    end
    local ok, seen = pcall(Seen, button)
    seen = ok and seen or ("unreadable: " .. tostring(seen))
    WCContextSeen[#WCContextSeen + 1] = seen
    WC.Say("The companion button saw " .. seen)
    return true
end
