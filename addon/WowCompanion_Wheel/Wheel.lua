-- Radial wheels of the player's own, each opened by a bar slot whose macro is
-- "/click WCWheel_<name> Macro" (WCWheel.Macro(name) gives the line).
-- Right stick points and letting it go uses; R2 uses; the d-pad keeps its bar actions;
-- Circle closes; the left stick
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

local ringData = {} -- [wheel] = { { label, icon, dx, dy }, ... }
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
local look = WC.Ring.Build(ring, { prompt = "Release stick or R2 Use      Circle Close" })

local function SecureButton(name)
    local button = CreateFrame("Button", name, UIParent, "SecureActionButtonTemplate,SecureHandlerBaseTemplate")
    button:SetSize(1, 1)
    button:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -20, 20)
    SecureHandlerSetFrameRef(button, "ring", ring)
    return button
end

-- The pick is the right stick's direction keys held (PADRSTICKUP and the rest,
-- each a click on WCWheelAim): their sum points at the nearest slot, so up and
-- right held together is the up-right slot. The game's own key thresholds draw
-- the borders, and every key edge is seen, so the highlight (wc-sticky, which
-- the look shows) is always what a release or R2 uses. Returns the slot, or nil
-- with no key held.
ring:SetAttribute("wc-pick", [[
    local dx, dy = 0, 0
    if self:GetAttribute("wc-held-PADRSTICKUP") then dy = dy + 1 end
    if self:GetAttribute("wc-held-PADRSTICKDOWN") then dy = dy - 1 end
    if self:GetAttribute("wc-held-PADRSTICKLEFT") then dx = dx - 1 end
    if self:GetAttribute("wc-held-PADRSTICKRIGHT") then dx = dx + 1 end
    if dx == 0 and dy == 0 then return nil end
    local key = self:GetAttribute("wc-active")
    local best, bestDot
    for index = 1, self:GetAttribute(key .. "-count") or 0 do
        local dot = dx * self:GetAttribute(key .. "-dx-" .. index) + dy * self:GetAttribute(key .. "-dy-" .. index)
        if not bestDot or dot > bestDot then best, bestDot = index, dot end
    end
    return best
]])
-- The stick's push now (0 centre, 1 the rim), or nil with no reading.
ring:SetAttribute("wc-push", [[
    local state = GetGamePadState()
    local sticks = state and state.sticks
    local stick = sticks and sticks[self:GetAttribute("wc-stick") or 2]
    if not (stick and stick.x and stick.y) then return nil end
    return (stick.x * stick.x + stick.y * stick.y) ^ 0.5
]])
-- forget the keys held (the ring opening or closing)
ring:SetAttribute("wc-forget", [[
    for _, key in ipairs(newtable("PADRSTICKUP", "PADRSTICKDOWN", "PADRSTICKLEFT", "PADRSTICKRIGHT")) do
        self:SetAttribute("wc-held-" .. key, nil)
    end
]])

-- R2 becomes "use" while the ring is up, but only once let go if it was held
-- when the ring opened (a slot on the R2 bar): its release has to reach the
-- game's own binding, which got the press, or the bar page stays down.
ring:SetAttribute("wc-take-r2", [[
    local opening = ...
    if not self:IsShown() then return end
    if not (opening or self:GetAttribute("wc-waiting")) then return end
    local state = GetGamePadState()
    local index = self:GetAttribute("wc-btn-r2")
    if state and state.buttons and index and state.buttons[index] then
        self:SetAttribute("wc-waiting", true)
        return
    end
    self:SetAttribute("wc-waiting", nil)
    for _, modifier in ipairs(]] .. MODIFIERS_LUA .. [[) do
        self:SetBindingClick(true, modifier .. "PADRTRIGGER", "WCWheelUse", "LeftButton")
    end
]])

