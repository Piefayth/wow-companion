-- TRIAL (2026-11-14): "Put on wheel" in the controller's triangle menus.
-- Every one of them (bags, spellbook, macros, character sheet...) is built by
-- Blizzard's PromptedBinding.lua under the tag MORE_CONTEXT_ACTIONS, and
-- Menu.ModifyMenu is their own way for an addon to add to a tagged menu (run
-- through securecallfunction, Menu.lua). This entry only says what it saw, to
-- measure that Blizzard's own entries, and A and B, stay clean beside it. It
-- only reads their frames.

local function Describe(owner)
    if not owner then return "no owner" end
    if owner.GetBagID and owner.GetID then
        local bag, slot = owner:GetBagID(), owner:GetID()
        local link = bag and slot and C_Container.GetContainerItemLink(bag, slot)
        if link then return ("bag %d slot %d, %s"):format(bag, slot, link) end
    end
    local parent = owner.GetParent and owner:GetParent()
    if parent and parent.slotIndex and parent.spellBank then
        local info = C_SpellBook.GetSpellBookItemInfo(parent.slotIndex, parent.spellBank)
        if info then return ("spellbook: %s (%s)"):format(tostring(info.name), tostring(info.spellID)) end
    end
    return "something else: " .. tostring(owner.GetDebugName and owner:GetDebugName() or owner:GetName())
end

Menu.ModifyMenu("MORE_CONTEXT_ACTIONS", function(owner, root)
    local ok, what = pcall(Describe, owner)
    local seen = ok and what or ("unreadable: " .. tostring(what))
    root:CreateButton("Put on wheel (test)", function() WC.Say("Put on wheel saw " .. seen) end)
end)
