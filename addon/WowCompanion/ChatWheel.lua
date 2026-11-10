-- The chat wheel (the player, 2026-11-10): talking to people without an agent in
-- the loop. Pick a channel on the wheel (the Chat macro, L2+R2 triangle); it
-- stays picked. Hold minus with L1 and R1 together and speak: the PC sends the
-- words straight here (no agent), and they open in the send preview on that
-- channel, one press to send. A line that opens with a channel word ("trade,
-- LF enchanter") uses that channel instead, for that line only.
--
--   WCChatChannel("/p")         pick a channel (the wheel's slots call this)
--   WC.ChatChannel.Line(text)   text with the picked channel in front
--   WC.ChatChannel.Current()    the slash command picked ("/s" until one is)
WC = WC or {}
do
	local NAMES = {
		["/s"] = "Say", ["/y"] = "Yell", ["/p"] = "Party", ["/g"] = "Guild",
		["/i"] = "Instance", ["/raid"] = "Raid", ["/1"] = "General", ["/2"] = "Trade",
		["/r"] = "Reply",
	}
	-- the wheel, in order around it (eight at most); icons from the game's own set
	local SLOTS = {
		{ "/s", "INV_Misc_Note_01" }, { "/p", "Spell_Holy_PrayerOfHealing02" },
		{ "/g", "INV_Shirt_GuildTabard_01" }, { "/i", "INV_Misc_Key_03" },
		{ "/raid", "Ability_Warrior_BattleShout" }, { "/1", "INV_Misc_Map_01" },
		{ "/2", "INV_Misc_Coin_01" }, { "/r", "INV_Letter_02" },
	}

	local function current()
		local picked = WowCompanionDB and WowCompanionDB.chatChannel
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
		WowCompanionDB = WowCompanionDB or {}
		WowCompanionDB.chatChannel = slash
		showTag()
		print("|cffffd100Chat:|r hold minus with L1 and R1 to speak to " .. NAMES[slash])
	end

	WC.ChatChannel = {
		Current = current,
		Name = function() return NAMES[current()] end,
		Line = function(text)
			text = (text or ""):gsub("^%s+", "")
			if text:sub(1, 1) == "/" then return text end
			return current() .. " " .. text
		end,
	}

	-- the wheel and its macro, made once, out of combat; never overwritten, so
	-- an agent or the player may rearrange them
	local function build()
		if InCombatLockdown() then return false end
		local wheels = WowCompanionWheelDB and WowCompanionWheelDB.wheels
		if WCWheel and WCWheel.Set and not (wheels and wheels.chat) then
			local slots = {}
			for _, s in ipairs(SLOTS) do
				slots[#slots + 1] = { macrotext = ("/run WCChatChannel(%q)"):format(s[1]),
					label = NAMES[s[1]], icon = "Interface\\Icons\\" .. s[2] }
			end
			pcall(WCWheel.Set, "chat", { label = "Chat", slots = slots })
		end
		if GetMacroIndexByName("Chat") == 0 then
			pcall(CreateMacro, "Chat", "INV_Letter_02", "/click WCWheel_chat Macro", false)
		end
		return true
	end

	local boot = CreateFrame("Frame")
	boot:RegisterEvent("PLAYER_LOGIN")
	boot:SetScript("OnEvent", function()
		showTag()
		if not build() and WC.AfterCombat then WC.AfterCombat(build) end
	end)
end