local OPEN_SNIPPET = [[
    if button ~= "Macro" and not down then return false end
    local ring = self:GetFrameRef("ring")
    local key = self:GetAttribute("wc-wheel")
    -- the same wheel's button closes it; another wheel's switches to that one
    if ring:IsShown() then
        local same = ring:GetAttribute("wc-active") == key
        ring:Hide()
        if same then return false end
    end
    if (ring:GetAttribute(key .. "-count") or 0) < 1 then return false end
    ring:SetAttribute("wc-sticky", nil)
    ring:SetAttribute("wc-aimed", nil)
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

-- Loads slot `pick` of the open wheel onto `self` and closes the ring; the
-- secure action then runs it. Shared by the stick release and R2.
local LOAD_PICK = [[
    ring:Hide()
    for _, attribute in ipairs(newtable("spell", "item", "macro", "macrotext", "unit")) do
        self:SetAttribute(attribute, nil)
    end
    self:SetAttribute(ring:GetAttribute(key .. "-attr-" .. pick), ring:GetAttribute(key .. "-value-" .. pick))
    self:SetAttribute("type", ring:GetAttribute(key .. "-type-" .. pick))
]]

-- Right stick directions (as keys): move the sticky pick, and use it when the
-- last key is let go. A key going down always moves the pick. A key going up
-- moves it only while the stick is still pushed out to the rim (the stick
-- turning, up-right to right); a stick on its way back to the centre lets its
-- keys go one at a time, and the first of them must not turn a diagonal into
-- its neighbour. The action runs on the up edge, hence useOnKeyDown false.
local aim = SecureButton("WCWheelAim")
aim:RegisterForClicks("AnyDown", "AnyUp")
aim:SetAttribute("useOnKeyDown", false)
SecureHandlerWrapScript(aim, "OnClick", aim, [[
    self:SetAttribute("type", nil)
    local ring = self:GetFrameRef("ring")
    ring:RunAttribute("wc-take-r2")
    if not ring:IsShown() then return false end
    ring:SetAttribute("wc-held-" .. button, down or nil)
    local pick = ring:RunAttribute("wc-pick")
    if pick then
        if down or (ring:RunAttribute("wc-push") or 0) >= 0.85 then
            ring:SetAttribute("wc-sticky", pick)
            ring:SetAttribute("wc-aimed", true)
        end
        return false
    end
    -- no key held: the stick is let go
    if down or not ring:GetAttribute("wc-aimed") then return false end
    pick = ring:GetAttribute("wc-sticky")
    if not pick then return false end
    local key = ring:GetAttribute("wc-active")
]] .. LOAD_PICK .. [[
]])

-- D-pad: step the pick round the ring (up / left back, down / right on).
local step = SecureButton("WCWheelStep")
step:RegisterForClicks("AnyDown")
SecureHandlerWrapScript(step, "OnClick", step, [[
    local ring = self:GetFrameRef("ring")
    ring:RunAttribute("wc-take-r2")
    local count = ring:GetAttribute((ring:GetAttribute("wc-active") or "") .. "-count") or 0
    if not ring:IsShown() or count < 1 then return false end
    local current = ring:GetAttribute("wc-sticky")
    local forward = button == "PADDRIGHT" or button == "PADDDOWN"
    if not current then
        current = forward and 1 or count
    elseif forward then
        current = current % count + 1
    else
        current = (current - 2) % count + 1
    end
    ring:SetAttribute("wc-sticky", current)
    return false
]])

-- R2: use what the stick points at now, else the sticky pick, on the press
-- or the release as ActionButtonUseKeyDown says action buttons fire.
local use = SecureButton("WCWheelUse")
use:RegisterForClicks("AnyDown", "AnyUp")
SecureHandlerWrapScript(use, "OnClick", use, [[
    self:SetAttribute("type", nil)
    local ring = self:GetFrameRef("ring")
    ring:RunAttribute("wc-take-r2")
    if not ring:IsShown() then
        self:SetAttribute("wc-pressed", nil)
        return false
    end
    if down then self:SetAttribute("wc-pressed", true) end
    if (down and 1 or 0) ~= (self:GetAttribute("wc-keydown") or 1) then return false end
    if not down and not self:GetAttribute("wc-pressed") then return false end
    self:SetAttribute("wc-pressed", nil)
    local key = ring:GetAttribute("wc-active")
    local pick = ring:GetAttribute("wc-sticky")
    if not pick then return false end
]] .. LOAD_PICK .. [[
]])

-- Circle: close.
local close = SecureButton("WCWheelClose")
close:RegisterForClicks("AnyDown")
SecureHandlerWrapScript(close, "OnClick", close, [[
    self:GetFrameRef("ring"):Hide()
    return false
]])

-- While the ring is up it owns R2, Circle and both sticks'
-- directions, whatever modifier the held triggers emulate.
SecureHandlerWrapScript(ring, "OnShow", ring, [[
    self:RunAttribute("wc-take-r2", true)
    for _, modifier in ipairs(]] .. MODIFIERS_LUA .. [[) do
        self:SetBindingClick(true, modifier .. "PAD2", "WCWheelClose", "LeftButton")
        -- the d-pad is left alone: it keeps its bar actions, so another
        -- wheel's button opens that wheel from inside this one
        for _, key in ipairs(newtable("PADRSTICKUP", "PADRSTICKDOWN", "PADRSTICKLEFT", "PADRSTICKRIGHT")) do
            self:SetBindingClick(true, modifier .. key, "WCWheelAim", key)
        end
        self:SetBinding(true, modifier .. "PADLSTICKUP", "MOVEFORWARD")
        self:SetBinding(true, modifier .. "PADLSTICKDOWN", "MOVEBACKWARD")
        self:SetBinding(true, modifier .. "PADLSTICKLEFT", "STRAFELEFT")
        self:SetBinding(true, modifier .. "PADLSTICKRIGHT", "STRAFERIGHT")
    end
]])
SecureHandlerWrapScript(ring, "OnHide", ring, [[
    self:ClearBindings()
    self:SetAttribute("wc-waiting", nil)
    self:SetAttribute("wc-aimed", nil)
    self:RunAttribute("wc-forget")
]])

-- Out of combat a held R2 is taken as soon as it is let go, not only at the
-- next stick or d-pad press.
local takeWatch = CreateFrame("Frame", nil, ring)
takeWatch:SetScript("OnUpdate", function()
    if ring:GetAttribute("wc-waiting") and not InCombatLockdown() then
        SecureHandlerExecute(ring, [[ self:RunAttribute("wc-take-r2") ]])
    end
end)

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
ring:HookScript("OnShow", function()
    local key = ring:GetAttribute("wc-active")
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
        return { type = "item", attr = "item", value = "item:" .. id,
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

local function ButtonIndex(binding)
    local index = C_GamePad.ButtonBindingToIndex(binding)
    return index and index + 1 -- GetGamePadState().buttons counts from 1
end

function W.Rebuild(quiet)
    if InCombatLockdown() then
        pending = true
        return false
    end
    pending = false
    ring:SetAttribute("wc-stick", 2) -- the right stick (StickConfigNameToIndex is absent here)
    ring:SetAttribute("wc-btn-r2", ButtonIndex("PADRTRIGGER"))
    use:SetAttribute("wc-keydown", GetCVarSafe("ActionButtonUseKeyDown") == "0" and 0 or 1)
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
