-- The bridge probe (docs/proposals/bridge-probe.md, approved by the player
-- 2026-11-11): measures two possible channels beside today's, changing nothing
-- in it. Runs by itself at login; nothing on screen, nothing in chat, nothing
-- bound. Everything goes to WowCompanionLinkDB.bridgeProbe, read after a reload.
--   .log   game to PC: what each C_Log call returned (section 1)
--   .font  PC to game: fonts written after launch, their letter widths (section 2)
--   .strip the strip's drawing time (section 3; recorded by Strip.lua)
do
	local function db()
		WowCompanionLinkDB = WowCompanionLinkDB or {}
		local p = WowCompanionLinkDB.bridgeProbe or {}
		WowCompanionLinkDB.bridgeProbe = p
		p.log, p.font, p.strip = p.log or {}, p.font or {}, p.strip or {}
		return p
	end
	local function keep(list, entry, most)
		list[#list + 1] = entry
		while #list > most do table.remove(list, 1) end
	end

	-- Section 1. Each line is "WCPROBE log <seq> <len> <text>"; text is len bytes,
	-- byte i being ALNUM's ((i - 1) % 62 + 1)th letter, so the PC can check every
	-- byte and see where a cut line ends.
	local ALNUM = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
	local LENS = { 16, 256, 1024, 4096, 16384 }
	local function pattern(len)
		local whole = ALNUM:rep(math.ceil(len / #ALNUM))
		return whole:sub(1, len)
	end
	local function logLine(fn, name, seq, len)
		local line = ("WCPROBE log %d %d %s"):format(seq, len, pattern(len))
		local ok, result = pcall(fn, line)
		keep(db().log, { seq = seq, len = len, via = name, at = date("%H:%M:%S"), t = GetTime(),
			ok = ok, result = tostring(result) }, 60)
	end
	local function startLog()
		if not (C_Log and C_Log.LogMessage) then
			keep(db().log, { error = "no C_Log.LogMessage" }, 60)
			return
		end
		local seq = 0
		local ticker
		ticker = C_Timer.NewTicker(2, function()
			seq = seq + 1
			logLine(C_Log.LogMessage, "LogMessage", seq, LENS[(seq - 1) % #LENS + 1])
			if seq >= 30 then ticker:Cancel() end -- 60 s
		end)
		-- once each through the other two
		C_Timer.After(1, function()
			if C_Log.LogErrorMessage then logLine(C_Log.LogErrorMessage, "LogErrorMessage", 1001, 256) end
			if C_Log.LogWarningMessage then logLine(C_Log.LogWarningMessage, "LogWarningMessage", 1002, 256) end
		end)
	end

	-- Section 2. A FontString of ours on a frame shown at alpha 0 (measured text
	-- needs no visible pixels); every second it tries the next font file.
	local DIR = [[Interface\AddOns\WowCompanion\Probe\]]
	local CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local MAX_FONTS = 5
	local function startFont()
		local holder = _G["WCBridgeProbeFont"] or CreateFrame("Frame", "WCBridgeProbeFont", UIParent)
		holder:SetSize(1, 1)
		holder:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
		holder:SetAlpha(0)
		holder:Show()
		local fs = holder.fs or holder:CreateFontString(nil, "ARTWORK")
		holder.fs = fs
		local nextFont, tries, started = 1, 0, GetTime()
		local ticker
		ticker = C_Timer.NewTicker(1, function()
			tries = tries + 1
			local path = DIR .. "f" .. nextFont .. ".ttf"
			local ok, loaded = pcall(fs.SetFont, fs, path, 64, "")
			if not (ok and loaded) then return end
			local widths = {}
			for i = 1, #CHARS do
				fs:SetText(CHARS:sub(i, i))
				widths[i] = fs:GetStringWidth()
			end
			fs:SetText("")
			keep(db().font, { n = nextFont, widths = widths, chars = CHARS, uiScale = UIParent:GetEffectiveScale(),
				at = date("%H:%M:%S"), sinceStart = GetTime() - started, tries = tries }, 20)
			nextFont, tries = nextFont + 1, 0
			if nextFont > MAX_FONTS then ticker:Cancel() end
		end)
	end

	local boot = CreateFrame("Frame")
	boot:RegisterEvent("PLAYER_LOGIN")
	boot:SetScript("OnEvent", function()
		db().session = date("%Y-%m-%d %H:%M:%S")
		startLog()
		startFont()
	end)
end
