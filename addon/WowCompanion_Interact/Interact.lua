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
-- The key is an addon keybinding in WoW's own Keybindings screen
-- (Bindings.xml, "Combat loot"): the binding clicks the secure button below.
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
