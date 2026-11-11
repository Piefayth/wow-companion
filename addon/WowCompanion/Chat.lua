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
			-- 2026-11-10), so a line whispers the character the friend is
			-- on, by name and realm. Not in WoW means no whisper.
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

-- Lines for other players go into Blizzard's chat box, and only there (the
-- player, 2026-11-11: "just the chat box"; it replaced our send preview). A line
-- (dictated, an agent's `send` step, an agent's WowCompanion_ChatLine) goes into
-- the box the player has open. With none open it waits, and goes into the box
-- the next time they open one, oldest first, one at a time: the next goes in
-- when that one was sent or cleared and the box is opened again, so cross always
-- sends exactly what they see. Nothing here ever opens the box; our code only
-- sets the text of a box the player opened. Blizzard parses the slash prefix on
-- send. The board's Chat row says a line is waiting.
local waitingLines = {}

local function openBox()
	local get = ChatEdit_GetActiveWindow or (ChatFrameUtil and ChatFrameUtil.GetActiveWindow)
	local box = get and get()
	if box and box.HasFocus and box:HasFocus() and box:IsVisible() then return box end
end

local function boardRow()
	local n = #waitingLines
	if not WowCompanion_Recent then return end
	if n == 0 then
		WowCompanion_Recent("chat", nil)
	else
		WowCompanion_Recent("chat", n == 1 and "a line is waiting: open chat"
			or ("%d lines are waiting: open chat"):format(n), { state = "waiting", keep = true })
	end
end

local function into(box, text)
	WC.Sandbox.measureOnce("line into chat box", function() box:SetText(text) end)
	if WC.ChatChannel and WC.ChatChannel.Trace then WC.ChatChannel.Trace("into chat box", box) end
	return ("chat box holds %q"):format(box:GetText() or "")
end

-- line: the full slash line ("/p words", "/w Name words"); words: what was
-- dictated, added to a draft already in the box (nil for an agent's line, which
-- then waits rather than joining someone's draft). Returns what happened.
local function chatLine(line, words)
	line = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if line == "" then return "refused: an empty line" end
	local rest = line:match("^/w%s+(.+)") or line:match("^/whisper%s+(.+)")
	if rest then
		local target, message = WowCompanion_ResolveWhisper(rest)
		if not target then
			remember("error", "Whisper not written: " .. message .. ".")
			return "refused: " .. message
		end
		line = "/w " .. target .. " " .. message
	end
	if #line > 255 then return "refused: longer than a chat line (255)" end
	local box = openBox()
	if box and #waitingLines == 0 then
		local had = box:GetText() or ""
		if had == "" then return into(box, line) end
		if words and words ~= "" then return into(box, had .. " " .. words) end
	end
	waitingLines[#waitingLines + 1] = line
	boardRow()
	return ("waiting for the chat box: %q"):format(line)
end

-- The box opened: the oldest waiting line goes in, if the box is empty. A frame
-- later, so Blizzard finishes opening it first (the event fires before
-- ActivateChat, and OpenChat sets its own text, a reply's /r, after the focus).
if EventRegistry and EventRegistry.RegisterCallback then
	EventRegistry:RegisterCallback("ChatFrame.OnEditBoxFocusGained", function(_, box)
		if #waitingLines == 0 or not (box and box.GetText and box.SetText) then return end
		C_Timer.After(0, function()
			if #waitingLines == 0 or openBox() ~= box or (box:GetText() or "") ~= "" then return end
			into(box, table.remove(waitingLines, 1))
			boardRow()
		end)
	end, waitingLines)
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

-- for agent code: a slash line into the chat box, or waiting for it
WowCompanion_ChatLine = function(line) return chatLine(line) end



WC.Chat = WC.Chat or {}
WC.Chat.chatLine = chatLine
