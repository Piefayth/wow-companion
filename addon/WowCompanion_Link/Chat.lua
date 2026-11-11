-- WowCompanion_Link: lines for other players. Dictation and the agents' `send`
-- steps go into Blizzard's chat box, and only there (WC.Chat; the messages
-- `chat` and `send`). Whispers are addressed by the name the player knows.

local function toast(...) return WC.Board.toast(...) end
local function problem(text) toast("|cffff7777" .. text .. "|r", 1, 0.6, 0.6, 10) end
-- the taint measurement of a chat path, when WowCompanion_Agent is there to keep it
local function measured(label, fn)
	if WC.Sandbox then return WC.Sandbox.measureOnce(label, fn) end
	return fn()
end

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
-- Orihime), and the game is the only side that knows
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
			-- A Battle.net whisper cannot go out from a macro, so a line whispers the character the friend is
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

-- Lines for other players go into Blizzard's chat box, and only there. A line
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
	WC.Board.Post("chat", n > 0 and (n == 1 and "a line is waiting: open chat"
		or ("%d lines are waiting: open chat"):format(n)) or nil, { state = "waiting", keep = true })
end

local function trace(what, box)
	if WC.ChatChannel and WC.ChatChannel.Trace then WC.ChatChannel.Trace(what, box) end
end
local function into(box, text)
	measured("line into chat box", function() box:SetText(text) end)
	trace("into chat box", box)
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
			problem("Whisper not written: " .. message .. ".")
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
	trace("line waiting", box)
	boardRow()
	return ("waiting for the chat box: %q"):format(line)
end

-- The box opened: the oldest waiting line goes in. A post-hook on Blizzard's
-- ActivateChat, which every way of opening chat ends in (a key, the pad's
-- radial focusing the chat frame, a click: the edit box's OnEditFocusGained
-- calls it), and which has shown and focused the box by the time it returns,
-- so no timer. A line that cannot go in stays waiting and the board says why;
-- every attempt is in the chat box trace (WC.ChatChannel.Trace).
local function refusedBecause(box)
	if not box:HasFocus() then return "the chat box opened without the cursor in it" end
	local had = box:GetText() or ""
	if had ~= "" then return ("the chat box opened holding %q: clear it with circle, then open chat again"):format(had) end
end
local function waitingWhy(why)
	local n = #waitingLines
	WC.Board.Post("chat", ("%s waiting, not placed: %s"):format(n == 1 and "a line is" or n .. " lines are", why),
		{ state = "waiting", keep = true })
