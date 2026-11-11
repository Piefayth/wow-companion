-- WowCompanion_Agent: the Companion window in a fight.
-- What this needs from Agent.lua comes through WC.Companion; what it
-- offers, the other files reach through WC.Companion.stow.

-- The window in combat (the player, 2026-11-10: "randomly disappearing and
-- sometimes showing up in combat is completely useless"). A secure button
-- inside a frame makes that frame protected, and a protected frame cannot be
-- shown or hidden by an addon mid-fight: that was the whole mess. So the
-- window's secure buttons (the offered press, Reload) are stowed in a hidden
-- holder of their own as combat begins (PLAYER_REGEN_DISABLED runs just before
-- the lockdown, the last moment protected frames can move), which leaves the
-- window an ordinary frame: a tap opens and closes it all fight long. They go
-- back when the fight ends, and a window opened mid-fight becomes a panel again
-- so the controller's focus cycle reaches it.
local stowed = {}
local extraStowed = {}
local stash = CreateFrame("Frame", "WowCompanionStash", UIParent)
stash:Hide()
local combatNote
local function noteCombat(inCombat)
	local frame = WC.Companion.built()
	if not frame then return end
	if not combatNote then
		combatNote = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		combatNote:SetPoint("BOTTOM", frame, "BOTTOM", 0, 14)
		combatNote:SetText("In combat: reading only. Buttons come back when the fight ends.")
	end
	combatNote:SetShown(inCombat and true or false)
end
local stowWatch = CreateFrame("Frame")
stowWatch:RegisterEvent("PLAYER_REGEN_DISABLED")
stowWatch:RegisterEvent("PLAYER_REGEN_ENABLED")
stowWatch:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_REGEN_DISABLED" then
		for button in pairs(stowed) do
			pcall(function()
				button:ClearAllPoints()
				button:SetParent(stash)
				button:SetPoint("CENTER")
			end)
		end
		-- anything else secure inside the window (a button another file added)
		-- would keep it protected and bring back the vanishing: stow those too,
		-- with their anchors
		local frame = WC.Companion.built()
		local function walk(f)
			for _, child in ipairs({ f:GetChildren() }) do
				if child:IsProtected() and not stowed[child] then
					local points = {}
					for i = 1, child:GetNumPoints() do points[i] = { child:GetPoint(i) } end
					local parent = child:GetParent()
					local ok = pcall(function()
						child:ClearAllPoints()
						child:SetParent(stash)
						child:SetPoint("CENTER")
					end)
					if ok then extraStowed[child] = { parent = parent, points = points } end
				else
					walk(child)
				end
			end
		end
		if frame then pcall(walk, frame) end
		noteCombat(true)
		return
	end
	for button, restore in pairs(stowed) do pcall(restore, button) end
	for child, was in pairs(extraStowed) do
		pcall(function()
			child:SetParent(was.parent)
			child:ClearAllPoints()
			for _, pt in ipairs(was.points) do child:SetPoint(unpack(pt)) end
		end)
	end
	wipe(extraStowed)
	noteCombat(false)
end)
-- button: a secure button that lives in the window; restore(button) puts it back
local function stow(button, restore)
	stowed[button] = restore
	if InCombatLockdown() then
		-- built mid-fight cannot happen (secure buttons are built out of combat),
		-- but say so rather than leave the window protected without knowing
		WC.Link.say("stow: " .. tostring(button:GetName()) .. " registered in combat")
	end
end

WC.Companion.stow = stow
