-- Font trial (tools/fonttrial/fonttrial.py): each clock second, load that
-- second's font from the bank and read its 512 bytes from the letter widths.
-- It only reads and counts, beside the channel: no slot, no bell, no message.
-- Results in WowCompanionFontTrialDB, written at a reload.
local TRIAL_END = 0
local BANK = 0
local DIR = "Interface\\AddOns\\WowCompanion_FontTrial\\"
local RESET = "Fonts\\FRIZQT__.TTF"
local BYTES, PER_FRAME = 512, 64

-- the game loads a font only for text it lays out: on screen, invisible. Off
-- screen it never loaded (the first trial, 2026-11-11)
local frame = CreateFrame("Frame", nil, UIParent)
local meter = UIParent:CreateFontString(nil, "OVERLAY")
meter:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
meter:SetAlpha(0)
meter:SetWordWrap(false)
meter:SetFont(RESET, 64, "")

local db, reading
local nextRead, misses = 0, 0

local function width(text)
    meter:SetText(text .. "~")
    return meter:GetUnboundedStringWidth()
end

local function glyph(i)
    local code = 0xE000 + i
    return string.char(224 + math.floor(code / 4096), 128 + math.floor(code / 64) % 64, 128 + code % 64)
end

local function expected(second, i)
    if i < 4 then return ("WCF1"):byte(i + 1) end
    if i < 8 then return math.floor(second / 256 ^ (7 - i)) % 256 end
    return (second * 31 + i * 7) % 256
end

local function finish(outcome, errors)
    local r = reading
    reading = nil
    meter:SetFont(RESET, 64, "")
    db.counts[outcome] = (db.counts[outcome] or 0) + 1
    misses = (outcome == "ok" or outcome == "errors") and 0 or misses + 1
    local entry = string.format("%s %d %s load %.0fms tries %d read %.1fms frames %d errors %d maxdev %.3f",
        date("%H:%M:%S"), r.second, outcome, r.loadMs or -1, r.tries or 0, r.readMs or -1, r.frames, errors or 0, r.maxDev)
    table.insert(db.recent, 1, entry)
    db.recent[31] = nil
    if r.readMs then
        db.readMs = db.readMs + r.readMs
        db.read = db.read + 1
    end
    db.maxDev = math.max(db.maxDev, r.maxDev)
    db.last = time()
    -- the writer stopped: ask once a minute, not every second
    if misses >= 3 then nextRead = time() + 60 end
end

local function step()
    local now = time()
    if not reading then
        if now >= TRIAL_END or now < nextRead then return end
        nextRead = now + 1
        reading = { second = now, start = debugprofilestop(), frames = 0, index = 0, errors = 0, maxDev = 0 }
        reading.path = DIR .. string.format("f%05d.ttf", now % BANK)
        db.first = db.first or now
        return
    end
    local r = reading
    r.frames = r.frames + 1
    if not r.range then
        -- SetFont answers false while the file loads, and true once it has
        -- (measured: the second call, a frame or more later)
        r.tries = (r.tries or 0) + 1
        if not meter:SetFont(r.path, 64, "") then
            width("!")
            if debugprofilestop() - r.start > 8000 then finish("noload") end
            return
        end
        local low, high = width("!"), width('"')
        if high - low < 100 then finish("refused") return end
        r.low, r.range = low, high - low
        r.loadMs = debugprofilestop() - r.start
        r.readStart = debugprofilestop()
    end
    for _ = 1, PER_FRAME do
        local i = r.index
        local value = (width(glyph(i)) - r.low) * 255 / r.range
        local rounded = math.floor(value + 0.5)
        r.maxDev = math.max(r.maxDev, math.abs(value - rounded))
        if rounded ~= expected(r.second, i) then r.errors = r.errors + 1 end
        r.index = i + 1
        if r.index == BYTES then
            r.readMs = debugprofilestop() - r.readStart
            -- all zero bytes is the blank: written late, or not at all
            if r.errors == 0 then finish("ok")
            elseif r.errors >= BYTES - 16 then finish("blank", r.errors)
            else finish("errors", r.errors) end
            return
        end
    end
end

frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, _, name)
    if name ~= "WowCompanion_FontTrial" then return end
    self:UnregisterEvent("ADDON_LOADED")
    WowCompanionFontTrialDB = WowCompanionFontTrialDB or {}
    db = WowCompanionFontTrialDB
    db.counts = db.counts or {}
    db.recent = db.recent or {}
    db.readMs, db.read, db.maxDev = db.readMs or 0, db.read or 0, db.maxDev or 0
    db.loads = (db.loads or 0) + 1
    local shown
    self:SetScript("OnUpdate", function()
        local ok, err = pcall(step)
        if not ok and not shown then
            shown = true
            db.error = tostring(err)
            print("|cffff6060font trial:|r " .. tostring(err))
        end
    end)
end)
