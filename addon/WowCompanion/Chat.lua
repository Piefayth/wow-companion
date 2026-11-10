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
local preview
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

	local send = CreateFrame("Button", "WowCompanionPreviewSend", frame,
		"SecureActionButtonTemplate, UIPanelButtonTemplate")
	send:SetSize(130, 26)
	send:SetPoint("BOTTOMRIGHT", -22, 18)
	send:SetText("Send")
	send:SetAttribute("type", "macro")
	send:RegisterForClicks("AnyDown") -- the only edge that runs the macro once
	send:SetScript("PostClick", function()
		-- not "Sent": the press is all we know here. Macro chat is restricted only
		-- during instance encounters (ChatConstants, RestrictedForMacroChatMessages).
		-- A Battle.net whisper to an offline friend fails without a chat line, so
		-- that one is reported from BN_CHAT_WHISPER_UNDELIVERABLE below.
		toast("|cffffd100Pressed|r  check chat to see it went out", 0.8, 0.8, 0.8, 4)
		frame:Hide()
	end)
	frame.send = send

	-- the edit path is the voice: the preview cannot tell the PC anything, but
	-- the PC remembers the line it put here
	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("BOTTOMLEFT", 22, 22)
	hint:SetText("To change it: \"edit, ...\"")

	local cancel = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	cancel:SetSize(110, 26)
	cancel:SetPoint("RIGHT", send, "LEFT", -10, 0)
	cancel:SetText("Don't send")
	cancel:SetScript("OnClick", function() frame:Hide() end)

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)
	close:SetScript("OnClick", function() frame:Hide() end)
	-- circle closes a focused window by clicking this (SmartNavigation:AttemptClose)
	frame.CloseButton = close

	if SmartNavigation_MarkFrameFocusable then
		pcall(SmartNavigation_MarkFrameFocusable, frame)
		pcall(SmartNavigation_MarkFrameFocusable, send)
		pcall(SmartNavigation_MarkFrameFocusable, cancel)
	end
	if UIPanelWindows then
		UIPanelWindows["WowCompanionPreview"] = { area = "center", pushable = 0, whileDead = 1, allowOtherPanels = 1 }
	end
	frame:SetScript("OnHide", function(self)
		if GamepadMode and GamepadMode.FrameControlsManager
			and InputUtil and InputUtil.IsGamepadUIEnabled() then
			GamepadMode.FrameControlsManager:FrameHidden(self)
		end
	end)
	return frame
end

-- line is the full slash line ("/w Name text"); heading says where it goes
local function showPreview(line, heading, shown)
	if InCombatLockdown() then return false end -- a secure button cannot be set in combat
	preview = preview or buildPreview()
	if not preview then return false end
	preview.title:SetText(heading)
	preview.body:SetText(shown)
	-- in the channel's own chat colour, read from Blizzard's ChatTypeInfo (the
	-- player's colour settings), so guild is guild green, raid is raid orange
	local slash = line:match("^(/%w+)")
	local chatType = PREVIEW_CHAT_TYPES[slash]
	if slash == "/w" and line:find("|K", 1, true) then chatType = "BN_WHISPER" end
	local info = chatType and ChatTypeInfo and ChatTypeInfo[chatType]
	local r, g, b = 1, 1, 1
	if info and info.r then r, g, b = info.r, info.g, info.b end
	preview.title:SetTextColor(r, g, b)
	preview.body:SetTextColor(r, g, b)
	preview.send:SetAttribute("macrotext", line)
	if UIPanelWindows and UIPanelWindows["WowCompanionPreview"] then
		ShowUIPanel(preview)
	end
	if not preview:IsShown() then preview:Show() end
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
		if SmartNavigation_MarkFrameFocusable then pcall(SmartNavigation_MarkFrameFocusable, b) end
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

	if SmartNavigation_MarkFrameFocusable then pcall(SmartNavigation_MarkFrameFocusable, frame) end
	if UIPanelWindows then
		UIPanelWindows["WowCompanionItemView"] = { area = "center", pushable = 0, whileDead = 1, allowOtherPanels = 1 }
	end
	frame:SetScript("OnHide", function(self)
		self.tip:Hide()
		if GamepadMode and GamepadMode.FrameControlsManager
			and InputUtil and InputUtil.IsGamepadUIEnabled() then
			GamepadMode.FrameControlsManager:FrameHidden(self)
		end
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
