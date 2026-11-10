-- Is the companion on the PC up? Shown the way addons show themselves: a button
-- on the minimap's rim, and an entry in the minimap's addon drawer (the one a
-- controller can reach). Either opens the companion window. The button is in
-- full colour while the companion can hear the player, and greyed with a red
-- edge when it cannot, so nobody talks into a companion that is not running.
--
-- How it knows: the companion keeps one of two silent bells present while it can
-- hear the player and swaps which one every 4 seconds (src/heartbeat.rs). A swap
-- seen recently means up. No swap for 12 seconds, or neither bell, means down: a
-- crashed companion stops swapping, and a closed one removes both.
--
-- Our own frames only. Parented to the minimap, as every minimap button is, but
-- nothing of Blizzard's is shown, hidden, moved or set; no secure code.

local SIGNALS = "Interface\\AddOns\\WowCompanion\\Signals\\"
local BELLS = { SIGNALS .. "alive-a.wav", SIGNALS .. "alive-b.wav" }
local STALE = 12
local ICON = "Interface\\Icons\\UI_Chat"

local up = false

local function openWindow()
	if SlashCmdList and SlashCmdList.WOWCOMPANION then
		SlashCmdList.WOWCOMPANION("log")
	end
end

local function describe(tooltip)
	tooltip:AddLine("WoW Companion")
	if up then
		tooltip:AddLine("Listening: hold minus to talk.", 0.4, 0.9, 0.4)
	else
		tooltip:AddLine("Off: the companion on your PC is not running, or is restarting.", 1, 0.4, 0.4)
	end
	tooltip:AddLine("Click to open the companion window.", 0.8, 0.8, 0.8)
end

-- the addon drawer (## AddonCompartmentFunc in the .toc): reachable by controller
function WowCompanion_OnCompartmentClick()
	openWindow()
end

function WowCompanion_OnCompartmentEnter(_, button)
	GameTooltip:SetOwner(button, "ANCHOR_LEFT")
	describe(GameTooltip)
	GameTooltip:Show()
end

function WowCompanion_OnCompartmentLeave()
	GameTooltip:Hide()
end

-- the minimap button
local button = CreateFrame("Button", "WowCompanionMinimapButton", Minimap)
button:SetSize(31, 31)
button:SetFrameStrata("MEDIUM")
button:SetFrameLevel(8)
button:RegisterForClicks("AnyUp")
button:RegisterForDrag("LeftButton")
button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local background = button:CreateTexture(nil, "BACKGROUND")
background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
background:SetSize(20, 20)
background:SetPoint("TOPLEFT", 7, -5)

local icon = button:CreateTexture(nil, "ARTWORK")
icon:SetTexture(ICON)
icon:SetSize(20, 20)
icon:SetPoint("TOPLEFT", 7, -5)

local border = button:CreateTexture(nil, "OVERLAY")
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
border:SetSize(53, 53)
border:SetPoint("TOPLEFT")

local function place()
	local angle = math.rad((WowCompanionDB and WowCompanionDB.minimapAngle) or 200)
	local radius = (Minimap:GetWidth() / 2) + 5
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

button:SetScript("OnDragStart", function(self)
	self:SetScript("OnUpdate", function()
		local x, y = GetCursorPosition()
		local scale = Minimap:GetEffectiveScale()
		local cx, cy = Minimap:GetCenter()
		local angle = math.deg(math.atan2(y / scale - cy, x / scale - cx))
		if WowCompanionDB then
			WowCompanionDB.minimapAngle = angle
		end
		place()
	end)
end)
button:SetScript("OnDragStop", function(self)
	self:SetScript("OnUpdate", nil)
end)
button:SetScript("OnClick", openWindow)
button:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	describe(GameTooltip)
	GameTooltip:Show()
end)
button:SetScript("OnLeave", function()
	GameTooltip:Hide()
end)

local function show(isUp)
	up = isUp
	icon:SetDesaturated(not isUp)
	if isUp then
		border:SetVertexColor(1, 1, 1)
		icon:SetVertexColor(1, 1, 1)
	else
		border:SetVertexColor(1, 0.25, 0.25)
		icon:SetVertexColor(0.8, 0.5, 0.5)
	end
end

-- the heartbeat
local present = { false, false }
local lastSeen = nil
local swappedAt = nil

local function decide()
	local which = present[1] and 1 or (present[2] and 2) or nil
	if which and lastSeen and which ~= lastSeen then
		swappedAt = GetTime()
	end
	if which then
		lastSeen = which
	end
	show(which ~= nil and swappedAt ~= nil and GetTime() - swappedAt < STALE)
end

local function check(index)
	local ok, _, handle = pcall(PlaySoundFile, BELLS[index], "Master")
	if not ok then
		present[index] = false
		return
	end
	C_Timer.After(0.15, function()
		local playing = handle ~= nil and C_Sound.IsPlaying(handle)
		if handle then
			StopSound(handle)
		end
		present[index] = playing and true or false
	end)
end

-- OnUpdate on a frame of our own, not a ticker: it keeps running whatever an
-- earlier frame did
local watcher = CreateFrame("Frame")
local since = 0
watcher:SetScript("OnUpdate", function(_, elapsed)
	since = since + elapsed
	if since < 1 then
		return
	end
	since = 0
	pcall(check, 1)
	pcall(check, 2)
	pcall(decide)
end)

-- the saved angle is only known once SavedVariables load
watcher:RegisterEvent("PLAYER_LOGIN")
watcher:SetScript("OnEvent", function()
	pcall(place)
end)

place()
show(false)
