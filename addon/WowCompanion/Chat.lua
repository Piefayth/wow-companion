-- Split out of Companion.lua (2026-11-10). What it needs from there comes
-- through WC.Core; what Companion.lua calls here is WC.Chat.

local core = WC.Core
local remember = core.remember
local spoken = core.spoken
local toast = core.toast

-- Whispers by the name the player knows someone by. "whisper Sage, on my way"
-- arrives as "/w Sage, on my way"; this finds who Sage is among the people the
-- game can see (Battle.net friends by BattleTag or the character they are on,
-- character friends, the guild, the group) and writes the name the way
-- Blizzard's own whisper menus do, which is the part a spoken name gets wrong:
-- names here are first and last, and UnitName gives only the first, so a
-- whisper to "Pietra" came back "no player named Pietra". The unit popup joins
-- name and surname with CHARACTERNAME_SURNAME_SEPARATOR when regional unique
-- names are on (UnitPopupUtils.lua, GetFullPlayerName); so do we.
local function plain(text)
	return (text or ""):lower():gsub("[^%w]", "")
end

-- Speech-to-text gets invented names a letter or two wrong ("Orihine" for
-- Orihime; the player, 2026-11-10), and the game is the only side that knows
-- the real spelling. Edit distance on the plain forms; close enough is about
-- one slip per three letters, and the best must be the only one that close.
local function distance(a, b)
	local prev, cur = {}, {}
	for j = 0, #b do prev[j] = j end
	for i = 1, #a do
		cur[0] = i
		local ca = a:byte(i)
		for j = 1, #b do
			local cost = (ca == b:byte(j)) and 0 or 1
			cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
		end
		prev, cur = cur, prev
	end
	return prev[#b]
end

-- spoken: what was heard; names: a list of strings; owners (optional): who each
-- name belongs to, so two names of one person never count as a tie. Returns the
-- index of the one name it most likely meant, or nil. A spoken first name matches the start
-- of a longer one ("Cecil" in "Cecil Sorrowheart").
function WowCompanion_Closest(spokenText, names, owners)
	local want = plain(spokenText)
	if want == "" then return nil end
	local best, bestD, tie = nil, math.huge, false
	for i, name in ipairs(names) do
		local have = plain(name)
		local d = distance(want, have)
		if #have > #want then d = math.min(d, distance(want, have:sub(1, #want))) end
		if d < bestD then best, bestD, tie = i, d, false
		elseif d == bestD and not (owners and owners[i] == owners[best]) then tie = true end
	end
	if best and not tie and bestD <= math.max(1, math.floor(#want / 3)) then return best end
	return nil
end

local function fullUnitName(unit)
	local name, surname = UnitName(unit)
	if not name then return nil end
	if surname and surname ~= "" then
		local seps = Constants and Constants.CharacterNameSeparatorConsts
		if RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled() and seps then
			return name .. seps.CHARACTERNAME_SURNAME_SEPARATOR .. surname
		elseif seps then
			return name .. seps.CHARACTERNAME_REALMNAME_SEPARATOR .. surname
		end
	end
	return name
end

-- every person we could mean: { keys = {...}, target = what goes after /w, label }
local function people()
	local list = {}
	local function add(target, label, ...)
		if not target or target == "" then return end
		local keys = {}
		for _, key in ipairs({ ... }) do
			key = plain(key)
			if key ~= "" then keys[#keys + 1] = key end
		end
		list[#list + 1] = { target = target, label = label, keys = keys }
	end
	-- Battle.net friends, online: their BattleTag and the character they are on
	if BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendAccountInfo then
		local count = BNGetNumFriends() or 0
		for i = 1, count do
			local ok, info = pcall(C_BattleNet.GetFriendAccountInfo, i)
			-- A Battle.net whisper cannot go out from a macro (the player,
			-- 2026-11-10): the send preview has to whisper the character the
			-- friend is on, by name and realm. Not in WoW means no whisper.
			if ok and info and info.gameAccountInfo and info.gameAccountInfo.isOnline then
				local game = info.gameAccountInfo
				local tag = info.battleTag and info.battleTag:match("^[^#]+")
				local character = game.characterName
				if character and character ~= "" and game.realmName and game.realmName ~= "" then
					local target = character
					local realm = game.realmName
					if realm and realm ~= "" and GetNormalizedRealmName and realm ~= GetNormalizedRealmName() then
						target = character .. "-" .. realm
					end
					add(target, (tag or "?") .. " (on " .. character .. ")", tag, character)
				end
			end
		end
	end
	-- character friends
	if C_FriendList and C_FriendList.GetNumFriends then
		for i = 1, C_FriendList.GetNumFriends() or 0 do
			local info = C_FriendList.GetFriendInfoByIndex(i)
			if info and info.connected and info.name then
				add(info.name, info.name, info.name, info.name:match("^[^%-%s]+"))
			end
		end
	end
	-- the guild, online
	if IsInGuild and IsInGuild() and GetNumGuildMembers then
		for i = 1, GetNumGuildMembers() or 0 do
			local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
			if name and online then
				add(name, name .. " (guild)", name, name:match("^[^%-%s]+"))
			end
		end
	end
	-- the group
	local prefix, size = IsInRaid() and "raid" or "party", IsInRaid() and GetNumGroupMembers() or GetNumSubgroupMembers()
	for i = 1, size or 0 do
		local unit = prefix .. i
		if UnitExists(unit) and UnitIsPlayer(unit) and not UnitIsUnit(unit, "player") then
			local full = fullUnitName(unit)
			add(full, full .. " (group)", full, (UnitName(unit)))
		end
	end
	return list
end

-- "/w sage on my way" -> target, message; or nil and why. Tries the first one to
-- three words as the name, longest first, so a two-word name wins over its
-- first word.
function WowCompanion_ResolveWhisper(rest)
	local words = {}
	for word in rest:gmatch("%S+") do words[#words + 1] = word end
	local everyone = people()
	for take = math.min(3, #words), 1, -1 do
		local spoken = plain(table.concat(words, " ", 1, take))
		local hits, seen = {}, {}
		for _, person in ipairs(everyone) do
			for _, key in ipairs(person.keys) do
				if key == spoken and not seen[person.target] then
					seen[person.target] = true
					hits[#hits + 1] = person
					break
				end
			end
		end
		-- several people by one name: whoever is online, else whoever has ever
		-- been seen online (a friend who never logged in has no last-online time)
		for _, keep in ipairs({ "online", "seen" }) do
			if #hits > 1 then
				local narrowed = {}
				for _, hit in ipairs(hits) do
					if hit[keep] ~= false then narrowed[#narrowed + 1] = hit end
				end
				if #narrowed >= 1 and #narrowed < #hits then hits = narrowed end
			end
		end
		if #hits == 1 then
			local message = table.concat(words, " ", take + 1):gsub("^[,:%.%-%s]+", "")
			return hits[1].target, message, hits[1].label
		elseif #hits > 1 then
			local labels = {}
			for _, hit in ipairs(hits) do labels[#labels + 1] = hit.label end
			return nil, "more than one person is called that: " .. table.concat(labels, ", ")
		end
	end
	-- nobody by that exact name: the closest one, a mis-heard letter or two away
	for take = math.min(3, #words), 1, -1 do
		local keys, owner = {}, {}
		for _, person in ipairs(everyone) do
			for _, key in ipairs(person.keys) do keys[#keys + 1] = key owner[#keys] = person end
		end
		local i = WowCompanion_Closest(table.concat(words, " ", 1, take), keys, owner)
		if i then
			local message = table.concat(words, " ", take + 1):gsub("^[,:%.%-%s]+", "")
			return owner[i].target, message, owner[i].label .. " (closest to what I heard)"
		end
	end
	local names = {}
	for i, person in ipairs(everyone) do
		if i > 12 then break end
		names[#names + 1] = person.label
	end
	return nil, "I don't see anyone called " .. (words[1] or "that") .. " online. "
		.. (#names > 0 and ("I can see: " .. table.concat(names, ", ")) or "Nobody on your friends list, guild or group is online.")
end

-- The send preview (the player, 2026-11-10). A dictated line with a channel
-- ("party, pulling now", "whisper Sage, on my way") no longer needs the chat box
-- at all: it shows here, and the Send button is a secure macro button whose
-- macro is the line itself, so the player's press is the send. Nothing of
-- Blizzard's is opened or touched, which is what broke A and B before. It opens
-- because the player just spoke a line meant to go out; nothing else opens it.
local PREVIEW_CHAT_TYPES = {
	["/p"] = "PARTY", ["/g"] = "GUILD", ["/o"] = "OFFICER", ["/raid"] = "RAID",
	["/rw"] = "RAID_WARNING", ["/i"] = "INSTANCE_CHAT", ["/s"] = "SAY", ["/y"] = "YELL",
	["/e"] = "EMOTE", ["/w"] = "WHISPER", ["/r"] = "WHISPER",
	["/1"] = "CHANNEL1", ["/2"] = "CHANNEL2", ["/4"] = "CHANNEL4",
}

-- A slash line made into what the Send press calls, or nil and why. Covers the
-- chat channels, numbered channels, whispers, /e and the built-in emotes; any
-- other slash command belongs in an offered button (a press step) instead.
local CHAT_SLASH = {
	["/g"] = "GUILD", ["/guild"] = "GUILD", ["/o"] = "OFFICER", ["/p"] = "PARTY", ["/party"] = "PARTY",
	["/raid"] = "RAID", ["/ra"] = "RAID", ["/rw"] = "RAID_WARNING", ["/i"] = "INSTANCE_CHAT",
	["/s"] = "SAY", ["/say"] = "SAY", ["/y"] = "YELL", ["/yell"] = "YELL",
	["/e"] = "EMOTE", ["/em"] = "EMOTE", ["/me"] = "EMOTE", ["/emote"] = "EMOTE",
}
local function emoteToken(slash)
	local want = slash:upper()
	local i = 1
	-- Blizzard's own list, read only (ChatFrameUtil.ImportEmoteTokensToHash)
	while i <= (MAXEMOTEINDEX or 1000) do
		local token = _G["EMOTE" .. i .. "_TOKEN"]
		if not token and not _G["EMOTE" .. i .. "_CMD1"] and i > 600 then break end
		local j = 1
		local cmd = _G["EMOTE" .. i .. "_CMD" .. j]
		while cmd do
			if token and cmd:upper() == want then return token end
			j = j + 1
			cmd = _G["EMOTE" .. i .. "_CMD" .. j]
		end
		i = i + 1
	end
end
local function parseLine(line)
	local slash, rest = line:match("^(/%S+)%s*(.*)$")
	if not slash then return nil, "not a slash line" end
	slash = slash:lower()
	local chatType = CHAT_SLASH[slash]
	if chatType then
		if rest == "" then return nil, "nothing to say" end
		return { kind = "chat", text = rest, chatType = chatType }
	end
	local number = slash:match("^/(%d+)$")
	if number then
		if rest == "" then return nil, "nothing to say" end
		return { kind = "chat", text = rest, chatType = "CHANNEL", target = tonumber(number) }
	end
	if slash == "/w" or slash == "/whisper" or slash == "/t" or slash == "/tell" then
		-- the target can be two words (first and last name): the longest known
		-- person the line starts with, else the first word
		local target
		for _, person in ipairs(people()) do
			local t = person.target
			if rest:sub(1, #t + 1):lower() == (t .. " "):lower() and (not target or #t > #target) then target = t end
		end
		target = target or rest:match("^(%S+)")
		local text = target and rest:sub(#target + 2):gsub("^%s+", "")
		if not target or text == "" then return nil, "no one to whisper, or nothing to say" end
		return { kind = "chat", text = text, chatType = "WHISPER", target = target }
	end
	local token = emoteToken(slash)
	if token then
		return { kind = "emote", token = token, target = rest ~= "" and rest or nil }
	end
	return nil, slash .. " is not a chat line"
end
-- runs on the player's press only
local function sendParsed(out)
	if not out then return false, "nothing to send" end
	if out.kind == "emote" then
		-- its return reads as success in the docs and as "restricted" in
		-- Blizzard's own caller, so it is not trusted either way
		C_ChatInfo.PerformEmote(out.token, out.target)
		return true
	end
	C_ChatInfo.SendChatMessage(out.text, out.chatType, nil, out.target)
	return true
end
local preview
local function focusTrace(what)
	pcall(function()
		local m = GamepadMode and GamepadMode.FrameControlsManager
		local d = WowCompanionDB
		d.previewFocus = d.previewFocus or {}
		local listed = false
		for _, f in ipairs(m and m.shownFrames or {}) do if f == preview then listed = true end end
		d.previewFocus[#d.previewFocus + 1] = ("%s %s | combat=%s shown=%s listed=%s focused=%s uiFocused=%s"):format(
			date("%H:%M:%S"), what, tostring(InCombatLockdown()), tostring(preview and preview:IsShown()),
			tostring(listed), tostring(m and m.focusedFrame == preview), tostring(m and m.isUIFocused))
		while #d.previewFocus > 30 do table.remove(d.previewFocus, 1) end
	end)
end
local function home(frame)
	frame:ClearAllPoints()
	frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 16, 260)
end
local function buildPreview()
	local made, frame = pcall(CreateFrame, "Frame", "WowCompanionPreview", UIParent, "BackdropTemplate")
	if not made or not frame then return nil end
	frame:SetSize(460, 150)
	frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 16, 260)
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)
	frame:Hide()
	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 22, -20)
	title:SetPoint("TOPRIGHT", -40, -20)
	title:SetJustifyH("LEFT")
	frame.title = title
	local body = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	body:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
	body:SetPoint("RIGHT", -22, 0)
	body:SetJustifyH("LEFT")
	body:SetJustifyV("TOP")
	body:SetMaxLines(4)
	frame.body = body

	-- Closing on Blizzard's own path (the player, 2026-11-10: in a fight confirm
	-- or circle must close it AND give the pad back to the bars). In combat only
	-- an untainted chain from the press may hide a focused window and hand focus
	-- back (HideUIPanel's CheckProtectedFunctionsAllowed, the wrapped
	-- FrameHidden). So the buttons that close are Blizzard's UIPanelCloseButton:
	-- confirm (SmartNavigation:Click -> PerformClick) or circle
	-- (SmartNavigation:AttemptClose finds a visible button named *CloseButton)
	-- runs UIPanelCloseButton_OnClick -> HideUIPanel(preview): with no
	-- UIPanelWindows entry that is Hide plus the manager's FrameHidden, and the
	-- bars are back. Our part runs after, in a HookScript (the send itself).
	-- Nothing of ours sits in that chain: no OnHide, no CloseButton field, no
	-- onCloseCallback, no OnSmartNavClick, no UIPanelWindows entry.
	-- With more than one line stacked, the buttons shown are plain ones that only
	-- settle the line shown; the closing pair is shown for the last line.
	local function look(b, label)
		b:SetSize(120, 24)
		b:SetNormalTexture("Interface\\Buttons\\UI-Panel-Button-Up")
		b:SetPushedTexture("Interface\\Buttons\\UI-Panel-Button-Down")
		b:SetHighlightTexture("Interface\\Buttons\\UI-Panel-Button-Highlight", "ADD")
		for _, tex in ipairs({ b:GetNormalTexture(), b:GetPushedTexture(), b:GetHighlightTexture() }) do
			tex:SetTexCoord(0, 0.625, 0, 0.6875)
		end
		local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		fs:SetPoint("CENTER")
		fs:SetText(label)
	end
	local function sendShown()
		local out = frame.out
		if not out then return end
		local ok, sent, why = pcall(sendParsed, out)
		local err = ok and why or sent
		if ok and sent then
			toast("|cffffd100Pressed|r  check chat to see it went out", 0.8, 0.8, 0.8, 4)
		else
			toast("|cffff7777Not sent|r: " .. tostring(err), 1, 0.6, 0.6, 8)
			remember("error", "The send preview could not send that: " .. tostring(err))
		end
	end
	-- the last line: these close the window. Names: Send must not match circle's
	-- "CloseButton" scan, Cancel must.
	local sendLast = CreateFrame("Button", "WowCompanionPreviewSendLast", frame, "UIPanelCloseButton")
	local cancelLast = CreateFrame("Button", "WowCompanionPreviewCancelCloseButton", frame, "UIPanelCloseButton")
	-- more lines waiting: these settle one and leave the window up
	local sendStep = CreateFrame("Button", "WowCompanionPreviewSendStep", frame)
	local cancelStep = CreateFrame("Button", "WowCompanionPreviewCancelStepCloseButton", frame)
	sendStep:RegisterForClicks("AnyUp")
	cancelStep:RegisterForClicks("AnyUp")
	look(sendLast, "Send")
	look(sendStep, "Send")
	look(cancelLast, "Don't send")
	look(cancelStep, "Don't send")
	for _, b in ipairs({ sendLast, sendStep }) do
		b:ClearAllPoints()
		b:SetPoint("BOTTOMRIGHT", -20, 16)
	end
	for _, b in ipairs({ cancelLast, cancelStep }) do
		b:ClearAllPoints()
		b:SetPoint("RIGHT", sendLast, "LEFT", -8, 0)
	end
	-- after Blizzard's own OnClick has closed the window
	sendLast:HookScript("OnClick", function()
		sendShown()
		frame.queue, frame.idx, frame.out = {}, 0, nil
		focusTrace("sent by its close button")
	end)
	cancelLast:HookScript("OnClick", function()
		frame.queue, frame.idx, frame.out = {}, 0, nil
		focusTrace("cancelled by its close button")
	end)
	sendStep:SetScript("OnClick", function() sendShown() frame.drop() end)
	cancelStep:SetScript("OnClick", function() frame.drop() end)
	frame.sendLast, frame.cancelLast, frame.sendStep, frame.cancelStep = sendLast, cancelLast, sendStep, cancelStep

	-- The stack (the player, 2026-11-10): lines spoken while one waits are kept,
	-- never replaced, shown "2 of 3"; the arrows page through.
	frame.queue, frame.idx = {}, 0
	local function arrow(dir)
		local b = CreateFrame("Button", nil, frame)
		b:SetSize(13, 20)
		b:SetNormalAtlas(dir < 0 and "common-icon-backarrow" or "common-icon-forwardarrow")
		b:SetHighlightAtlas(dir < 0 and "common-icon-backarrow" or "common-icon-forwardarrow", "ADD")
		b:RegisterForClicks("AnyDown")
		b:SetScript("OnClick", function()
			local n = #frame.queue
			if n < 2 then return end
			frame.idx = (frame.idx - 1 + dir) % n + 1
			frame.render()
		end)
		return b
	end
	frame.prev, frame.next = arrow(-1), arrow(1)
	frame.prev:SetPoint("BOTTOMLEFT", 18, 18)
	frame.next:SetPoint("LEFT", frame.prev, "RIGHT", 50, 0)
	frame.count = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	frame.count:SetPoint("LEFT", frame.prev, "RIGHT", 0, 0)
	frame.count:SetPoint("RIGHT", frame.next, "LEFT", 0, 0)
	function frame.render()
		local n = #frame.queue
		local item = frame.queue[frame.idx]
		if not item then
			frame.out = nil
			return
		end
		frame.out = item.out
		frame.title:SetText(item.heading or "")
		frame.body:SetText(item.shown or "")
		frame.title:SetTextColor(item.r, item.g, item.b)
		frame.body:SetTextColor(item.r, item.g, item.b)
		local many = n > 1
		frame.prev:SetShown(many)
		frame.next:SetShown(many)
		frame.count:SetShown(many)
		frame.count:SetText(("%d of %d"):format(frame.idx, n))
		-- the closing pair only for the last line
		frame.sendLast:SetShown(not many)
		frame.cancelLast:SetShown(not many)
		frame.sendStep:SetShown(many)
		frame.cancelStep:SetShown(many)
	end
	-- settle the line shown while others wait (never the last: that one closes
	-- through Blizzard's button)
	function frame.drop()
		table.remove(frame.queue, frame.idx)
		frame.idx = math.max(1, math.min(frame.idx, #frame.queue))
		frame.render()
	end

	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("BOTTOMLEFT", frame.next, "BOTTOMRIGHT", 12, 2)
	frame.hint = hint

	-- built on first use, which can be mid-fight: marking waits for its end
	if SmartNavigation_MarkFrameFocusable then
		for _, b in ipairs({ frame, sendLast, cancelLast, sendStep, cancelStep, frame.prev, frame.next }) do
			WC.AfterCombat(function() pcall(SmartNavigation_MarkFrameFocusable, b) end)
		end
	end
	return frame
end

-- Built at login, out of combat (focus marks are refused in a fight).
-- Listing for combat (the player, 2026-11-10: one focus, the game's own): the
-- frame manager adds no window in a fight but keeps those it has. So at the
-- fight's start the hidden preview is listed as a popup that skips auto focus:
-- the UI's focus state is left as it was, and if nothing is focused it becomes
-- the frame focused when the player next presses their focus button
-- (FrameControlsManager:FrameShown). After the fight it is delisted unless up.
-- A trace of each step: WowCompanionDB.previewFocus (30 lines).
do
	local function manager()
		local m = GamepadMode and GamepadMode.FrameControlsManager
		if m and m.FrameShown and InputUtil and InputUtil.IsGamepadUIEnabled() then return m end
	end
	local w = CreateFrame("Frame")
	w:RegisterEvent("PLAYER_LOGIN")
	w:RegisterEvent("PLAYER_REGEN_DISABLED")
	w:RegisterEvent("PLAYER_REGEN_ENABLED")
	w:SetScript("OnEvent", function(_, event)
		preview = preview or buildPreview()
		local m = manager()
		if not (preview and m) then return end
		if event == "PLAYER_REGEN_DISABLED" and not preview:IsShown() then
			preview.skipGamepadAutoFocus = true
			pcall(m.FrameShown, m, preview, true)
			focusTrace("listed at fight start")
		elseif event == "PLAYER_REGEN_ENABLED" then
			preview.skipGamepadAutoFocus = nil
			if preview:IsShown() then
				-- shown again mid-fight after one close: listed now, reachable
				pcall(m.FrameShown, m, preview)
			else
				pcall(m.FrameHidden, m, preview)
			end
			focusTrace("fight over")
		end
	end)
	-- a close by Blizzard's button, seen after its work is done
	hooksecurefunc("HideUIPanel", function(f)
		if f == preview then focusTrace("closed by HideUIPanel") end
	end)
end

-- line is the full slash line ("/w Name text"); heading says where it goes
-- Works in combat: nothing in the window is secure. Returns false and why when
-- the line is not one the Send press can send.
local showPreview
function showPreview(line, heading, shown, dictated)
	local out, why = parseLine(line or "")
	if not out then
		remember("error", "The send preview cannot send that line (" .. tostring(why) .. "). Ask for a button instead.")
		return false, why
	end
	preview = preview or buildPreview()
	if not preview then return false, "the preview window could not be made" end
	preview.dictated = dictated
	-- in the channel's own chat colour, read from Blizzard's ChatTypeInfo (the
	-- player's colour settings), so guild is guild green, raid is raid orange
	local slash = line:match("^(/%w+)")
	local chatType = PREVIEW_CHAT_TYPES[slash]
	if slash == "/w" and line:find("|K", 1, true) then chatType = "BN_WHISPER" end
	local info = chatType and ChatTypeInfo and ChatTypeInfo[chatType]
	local r, g, b = 1, 1, 1
	if info and info.r then r, g, b = info.r, info.g, info.b end
	-- stacked, never replacing what waits; the new line is the one shown
	table.insert(preview.queue, { out = out, heading = heading, shown = shown, r = r, g = g, b = b })
	preview.idx = #preview.queue
	preview.render()
	-- out of combat the manager lists and focuses it (the wrapped call); in a
	-- fight a plain Show: it was listed when the fight began, and the player's
	-- focus button reaches it
	local wasShown = preview:IsShown()
	if not wasShown then
		home(preview)
		preview:Show()
	end
	local m = GamepadMode and GamepadMode.FrameControlsManager
	if not InCombatLockdown() and m and m.FrameShown and not wasShown then pcall(m.FrameShown, m, preview) end
	if InCombatLockdown() then focusTrace("shown in combat") end
	local glyph = WowCompanion_Glyph or function(k) return k end
	preview.hint:SetText(("%s Send     %s Don't send"):format(glyph("PAD1"), glyph("PAD2")))
	return true
end
-- Blizzard's chat prints nothing when a Battle.net whisper cannot be delivered
-- (the friend is offline, or appearing offline), so say it ourselves
do
	local undeliverable = CreateFrame("Frame")
	undeliverable:RegisterEvent("BN_CHAT_WHISPER_UNDELIVERABLE")
	undeliverable:SetScript("OnEvent", function()
		toast("|cffff7777Battle.net could not deliver that whisper|r: they are offline, or appearing offline", 1, 0.6, 0.6, 10)
		remember("error", "Battle.net could not deliver that whisper: the friend is offline, or appearing offline.")
	end)
end

-- The item viewer (the player, 2026-11-10): an item someone linked, shown in a
-- window the controller can focus, closed with a button or circle, with
-- Previous / Next through the links remembered from chat (WowCompanionDB.links,
-- filled by the LinkCatcher module). The tooltip is our own GameTooltip, a
-- child of this window, so nothing of Blizzard's is shown or touched.
local viewer
local function buildViewer()
	local made, frame = pcall(CreateFrame, "Frame", "WowCompanionItemView", UIParent, "BackdropTemplate")
	if not made or not frame then return nil end
	frame:SetSize(340, 200)
	frame:SetPoint("CENTER", UIParent, "CENTER", 220, 60)
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)
	frame:Hide()
	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	local caption = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	caption:SetPoint("TOPLEFT", 20, -18)
	caption:SetPoint("TOPRIGHT", -36, -18)
	caption:SetJustifyH("LEFT")
	frame.caption = caption

	local tip = CreateFrame("GameTooltip", "WowCompanionItemViewTip", frame, "GameTooltipTemplate")
	frame.tip = tip

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)
	close:SetScript("OnClick", function() frame:Hide() end)
	frame.CloseButton = close -- circle clicks this (SmartNavigation:AttemptClose)

	local function button(label, width)
		local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		b:SetSize(width, 24)
		b:SetText(label)
		if SmartNavigation_MarkFrameFocusable then WC.AfterCombat(function() pcall(SmartNavigation_MarkFrameFocusable, b) end) end
		return b
	end
	frame.closeButton = button("Close", 90)
	frame.closeButton:SetPoint("BOTTOMRIGHT", -20, 16)
	frame.closeButton:SetScript("OnClick", function() frame:Hide() end)
	frame.nextButton = button("Older", 80)
	frame.nextButton:SetPoint("RIGHT", frame.closeButton, "LEFT", -8, 0)
	frame.nextButton:SetScript("OnClick", function() WowCompanion_ShowItem((frame.index or 1) + 1) end)
	frame.prevButton = button("Newer", 80)
	frame.prevButton:SetPoint("RIGHT", frame.nextButton, "LEFT", -8, 0)
	frame.prevButton:SetScript("OnClick", function() WowCompanion_ShowItem((frame.index or 1) - 1) end)

	if SmartNavigation_MarkFrameFocusable then WC.AfterCombat(function() pcall(SmartNavigation_MarkFrameFocusable, frame) end) end
	if UIPanelWindows then
		UIPanelWindows["WowCompanionItemView"] = { area = "center", pushable = 0, whileDead = 1, allowOtherPanels = 1 }
	end
	frame:SetScript("OnHide", function(self)
		self.tip:Hide()
		WC.FrameHidden(self)
	end)
	return frame
end

-- what: an index into the remembered links (1 = newest) or an item link
function WowCompanion_ShowItem(what)
	local links = WowCompanionDB.links or {}
	local index, entry
	if type(what) == "string" then
		entry = { link = what }
	else
		index = math.max(1, math.min(tonumber(what) or 1, #links))
		entry = links[index]
	end
	if not entry then
		remember("error", "No item link remembered yet: link one in chat, then ask again.")
		return false
	end
	viewer = viewer or buildViewer()
	if not viewer then return false end
	viewer.index = index
	viewer.caption:SetText(entry.from and ("Linked by %s in %s%s"):format(entry.from, entry.where or "chat",
		index and ("  (%d of %d)"):format(index, #links) or "") or "")
	viewer.prevButton:SetEnabled(index ~= nil and index > 1)
	viewer.nextButton:SetEnabled(index ~= nil and index < #links)
	local tip = viewer.tip
	tip:SetOwner(viewer, "ANCHOR_NONE")
	tip:ClearAllPoints()
	tip:SetPoint("TOPLEFT", viewer, "TOPLEFT", 14, -34)
	tip:SetHyperlink(entry.link)
	tip:Show()
	-- the window wraps the tooltip, with room for the caption and the buttons
	viewer:SetSize(math.max(300, tip:GetWidth() + 28), tip:GetHeight() + 34 + 52)
	if not InCombatLockdown() and UIPanelWindows and UIPanelWindows["WowCompanionItemView"] then
		ShowUIPanel(viewer)
	end
	if not viewer:IsShown() then viewer:Show() end
	return true
end

-- for agent code: show a line in the send preview (line, heading, shown text)
WowCompanion_Preview = showPreview



WC.Chat = WC.Chat or {}
WC.Chat.showPreview = showPreview
