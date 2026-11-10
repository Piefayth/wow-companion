-- Is the companion on the PC up? A small mark, so the player never talks into a
-- companion that is not running.
--
-- The companion keeps one of two silent bells present while it can hear the
-- player, and swaps which one every 4 seconds (src/heartbeat.rs). Seeing the swap
-- recently means up. No swap for 12 seconds, or neither bell, means down: a
-- crashed companion stops swapping, and a closed one removes both.
--
-- Its own frame on UIParent, nothing of Blizzard's touched, and no secure code.

local SIGNALS = "Interface\\AddOns\\WowCompanion\\Signals\\"
local BELLS = { SIGNALS .. "alive-a.wav", SIGNALS .. "alive-b.wav" }
local STALE = 12

local mark = CreateFrame("Frame", "WowCompanionStatus", UIParent)
mark:SetSize(160, 18)
mark:SetPoint("TOP", UIParent, "TOP", 0, -2)
mark:SetFrameStrata("HIGH")
local text = mark:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
text:SetPoint("CENTER")

local present = { false, false }
local lastSeen = nil -- which bell was present at the last check
local swappedAt = nil -- GetTime() of the last swap seen

local function show(up)
	if up then
		text:SetText("|cff55dd55\226\151\143|r companion")
		mark:SetAlpha(0.55)
	else
		text:SetText("|cffff5555\226\151\143 companion off|r")
		mark:SetAlpha(1)
	end
end

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

-- OnUpdate, not a ticker: it keeps running whatever an earlier frame did
local since = 0
mark:SetScript("OnUpdate", function(_, elapsed)
	since = since + elapsed
	if since < 1 then
		return
	end
	since = 0
	pcall(check, 1)
	pcall(check, 2)
	-- judged on the results of the checks a second ago
	pcall(decide)
end)

show(false)
