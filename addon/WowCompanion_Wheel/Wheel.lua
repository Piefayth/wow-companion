-- Radial wheels of the player's own, each opened by a bar slot whose macro is
-- "/click WCWheel_<name> Macro" (WCWheel.Macro(name) gives the line).
-- Right stick points and letting it go uses; R2 uses; the d-pad keeps its bar actions;
-- Circle closes; the left stick
-- still walks. Every button is secure, so a wheel works in combat; what is on
-- it is rebuilt out of combat only.
--
-- The ring (its secure snippets, the stick capture, the axis CVar dance) is
-- adapted from Improved Forever's Ring.lua by markg, MIT licence, see
-- LICENSE-ImprovedForever. What is left out: its built-in wheels, its editor,
-- its R3 combos, pages, and everything it needed its core for.
--
-- Configured by the companion agent, in Lua, out of combat:
--   WCWheel.Set("travel", { label = "Travel", slots = {
--       { spell = "<a spell the character knows>" }, { item = 6948 }, { macro = "Ping" },
--       { emote = "WAVE" }, { macrotext = "/sit", label = "Sit", icon = 134400 } } })
--   WCWheel.Remove("travel")   WCWheel.List()
-- No wheel ships: a character starts with none, and each is made on request
-- from what that character has.
-- A slot may carry `label` and `icon` to override what is looked up.
-- A slot { rule = "items" } or { rule = "quest" } fills itself from the bags.

WCWheel = WCWheel or {}
WC.Wheel = WCWheel
local W = WCWheel

local MAX_SLOTS = 8
local WHEEL_WIDTH, WHEEL_HEIGHT = 540, 541 -- Forever's GamepadRadial, measured by Improved Forever
local SLOT_RADIUS = 150
local ICON_SIZE = 45 -- Blizzard's segment icon size
local PICK_LENGTH_SQ = 0.25
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
ring:SetSize(WHEEL_WIDTH, WHEEL_HEIGHT)
ring:SetPoint("CENTER", UIParent, "CENTER", 312, 10) -- where the native radial sits
ring:SetFrameStrata("DIALOG")
ring:Hide()

-- While the ring is up this child takes the sticks, so the right stick aims
-- without turning the camera; the left one walks through bindings instead
-- (its directions arrive as keys, GamePadStickAxisButtons).
local stickCapture = CreateFrame("Frame", nil, ring)
stickCapture:SetAllPoints(ring)
if stickCapture.EnableGamePadStick then
    stickCapture:EnableGamePadStick(true)
    stickCapture:SetScript("OnGamePadStick", function() end)
end

-- After the ring closes the right stick is often still pushed: keep the
-- sticks a moment so the camera does not swing round.
local RELEASE_SQ, RELEASE_MAX = 0.04, 0.5
local afterCapture = CreateFrame("Frame", nil, UIParent)
afterCapture:SetAllPoints(UIParent)
afterCapture:SetFrameStrata("DIALOG")
afterCapture:Hide()
if afterCapture.EnableGamePadStick then
    afterCapture:EnableGamePadStick(true)
    afterCapture:SetScript("OnGamePadStick", function() end)
end

local function Sticks()
    local state = C_GamePad.GetDeviceMappedState(C_GamePad.GetActiveDeviceID())
    return state and state.sticks
end

local function AimStick()
    local sticks = Sticks()
    local stick = sticks and sticks[ring:GetAttribute("wc-stick") or 2]
    if stick and stick.x and stick.y then return stick.x, stick.y end
end

afterCapture:SetScript("OnUpdate", function(self, elapsed)
    self.held = (self.held or 0) + elapsed
    local x, y = AimStick()
    if self.held >= RELEASE_MAX or not x or x * x + y * y <= RELEASE_SQ then self:Hide() end
end)
ring:HookScript("OnHide", function()
    local x, y = AimStick()
    if x and x * x + y * y > RELEASE_SQ then
        afterCapture.held = 0
        afterCapture:Show()
    end
end)
ring:HookScript("OnShow", function() afterCapture:Hide() end)

local function SecureButton(name)
    local button = CreateFrame("Button", name, UIParent, "SecureActionButtonTemplate,SecureHandlerBaseTemplate")
    button:SetSize(1, 1)
    button:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -20, 20)
    SecureHandlerSetFrameRef(button, "ring", ring)
    return button
end

