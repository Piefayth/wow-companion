-- Radial wheels of the player's own, each opened by a bar slot whose macro is
-- "/click WCWheel_<name> Macro" (WCWheel.Macro(name) gives the line).
-- Right stick points and letting it go uses (the one way); the d-pad keeps its bar actions;
-- the wheel's own button again uses what it used last; Circle closes; the left stick
-- keeps walking (Ring.Take blocks only the camera stick). Every button is secure, so a wheel works in combat; what is on
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
-- The player places things too, with no agent: W.Place(slot, label) (the
-- companion button's tap on a spell, item or macro, ContextTap.lua) and then a
-- wheel opened and flicked puts it in that slot, or in the "Add here" one.

WCWheel = WCWheel or {}
WC.Wheel = WCWheel
local W = WCWheel

local MAX_SLOTS = WC.Ring.PAGE
local AXIS_CVAR = "GamePadStickAxisButtons"
local MODIFIERS_LUA = [[newtable("", "SHIFT-", "CTRL-", "ALT-", "CTRL-SHIFT-", "ALT-SHIFT-", "CTRL-ALT-", "CTRL-ALT-SHIFT-")]]

local ringData = {} -- [wheel] = { { label, icon, itemID, count, dx, dy }, ... }
local pending = false

local function Print(text) WC.Say("Wheel: " .. text) end

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
-- The pick (wc-sticky, which the look shows) is the stick's own angle, read
-- every frame the ring is up: the slot nearest it whenever the stick is out
-- past 0.3, so every slot gets an equal slice and a release uses the last
-- reading before the stick fell back. Secure code reads the stick only in a
-- snippet, so the frame comes from Blizzard's state driver: while the ring is
-- up its manager ticks every frame (updatetime 0) and the sampler's driver,
-- cleared after each tick, fires on every one (Forever Tweaks' way,
-- ivribalko/wow-forever-tweaks GamepadQuickMenu.lua).
ring:SetAttribute("wc-sample", [[
    local state = GetGamePadState()
    local stick = state and state.sticks and state.sticks[2]
    if stick and stick.x and (stick.x * stick.x + stick.y * stick.y) >= 0.09 then
        self:SetAttribute("wc-sticky", self:RunAttribute("wc-aim", stick.x, stick.y))
    end
]])
-- the stick's direction keys still down (a release is the last one up)
ring:SetAttribute("wc-any-held", [[
    for _, key in ipairs(newtable("PADRSTICKUP", "PADRSTICKDOWN", "PADRSTICKLEFT", "PADRSTICKRIGHT")) do
        if self:GetAttribute("wc-held-" .. key) then return true end
    end
]])
-- forget the keys held (the ring opening or closing)
ring:SetAttribute("wc-forget", [[
    for _, key in ipairs(newtable("PADRSTICKUP", "PADRSTICKDOWN", "PADRSTICKLEFT", "PADRSTICKRIGHT")) do
        self:SetAttribute("wc-held-" .. key, nil)
    end
]])

local sampler = CreateFrame("Frame", "WCWheelSampler", UIParent, "SecureHandlerStateTemplate")
SecureHandlerSetFrameRef(sampler, "ring", ring)
sampler:SetAttribute("_onstate-aim", [[
    if newstate ~= "sample" then return end
    local ring = self:GetFrameRef("ring")
    if not ring:IsShown() then return end -- left set, so the driver stops firing
    ring:RunAttribute("wc-sample")
    self:SetAttribute("state-aim", nil)
]])
RegisterStateDriver(sampler, "aim", "sample")
SecureHandlerSetFrameRef(ring, "sampler", sampler)
SecureHandlerSetFrameRef(ring, "driver", SecureStateDriverManager)

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
        if not same or ring:GetAttribute("wc-placing") then
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

-- Right stick directions (as keys): only the release, the last key up, uses
-- the pick; every edge also reads the stick, in case the frame's tick has not
-- run yet. Each direction has its own button, because the game gives a
-- button one up edge however many keys hold it: on one shared button a
-- diagonal's second key never came up, and the wheel waited on it with the
-- spell unused (measured 2026-11-13). The action runs on the up edge, hence
-- useOnKeyDown false.
local STICK_KEYS = { "PADRSTICKUP", "PADRSTICKDOWN", "PADRSTICKLEFT", "PADRSTICKRIGHT" }
local AIM = [[
    self:SetAttribute("type", nil)
    local ring = self:GetFrameRef("ring")
    if not ring:IsShown() then return false end
    ring:SetAttribute("wc-held-" .. button, down or nil)
    ring:RunAttribute("wc-sample")
    if down or ring:RunAttribute("wc-any-held") then return false end
    local pick = ring:GetAttribute("wc-sticky")
    if not pick then return false end
    local key = ring:GetAttribute("wc-active")
    if ring:GetAttribute("wc-placing") and not PlayerInCombat() then
        ring:Hide()
        ring:CallMethod("WCPlace", key, pick)
        return false
    end
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
    -- the stick read every frame while up (the sampler above); the manager's
    -- own pace (0.2 s unless another addon changed it) is put back on hide
    local driver = self:GetFrameRef("driver")
    if driver:GetAttribute("updatetime") ~= 0 then
        self:SetAttribute("wc-pace", driver:GetAttribute("updatetime") or 0.2)
        driver:SetAttribute("updatetime", 0)
    end
    self:GetFrameRef("sampler"):SetAttribute("state-aim", nil)
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
    local driver = self:GetFrameRef("driver")
    if driver:GetAttribute("updatetime") == 0 and self:GetAttribute("wc-pace") then
        driver:SetAttribute("updatetime", self:GetAttribute("wc-pace"))
    end
    self:SetAttribute("wc-pace", nil)
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
    look:Open(W.placing and ("Place " .. W.placing.label) or (wheel and wheel.label or key), ringData[key] or {})
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
            icon = slot.icon or info.iconID, spellID = info.spellID }
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
    elseif not next(slot) then
        -- a gap, kept so the slots after it stay where they are
        return { empty = true, label = "" }
    end
    return nil, "not a slot"
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

-- a wheel's slots with every rule replaced by what it finds now, and for each
-- the definition it came from ({ index, rule })
local function Expand(slots)
    local out, from = {}, {}
    for index, slot in ipairs(slots or {}) do
        local rule = slot.rule and RULES[slot.rule]
        if rule then
            local ok, found = pcall(rule)
            for _, each in ipairs(ok and found or {}) do
                out[#out + 1], from[#out + 1] = each, { index = index, rule = slot.rule }
            end
        else
            out[#out + 1], from[#out + 1] = slot, { index = index }
        end
    end
    return out, from
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
    ring:SetAttribute("wc-placing", W.placing and true or nil)
    for key in pairs(ringData) do ring:SetAttribute(key .. "-count", 0) end
    wipe(ringData)
    for key, wheel in pairs(WowCompanionWheelDB.wheels) do
        OpenButton(key)
        local entries = {}
        local slots, from = Expand(wheel.slots)
        for index, slot in ipairs(slots) do
            local entry, why = Resolve(slot)
            if entry and #entries < MAX_SLOTS then
                entry.from = from[index]
                entries[#entries + 1] = entry
            elseif not quiet then
                Print(key .. ": skipped a slot, " .. (why or "the wheel is full"))
            end
        end
        -- while placing, every free position shows itself: the gaps and all
        -- past the last slot
        if W.placing then
            for _, entry in ipairs(entries) do
                if entry.empty then entry.label, entry.icon = "Add here", 134400 end
            end
            for _ = #entries + 1, MAX_SLOTS do entries[#entries + 1] = { label = "Add here", icon = 134400, add = true } end
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

-- Placing: what the companion button picked waits for a wheel's flick (the
-- secure release calls WCPlace instead of using the slot, never in a fight).
-- It ends with the placement, a fight, a tap on nothing, or after a minute;
-- Circle only closes the wheel, so another can be opened.
local PLACE_FOR = 60
local function EndPlacing()
    local placing = W.placing
    W.placing = nil
    W.Rebuild(true)
    if placing and placing.onEnd then pcall(placing.onEnd) end
end
function W.Placing() return W.placing end
-- onEnd runs as placing ends, however it ends
function W.Place(slot, label, onEnd)
    if InCombatLockdown() then return Print("not in combat") end
    if not next(WowCompanionWheelDB.wheels) then return Print("there is no wheel yet to put " .. label .. " on") end
    local placing = { slot = slot, label = label, onEnd = onEnd }
    W.placing = placing
    W.Rebuild(true)
    Print("placing " .. label .. ": open a wheel and flick to a slot (minus cancels)")
    C_Timer.After(PLACE_FOR, function()
        if W.placing == placing then EndPlacing() Print("stopped placing " .. label) end
    end)
    return true
end
function W.CancelPlacing()
    if not W.placing then return end
    local label = W.placing.label
    EndPlacing()
    Print("stopped placing " .. label)
end
function ring:WCPlace(key, index)
    local placing, wheel = W.placing, WowCompanionWheelDB.wheels[key]
    local entry = ringData[key] and ringData[key][index]
    if not (placing and wheel and entry) then return end
    if entry.from and entry.from.rule then
        return Print("that slot is filled from the bags (the " .. entry.from.rule .. " rule): flick to another")
    end
    wheel.slots = wheel.slots or {}
    local said = placing.label .. " added to " .. (wheel.label or key)
    if entry.add then
        -- past the last slot: gaps up to the position flicked
        local last = 0
        for i, each in ipairs(ringData[key]) do if not each.add then last = i end end
        for _ = last + 1, index - 1 do wheel.slots[#wheel.slots + 1] = {} end
        wheel.slots[#wheel.slots + 1] = placing.slot
    else
        if not entry.empty then said = placing.label .. " is on " .. (wheel.label or key) .. " in place of " .. tostring(entry.label) end
        wheel.slots[entry.from.index] = placing.slot
    end
    EndPlacing()
    Print(said)
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
events:RegisterEvent("PLAYER_REGEN_DISABLED")
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
    elseif event == "PLAYER_REGEN_DISABLED" then
        W.CancelPlacing() -- the secure release already refuses in a fight
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
