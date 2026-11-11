-- Talking to people without an agent in the loop (the player, 2026-11-10).
-- Hold minus with L1 and R1 together and speak: the PC sends the words straight
-- here (no agent) and they open in the send preview, one press to send.
-- The channel is picked on the same hold (the player: "combine the speaking
-- trigger and the channel selection"): while the chord is held a small ring of
-- channels shows, and the right stick points at one. Let go: that channel is
-- kept for next time; leave the stick alone and the last one stays. A line that
-- opens with a channel word ("trade, LF enchanter") still wins for that line.
-- Nothing goes on the action bars (the player's rule, 2026-11-10).
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
			WowCompanionDB.chatChannel = slash
			showTag()
			return slash
		end,
		Current = current,
		Name = function() return NAMES[current()] end,
		Line = function(text)
			text = (text or ""):gsub("^%s+", "")
			if text:sub(1, 1) == "/" then return text end
			return current() .. " " .. text
		end,
	}

	-- The ring: ours, Blizzard's gamepad slot art and fonts. Shown only while
	-- the chord is held; it takes the right stick then, so the camera stays put.
	local RADIUS, PICK_SQ = 92, 0.25
	local ring = _G["WCChatRing"] or CreateFrame("Frame", "WCChatRing", UIParent)
	ring:SetSize(2 * RADIUS + 80, 2 * RADIUS + 80)
	ring:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
	ring:SetFrameStrata("DIALOG")
	ring:Hide()
	if ring.EnableGamePadStick then
		ring:EnableGamePadStick(true)
		ring:SetScript("OnGamePadStick", function() end)
	end
	ring.title = ring.title or ring:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	ring.title:SetPoint("CENTER")
	ring.slots = ring.slots or {}
	for index, s in ipairs(SLOTS) do
		local angle = math.pi / 2 - (index - 1) * math.pi / 4
		local slot = ring.slots[index] or {}
		ring.slots[index] = slot
		slot.dx, slot.dy, slot.slash = math.cos(angle), math.sin(angle), s[1]
		slot.icon = slot.icon or ring:CreateTexture(nil, "ARTWORK")
		slot.icon:SetSize(40, 40)
		slot.icon:SetPoint("CENTER", ring, "CENTER", slot.dx * RADIUS, slot.dy * RADIUS)
		slot.icon:SetTexture("Interface\\Icons\\" .. s[2])
		-- the icon art's own edge cropped off, then cut round by Blizzard's
		-- portrait mask clamped to black, as the wheels do (Wheel.lua), so only
		-- the circle shows inside the round border
		slot.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		if not slot.mask then
			slot.mask = ring:CreateMaskTexture()
			slot.mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
			slot.mask:SetPoint("TOPLEFT", slot.icon, "TOPLEFT", 3, -3)
			slot.mask:SetPoint("BOTTOMRIGHT", slot.icon, "BOTTOMRIGHT", -3, 3)
			slot.icon:AddMaskTexture(slot.mask)
		end
		slot.border = slot.border or ring:CreateTexture(nil, "OVERLAY", nil, 2)
		slot.border:SetAllPoints(slot.icon)
		slot.label = slot.label or ring:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		slot.label:SetPoint("TOP", slot.icon, "BOTTOM", 0, -2)
		slot.label:SetText(NAMES[s[1]])
	end
	local function light(pick)
		for _, slot in ipairs(ring.slots) do
			local on = slot.slash == pick
			pcall(slot.border.SetAtlas, slot.border, on and "gamepad-actionbar-circleslot-border-selected"
				or "gamepad-actionbar-circleslot-border-normal")
			slot.icon:SetDesaturated(not on)
			slot.label:SetFontObject(on and "GameFontNormalSmall" or "GameFontHighlightSmall")
		end
		ring.title:SetText(NAMES[pick] or "")
	end
	local function stickPick()
		local ok, state = pcall(C_GamePad.GetDeviceMappedState, C_GamePad.GetActiveDeviceID())
		local stick = ok and state and state.sticks and state.sticks[2]
		if not (stick and stick.x and stick.y) or stick.x * stick.x + stick.y * stick.y < PICK_SQ then return nil end
		local best, bestDot
		for _, slot in ipairs(ring.slots) do
			local dot = stick.x * slot.dx + stick.y * slot.dy
			if not bestDot or dot > bestDot then best, bestDot = slot.slash, dot end
		end
		return best
	end
	ring:SetScript("OnUpdate", function(self)
		-- the last direction pushed is kept, so a flick and let go picks it
		local pick = stickPick()
		if pick and pick ~= self.pick then
			self.pick = pick
			light(pick)
		end
	end)

	-- the talk button (Companion.lua's WowCompanionTap) down and up: the ring
	-- shows once L1 and R1 are both held with it, a moment late is fine
	local watch = _G["WCChatRingWatch"] or CreateFrame("Frame", "WCChatRingWatch")
	watch:Hide()
	watch:SetScript("OnUpdate", function(self, elapsed)
		self.t = (self.t or 0) + elapsed
		if not ring:IsShown() and WowCompanion_PadSlot and WowCompanion_PadSlot() == "say" then
			ring.pick = current()
			light(ring.pick)
			ring:Show()
		end
		if self.t > 0.6 and not ring:IsShown() then self:Hide() end
	end)
	local tap = _G["WowCompanionTap"]
	if tap and not tap.wcChatRing then
		tap.wcChatRing = true
		tap:HookScript("OnClick", function(_, _, down)
			if down then
				watch.t = 0
				watch:Show()
			else
				watch:Hide()
				if ring:IsShown() then
					ring:Hide()
					if ring.pick and ring.pick ~= current() then WCChatChannel(ring.pick) end
					WC.ChatChannel.Waiting()
				end
			end
		end)
	end

	-- From letting go of minus until the line is in the send preview: the tag
	-- says it is on its way (the player, 2026-11-10: a slow line popped up
	-- after they had given up and spoken another). Shown out of turn of the
	-- Say-only rule; gone when the preview opens, a clip is dropped, or after 6 s.
	local waiting = _G["WCChatWaiting"] or CreateFrame("Frame", "WCChatWaiting")
	waiting:Hide()
	waiting:SetScript("OnUpdate", function(self, elapsed)
		self.t = self.t + elapsed
		local preview = _G["WowCompanionPreview"]
		if preview and preview:IsShown() and self.t > 0.1 then
			self:Hide()
			showTag()
			return
		end
		local dots = ("."):rep(math.floor(self.t * 2) % 4)
		-- transcription takes about a second; past 6 s nothing is coming (the
		-- player, 2026-11-10: a 30 s wait looked stuck)
		if self.t > 6 then
			self:Hide()
			showTag()
			return
		end
		tag.text:SetText(("Chat: |cffffffff%s|r  transcribing%s"):format(NAMES[current()], dots))
		tag:Show()
	end)
	-- a dropped clip (too short, nothing heard) ends the wait at once, with why
	WC.ChatChannel.Dropped = function(why)
		if not waiting:IsShown() then return end
		waiting:Hide()
		showTag()
		print("|cffffd100Chat:|r " .. tostring(why))
	end
	WC.ChatChannel.Waiting = function()
		-- a waiting line is never hidden from here: new lines stack in the
		-- preview, and only its own (Blizzard) buttons close it
		waiting.t = 0
		waiting:Show()
	end

	local boot = CreateFrame("Frame")
	boot:RegisterEvent("PLAYER_LOGIN")
	boot:SetScript("OnEvent", showTag)
end
