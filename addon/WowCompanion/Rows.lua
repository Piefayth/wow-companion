-- Settings rows the controller reaches the way Blizzard's Settings do: each row
-- is one stop; while the cursor is on it, d-pad left and right change its
-- value (a slider steps, a dropdown cycles its choices); confirm opens a
-- dropdown's menu; up and down move between rows.
--
-- Nothing of ours runs from the navigation. A frame of our own polls which row
-- the cursor is on (its button's highlight is locked while it is the cursor's)
-- and binds left and right with override bindings of its own, set and cleared
-- out of combat only (cleared as a fight starts). The same poll lights the row
-- under the cursor or the mouse, in a fight too. The window's legend shows the
-- row's prompt (WC.RowPrompt).
--
--   WC.RowStop(button, step, prompt)  step(-1 | 1) changes the value (nil: a
--                                     row with nothing to step, left and right
--                                     do nothing); prompt is the legend's word
--                                     ("Adjust", "Change"); button.OnRowFocus(),
--                                     when set, runs as the cursor arrives;
--                                     button.OnRowLit(on), when set, as the
--                                     cursor or the mouse comes and goes
--   WC.RowPrompt(window)              the legend's words while a row in window
--                                     has the cursor, else nil

local rows = {}
local current -- the row the left and right keys change now, or nil
local keys = CreateFrame("Frame", "WCRowKeys", UIParent)

local less = CreateFrame("Button", "WCRowLess", UIParent)
less:SetScript("OnClick", function() if current and current.rowStep then current.rowStep(-1) end end)
local more = CreateFrame("Button", "WCRowMore", UIParent)
more:SetScript("OnClick", function() if current and current.rowStep then current.rowStep(1) end end)

local function focused()
	for _, row in ipairs(rows) do
		if row:IsVisible() and row:IsHighlightLocked() then return row end
	end
end

local function bind(row)
	if row == current then return end
	current = row
	if row and row.OnRowFocus then row.OnRowFocus() end
	ClearOverrideBindings(keys)
	if row then
		SetOverrideBindingClick(keys, true, "PADDLEFT", "WCRowLess")
		SetOverrideBindingClick(keys, true, "PADDRIGHT", "WCRowMore")
	end
end

-- the cursor's row, else the one the mouse is over
local lit
local function under()
	local row = focused()
	if row then return row end
	for _, r in ipairs(rows) do
		if r:IsVisible() and r:IsMouseOver() then return r end
	end
end
local function light(row)
	if row == lit then return end
	if lit and lit.OnRowLit then lit.OnRowLit(false) end
	lit = row
	if row and row.OnRowLit then row.OnRowLit(true) end
end

local since = 0
keys:SetScript("OnUpdate", function(_, elapsed)
	since = since + elapsed
	if since < 0.05 then return end
	since = 0
	light(under())
	if not InCombatLockdown() then bind(focused()) end
end)
-- the bindings go before the lockdown takes them out of reach
keys:RegisterEvent("PLAYER_REGEN_DISABLED")
keys:SetScript("OnEvent", function() bind(nil) end)

function WC.RowStop(button, step, prompt)
	button.rowStep, button.rowPrompt = step, prompt
	rows[#rows + 1] = button
	WC.MarkFocusable(button)
	return button
end

function WC.RowPrompt(window)
	local row = current
	if not (row and row.rowStep and window) then return end
	local parent = row:GetParent()
	while parent and parent ~= window do parent = parent:GetParent() end
	if parent then
		return WowCompanion_Glyph("PADDLEFT") .. WowCompanion_Glyph("PADDRIGHT") .. " " .. (row.rowPrompt or "Change")
	end
end