-- The slot the right stick points at, or nil when it is not past `needed`.
ring:SetAttribute("wc-pick", [[
    local needed = ...
    local state = GetGamePadState()
    local sticks = state and state.sticks
    local stick = sticks and sticks[self:GetAttribute("wc-stick") or 2]
    if not (stick and stick.x and stick.y) then return nil end
    if stick.x * stick.x + stick.y * stick.y < needed then return nil end
    local key = self:GetAttribute("wc-active")
    local best, bestDot
    for index = 1, self:GetAttribute(key .. "-count") or 0 do
        local dot = stick.x * self:GetAttribute(key .. "-dx-" .. index) + stick.y * self:GetAttribute(key .. "-dy-" .. index)
        if not bestDot or dot > bestDot then best, bestDot = index, dot end
    end
    return best
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
-- stick is let go. A direction key going up while the stick is still pushed
-- is the stick turning (up to up-right, say), not a release, so it only moves
-- the pick. The action runs on the up edge, hence useOnKeyDown false.
local aim = SecureButton("WCWheelAim")
aim:RegisterForClicks("AnyDown", "AnyUp")
aim:SetAttribute("useOnKeyDown", false)
SecureHandlerWrapScript(aim, "OnClick", aim, [[
    self:SetAttribute("type", nil)
    local ring = self:GetFrameRef("ring")
    ring:RunAttribute("wc-take-r2")
    if not ring:IsShown() then return false end
    -- On the up edge only a stick still pushed well out is a turn between
    -- directions; at 0.5 a normal release, read as the key lets go near that
    -- same threshold, was taken for a turn and nothing was used.
    local pick = ring:RunAttribute("wc-pick", down and 0.12 or 0.8)
    -- A fast flick can be over before the stick state shows it: the key goes
    -- down while GetGamePadState still reads the centre, and nothing was aimed,
    -- so the release did nothing. The key itself names a direction; aim there.
    if down and not pick then
        local dx, dy = 0, 0
        if button == "PADRSTICKUP" then dy = 1 elseif button == "PADRSTICKDOWN" then dy = -1
        elseif button == "PADRSTICKLEFT" then dx = -1 elseif button == "PADRSTICKRIGHT" then dx = 1 end
        local key = ring:GetAttribute("wc-active")
        local bestDot
        for index = 1, ring:GetAttribute(key .. "-count") or 0 do
            local dot = dx * ring:GetAttribute(key .. "-dx-" .. index) + dy * ring:GetAttribute(key .. "-dy-" .. index)
            if not bestDot or dot > bestDot then pick, bestDot = index, dot end
        end
    end
    if pick then
        ring:SetAttribute("wc-sticky", pick)
        ring:SetAttribute("wc-aimed", true)
        return false
    end
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
    local pick = ring:RunAttribute("wc-pick", 0.25) or ring:GetAttribute("wc-sticky")
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

---------------------------------------------------------------------------
-- Visuals (Forever's native radial art)
---------------------------------------------------------------------------

local function Atlas(texture, atlas, fallback)
    if C_Texture.GetAtlasInfo(atlas) then
        texture:SetAtlas(atlas)
    elseif fallback then
        texture:SetColorTexture(unpack(fallback))
    end
end

local bg = ring:CreateTexture(nil, "OVERLAY", nil, -3)
bg:SetPoint("CENTER")
bg:SetSize(WHEEL_WIDTH, WHEEL_HEIGHT)
Atlas(bg, "gamepad-radial-menu-wheelbg", { 0, 0, 0, 0.6 })

local highlight = ring:CreateTexture(nil, "OVERLAY", nil, -2)
highlight:SetSize(169, 165)
Atlas(highlight, "gamepad-radial-menu-selected", { 1, 0.82, 0, 0.25 })
highlight:Hide()

local header = ring:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
header:SetPoint("BOTTOM", ring, "TOP", 0, 40)
local headerBar = ring:CreateTexture(nil, "OVERLAY", nil, -2)
headerBar:SetSize(487, 75)
headerBar:SetPoint("TOP", header, "BOTTOM", 0, 4)
Atlas(headerBar, "gamepad-radial-menu-toptext")

local footerBar = ring:CreateTexture(nil, "OVERLAY", nil, -1)
footerBar:SetSize(570, 151)
footerBar:SetPoint("CENTER", ring, "BOTTOM", 0, -30)
Atlas(footerBar, "gamepad-radial-menu-bottomtext")
local selected = ring:CreateFontString(nil, "OVERLAY", "GameFontNormal")
selected:SetPoint("CENTER", footerBar, "CENTER", 0, 14)
local prompts = ring:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
prompts:SetPoint("TOP", selected, "BOTTOM", 0, -6)
prompts:SetText("Release stick or R2 Use      Circle Close")

local slots = {}
for index = 1, MAX_SLOTS do
    local slot = {}
    slot.icon = ring:CreateTexture(nil, "OVERLAY")
    slot.icon:SetSize(ICON_SIZE, ICON_SIZE)
    -- round: Blizzard's portrait circle mask, clamped to black outside so
    -- nothing past the circle shows (Blizzard_ArtifactPowerButton.xml does
    -- exactly this). The CircleMask atlas without the clamp cut corners off
    -- instead of rounding them. A drop shadow sits behind.
    local mask = ring:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetPoint("TOPLEFT", slot.icon, "TOPLEFT", 3, -3)
    mask:SetPoint("BOTTOMRIGHT", slot.icon, "BOTTOMRIGHT", -3, 3)
    slot.icon:AddMaskTexture(mask)
    -- the gamepad bar's own round frame over the masked icon, the same size as
    -- the icon (ActionBarButton.lua: SetNormalAtlas on a button the icon fills)
    slot.border = ring:CreateTexture(nil, "OVERLAY", nil, 2)
    Atlas(slot.border, "gamepad-actionbar-circleslot-border-normal")
    slot.border:SetAllPoints(slot.icon)
    slot.shadow = ring:CreateTexture(nil, "OVERLAY", nil, -1)
    Atlas(slot.shadow, "gamepad-actionbar-circleslot-dropshadow")
    slot.shadow:SetPoint("TOPLEFT", slot.icon, "TOPLEFT", -4, 4)
    slot.shadow:SetPoint("BOTTOMRIGHT", slot.icon, "BOTTOMRIGHT", 4, -4)
    slot.label = ring:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    slot.label:SetSize(80, 40)
    slot.label:SetWordWrap(true)
    -- two lines at most, ending in "..." past that: a long name wrapped on and
    -- spilled out of its triangle
    slot.label:SetMaxLines(2)
    slot.label:SetJustifyH("CENTER")
    slot.label:SetJustifyV("MIDDLE")
    slots[index] = slot
end

-- Slot i sits in the art's segment i: the native wheel is always eight
-- triangles centred on the cardinals and diagonals (GamepadRadial.xml), so a
-- wheel of three still uses three of the eight, starting at the top and going
-- clockwise. Spreading n slots evenly put icons across the triangle edges.
local function Direction(index)
    local angle = math.pi / 2 - (index - 1) * math.pi / 4
    return math.cos(angle), math.sin(angle), angle
end

local function LayOut(entries)
    for index, slot in ipairs(slots) do
        local entry = entries[index]
        if entry then
            local dx, dy = entry.dx, entry.dy
            -- Blizzard draws a segment's icon 20 in from its centre (GetIconOffset)
            local reach = SLOT_RADIUS - 20
            slot.icon:SetPoint("CENTER", ring, "CENTER", dx * reach, dy * reach)
            slot.icon:SetTexture(entry.icon or 134400)
            -- and its label outward from the icon, in an 80x40 box that wraps
            -- (textAnchorData, GamepadRadial.xml): 60 out on a cardinal,
            -- (30, 45) on a diagonal, which keeps it inside the triangle
            local lx, ly
            if math.abs(dx) < 0.1 then lx, ly = 0, dy > 0 and 60 or -60
            elseif math.abs(dy) < 0.1 then lx, ly = dx > 0 and 60 or -60, 0
            else lx, ly = dx > 0 and 30 or -30, dy > 0 and 45 or -45 end
            slot.label:ClearAllPoints()
            slot.label:SetPoint("CENTER", slot.icon, "CENTER", lx, ly)
            slot.label:SetText(entry.label)
            slot.icon:Show()
            slot.shadow:Show()
            slot.border:Show()
            slot.label:Show()
        else
            slot.icon:Hide()
            slot.shadow:Hide()
            slot.border:Hide()
            slot.label:Hide()
        end
    end
end

local lit
local function Highlight(pick, entries)
    lit = pick
    local entry = pick and entries[pick]
    if entry then
        highlight:ClearAllPoints()
        highlight:SetPoint("CENTER", ring, "CENTER", entry.dx * SLOT_RADIUS, entry.dy * SLOT_RADIUS)
        highlight:SetRotation(entry.angle + math.pi / 2)
        highlight:Show()
        selected:SetText(entry.label)
    else
        highlight:Hide()
        selected:SetText("")
    end
    for index, slot in ipairs(slots) do
        if index == pick then slot.label:SetTextColor(1, 1, 1) else slot.label:SetTextColor(1, 0.82, 0) end
        -- the picked one wears the bar's "selected" frame, as a focused button does
        Atlas(slot.border, index == pick and "gamepad-actionbar-circleslot-border-selected"
            or "gamepad-actionbar-circleslot-border-normal")
    end
end

local function StickPick(entries)
    local x, y = AimStick()
    if not x or x * x + y * y < PICK_LENGTH_SQ then return nil end
    local best, bestDot
    for index, entry in ipairs(entries) do
        local dot = x * entry.dx + y * entry.dy
        if not bestDot or dot > bestDot then best, bestDot = index, dot end
    end
    return best
end

ring:SetScript("OnUpdate", function()
    local entries = ringData[ring:GetAttribute("wc-active")] or {}
    local pick = StickPick(entries) or ring:GetAttribute("wc-sticky")
    if pick ~= lit then Highlight(pick, entries) end
end)
ring:HookScript("OnShow", function()
    local key = ring:GetAttribute("wc-active")
    local wheel = WowCompanionWheelDB.wheels[key]
    header:SetText(wheel and wheel.label or key)
    local entries = ringData[key] or {}
    LayOut(entries)
    lit = false
    Highlight(nil, entries)
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
            entry.dx, entry.dy, entry.angle = Direction(index, #entries)
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