end
local justPlaced -- { box, line }: until OpenChat has had its say
hooksecurefunc(ChatFrameUtil, "ActivateChat", function(box)
	justPlaced = nil
	if #waitingLines == 0 or not (box and box.GetText and box.SetText) then return end
	local why = refusedBecause(box)
	if why then
		trace("waiting line refused: " .. why, box)
		waitingWhy(why)
		return
	end
	local line = table.remove(waitingLines, 1)
	into(box, line)
	justPlaced = { box = box, line = line }
	boardRow()
end)
-- OpenChat(text) activates the box and then sets its own text (a reply's /r)
-- on the box's next update, over ours: put the line back at the front, and say so.
hooksecurefunc(ChatFrameUtil, "OpenChat", function(text)
	local placed = justPlaced
	justPlaced = nil
	if not (placed and text) then return end
	table.insert(waitingLines, 1, placed.line)
	trace("waiting line pushed back: chat opened with its own text", placed.box)
	waitingWhy(("chat opened with its own text (%q); send or clear that, then open chat again"):format(text))
end)

-- Blizzard's chat prints nothing when a Battle.net whisper cannot be delivered
-- (the friend is offline, or appearing offline), so say it ourselves
do
	local undeliverable = CreateFrame("Frame")
	undeliverable:RegisterEvent("BN_CHAT_WHISPER_UNDELIVERABLE")
	undeliverable:SetScript("OnEvent", function()
		toast("|cffff7777Battle.net could not deliver that whisper|r: they are offline, or appearing offline", 1, 0.6, 0.6, 10)
	end)
end

local function activeEditBox()
	local get = ChatEdit_GetActiveWindow or (ChatFrameUtil and ChatFrameUtil.GetActiveWindow)
	return get and get()
end

-- the agent's `send` step: a chat line for the player to send from the chat box.
-- Not agent code, so it is not refused in combat as a lua step is.
WC.Link.Handle("send", function(inbox) return chatLine(inbox.text or "") end)

-- "/g hi" placed by SetText still says Say: the box only reads its slash command
-- when a space is typed (OnSpacePressed -> ParseText(0)) or on send. Run the same
-- parse, so the header shows the channel before the player presses send.
local function onDictated(box)
	local text = box:GetText() or ""
	if text:find("^/%S+ ") and box.ParseText then
		measured("chat channel", function() pcall(box.ParseText, box, 0) end)
	end
end

-- Writes into a box the player already opened, and never opens one itself:
-- when we called ChatFrame_OpenChat, the gamepad focus restore on close came
-- back blocked and the A and B buttons died.
WC.Link.Handle("chat", function(inbox)
	-- The controller's cancel unfocuses the box but keeps its text, and dictation
	-- appends, so a discarded line would come back glued to the next one. Clearing
	-- only sets its text: showing or hiding Blizzard's frame is what broke A and B.
	if inbox.clear then
		local box = activeEditBox() or LAST_ACTIVE_CHAT_EDIT_BOX or ChatFrame1EditBox
		if box and box.SetText then
			box:SetText("")
			return "chat box cleared"
		end
		return "refused: no chat box to clear"
	end
	-- a line spoken with a channel goes to the chat box, or waits for it
	if inbox.raw and inbox.raw ~= (inbox.text or "") and (inbox.text or ""):find("^/%w+") then
		return chatLine(inbox.text or "")
	end
	-- L1+R1 dictation (ChatWheel.lua): into the chat box the player opened, its
	-- words added to a draft there; with no box open it waits for one
	if inbox.wheel and WC.ChatChannel then
		local words = (inbox.text or ""):gsub("^%s+", "")
		local result = chatLine(WC.ChatChannel.Line(words), words)
		WC.ChatChannel.Arrived()
		return result
	end
	-- Any text box the player put the cursor in takes dictation: the auction
	-- house search, a mail recipient, a search field, as said; only chat gets
	-- the words as a slash command.
	local focused = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
	local chatBox = activeEditBox()
	if focused and focused ~= chatBox and focused.SetText and focused.GetText
		and focused.IsObjectType and focused:IsObjectType("EditBox") and focused:IsVisible() then
		focused:SetText((focused:GetText() or "") .. (inbox.raw or inbox.text or ""))
		return ("%s holds %q"):format(tostring(focused:GetName() or "a text box"), focused:GetText())
	end
	local box = chatBox
	if not box or not box:IsVisible() then
		problem("No text box open, so nothing was written. Open chat or click into a search box, then speak.")
		return "refused: no text box open"
	end
	-- append, so speaking twice builds a line instead of replacing it
	local text = inbox.text or ""
	local rest = text:match("^/w%s+(.+)") or text:match("^/whisper%s+(.+)")
	if rest then
		local target, message, label = WowCompanion_ResolveWhisper(rest)
		if not target then
			problem("Whisper not written: " .. message .. ".")
			return "refused: " .. message
		end
		text = "/w " .. target .. " " .. message
		toast("|cffffd100Whisper|r to " .. label .. ": press send when it reads right", 0.9, 0.9, 0.9, 8)
	end
	box:SetText((box:GetText() or "") .. text)
	onDictated(box)
	return ("chat box holds %q"):format(box:GetText())
end)

-- The controller's cancel takes the box's focus away, and Blizzard closes it then
-- only if it is empty (ShouldDeactivateChatOnEditFocusLost: GetText() == ""), so a
-- draft lingered and came back glued to the next line. EventRegistry tells addons
-- the moment focus goes, before that check, so emptying the box there lets
-- Blizzard's own code close it. Not while the gamepad chat menu is open: that
-- takes focus too, and means to come back.
if EventRegistry and EventRegistry.RegisterCallback then
	EventRegistry:RegisterCallback("ChatFrame.OnEditBoxFocusLost", function(_, box)
		if WowCompanionLinkDB and WowCompanionLinkDB.keepChatDraft then return end
		if not (box and box.GetText and box.SetText) or (box:GetText() or "") == "" then return end
		local chat = box.chatFrame
		if chat and chat.IsGamepadMenuOpen and chat:IsGamepadMenuOpen() then return end
		measured("draft clear", function() box:SetText("") end)
	end, activeEditBox)
end

-- for agent code: a slash line into the chat box, or waiting for it
WowCompanion_ChatLine = function(line) return chatLine(line) end
WC.Chat = {
	chatLine = chatLine,
	Line = chatLine,
	ResolveWhisper = function(...) return WowCompanion_ResolveWhisper(...) end,
	ActiveBox = activeEditBox,
}
