-- Combat interact (the player, 2026-11-10): one press that loots the nearest
-- corpse, else interacts with the nearest thing, even in combat with a hostile
-- target.
--
-- Why it fails today: Blizzard's GamepadTargetLogicMixin:UpdateSoftTargetInteract
-- (Blizzard_GamepadTargeting/TargetLogic.lua) sets the temp CVar
-- SoftTargetInteract to 0 whenever we are in combat with an attackable hard
-- target, and back to 1 otherwise, on PLAYER_TARGET_CHANGED and on entering and
-- leaving combat. With it at 0 there is no "softinteract" unit, so interact can
-- only reach the hard target.
--
-- How this works, with nothing of Blizzard's called from our code:
--  * The key is bound (an override binding, set out of combat) to a click on our
--    plain button. Down: SoftTargetInteract = 1 (C_CVar.SetTempCVar, which has no
--    combat or taint restriction in api-1.60.1-signatures.txt), and re-asserted on
--    the events Blizzard resets it on, while the key is held.
--  * The interact itself is Blizzard's own secure binding INTERACTSOFTTARGET
--    (Blizzard_GamepadTargeting/Bindings.xml: InteractUnit("softinteract"), which,
--    unlike "anyinteract", never starts an auto-attack). It cannot fire on the
--    same press: soft targeting resolves a frame or more after the CVar turns
--    on, and a binding command fires on the way down only. So it is Plan B:
--      hold this key: soft interact turns on and the game shows the loot or
--      interact icon over the nearest corpse or object;
--      tap your usual interact button while holding: Blizzard's interact takes
--      it, lootable soft target first (MainActionBarFrame.lua interactActions);
--      let go: Blizzard's own rule is applied again.
--    A second key, WowCompanionDB.interact.takeKey, may be bound straight to
--    INTERACTSOFTTARGET so the take does not depend on the usual interact button.
--  * Plan A (a secure /cleartarget, letting Blizzard re-enable soft interact
--    itself) also works with no CVar from us, but drops the target mid-fight, so
--    it is only the fallback: /wci mode clear.
--
-- Nothing is bound until the player says which key: /wci bind <KEY> (it reports
-- what the key did before and refuses a bound key unless "force" is added).
-- /wci status, /wci unbind, /wci mode hold|clear, /wci take <KEY>.
do
	local OWNER_NAME, BUTTON_NAME = "WCCombatInteractOwner", "WCCombatInteract"

	local function db()
		WowCompanionDB = WowCompanionDB or {}
		WowCompanionDB.interact = WowCompanionDB.interact or {}
		-- Measured 2026-11-10: SetTempCVar("SoftTargetInteract") from our code in
		-- combat is ADDON_ACTION_BLOCKED, so "hold" cannot work there. "clear" (a
		-- secure /cleartarget on a live hostile target) is the default, and any
		-- saved "hold" is moved over once.
		-- 2026-11-10: "tap" (below) replaces "clear" as the default, moved over once
		if not WowCompanionDB.interact.tapMoved then
			WowCompanionDB.interact.tapMoved = true
			WowCompanionDB.interact.mode = "tap"
		end
		return WowCompanionDB.interact
	end

	local function say(text)
		if WC and WC.Toast then pcall(WC.Toast, "Combat interact: " .. text, 1, 0.82, 0, 4) end
		print("|cffffd100combat interact:|r " .. text)
	end

	local function setInteract(on)
		local ok, err = pcall(C_CVar.SetTempCVar, "SoftTargetInteract", on and "1" or "0")
		if not ok then say("could not set SoftTargetInteract: " .. tostring(err)) end
		return ok
	end

	-- Blizzard's rule, unchanged, so letting go leaves things as it would have
	local function blizzardRule()
		local off = UnitAffectingCombat("player") and UnitExists("target")
			and UnitCanAttack("player", "target")
		setInteract(not off)
	end

	-- the hold: a plain button (nothing protected happens on it), clicked by the
	-- key on its way down and up
	local held = false
	local button = _G[BUTTON_NAME] or CreateFrame("Button", BUTTON_NAME, UIParent, "SecureActionButtonTemplate")
	button:RegisterForClicks("AnyDown", "AnyUp")
	-- "back": after looting, one press puts the enemy kept in focus back as the
	-- target, and lets focus go
	local back = _G["WCCombatInteractBack"] or CreateFrame("Button", "WCCombatInteractBack", UIParent, "SecureActionButtonTemplate")
	back:RegisterForClicks("AnyDown")
	if not InCombatLockdown() then
		back:SetAttribute("type", "macro")
		back:SetAttribute("macrotext", "/target [@focus,harm,nodead] focus\n/clearfocus")
	end
	-- Plan A: a secure /cleartarget on the way down, only in mode "clear"
	local function applyMode()
		if InCombatLockdown() then return end
		if db().mode == "clear" then
			button:SetAttribute("type", "macro")
			-- Why "arm" (the player, 2026-11-10; /targetlasttarget and /cleartarget
			-- both rejected): Blizzard keeps soft interact off while the hard target
			-- is attackable in combat (TargetLogic.lua UpdateSoftTargetInteract),
			-- and SoftTargetInteract is a secure CVar: our SetTempCVar is blocked,
			-- and /console runs forceinsecure() (SlashCommands.lua). So the target
			-- changes, but to YOU, not to nothing: the enemy is kept in focus, you
			-- are not attackable, Blizzard turns soft interact on itself, and the
			-- gamepad's TargetEnemyAttacker does not grab a new target (it only
			-- acts with no target; the race that undid /cleartarget).
			button:SetAttribute("macrotext", "/focus [@target,harm,nodead]\n/target player")
		else
			button:SetAttribute("type", nil)
			button:SetAttribute("macrotext", nil)
		end
	end
	button:HookScript("OnClick", function(_, _, down)
		if db().mode == "clear" or InCombatLockdown() then return end
		held = down and true or false
		if held then setInteract(true) else blizzardRule() end
	end)

	-- Blizzard resets the CVar on these; while held, ours wins (run after theirs:
	-- the frame's own events fire after EventRegistry's frame-event callbacks
	-- registered earlier, and a reset still lands next frame at worst)
	-- the fight is over: Blizzard's own auto-target-attacker comes back
	local restore = _G["WCCombatInteractRestore"] or CreateFrame("Frame", "WCCombatInteractRestore")
	restore:UnregisterAllEvents()
	restore:RegisterEvent("PLAYER_REGEN_ENABLED")
	restore:SetScript("OnEvent", function()
		if C_CVar.GetCVar("TargetEnemyAttacker") == "0" then
			pcall(C_CVar.SetTempCVar, "TargetEnemyAttacker", "1")
		end
	end)

	local watch = _G["WCCombatInteractWatch"] or CreateFrame("Frame", "WCCombatInteractWatch")
	watch:UnregisterAllEvents()
	for _, e in ipairs({ "PLAYER_TARGET_CHANGED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }) do
		watch:RegisterEvent(e)
	end
	watch:SetScript("OnEvent", function()
		if held then C_Timer.After(0, function() if held then setInteract(true) end end) end
	end)

	local owner = _G[OWNER_NAME] or CreateFrame("Frame", OWNER_NAME)
	-- One key that does both (the player, 2026-11-10: "out of combat, no target,
	-- I press Home, no reaction"): a state driver swaps what the key is bound to,
	-- securely and in combat too. A live hostile target: the key clears it (so
	-- Blizzard turns soft interact back on). Otherwise: the key is Blizzard's own
	-- INTERACTSOFTTARGET, which loots or interacts with the nearest thing.
	local switch = _G["WCCombatInteractSwitch"]
		or CreateFrame("Frame", "WCCombatInteractSwitch", UIParent, "SecureHandlerStateTemplate")
	switch:SetAttribute("_onstate-interact", [[
		local key = self:GetAttribute("key")
		self:ClearBindings()
		if not key then return end
		if newstate == "clear" then
			self:SetBindingClick(true, key, "WCCombatInteract", "LeftButton")
		elseif newstate == "back" then
			self:SetBindingClick(true, key, "WCCombatInteractBack", "LeftButton")
		elseif newstate == "corpse" then
			-- the hard target is a dead mob: Blizzard keeps soft interact off for
			-- it (UnitCanAttack is true of a corpse; traced), so interact with it
			self:SetBinding(true, key, "INTERACTTARGET")
		elseif newstate == "none" then
			-- in combat, nothing lootable picked yet: Home does nothing, so it
			-- never opens a chest mid-fight (it cannot: "Ability is not ready")
		else
			self:SetBinding(true, key, "INTERACTSOFTTARGET")
		end
		self:CallMethod("Trace", "state " .. tostring(newstate))
	]])

	-- Trace (the player, 2026-11-10: in combat the second press does not loot).
	-- What the second press depends on, each time it may change: the key's
	-- state, the target, Blizzard's SoftTargetInteract, and whether a lootable
	-- soft interact target exists and is in range. Kept in
	-- WowCompanionDB.interact.trace (newest last, 60 lines), read from disk on
	-- the PC after a reload. Insecure, read only, everything under pcall.
	local function snap()
		local function v(fn, ...) local ok, r = pcall(fn, ...) return ok and tostring(r) or "err" end
		return ("combat=%s tgt=%s harm=%s dead=%s cvar=%s soft=%s obj=%s range=%s loot=%s name=%s"):format(
			v(InCombatLockdown), v(UnitExists, "target"), v(UnitCanAttack, "player", "target"),
			v(UnitIsDead, "target"), v(C_CVar.GetCVar, "SoftTargetInteract"),
			v(UnitExists, "softinteract"), v(UnitIsGameObject, "softinteract"),
			v(UnitIsInInteractRange, "softinteract"), v(UnitHasLootInteraction, "softinteract"),
			v(UnitName, "softinteract"))
	end
	local function trace(what)
		pcall(function()
			local d = db()
			d.trace = d.trace or {}
			-- GetTime for ordering: its fraction does not line up with date()'s seconds
			d.trace[#d.trace + 1] = ("%s %.3f %s | %s"):format(date("%H:%M:%S"),
				GetTime(), what, snap())
			while #d.trace > 60 do table.remove(d.trace, 1) end
		end)
	end
	function switch:Trace(what) trace(what) end
	local tracer = _G["WCCombatInteractTrace"] or CreateFrame("Frame", "WCCombatInteractTrace")
	tracer:UnregisterAllEvents()
	for _, e in ipairs({ "PLAYER_TARGET_CHANGED", "PLAYER_SOFT_INTERACT_CHANGED", "PLAYER_REGEN_DISABLED",
		"PLAYER_REGEN_ENABLED", "UI_ERROR_MESSAGE", "LOOT_READY", "LOOT_OPENED", "LOOT_CLOSED", "CVAR_UPDATE" }) do
		pcall(tracer.RegisterEvent, tracer, e)
	end
	tracer:SetScript("OnEvent", function(_, event, a, b)
		if event == "CVAR_UPDATE" and a ~= "SoftTargetInteract" then return end
		trace(event .. (a and (" " .. tostring(a)) or "") .. (b and (" " .. tostring(b)) or ""))
	end)
	button:HookScript("OnClick", function(_, _, down) trace("Home clicked (clear) " .. (down and "down" or "up")) end)
	back:HookScript("OnClick", function() trace("Home clicked (back)") end)

	-- Tap mode (the player, 2026-11-10; the default): one Home press, down and up.
	-- Blizzard's own gamepad interact button (GamepadMainActionBarFrame, top bar,
	-- Right.ActionButton1) resolves on release what to do, lootable soft interact
	-- first (MainActionBarFrame.lua interactActions), or at 0.5 s held. /click
	-- reaches it from a macro (SlashCommands.lua CLICK passes up or down). So:
	--   down: in a fight with a live enemy targeted, keep it in focus and target
	--         yourself, so Blizzard turns soft interact on (it is a secure CVar:
	--         nothing else can), then press Blizzard's interact button down;
	--   up:   let Blizzard's interact button go (it loots the corpse soft interact
	--         picked by now, measured 0.1 s after targeting yourself), then put
	--         the enemy back as target and let focus go.
	-- A secure action button acts on one edge only (SecureTemplates.lua), so a
	-- wrapper picks the edge and the attribute set for each press.
	local tap = _G["WCCombatInteractTap"] or CreateFrame("Button", "WCCombatInteractTap", UIParent, "SecureActionButtonTemplate")
	tap:RegisterForClicks("AnyDown", "AnyUp")
	local tapHeader = _G["WCCombatInteractTapHeader"]
		or CreateFrame("Frame", "WCCombatInteractTapHeader", UIParent, "SecureHandlerBaseTemplate")
	local function interactButtonName()
		local ok, name = pcall(function()
			return GamepadMainActionBarFrame:GetActionBars().topBar.Right.ActionButton1:GetName()
		end)
		return ok and name or nil
	end
	local function setupTap()
		if InCombatLockdown() then return false end
		local name = interactButtonName()
		if not name then say("Blizzard's gamepad interact button was not found") return false end
		tap:SetAttribute("type-dn", "macro")
		tap:SetAttribute("macrotext-dn", "/focus [combat,@target,harm,nodead]\n/target [combat,@target,harm,nodead] player\n/click " .. name .. " LeftButton true")
		tap:SetAttribute("type-up", "macro")
		tap:SetAttribute("macrotext-up", "/click " .. name .. " LeftButton false\n/target [combat,@focus,harm,nodead] focus\n/clearfocus [combat,@focus,exists]")
		if not tap.wcWrapped then
			tap.wcWrapped = true
			SecureHandlerWrapScript(tap, "OnClick", tapHeader, [[
				self:SetAttribute("useOnKeyDown", down and true or false)
				return down and "dn" or "up"
			]])
			tap:HookScript("OnClick", function(_, b, down) trace("Home " .. (down and "down" or "up") .. " (" .. tostring(b) .. ")") end)
		end
		db().tapButton = name
		return true
	end

	local function bindAll()
		if InCombatLockdown() then return false end
		ClearOverrideBindings(owner)
		local d = db()
		switch:SetAttribute("key", d.key)
		UnregisterStateDriver(switch, "interact")
		ClearOverrideBindings(switch)
		if d.key and (d.mode or "tap") == "tap" and setupTap() then
			SetOverrideBindingClick(owner, true, d.key, "WCCombatInteractTap", "LeftButton")
		elseif d.key then RegisterStateDriver(switch, "interact", "[@softinteract,dead] take; [@target,dead] corpse; [combat,@target,harm,nodead] clear; [combat,@focus,harm,nodead] back; [combat] none; take") end
		if d.takeKey then SetOverrideBinding(owner, false, d.takeKey, "INTERACTSOFTTARGET") end
		applyMode()
		return true
	end

	local function describe(key)
		local action = key and GetBindingAction(key) or ""
		return action ~= "" and action or "nothing"
	end

	SLASH_WCCOMBATINTERACT1 = "/wci"
	SlashCmdList.WCCOMBATINTERACT = function(msg)
		local cmd, arg, extra = (msg or ""):match("^%s*(%S*)%s*(%S*)%s*(%S*)")
		cmd, arg = cmd:lower(), arg:upper()
		local d = db()
		if InCombatLockdown() and cmd ~= "status" and cmd ~= "" then
			say("not in combat: bindings cannot change until it ends")
			return
		end
		if cmd == "bind" or cmd == "take" then
			if arg == "" then say("which key? e.g. /wci " .. cmd .. " PADRSTICK") return end
			local before = describe(arg)
			local ours = (arg == d.key or arg == d.takeKey)
			if before ~= "nothing" and not ours and extra:lower() ~= "force" then
				say(("%s already does %s: add 'force' to take it anyway"):format(arg, before))
				return
			end
			if cmd == "bind" then d.key = arg else d.takeKey = arg end
			bindAll()
			say(("%s is now %s (was %s)"):format(arg,
				cmd == "bind" and "hold for combat interact" or "take the soft target", before))
		elseif cmd == "unbind" then
			d.key, d.takeKey = nil, nil
			ClearOverrideBindings(owner)
			UnregisterStateDriver(switch, "interact")
			ClearOverrideBindings(switch)
			blizzardRule()
			say("unbound; the keys do what they did before")
		elseif cmd == "mode" then
			if arg ~= "HOLD" and arg ~= "CLEAR" and arg ~= "TAP" then say("mode is tap, hold or clear") return end
			d.mode = arg:lower()
			bindAll()
			say("mode " .. d.mode)
		else
			say(("key %s, take key %s, mode %s; SoftTargetInteract now %s"):format(
				tostring(d.key or "unbound"), tostring(d.takeKey or "none"), tostring(d.mode),
				tostring(C_CVar.GetCVar("SoftTargetInteract"))))
		end
	end

	-- the binding survives a reload once chosen
	local login = CreateFrame("Frame")
	login:RegisterEvent("PLAYER_LOGIN")
	login:SetScript("OnEvent", function()
		if db().key or db().takeKey then
			if not bindAll() then WC.AfterCombat(bindAll) end
		end
	end)

	WC.CombatInteract = { Status = function() SlashCmdList.WCCOMBATINTERACT("status") end }
end
