-- Radial wheels of the player's own, each opened by a bar slot whose macro is
-- "/click WCWheel_<name> Macro" (WCWheel.Macro(name) gives the line).
-- Right stick points and letting it go uses (the one way); the d-pad keeps its bar actions;
-- the wheel's own button again uses what it used last; Circle closes; the left stick
-- still walks. Every button is secure, so a wheel works in combat; what is on
-- it is rebuilt out of combat only.
--
-- The ring's look, layout, aim and stick capture are Core's (Ring.lua, shared
-- with the chat wheel); what is this addon's own is the secure part: the
-- buttons that open a wheel and use its slots, the bindings it takes while
-- open, the stick-direction keys (the axis CVar dance). Adapted from Improved
-- Forever's Ring.lua by markg, MIT licence, see LICENSE-ImprovedForever.
--
-- Configured by the companion agent, in Lua, out of combat:
--   WCWheel.Set("travel", { label = "Travel", slots = {
--       { spell = "<a spell the character knows>" }, { item = 6948 }, { macro = "Ping" },
--       { emote = "WAVE" }, { macrotext = "/sit", label = "Sit", icon = 134400 } } })
--   WCWheel.Remove("travel")   WCWheel.List()
-- Read by other addons through WCWheel.Each(fn(name, wheel)) only: the saved
-- table is this file's.
-- No wheel ships: a character starts with none, and each is made on request
-- from what that character has.
-- A slot may carry `label` and `icon` to override what is looked up.
-- A slot { rule = "items" } or { rule = "quest" } fills itself from the bags.

WCWheel = WCWheel or {}
WC.Wheel = WCWheel
local W = WCWheel

local MAX_SLOTS = WC.Ring.PAGE
local AXIS_CVAR = "GamePadStickAxisButtons"
local MODIFIERS_LUA = [[newtable("", "SHIFT-", "CTRL-", "ALT-", "CTRL-SHIFT-", "ALT-SHIFT-", "CTRL-ALT-", "CTRL-ALT-SHIFT-")]]

local ringData = {} -- [wheel] = { { label, icon, itemID, count, dx, dy }, ... }
local pending = false

local function Print(...) print("|cff66ccffWheel|r:", ...) end

local function SetCVarSafe(name, value)
    local ok, result = pcall(C_CVar.SetCVar, name, value)
    return ok and result ~= false
end

local function GetCVarSafe(name)
    local ok, value = pcall(C_CVar.GetCVar, name)
    return ok and value or nil
end

---------------------------------------------------------------------------
-- Secure frames
---------------------------------------------------------------------------

local ring = CreateFrame("Frame", "WCWheelRing", UIParent, "SecureHandlerBaseTemplate")
ring:Hide()
-- the look, the aim, the stick capture and the camera hold (Core's Ring.lua)
local look = WC.Ring.Build(ring, { prompt = "Release stick Use      Circle Close" })

local function SecureButton(name)
    local button = CreateFrame("Button", name, UIParent, "SecureActionButtonTemplate,SecureHandlerBaseTemplate")
    button:SetSize(1, 1)
    button:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -20, 20)
    SecureHandlerSetFrameRef(button, "ring", ring)
    return button
end

