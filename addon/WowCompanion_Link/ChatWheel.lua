-- Talking to people without an agent in the loop.
-- Hold minus with L1 and R1 together and speak: the PC sends the words straight
-- here (no agent) and they go into the chat box (Chat.lua's chat line): the one
-- the player has open, or the next one they open. Cross sends.
-- The channel is picked on the same hold: while the chord is held the ring
-- (Core's Ring.lua) shows the channels, and the right stick points at one. Let go: that channel is
-- kept for next time; leave the stick alone and the last one stays.
-- Nothing goes on the action bars.
--
--   WCChatChannel("/p")         pick a channel
--   WC.ChatChannel.Line(text)   text with the picked channel in front
--   WC.ChatChannel.Current()    the slash command picked ("/s" until one is)
WC = WC or {}
do
	local NAMES = {
		["/s"] = "Say", ["/y"] = "Yell", ["/p"] = "Party", ["/g"] = "Guild",
		["/i"] = "Instance", ["/raid"] = "Raid", ["/1"] = "General", ["/2"] = "Trade",
		["/r"] = "Reply",
	}
	-- the ring, from the top, clockwise; icons from the game's own set
	local SLOTS = {
		{ "/p", "Spell_Holy_PrayerOfHealing02" }, { "/i", "INV_Misc_Key_03" },
		{ "/g", "INV_Shirt_GuildTabard_01" }, { "/raid", "Ability_Warrior_BattleShout" },
		{ "/s", "INV_Misc_Note_01" }, { "/1", "INV_Misc_Map_01" },
		{ "/r", "INV_Letter_02" }, { "/2", "INV_Misc_Coin_01" },
	}

	local function current()
		local picked = WowCompanionLinkDB and WowCompanionLinkDB.chatChannel
		return NAMES[picked] and picked or "/s"
	end

	-- a small tag of ours, Blizzard's font, over the chat area: which channel
	-- dictation will use. Shown only while a channel other than Say is picked.
	local tag = _G["WCChatChannelTag"] or CreateFrame("Frame", "WCChatChannelTag", UIParent)
	tag:SetSize(160, 18)
	tag:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 36, 250)
	tag.text = tag.text or tag:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	tag.text:SetPoint("LEFT")
	local function showTag()
		local slash = current()
		tag.text:SetText("Chat: |cffffffff" .. NAMES[slash] .. "|r")
		tag:SetShown(slash ~= "/s")
	end

	function WCChatChannel(slash)
		if not NAMES[slash] then return end
		WowCompanionLinkDB = WowCompanionLinkDB or {}
		WowCompanionLinkDB.chatChannel = slash
		showTag()
		print("|cffffd100Chat:|r speaking to " .. NAMES[slash])
	end

	-- the ring's order, for turning the channel a step at a time
	local ORDER = {}
	for i, s in ipairs(SLOTS) do ORDER[i] = s[1] end
	WC.ChatChannel = {
		Cycle = function(step)
			local at = 1
			for i, slash in ipairs(ORDER) do if slash == current() then at = i end end
			local slash = ORDER[(at - 1 + step) % #ORDER + 1]
			WowCompanionLinkDB.chatChannel = slash
			showTag()
			return slash
		end,
		Current = current,
		Name = function() return NAMES[current()] end,
		Line = function(text)
			return current() .. " " .. (text or ""):gsub("^%s+", "")
		end,
	}

	-- The ring: Core's (Ring.lua), shown only while the chord is held; it takes
	-- the sticks then, so the camera stays put, and holds them a moment after.
	-- The last direction pushed is kept, so a flick and let go picks it.
	local ring = _G["WCChatRing"] or CreateFrame("Frame", "WCChatRing", UIParent)
	ring:Hide()
	local look = WC.Ring.Build(ring, { prompt = "Let go to keep it" })
	local entries = {}
	for i, s in ipairs(SLOTS) do
		entries[i] = { slash = s[1], label = NAMES[s[1]], icon = "Interface\\Icons\\" .. s[2] }
	end
	local function indexOf(slash)
		for i, e in ipairs(entries) do if e.slash == slash then return i end end
	end
	ring:SetScript("OnUpdate", function(self)
		local aimed = look:Picked(entries)
		if aimed then self.pick = entries[aimed].slash end
		look:Aim(entries, indexOf(self.pick))
	end)

	-- the Companion key down and up (TALK_DOWN, TALK_UP; Link.lua): the ring
	-- shows once L1 and R1 are both held with it, a moment late is fine
	local watch = _G["WCChatRingWatch"] or CreateFrame("Frame", "WCChatRingWatch")
	watch:Hide()
	watch:SetScript("OnUpdate", function(self, elapsed)
		self.t = (self.t or 0) + elapsed
		if not ring:IsShown() and WowCompanion_PadSlot and WowCompanion_PadSlot() == WC.Conversations.DICTATION then
			ring.pick = current()
			look:Open("Chat channel", entries)
			ring:Show()
		end
		if self.t > 0.6 and not ring:IsShown() then self:Hide() end
	end)
	local talk = WC.Module("ChatRing")
	talk:On("TALK_DOWN", function()
		watch.t = 0
		watch:Show()
	end)
	talk:On("TALK_UP", function()
		watch:Hide()
		if ring:IsShown() then
			ring:Hide()
			if ring.pick and ring.pick ~= current() then WCChatChannel(ring.pick) end
		end
	end)

	-- While a dictation clip's job is out (named by the PC's `heard`, ended
	-- by the chat line that carries its words or the notice that says why
	-- none came): the tag says it is on its way, so a slow line is not given
	-- up on and spoken again. Shown out of turn of the Say-only rule.
	local waiting = _G["WCChatWaiting"] or CreateFrame("Frame", "WCChatWaiting")
	waiting:Hide()
	waiting.jobs = {}
	waiting:SetScript("OnUpdate", function(self, elapsed)
		self.t = self.t + elapsed
		local dots = ("."):rep(math.floor(self.t * 2) % 4)
		tag.text:SetText(("Chat: |cffffffff%s|r  transcribing%s"):format(NAMES[current()], dots))
		tag:Show()
	end)
	local ENDED = { answered = true, cancelled = true, failed = true }
	WC.Module("ChatDictation"):On("JOB_MESSAGE", function(inbox)
		local id = tonumber(inbox.job)
		if inbox.slot ~= WC.Conversations.DICTATION or not id then return end
		if inbox.state == "hearing" then
			if not waiting:IsShown() then waiting.t = 0 end
			waiting.jobs[id] = true
			waiting:Show()
		elseif ENDED[inbox.state] and waiting.jobs[id] then
			waiting.jobs[id] = nil
			if inbox.state == "failed" then print("|cffffd100Chat:|r " .. tostring(inbox.text or "nothing was sent")) end
			if not next(waiting.jobs) then
				waiting:Hide()
				showTag()
			end
		end
	end)

	local boot = CreateFrame("Frame")
	boot:RegisterEvent("PLAYER_LOGIN")
	boot:SetScript("OnEvent", showTag)
end
