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
-- /wci bind <KEY> [force]   take a key (refused if bound, unless force)
-- /wci unbind               give it back
-- /wci trace on|off         record targets, soft interact and loot events to
--                           WowCompanionInteractDB.trace (60 lines), for debugging
-- /wci status
WC.Saved("WowCompanion_Interact", "WowCompanionInteractDB")
do
	local function db()
		WowCompanionInteractDB = WowCompanionInteractDB or {}
		local d = WowCompanionInteractDB
		-- saved fields nothing reads are cleared
		d.mode, d.takeKey, d.holdTested, d.tapMoved = nil, nil, nil, nil
		if not d.traceOn then d.trace = nil end
		return d
	end

	local function say(text)
		print("|cffffd100combat interact:|r " .. text)
	end

	-- the trace, off unless asked for: insecure, read only, under pcall
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
		if not db().traceOn then return end
		pcall(function()
			local d = db()
			d.trace = d.trace or {}
			d.trace[#d.trace + 1] = ("%s %.3f %s | %s"):format(date("%H:%M:%S"), GetTime(), what, snap())
			while #d.trace > 60 do table.remove(d.trace, 1) end
		end)
	end
	local tracer = _G["WCCombatInteractTrace"] or CreateFrame("Frame", "WCCombatInteractTrace")
	local function setTrace(on)
		tracer:UnregisterAllEvents()
		if not on then return end
		for _, e in ipairs({ "PLAYER_TARGET_CHANGED", "PLAYER_SOFT_INTERACT_CHANGED", "PLAYER_REGEN_DISABLED",
			"PLAYER_REGEN_ENABLED", "UI_ERROR_MESSAGE", "LOOT_READY", "LOOT_OPENED", "LOOT_CLOSED", "CVAR_UPDATE" }) do
			pcall(tracer.RegisterEvent, tracer, e)
		end
	end
	tracer:SetScript("OnEvent", function(_, event, a, b)
		if event == "CVAR_UPDATE" and a ~= "SoftTargetInteract" then return end
		trace(event .. (a and (" " .. tostring(a)) or "") .. (b and (" " .. tostring(b)) or ""))
	end)

	-- the key's button
	local owner = _G["WCCombatInteractOwner"] or CreateFrame("Frame", "WCCombatInteractOwner")
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
		if not name then say("Blizzard's gamepad interact button was not found (is the gamepad UI on?)") return false end
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
			tap:HookScript("OnClick", function(_, _, down) trace("press " .. (down and "down" or "up")) end)
		end
		return true
	end

	local function bind()
		if InCombatLockdown() then return false end
		ClearOverrideBindings(owner)
		local d = db()
		if d.key and setup() then
			SetOverrideBindingClick(owner, true, d.key, "WCCombatInteractTap", "LeftButton")
		end
		return true
	end

	local function describe(key)
		local action = key and GetBindingAction(key) or ""
		return action ~= "" and action or "nothing"
	end

	SLASH_WCCOMBATINTERACT1 = "/wci"
	SlashCmdList.WCCOMBATINTERACT = function(msg)
		local cmd, arg, extra = (msg or ""):match("^%s*(%S*)%s*(%S*)%s*(%S*)")
		cmd = cmd:lower()
		local d = db()
		if cmd == "trace" then
			d.traceOn = arg:lower() ~= "off"
			if d.traceOn then d.trace = {} end
			setTrace(d.traceOn)
			say("trace " .. (d.traceOn and "on (WowCompanionInteractDB.trace, saved at a reload)" or "off"))
			return
		end
		if (cmd == "bind" or cmd == "unbind") and InCombatLockdown() then
			say("bindings cannot change until the fight ends")
			return
		end
		if cmd == "bind" then
			arg = arg:upper()
			if arg == "" then say("which key? e.g. /wci bind PADSYSTEM") return end
			local before = describe(arg)
			if before ~= "nothing" and arg ~= d.key and extra:lower() ~= "force" then
				say(("%s already does %s: add 'force' to take it anyway"):format(arg, before))
				return
			end
			d.key = arg
			bind()
			say(("%s now loots or interacts, in combat too (was %s)"):format(arg, before))
		elseif cmd == "unbind" then
			d.key = nil
			ClearOverrideBindings(owner)
			say("unbound; the key does what it did before")
		else
			say(("key %s, trace %s"):format(tostring(d.key or "unbound"), d.traceOn and "on" or "off"))
		end
	end

	-- the binding survives a reload once chosen
	local login = CreateFrame("Frame")
	login:RegisterEvent("PLAYER_LOGIN")
	login:SetScript("OnEvent", function()
		local d = db()
		setTrace(d.traceOn)
		if d.key and not bind() then WC.AfterCombat(bind) end
	end)

	WC.CombatInteract = { Status = function() SlashCmdList.WCCOMBATINTERACT("status") end }
end