-- The slot nearest a direction (x, y), by the slots' own directions.
ring:SetAttribute("wc-aim", [[
    local dx, dy = ...
    local key = self:GetAttribute("wc-active")
    local best, bestDot
    for index = 1, self:GetAttribute(key .. "-count") or 0 do
        local dot = dx * self:GetAttribute(key .. "-dx-" .. index) + dy * self:GetAttribute(key .. "-dy-" .. index)
        if not bestDot or dot > bestDot then best, bestDot = index, dot end
    end
    return best
]])
-- The pick is the right stick's direction keys held (PADRSTICKUP and the rest,
-- each a click on its own WCWheelAim<key>): their sum points at the nearest slot, so up and
-- right held together is the up-right slot. The game's own key thresholds draw
-- those borders: on the stick's rim a key changes only at 30 and 60 degrees,
-- so there a straight direction takes 60 and a diagonal 30 (no reading between
-- edges can do better; tools/wheel_sim.py). Every key edge is seen, so the
-- highlight (wc-sticky, which the look shows) is always what a release uses.
-- Returns the slot, or nil with no key held.
ring:SetAttribute("wc-pick", [[
    local dx, dy = 0, 0
    if self:GetAttribute("wc-held-PADRSTICKUP") then dy = dy + 1 end
    if self:GetAttribute("wc-held-PADRSTICKDOWN") then dy = dy - 1 end
    if self:GetAttribute("wc-held-PADRSTICKLEFT") then dx = dx - 1 end
    if self:GetAttribute("wc-held-PADRSTICKRIGHT") then dx = dx + 1 end
    if dx == 0 and dy == 0 then return nil end
    return self:RunAttribute("wc-aim", dx, dy)
]])
-- forget the keys held (the ring opening or closing)
ring:SetAttribute("wc-forget", [[
    for _, key in ipairs(newtable("PADRSTICKUP", "PADRSTICKDOWN", "PADRSTICKLEFT", "PADRSTICKRIGHT")) do
        self:SetAttribute("wc-held-" .. key, nil)
    end
]])

-- Loads a use onto `self` (type `t`, attribute `a` = `v`), remembered as the
-- wheel's last (before the ring closes, whose OnHide shows it on the macro),
-- and closes the ring; the secure action then runs it.
local LOAD = [[
    ring:SetAttribute(key .. "-last-type", t)
    ring:SetAttribute(key .. "-last-attr", a)
    ring:SetAttribute(key .. "-last-value", v)
    ring:Hide()
    for _, attribute in ipairs(newtable("spell", "item", "macro", "macrotext", "unit")) do
        self:SetAttribute(attribute, nil)
    end
    self:SetAttribute(a, v)
    self:SetAttribute("type", t)
]]

-- The same wheel's button closes it, using what it used last (kept as values,
-- so a rebuild of the wheel cannot turn it into another slot; gone at a
-- /reload). Another wheel's switches to that one. The use runs on whichever
-- edge the macro's /click brought, hence useOnKeyDown set to it.
local OPEN_SNIPPET = [[
    self:SetAttribute("type", nil)
    if button ~= "Macro" and not down then return false end
    local ring = self:GetFrameRef("ring")
    local key = self:GetAttribute("wc-wheel")
    if ring:IsShown() then
        local same = ring:GetAttribute("wc-active") == key
        ring:Hide()
        if not same then
        elseif ring:GetAttribute(key .. "-last-type") then
            local t, a, v = ring:GetAttribute(key .. "-last-type"), ring:GetAttribute(key .. "-last-attr"),
                ring:GetAttribute(key .. "-last-value")
            self:SetAttribute("useOnKeyDown", down and true or false)
]] .. LOAD .. [[
            return
        else
            return false
        end
    end
    if (ring:GetAttribute(key .. "-count") or 0) < 1 then return false end
    ring:SetAttribute("wc-sticky", nil)
    ring:RunAttribute("wc-forget")
    ring:SetAttribute("wc-active", key)
    ring:Show()
    return false
]]

local function OpenButton(name)
    local button = _G["WCWheel_" .. name]
    if button then return button end
    button = SecureButton("WCWheel_" .. name)
    button:RegisterForClicks("AnyDown", "AnyUp")
    button:SetAttribute("wc-wheel", name)
    SecureHandlerWrapScript(button, "OnClick", button, OPEN_SNIPPET)
    return button
end

