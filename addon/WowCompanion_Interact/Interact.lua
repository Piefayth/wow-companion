-- Combat interact: one press of a key
-- loots the nearest corpse, else interacts with the nearest thing, in combat too.
--
-- Why it needs a trick: Blizzard's gamepad code turns soft interact off while
-- the target is attackable in combat (Blizzard_GamepadTargeting/TargetLogic.lua,
-- UpdateSoftTargetInteract), and SoftTargetInteract is a secure CVar: addon code
-- cannot set it in combat, nor can /console (it runs forceinsecure()). Blizzard
-- re-checks it only when the target changes.
--
-- How (measured working; the designs that fail, and why, are in
-- docs/api-useful.md, "Looting in combat on the gamepad"):
--   down: in a fight with a live enemy targeted, keep it in focus and target
--         yourself, so Blizzard turns soft interact on (the corpse is picked in
--         about 0.1 s), then press Blizzard's own gamepad interact button down
--         (GamepadMainActionBarFrame, top bar Right.ActionButton1, via /click);
--   up:   let that button go: it decides now, lootable soft interact first
--         (MainActionBarFrame.lua interactActions), or at 0.5 s held. Then the
--         enemy goes back to target and focus is let go.
-- All within one press, before the gamepad's auto-retarget (about 1 s) can undo
-- it. A secure button acts on one edge only (SecureTemplates.lua), so a wrapper
-- picks the down or up macro for each press.
--
-- The key is an addon keybinding (Bindings.xml, "Combat loot"): the binding
-- clicks the secure button below. It is set on our settings page by pressing
-- (the row at the end), or in WoW's own Keybindings screen.
WC.Saved("WowCompanion_Interact", "WowCompanionInteractDB")
do
	local function say(text)
		WC.Say("combat interact: " .. text)
	end

	local tap = _G["WCCombatInteractTap"] or CreateFrame("Button", "WCCombatInteractTap", UIParent, "SecureActionButtonTemplate")
	tap:RegisterForClicks("AnyDown", "AnyUp")
	local header = _G["WCCombatInteractTapHeader"]
		or CreateFrame("Frame", "WCCombatInteractTapHeader", UIParent, "SecureHandlerBaseTemplate")
	local function interactButtonName()
		local ok, name = pcall(function()
			return GamepadMainActionBarFrame:GetActionBars().topBar.Right.ActionButton1:GetName()
		end)
		return ok and name or nil
	end
	local function setup()
		if InCombatLockdown() then return false end
		local name = interactButtonName()
		if not name then say("Blizzard's gamepad interact button was not found (is the gamepad UI on?)") return true end
		tap:SetAttribute("type-dn", "macro")
		tap:SetAttribute("macrotext-dn", "/focus [combat,@target,harm,nodead]\n/target [combat,@target,harm,nodead] player\n/click " .. name .. " LeftButton true")
		tap:SetAttribute("type-up", "macro")
		tap:SetAttribute("macrotext-up", "/click " .. name .. " LeftButton false\n/target [combat,@focus,harm,nodead] focus\n/clearfocus [combat,@focus,exists]")
		if not tap.wcWrapped then
			tap.wcWrapped = true
			SecureHandlerWrapScript(tap, "OnClick", header, [[
				self:SetAttribute("useOnKeyDown", down and true or false)
				return down and "dn" or "up"
			]])
		end
		return true
	end
	_G["BINDING_NAME_CLICK WCCombatInteractTap:LeftButton"] = "Combat loot (loot or interact, in combat too)"

	local login = CreateFrame("Frame")
	login:RegisterEvent("PLAYER_LOGIN")
	login:SetScript("OnEvent", function()
		if not setup() then WC.AfterCombat(setup) end
	end)
end

-- The settings row: press it, then the button. The press is taken as Blizzard's
-- key settings take one (KeybindListener: the button with the modifiers held,
-- CreateKeyChordStringUsingMetaKeyState; whatever the button did before is
-- unbound), and saved to the character's bindings. The button it already has
-- clears it, so the feature is off with no button.
do
	local ACTION = "CLICK WCCombatInteractTap:LeftButton"
	local SECONDS = 15
	-- the game keeps these to itself: Focus UI and the game menu
	local REFUSED = { PADBACK = true, PADFORWARD = true }
	local listening, note
	local listen = _G["WCLootBindCapture"] or CreateFrame("Frame", "WCLootBindCapture", UIParent)
	listen:Hide()
	local function refresh() if WC.SettingsPage.Refresh then WC.SettingsPage.Refresh() end end
	local function stop()
		listening = nil
		listen:EnableGamePadButton(false)
		listen:SetScript("OnUpdate", nil)
		listen:Hide()
		refresh()
	end
	local function take(key)
		if IsKeyPressIgnoredForBinding(key) then return end
		if REFUSED[key] then
			note = ("%s is the game's own; press another."):format(WowCompanion_Glyph(key))
			refresh()
			return
		end
		if InCombatLockdown() then note = "Set it out of combat." stop() return end
		local chord = CreateKeyChordStringUsingMetaKeyState(key)
		local had = GetBindingKey(ACTION)
		for _, old in ipairs({ GetBindingKey(ACTION) }) do SetBinding(old) end
		if had == chord then
			note = "Cleared: combat loot has no button."
		else
			local before = GetBindingAction(chord)
			SetBinding(chord, ACTION)
			note = before ~= "" and ("It no longer does %s."):format(GetBindingName(before)) or nil
		end
		SaveBindings(GetCurrentBindingSet())
		stop()
	end
	listen:SetScript("OnGamePadButtonDown", function(_, key) if listening then take(key) end end)
	local function start()
		if InCombatLockdown() then note = "Set it out of combat." refresh() return end
		note, listening = nil, GetTime()
		listen:Show()
		-- from the next frame, so the press that opened it is not taken
		listen:SetScript("OnUpdate", function()
			if listening then listen:EnableGamePadButton(true) end
			if listening and GetTime() - listening > SECONDS then stop() end
		end)
		refresh()
	end
	WC.SettingsPage.Add({
		kind = "key", section = "Combat loot", order = 60, label = "Loot button",
		text = function()
			return note or "Loots the nearest corpse, else interacts, in combat too. Press the row, then the button; its own button again clears it."
		end,
		button = function()
			if listening then return "Press a button" end
			local key = GetBindingKey(ACTION)
			if not key then return "Not set" end
			local glyphs = {}
			for part in key:gmatch("[^-]+") do glyphs[#glyphs + 1] = WowCompanion_Glyph(part) end
			return table.concat(glyphs, " + ")
		end,
		onClick = function() if listening then stop() else start() end end,
	})
end