-- Right stick directions (as keys): move the sticky pick, and use it when the
-- stick is let go. Only a key going down moves the pick: a diagonal let go
-- loses its keys one at a time, and the first must not turn it into its
-- neighbour; a key let go with the stick still out is a move, and does. Each direction has its own button, because the game gives a
-- button one up edge however many keys hold it: on one shared button a
-- diagonal's second key never came up, and the wheel waited on it with the
-- spell unused (measured 2026-11-13). So a release is simply the last key up.
-- A flick out of the centre takes the stick's own angle instead: the first key
-- on reads the stick a few milliseconds on, still on the line of the flick, so
-- a flick picks from equal slices (99% in tools/wheel_sim.py, against 80% by
-- keys). The action runs on the up edge, hence useOnKeyDown false.
local STICK_KEYS = { "PADRSTICKUP", "PADRSTICKDOWN", "PADRSTICKLEFT", "PADRSTICKRIGHT" }
local AIM = [[
    self:SetAttribute("type", nil)
    local ring = self:GetFrameRef("ring")
    if not ring:IsShown() then return false end
    local flick = down and not ring:RunAttribute("wc-pick")
    ring:SetAttribute("wc-held-" .. button, down or nil)
    local pick = ring:RunAttribute("wc-pick")
    if flick then
        local state = GetGamePadState()
        local stick = state and state.sticks and state.sticks[2]
        if stick and stick.x and (stick.x * stick.x + stick.y * stick.y) >= 0.09 then
            pick = ring:RunAttribute("wc-aim", stick.x, stick.y)
        end
    end
    if down then
        ring:SetAttribute("wc-sticky", pick)
        return false
    end
    -- An up edge with a key still held: the stick still out is a move to the
    -- neighbour (diagonal to cardinal), which the pick follows; back at the
    -- centre it is a diagonal let go a key at a time, and the pick stays. The
    -- trace measured both: a move's stick at 0.85-1.0, a release's at 0.0-0.1.
    if pick then
        local state = GetGamePadState()
        local stick = state and state.sticks and state.sticks[2]
        if stick and stick.x and (stick.x * stick.x + stick.y * stick.y) >= 0.25 then
            ring:SetAttribute("wc-sticky", pick)
        end
        return false
    end
    pick = ring:GetAttribute("wc-sticky")
    if not pick then return false end
    local key = ring:GetAttribute("wc-active")
    local t, a, v = ring:GetAttribute(key .. "-type-" .. pick), ring:GetAttribute(key .. "-attr-" .. pick),
        ring:GetAttribute(key .. "-value-" .. pick)
]] .. LOAD
local aims = {}
for _, key in ipairs(STICK_KEYS) do
    local aim = SecureButton("WCWheelAim" .. key)
    aim:RegisterForClicks("AnyDown", "AnyUp")
    aim:SetAttribute("useOnKeyDown", false)
    SecureHandlerWrapScript(aim, "OnClick", aim, AIM)
    aims[#aims + 1] = aim
end

-- Circle: close.
local close = SecureButton("WCWheelClose")
close:RegisterForClicks("AnyDown")
SecureHandlerWrapScript(close, "OnClick", close, [[
    self:GetFrameRef("ring"):Hide()
    return false
]])

-- While the ring is up it owns Circle and the right stick's directions, whatever
-- modifier the held triggers emulate.
SecureHandlerWrapScript(ring, "OnShow", ring, [[
    for _, modifier in ipairs(]] .. MODIFIERS_LUA .. [[) do
        self:SetBindingClick(true, modifier .. "PAD2", "WCWheelClose", "LeftButton")
        -- the d-pad is left alone: it keeps its bar actions, so another
        -- wheel's button opens that wheel from inside this one
        for _, key in ipairs(newtable("PADRSTICKUP", "PADRSTICKDOWN", "PADRSTICKLEFT", "PADRSTICKRIGHT")) do
            self:SetBindingClick(true, modifier .. key, "WCWheelAim" .. key, key)
        end
    end
]])
SecureHandlerWrapScript(ring, "OnHide", ring, [[
    self:ClearBindings()
    self:RunAttribute("wc-forget")
]])

-- Stick directions only arrive as keys with GamePadStickAxisButtons on: on
-- while the ring is up, put back after (saved, so a /reload mid-ring still
-- restores it).
local function RestoreAxis()
    if ring:IsShown() then return end
    local db = WowCompanionWheelDB
    if db and db.axisSaved ~= nil and SetCVarSafe(AXIS_CVAR, db.axisSaved) then db.axisSaved = nil end
end
ring:HookScript("OnShow", function()
    local current = GetCVarSafe(AXIS_CVAR)
    if current and current ~= "1" then
        if WowCompanionWheelDB.axisSaved == nil then WowCompanionWheelDB.axisSaved = current end
        SetCVarSafe(AXIS_CVAR, "1")
    end
end)
ring:HookScript("OnHide", RestoreAxis)

-- the look shows the secure pick itself, never a reading of its own
ring:SetScript("OnUpdate", function()
    local pick = ring:GetAttribute("wc-sticky")
    if pick ~= look.lit then look:Light(pick, ringData[ring:GetAttribute("wc-active")] or {}) end
end)
-- An item slot shows how many are carried, as a bar button does: a stack or a
-- consumable (its charges counted), never a single thing like the Hearthstone.
-- Read at each opening, so a fight's use is counted too.
local function Counts(entries)
    for _, entry in ipairs(entries) do
        local id = entry.itemID
        if id then
            local consumable = C_Item.IsConsumableItem(id)
            if consumable or (C_Item.GetItemMaxStackSizeByID(id) or 1) > 1 then
                entry.count = tostring(C_Item.GetItemCount(id, false, consumable))
            end
        end
    end
end
ring:HookScript("OnShow", function()
    local key = ring:GetAttribute("wc-active")
    Counts(ringData[key] or {})
    local wheel = WowCompanionWheelDB.wheels[key]
    look:Open(wheel and wheel.label or key, ringData[key] or {})
end)

---------------------------------------------------------------------------
-- What is on each wheel (out of combat)
---------------------------------------------------------------------------

-- A slot as the secure button needs it: type, the attribute holding its
-- value, the value, and what is drawn. nil (and why) when it cannot be used.
local function Resolve(slot)
    if slot.spell then
        local info = C_Spell.GetSpellInfo(slot.spell)
        if not info then return nil, "no spell " .. tostring(slot.spell) end
        return { type = "spell", attr = "spell", value = info.name, label = slot.label or info.name,
            icon = slot.icon or info.iconID }
    elseif slot.item then
        local id = tonumber(slot.item) or (C_Item.GetItemInfoInstant(slot.item))
        if not id then return nil, "no item " .. tostring(slot.item) end
        return { type = "item", attr = "item", value = "item:" .. id, itemID = id,
            label = slot.label or C_Item.GetItemNameByID(id) or ("item " .. id),
            icon = slot.icon or C_Item.GetItemIconByID(id) }
    elseif slot.macro then
        local name, icon = GetMacroInfo(slot.macro)
        if not name then return nil, "no macro " .. tostring(slot.macro) end
        return { type = "macro", attr = "macro", value = name, label = slot.label or name, icon = slot.icon or icon }
    elseif slot.emote then
        local token = string.lower(slot.emote)
        return { type = "macro", attr = "macrotext", value = "/" .. token,
            label = slot.label or (token:gsub("^%l", string.upper)), icon = slot.icon or 236373 }
    elseif slot.macrotext then
        return { type = "macro", attr = "macrotext", value = slot.macrotext, label = slot.label or slot.macrotext,
            icon = slot.icon or 134400 }
    elseif slot.rule then
        return nil, "unknown rule " .. tostring(slot.rule)
    end
    return nil, "empty slot"
end

-- Rules fill themselves, out of combat, each time the wheel is rebuilt. Each
-- takes bag items that have a Use: effect, once per item, in bag order:
--   "items"  everything usable from the bags but quest items and gear: food,
--            drink, potions, scrolls, the Hearthstone
--   "quest"  quest items only
local RULES = {}
local QUEST_CLASS, CONSUMABLE_CLASS = 12, 0
local function BagUsable(keep)
    local found, seen = {}, {}
    for bag = 0, 4 do
        local count = C_Container.GetContainerNumSlots(bag) or 0
        for index = 1, count do
            local info = C_Container.GetContainerItemInfo(bag, index)
            local id = info and info.itemID
            if id and not seen[id] then
                -- only what has a Use: effect; a quest item you only carry has
                -- no spell and stays off
                local classID = select(6, C_Item.GetItemInfoInstant(id))
                local quest = C_Container.GetContainerItemQuestInfo(bag, index)
                local isQuest = classID == QUEST_CLASS or (quest and (quest.isQuestItem or quest.questID)) and true or false
                if C_Item.GetItemSpell(id) ~= nil and keep(isQuest, classID) then
                    seen[id] = true
                    found[#found + 1] = { item = id }
                end
            end
        end
    end
    return found
end
-- not only consumables: the Hearthstone is "miscellaneous" (15). Weapons (2)
-- and armour (4) with a Use: only work worn, so they stay off.
function RULES.items() return BagUsable(function(isQuest, classID) return not isQuest and classID ~= 2 and classID ~= 4 end) end
function RULES.quest() return BagUsable(function(isQuest) return isQuest end) end

-- a wheel's slots with every rule replaced by what it finds now
local function Expand(slots)
    local out = {}
    for _, slot in ipairs(slots or {}) do
        local rule = slot.rule and RULES[slot.rule]
        if rule then
            local ok, found = pcall(rule)
            for _, each in ipairs(ok and found or {}) do out[#out + 1] = each end
        else
            out[#out + 1] = slot
        end
    end
    return out
end

-- A wheel's bar macros show what a tap of them uses again: SetMacroSpell /
-- SetMacroItem, the game's feedback for a macro that opens with a bare
-- #showtooltip (measured 2026-11-14, in combat too: the Buffs macro took Mark
-- of the Wild's icon). Every macro holding the wheel's line counts.
local function WheelMacros(key, fn)
    local line = W.Macro(key)
    local global, character = GetNumMacros()
    local base = Constants.MacroConsts.MAX_ACCOUNT_MACROS
    for index = 1, base + character do
        if index <= global or index > base then
            local body = select(3, GetMacroInfo(index))
            if body and body:find(line, 1, true) then fn(index, body) end
        end
    end
end

local function ShowLast(key)
    local attr, value = ring:GetAttribute(key .. "-last-attr"), ring:GetAttribute(key .. "-last-value")
    local set = (attr == "spell" and SetMacroSpell) or (attr == "item" and SetMacroItem)
    if set then WheelMacros(key, function(index) pcall(set, index, value) end) end
end
ring:HookScript("OnHide", function()
    local key = ring:GetAttribute("wc-active")
    if key then ShowLast(key) end
end)

-- the macro text change is out of combat only, so it is made at each rebuild:
-- a bare #showtooltip on top, the question-mark icon, which lets the feedback show
local function PrepareMacros(key)
    WheelMacros(key, function(index, body)
        if not body:find("^#showtooltip") then EditMacro(index, nil, 134400, "#showtooltip\n" .. body) end
    end)
end

function W.Rebuild(quiet)
    if InCombatLockdown() then
        pending = true
        return false
    end
    pending = false
    for key in pairs(ringData) do ring:SetAttribute(key .. "-count", 0) end
    wipe(ringData)
    for key, wheel in pairs(WowCompanionWheelDB.wheels) do
        OpenButton(key)
        local entries = {}
        for _, slot in ipairs(Expand(wheel.slots)) do
            local entry, why = Resolve(slot)
            if entry and #entries < MAX_SLOTS then
                entries[#entries + 1] = entry
            elseif not quiet then
                Print(key .. ": skipped a slot, " .. (why or "the wheel is full"))
            end
        end
        for index, entry in ipairs(entries) do
            entry.dx, entry.dy, entry.angle = WC.Ring.Direction(index)
            ring:SetAttribute(key .. "-dx-" .. index, entry.dx)
            ring:SetAttribute(key .. "-dy-" .. index, entry.dy)
            ring:SetAttribute(key .. "-type-" .. index, entry.type)
            ring:SetAttribute(key .. "-attr-" .. index, entry.attr)
            ring:SetAttribute(key .. "-value-" .. index, entry.value)
        end
        ring:SetAttribute(key .. "-count", #entries)
        ringData[key] = entries
        PrepareMacros(key)
    end
    return true
end

local function ValidName(name)
    return type(name) == "string" and name:match("^[%w_]+$") ~= nil
end

function W.Set(name, wheel)
    if not ValidName(name) then return Print("a wheel's name is letters, digits and _") end
    if InCombatLockdown() then return Print("not in combat") end
    WowCompanionWheelDB.wheels[name] = wheel
    W.Rebuild()
    Print("wheel " .. name .. " set, " .. #(ringData[name] or {}) .. " slots; its macro: " .. W.Macro(name))
end

function W.Remove(name)
    if InCombatLockdown() then return Print("not in combat") end
    WowCompanionWheelDB.wheels[name] = nil
    W.Rebuild()
    Print("wheel " .. tostring(name) .. " removed (its bar macro now does nothing)")
end

function W.Macro(name)
    return "/click WCWheel_" .. name .. " Macro"
end

-- every wheel, name and definition (slots, label), for the addons that read
-- them (the export's reach, the Status tab, the buff glow); nothing before login
function W.Each(fn)
    for name, wheel in pairs(WowCompanionWheelDB and WowCompanionWheelDB.wheels or {}) do fn(name, wheel) end
end

function W.List()
    for key, wheel in pairs(WowCompanionWheelDB.wheels) do
        local names = {}
        for _, entry in ipairs(ringData[key] or {}) do names[#names + 1] = entry.label end
        Print(key .. " (" .. (wheel.label or key) .. "): " .. table.concat(names, ", "))
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("SPELLS_CHANGED")
events:RegisterEvent("UPDATE_MACROS")
events:RegisterEvent("CVAR_UPDATE")
events:RegisterEvent("BAG_UPDATE_DELAYED") -- an items rule follows the bags
events:SetScript("OnEvent", function(_, event, name)
    if event == "PLAYER_LOGIN" then
        WowCompanionWheelDB = WowCompanionWheelDB or {}
        local db = WowCompanionWheelDB
        db.wheels = db.wheels or {}
        RestoreAxis()
        W.Rebuild()
    elseif not WowCompanionWheelDB then
        return
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pending then W.Rebuild(true) end
    elseif event == "CVAR_UPDATE" then
        if name == "ActionButtonUseKeyDown" then W.Rebuild(true) end
    else
        W.Rebuild(true)
    end
end)

-- The release trace (2026-11-13: a release sometimes used nothing): every stick
-- edge on an open wheel, what the secure code then held, and what the game did
-- after a use. Only watches; WowCompanionWheelDB.trace, the newest 300 lines,
-- read after a reload.
local function Note(text)
    local db = WowCompanionWheelDB
    if not db then return end
    local log = db.trace or {}
    db.trace = log
    log[#log + 1] = ("%.2f %s"):format(GetTime(), text)
    while #log > 300 do table.remove(log, 1) end
end
local function Push()
    local ok, state = pcall(C_GamePad.GetDeviceMappedState, C_GamePad.GetActiveDeviceID())
    local stick = ok and state and state.sticks and state.sticks[2]
    if not (stick and stick.x) then return "?" end
    return ("%.2f,%.2f"):format(stick.x, stick.y)
end
local watching = false
ring:HookScript("OnShow", function()
    watching = true
    Note(("open %s stick=%s axis=%s combat=%s"):format(tostring(ring:GetAttribute("wc-active")), Push(),
        tostring(GetCVarSafe(AXIS_CVAR)), tostring(InCombatLockdown())))
end)
for _, aim in ipairs(aims) do aim:HookScript("OnClick", function(self, button, down)
    local used = self:GetAttribute("type")
    Note(("%s %s stick=%s sticky=%s %s"):format(button, down and "down" or "up", Push(),
        tostring(ring:GetAttribute("wc-sticky")),
        used and ("USED " .. tostring(self:GetAttribute("spell") or self:GetAttribute("item")
            or self:GetAttribute("macro") or self:GetAttribute("macrotext"))) or "kept"))
end) end
local after = CreateFrame("Frame")
after:RegisterEvent("UI_ERROR_MESSAGE")
after:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player")
after:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
after:SetScript("OnEvent", function(_, event, a, b, c)
    if not watching then return end
    if event == "UI_ERROR_MESSAGE" then Note("error " .. tostring(b)) else Note(event:lower() .. " " .. tostring(c)) end
end)
-- a use's result arrives after the ring closes: watched a second more
ring:HookScript("OnHide", function()
    Note("closed")
    C_Timer.After(1, function() if not ring:IsShown() then watching = false end end)
end)
